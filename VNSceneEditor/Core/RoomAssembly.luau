-- JSON-only room definitions. No Instances, sampled frames, or source geometry.
local HttpService = game:GetService("HttpService")
local Assembly = {}
Assembly.RECIPES = { "Hinge Fold", "Drop and Settle", "Rise and Unfold", "Slide and Rebound", "Swing and Settle", "Static Reveal" }
Assembly.ROLES = { "Floor", "Wall", "Ceiling", "Furniture", "Fixture", "Decoration" }
local function number(value, fallback, low, high)
	local n = tonumber(value)
	if not n or n ~= n or math.abs(n) == math.huge then n = fallback end
	return math.clamp(n, low, high)
end
local function choice(value, values, fallback)
	return table.find(values, value) and value or fallback
end
function Assembly.id() return "assembly_" .. HttpService:GenerateGUID(false):gsub("-", "") end
function Assembly.copy(value)
	if type(value) ~= "table" then return value end
	local result = {}
	for k, v in pairs(value) do result[k] = Assembly.copy(v) end
	return result
end
function Assembly.vector(raw, default)
	raw = type(raw) == "table" and raw or {}
	default = default or { 0, 0, 0 }
	return { number(raw[1], default[1], -10000, 10000), number(raw[2], default[2], -10000, 10000), number(raw[3], default[3], -10000, 10000) }
end
function Assembly.motion(raw)
	raw = type(raw) == "table" and raw or {}
	local function curve(v)
		v = type(v) == "table" and v or {}
		return { number(v[1], 0.22, 0, 1), number(v[2], 0, -2, 3), number(v[3], 0.35, 0, 1), number(v[4], 1, -2, 3) }
	end
	return {
		recipe = choice(raw.recipe, Assembly.RECIPES, "Drop and Settle"),
		start = number(raw.start, 0, 0, 120), duration = number(raw.duration, 1, 0.05, 30),
		anticipation = number(raw.anticipation, 0.06, 0, 0.3), impact = number(raw.impact, 0.7, 0.35, 0.9),
		distance = number(raw.distance, 8, -500, 500), angle = number(raw.angle, 85, -720, 720),
		axis = choice(raw.axis, { "X", "Y", "Z" }, "X"), direction = Assembly.vector(raw.direction, { 0, 1, 0 }),
		rotation = Assembly.vector(raw.rotation),
		overshoot = number(raw.overshoot, 0.06, 0, 1), wobble = number(raw.wobble, 4, 0, 90),
		settleStyle = choice(raw.settleStyle, { "Bounce", "Wobble" }, "Bounce"),
		frequency = number(raw.frequency, 2, 0.1, 12), damping = number(raw.damping, 4, 0, 20),
		moveCurve = curve(raw.moveCurve), rotateCurve = curve(raw.rotateCurve),
	}
end

function Assembly.edgeFade(raw)
	raw = type(raw) == "table" and raw or {}
	return {
		id = type(raw.id) == "string" and raw.id ~= "" and raw.id or Assembly.id(),
		face = choice(raw.face, { "Top", "Bottom", "Left", "Right", "Front", "Back" }, "Front"),
		edge = choice(raw.edge, { "Left", "Right", "Top", "Bottom" }, "Bottom"),
		width = number(raw.width, 2, 0.05, 1000),
		opacity = number(raw.opacity, 0.94, 0, 1),
	}
end

function Assembly.group(name, reference)
	return { id = Assembly.id(), name = name or "Component", role = "Furniture", parentId = "", reference = reference,
		required = true, pivot = { 0, 0, 0 }, motion = Assembly.motion(),
		sync = { groupId = "", marker = "Impact", offset = 0 }, panels = { x = 1, z = 1, stagger = 0.04, mirror = true }, edgeFades = {} }
end
function Assembly.new(name)
	return { id = Assembly.id(), name = name or "Room Assembly", groups = {}, hideReferences = {}, sounds = {},
		camera = { duration = 2.5, offset = { 0, 1, 6 }, rotation = { 0, 0, 0 }, fovOffset = 0 }, backdrop = false,
		variationSeed = 0 }
end
function Assembly.normalize(raw)
	raw = type(raw) == "table" and raw or {}
	local result = Assembly.new(type(raw.name) == "string" and raw.name or nil)
	result.id = type(raw.id) == "string" and raw.id ~= "" and raw.id or result.id
	local seen = {}
	for _, source in ipairs(type(raw.groups) == "table" and raw.groups or {}) do
		if type(source) == "table" then
			local g = Assembly.group(type(source.name) == "string" and source.name or nil, type(source.reference) == "table" and Assembly.copy(source.reference) or nil)
			g.id = type(source.id) == "string" and source.id ~= "" and source.id or g.id
			if seen[g.id] then g.id = Assembly.id() end
			seen[g.id] = true
			g.role = choice(source.role, Assembly.ROLES, "Furniture")
			g.parentId = type(source.parentId) == "string" and source.parentId or ""
			g.required = source.required ~= false
			g.pivot = Assembly.vector(source.pivot)
			g.motion = Assembly.motion(source.motion)
			local sync = type(source.sync) == "table" and source.sync or {}
			g.sync = { groupId = type(sync.groupId) == "string" and sync.groupId or "", marker = choice(sync.marker, { "Start", "Impact", "Settled" }, "Impact"), offset = number(sync.offset, 0, -120, 120) }
			local panels = type(source.panels) == "table" and source.panels or {}
			g.panels = { x = math.floor(number(panels.x, 1, 1, 16)), z = math.floor(number(panels.z, 1, 1, 16)), stagger = number(panels.stagger, 0.04, 0, 2), mirror = panels.mirror ~= false }
			local fadeIds = {}
			for _, rawFade in ipairs(type(source.edgeFades) == "table" and source.edgeFades or {}) do
				local fade = Assembly.edgeFade(rawFade)
				if fadeIds[fade.id] then fade.id = Assembly.id() end
				fadeIds[fade.id] = true
				table.insert(g.edgeFades, fade)
			end
			table.insert(result.groups, g)
		end
	end
	local camera = type(raw.camera) == "table" and raw.camera or {}
	result.camera = { duration = number(camera.duration, 2.5, 0.05, 120), offset = Assembly.vector(camera.offset, { 0, 1, 6 }), rotation = Assembly.vector(camera.rotation), fovOffset = number(camera.fovOffset, 0, -40, 40) }
	result.backdrop = raw.backdrop == true
	result.variationSeed = math.floor(number(raw.variationSeed, 0, 0, 2147483647))
	for _, ref in ipairs(type(raw.hideReferences) == "table" and raw.hideReferences or {}) do
		if type(ref) == "table" then table.insert(result.hideReferences, Assembly.copy(ref)) end
	end
	for _, cue in ipairs(type(raw.sounds) == "table" and raw.sounds or {}) do
		if type(cue) == "table" then table.insert(result.sounds, { time = number(cue.time, 0, 0, 120), assetId = tostring(cue.assetId or ""), volume = number(cue.volume, 0.5, 0, 2) }) end
	end
	return result
end
function Assembly.normalizeList(raw)
	local list, seen = {}, {}
	for _, value in ipairs(type(raw) == "table" and raw or {}) do
		if type(value) == "table" then
			local definition = Assembly.normalize(value)
			if seen[definition.id] then definition.id = Assembly.id() end
			seen[definition.id] = true
			table.insert(list, definition)
		end
	end
	return list
end
function Assembly.normalizePresets(raw)
	local list = Assembly.normalizeList(raw)
	for _, preset in ipairs(list) do
		preset.hideReferences = {}
		for _, group in ipairs(preset.groups) do group.reference = nil end
	end
	return list
end
-- Role choreography is saved as ordinary editable data, never rerandomized.
function Assembly.generate(definition)
	local counts = {}
	local starts = { Floor = 0, Wall = 0.25, Ceiling = 0.6, Furniture = 0.8, Fixture = 1.3, Decoration = 1.4 }
	for _, g in ipairs(definition.groups) do
		local i = counts[g.role] or 0
		counts[g.role] = i + 1
		local m = Assembly.motion()
		m.start = (starts[g.role] or 0.8) + i * 0.08
		m.duration = g.role == "Fixture" and 1.1 or 0.95
		if g.role == "Floor" or g.role == "Wall" then m.recipe = "Hinge Fold"; m.distance = 0; m.wobble = 2
		elseif g.role == "Fixture" then m.recipe = "Swing and Settle"; m.angle = 18; m.distance = 0
		elseif g.role == "Decoration" then m.recipe = "Rise and Unfold"; m.distance = 3; m.angle = 15
		else m.angle = 5; m.wobble = 3 end
		g.motion = m
		g.sync = { groupId = "", marker = "Impact", offset = 0 }
	end
	definition.variationSeed = 0
end

-- A variation is intentionally modest and written into the ordinary motion data.
-- It is not random at playback time, so a room remains deterministic after saving.
function Assembly.randomize(definition, seed)
	Assembly.generate(definition)
	seed = tonumber(seed)
	if not seed or seed <= 0 then seed = Random.new():NextInteger(1, 2147483646) end
	seed = math.floor(seed)
	seed = math.clamp(seed, 1, 2147483646)
	local random = Random.new(seed)
	for _, group in ipairs(definition.groups) do
		local motion = group.motion
		motion.start = math.max(0, motion.start + random:NextNumber(-0.065, 0.065))
		motion.duration = math.max(0.05, motion.duration * random:NextNumber(0.91, 1.09))
		motion.overshoot = math.max(0, motion.overshoot + random:NextNumber(-0.018, 0.026))
		motion.wobble = math.max(0, motion.wobble * random:NextNumber(0.88, 1.14))
		if motion.distance ~= 0 then motion.distance *= random:NextNumber(0.88, 1.12) end
		if motion.angle ~= 0 then motion.angle *= random:NextNumber(0.9, 1.1) end
	end
	definition.variationSeed = seed
	return seed
end

-- Copying an assembly must not preserve IDs that can be used as cross-definition
-- references. Rebuild the parent and synchronization graph around fresh IDs.
function Assembly.duplicate(definition, name)
	local copy = Assembly.normalize(Assembly.copy(definition))
	copy.id = Assembly.id()
	copy.name = name or (copy.name .. " copy")
	local ids = {}
	for _, group in ipairs(copy.groups) do
		local old = group.id
		group.id = Assembly.id()
		ids[old] = group.id
	end
	for _, group in ipairs(copy.groups) do
		group.parentId = ids[group.parentId] or ""
		group.sync.groupId = ids[group.sync.groupId] or ""
	end
	return copy
end
function Assembly.template(definition, name)
	local copy = Assembly.normalize(definition)
	copy.id = Assembly.id(); copy.name = name or definition.name
	copy.hideReferences = {}
	for _, g in ipairs(copy.groups) do g.reference = nil end
	return copy
end
function Assembly.applyTemplate(definition, template)
	local used, mapping, matched = {}, {}, {}
	for _, g in ipairs(definition.groups) do
		for i, source in ipairs(template.groups) do
			if source.role == g.role and not used[i] then
				used[i] = true; g.motion = Assembly.copy(source.motion); g.panels = Assembly.copy(source.panels)
				mapping[source.id] = g.id; matched[g.id] = source; break
			end
		end
	end
	local compiled = require(script.Parent.Parent.Runtime.AssemblyEvaluator).compile(template)
	for _, g in ipairs(definition.groups) do
		local source = matched[g.id]
		if source then
			g.sync = Assembly.copy(source.sync)
			g.sync.groupId = mapping[source.sync.groupId] or ""
			if source.sync.groupId ~= "" and g.sync.groupId == "" then
				-- Preserve the resolved timing if this room lacks the cue's role.
				g.motion.start = compiled and compiled.groups[source.id].start or source.motion.start
			end
		end
	end
	definition.camera = Assembly.copy(template.camera)
end
return Assembly
