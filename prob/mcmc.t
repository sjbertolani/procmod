local LS = require("std")
local trace = require("prob.trace")
local distrib = require("prob.distrib")


-- Bookkeeping to help us tell whether an MH-run is replaying still-valid trace or is
--    generating new trace.
local propVarIndex = -1
local function setPropVarIndex(i)
	propVarIndex = i
end
local function unsetPropVarIndex()
	propVarIndex = -1
end
local function isReplaying()
	local nextVarIndex = trace.nextVarIndex()
	if nextVarIndex then
		return nextVarIndex <= propVarIndex
	else
		return false
	end
	-- return false
end



-- An MH chain
local MHChain = LS.LObject()

function MHChain:init(program, args, temp)
	self.temp = temp or 1
	self.trace = trace.StructuredERPTrace.alloc():init(program, unpack(args))
	self.trace:rejectionSample()
	return self
end

function MHChain:copy(other)
	self.temp = other.temp
	self.trace = other.trace:newcopy()
	return self
end

-- Returns true if step was an accepted proposal, false otherwise.
function MHChain:step(depthBiasedVarSelect)
	-- Copy the trace
	local newtrace = self.trace:newcopy()
	-- Select a variable at random, propose change
	local recs = newtrace:records()

	local randidx
	local fwdVarChoiceProb
	if not depthBiasedVarSelect then
		randidx = math.ceil(math.random()*#recs)
		fwdVarChoiceProb = -math.log(#recs)
	else
		local weights = {}
		for _,rec in ipairs(recs) do
			table.insert(weights, math.exp(-rec.depth))
		end
		randidx = distrib.multinomial.sample(weights)
		fwdVarChoiceProb = distrib.multinomial.logprob(randidx, weights)
	end

	local rec = recs[randidx]
	local oldval = rec.value
	local fwdlp, rvslp = rec:propose()
	-- print("\n!! Proposing to change var #"..tostring(rec.index).." from "..tostring(oldval).." to "..tostring(rec.value))
	fwdlp = fwdlp + fwdVarChoiceProb
	-- Re-run trace to propagate changes
	setPropVarIndex(rec.index)
	newtrace.propVarIndex = rec.index
	newtrace:run()
	unsetPropVarIndex()
	fwdlp = fwdlp + newtrace.newlogprob
	recs = newtrace:records()

	local rvsVarChoiceProb
	if not depthBiasedVarSelect then
		rvsVarChoiceProb = -math.log(#recs)
	else
		local weights = {}
		for _,rec in ipairs(recs) do
			table.insert(weights, math.exp(-rec.depth))
		end
		rvsVarChoiceProb = distrib.multinomial.logprob(randidx, weights)
	end

	rvslp = rvslp + rvsVarChoiceProb + newtrace.oldlogprob
	-- Accept/reject
	local oldlp = self.trace.logprior + (self.trace.loglikelihood)/self.temp
	local newlp = newtrace.logprior + (newtrace.loglikelihood)/self.temp
	local accept = math.log(math.random()) < newlp - oldlp + rvslp - fwdlp
	if accept then
		-- print("!! ACCEPT !!")
		self.trace:freeMemory()
		self.trace = newtrace
	else
		-- print("!! REJECT !!")
		newtrace:freeMemory()
	end
	return accept
end


-- Do lightweight MH
-- Options are:
--    * nSamples: how many samples to collect?
--    * timeBudget: how long to run for before terminating? (overrules nSamples)
--    * lag: How many iterations between collected samples?
--    * verbose: print verbose output
--    * onSample: Callback that says what to do with the trace every time a sample is reached
--    * temp: Temperature to divide the log posterior by when calculating accept/reject
--    * depthBiasedVarSelect: If false, select proposal site uniformly at random. If true, select
--         proportional to depth in program trace.
local function MH(program, args, opts)
	-- Extract options
	local nSamples = opts.nSamples or 1000
	local timeBudget = opts.timeBudget
	local lag = opts.lag or 1
	local verbose = opts.verbose
	local onSample = opts.onSample or function() end
	local temp = opts.temp or 1
	local depthBiasedVarSelect = opts.depthBiasedVarSelect
	local iters = lag*nSamples

	trace.StructuredERPTrace.clearTraceReplayTime()

	-- Initialize with a complete trace of nonzero probability
	local chain = MHChain.alloc():init(program, args, temp)
	-- Do MH loop
	local numAccept = 0
	local t0 = terralib.currenttimeinseconds()
	local itersdone = 0
	for i=1,iters do
		-- Do a proposal step
		local accept = chain:step(depthBiasedVarSelect)
		if accept then numAccept = numAccept + 1 end
		-- Do something with the sample
		if i % lag == 0 then
			onSample(chain.trace)
			if verbose then
				io.write(string.format("Done with sample %u/%u\r", i/lag, nSamples))
				io.flush()
			end
		end
		itersdone = itersdone + 1
		-- Maybe terminate, if we're on a time budget
		if timeBudget then
			local t = terralib.currenttimeinseconds()
			if t - t0 >= timeBudget then
				break
			end
		end
	end
	if verbose then
		local t1 = terralib.currenttimeinseconds()
		io.write("\n")
		print("Acceptance ratio:", numAccept/itersdone)
		print("Time:", t1 - t0)
		local trp = trace.StructuredERPTrace.getTraceReplayTime()
		print(string.format("Time spent on trace replay: %g (%g%%)",
			trp, 100*(trp/(t1-t0))))
	end
end


-- Do lightweight MH with parallel tempering (sequential implementation)
-- Options are:
--    * nSamples: how many samples to collect?
--    * timeBudget: how long to run for before terminating? (overrules nSamples)
--    * lag: How many iterations between collected samples?
--    * verbose: print verbose output
--    * onSample: Callback that says what to do with the trace every time a sample is reached
--    * temps: List of temperatures, one per MCMC chain (these should be in order).
--    * tempSwapInterval: Number of iterations between chain temperature swap proposals.
--    * depthBiasedVarSelect: If false, select proposal site uniformly at random. If true, select
--         proportional to depth in program trace.
local function MHPT(program, args, opts)
	-- Extract options
	local nSamples = opts.nSamples or 1000
	local timeBudget = opts.timeBudget
	local lag = opts.lag or 1
	local verbose = opts.verbose
	local onSample = opts.onSample or function() end
	local temps = opts.temps or {1, 1}	-- This'll do no tempering
	local tempSwapInterval = opts.tempSwapInterval or 1
	local depthBiasedVarSelect = opts.depthBiasedVarSelect
	local iters = lag*nSamples

	trace.StructuredERPTrace.clearTraceReplayTime()

	-- Initialize chains (have to initialize them all as copies,
	--    in case any of the args need copying)
	local chains = {}
	for i,temp in ipairs(temps) do
		local chain
		if i == 1 then
			chain = MHChain.alloc():init(program, args, temp)
		else
			chain = MHChain.alloc():copy(chains[1])
			chain.temp = temp
		end
		table.insert(chains, chain)
	end
	-- Do MH loop
	local numAccept = 0
	local numTempSwapAccept = 0
	local t0 = terralib.currenttimeinseconds()
	local itersdone = 0
	local tempSwapsDone = 0
	local function mainloop()
		while itersdone ~= iters do
			-- Advance all chains up to the temp swap point
			for _,chain in ipairs(chains) do
				for i=1,tempSwapInterval do
					local accept = chain:step(depthBiasedVarSelect)
					if accept then numAccept = numAccept + 1 end
					-- Do something with the sample
					if itersdone % lag == 0 then
						onSample(chain.trace)
						if verbose then
							io.write(string.format("Done with sample %u/%u\r", itersdone/lag, nSamples))
							io.flush()
						end
					end
					itersdone = itersdone + 1
					-- Terminate if we've reached the last iter
					if itersdone == iters then
						return
					end
					-- Terminate if we've used up our time budget
					if timeBudget then
						local t = terralib.currenttimeinseconds()
						if t - t0 >= timeBudget then
							return
						end
					end
				end
			end
			-- Pick a random chain index for temperature swap
			local randidx = math.floor(1 + (#chains-1)*math.random())
			local chain1 = chains[randidx]
			local chain2 = chains[randidx+1]
			local thresh = (chain1.trace.logposterior/chain2.temp + chain2.trace.logposterior/chain1.temp) -
						   (chain1.trace.logposterior/chain1.temp + chain2.trace.logposterior/chain2.temp)
			local accept = math.log(math.random()) < thresh
			if accept then
				local tmp = chain1.temp
				chain1.temp = chain2.temp
				chain2.temp = tmp
				numTempSwapAccept = numTempSwapAccept + 1
			end
			tempSwapsDone = tempSwapsDone + 1
		end
	end
	mainloop()
	if verbose then
		local t1 = terralib.currenttimeinseconds()
		io.write("\n")
		print("Acceptance ratio:", numAccept/itersdone)
		print("Temp swap acceptance ratio:", numTempSwapAccept/tempSwapsDone)
		print("Time:", t1 - t0)
		local trp = trace.StructuredERPTrace.getTraceReplayTime()
		print(string.format("Time spent on trace replay: %g (%g%%)",
			trp, 100*(trp/(t1-t0))))
	end
end

return
{
	MH = MH,
	MHPT = MHPT,
	isReplaying = isReplaying
}



