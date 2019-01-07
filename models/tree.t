local prob = require("prob.prob")
local S = require("qs.lib.std")
local LVec3 = require("linalg.luavec")(3)
local treelib = require("models.treelib")

local flip = prob.flip
local uniform = prob.uniform
local gaussian = prob.gaussian

---------------------------------------------------------------

return S.memoize(function(makeGeoPrim, geoRes)

	local T = treelib(makeGeoPrim, geoRes)

	local origradius
	local function branch(frame, depth, prev)
		-- if depth > 2 then return end
		local finished = false
		local i = 0
		repeat
			-- Kill things that get too small to matter
			if frame.radius/origradius < 0.1 then break end

			local uprot = gaussian(0, math.pi/12)
			local leftrot = gaussian(0, math.pi/12)
			local len = uniform(3, 5) * frame.radius
			local endradius = uniform(0.7, 0.9) * frame.radius

			-- Figure out where we need to split the segment
			-- (This is so the part that we branch from is a pure conic section)
			local nextframe = T.advanceFrame(frame, uprot, leftrot, len, endradius)
			local splitFrame = T.findSplitFrame(frame, nextframe)

			-- Place geometry
			T.treeSegment(T.N_SEGS, prev, frame, splitFrame, nextframe)

			if flip(T.branchProb(depth, i)) then
				-- Theta mean/variance based on avg weighted by 'up-facing-ness'
				local theta_mu, theta_sigma = T.estimateThetaDistrib(splitFrame, nextframe)
				local theta = gaussian(theta_mu, theta_sigma)
				local maxbranchradius = 0.5*(nextframe.center - splitFrame.center):norm()
				local branchradius = math.min(uniform(0.9, 1) * nextframe.radius, maxbranchradius)
				local bframe, prev = T.branchFrame(splitFrame, nextframe, 0.5, theta, branchradius, T.N_SEGS)
				branch(bframe, depth+1, prev)
			end
			-- local finished = true
			local finished = flip(1-T.continueProb(i))
			-- local finished = endradius < 0.2
			i = i + 1
			frame = nextframe
			-- 'Blank' this out, since it only matters for the first segment in a branch
			prev = nil
		until finished
	end

	return function()
		local startFrame = {
			center = LVec3.new(0, 0, 0),
			forward = LVec3.new(0, 1, 0),
			up = LVec3.new(0, 0, -1),
			radius = uniform(1.5, 2),
			v = 0
		}
		origradius = startFrame.radius
		branch(startFrame, 0, nil)
	end
end)



