-- Keyframe sampling for portrait and background-image transforms.
--
-- A track is { target = "portrait" | "background", keys = { { t, x, y, scale, rotation, alpha, easing } } }
-- sorted by t. Sampling between two keys eases with the outgoing key's curve.

local Easing = require(script.Parent.Easing)

local Tracks = {}

Tracks.DEFAULT_PORTRAIT_TRANSFORM = { x = 0.5, y = 1, scale = 1, rotation = 0, alpha = 1 }
Tracks.DEFAULT_BACKGROUND_TRANSFORM = { x = 0.5, y = 0.5, scale = 1, rotation = 0, alpha = 1 }

local FIELDS = { "x", "y", "scale", "rotation", "alpha" }

function Tracks.defaultTransform(target)
	return table.clone(target == "background" and Tracks.DEFAULT_BACKGROUND_TRANSFORM or Tracks.DEFAULT_PORTRAIT_TRANSFORM)
end

function Tracks.sampleTrack(track, t)
	local keys = track.keys

	if #keys == 0 then
		return Tracks.defaultTransform(track.target)
	end

	if t <= keys[1].t then
		return Tracks.keyToTransform(keys[1])
	end

	local last = keys[#keys]
	if t >= last.t then
		return Tracks.keyToTransform(last)
	end

	for index = 1, #keys - 1 do
		local a = keys[index]
		local b = keys[index + 1]

		if t >= a.t and t <= b.t then
			local span = b.t - a.t
			local raw = span > 0 and (t - a.t) / span or 1
			local alpha = Easing.alpha(a.easing, raw)
			local result = {}

			for _, field in ipairs(FIELDS) do
				result[field] = a[field] + (b[field] - a[field]) * alpha
			end

			return result
		end
	end

	return Tracks.keyToTransform(last)
end

function Tracks.keyToTransform(key)
	local result = {}
	for _, field in ipairs(FIELDS) do
		result[field] = key[field]
	end
	return result
end

-- First portrait track in the list, sampled at t. nil when there are none.
function Tracks.samplePortrait(tracks, t)
	for _, track in ipairs(tracks or {}) do
		if track.target == "portrait" then
			return Tracks.sampleTrack(track, t)
		end
	end

	return nil
end

-- First background-image track in the list, sampled at t. nil when absent.
function Tracks.sampleBackground(tracks, t)
	for _, track in ipairs(tracks or {}) do
		if track.target == "background" then
			return Tracks.sampleTrack(track, t)
		end
	end

	return nil
end

function Tracks.sortKeys(track)
	table.sort(track.keys, function(a, b)
		return a.t < b.t
	end)
end

-- Insert or replace a key at time t, copying the transform.
function Tracks.setKey(track, t, transform)
	for _, key in ipairs(track.keys) do
		if math.abs(key.t - t) < 0.001 then
			for _, field in ipairs(FIELDS) do
				key[field] = transform[field]
			end
			return key
		end
	end

	local key = { t = t, easing = "Quad" }
	for _, field in ipairs(FIELDS) do
		key[field] = transform[field]
	end

	table.insert(track.keys, key)
	Tracks.sortKeys(track)
	return key
end

return Tracks
