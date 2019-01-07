local trace = require("prob.trace")
local future = require("prob.future")

local prob = {
	-- ERPs
	flip = trace.flip,
	uniform = trace.uniform,
	multinomial = trace.multinomial,
	gaussian = trace.gaussian,

	-- Likelihood adjustments
	factor = trace.factor,
	likelihood = trace.likelihood,

	-- Futures
	future = future,

	-- Address management
	pushAddress = trace.pushAddress,
	popAddress = trace.popAddress,
	setAddressLoopIndex = trace.setAddressLoopIndex,

	-- Misc
	throwZeroProbabilityError = trace.throwZeroProbabilityError
}

return prob