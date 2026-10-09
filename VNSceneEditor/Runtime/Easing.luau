-- Named easing curves shared by tracks, durational events and textbox anims.
-- Names match Schema.EASINGS.

local TweenService = game:GetService("TweenService")

local Easing = {}

local styles = {
	Linear = Enum.EasingStyle.Linear,
	Quad = Enum.EasingStyle.Quad,
	Cubic = Enum.EasingStyle.Cubic,
	Quart = Enum.EasingStyle.Quart,
	Sine = Enum.EasingStyle.Sine,
	Back = Enum.EasingStyle.Back,
	Bounce = Enum.EasingStyle.Bounce,
	Elastic = Enum.EasingStyle.Elastic,
}

function Easing.style(name)
	return styles[name] or Enum.EasingStyle.Quad
end

-- Progress 0..1 mapped through the named curve (InOut direction).
function Easing.alpha(name, t)
	t = math.clamp(t, 0, 1)

	local ok, result = pcall(function()
		return TweenService:GetValue(t, Easing.style(name), Enum.EasingDirection.InOut)
	end)

	if ok then
		return result
	end

	return t
end

-- Out direction, used for element in-animations.
function Easing.alphaOut(name, t)
	t = math.clamp(t, 0, 1)

	local ok, result = pcall(function()
		return TweenService:GetValue(t, Easing.style(name), Enum.EasingDirection.Out)
	end)

	if ok then
		return result
	end

	return t
end

-- Fraction of a tween that has elapsed given its start on a local clock.
function Easing.progress(localTime, start, duration)
	if not duration or duration <= 0 then
		return 1
	end

	return math.clamp((localTime - (start or 0)) / duration, 0, 1)
end

return Easing
