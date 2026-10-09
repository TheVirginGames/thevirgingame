-- Pure, seekable motion. Never integrate velocity or accumulate transforms.
local Evaluator = {}
local function vector(v) return Vector3.new(v[1], v[2], v[3]) end
local function smooth(t) return t * t * (3 - 2 * t) end
local function bezier(t, a, b) return 3 * (1-t)^2 * t * a + 3 * (1-t) * t*t * b + t^3 end
local function curve(t, c)
	if t <= 0 then return 0 end
	if t >= 1 then return 1 end
	local lo, hi = 0, 1
	for _ = 1, 18 do
		local mid = (lo + hi) * 0.5
		if bezier(mid, c[1], c[3]) < t then lo = mid else hi = mid end
	end
	return bezier((lo + hi) * 0.5, c[2], c[4])
end
function Evaluator.compile(definition)
	local result = { definition = definition, groups = {}, order = {}, duration = definition.camera.duration }
	for _, group in ipairs(definition.groups) do
		if result.groups[group.id] then return nil, "Duplicate group ID: " .. group.id end
		result.groups[group.id] = { data = group }
	end
	local visiting = {}
	local function visit(id)
		local node = result.groups[id]
		if not node then error("Missing parent or timing group: " .. id) end
		if node.start then return node end
		if visiting[id] then error("Circular parent/timing dependency at " .. node.data.name) end
		visiting[id] = true
		local g = node.data
		if g.parentId ~= "" then visit(g.parentId) end
		local start = g.motion.start
		if g.sync.groupId ~= "" then
			local source = visit(g.sync.groupId)
			local marker = g.sync.marker == "Start" and 0 or (g.sync.marker == "Impact" and source.data.motion.duration * source.data.motion.impact or source.length)
			start = source.start + marker + g.sync.offset
		end
		if start < 0 then error("Negative start time: " .. g.name) end
		node.start = start
		node.length = g.motion.duration + (g.panels.x * g.panels.z - 1) * g.panels.stagger
		result.duration = math.max(result.duration, start + node.length)
		visiting[id] = nil
		table.insert(result.order, node)
		return node
	end
	local ok, err = pcall(function() for _, g in ipairs(definition.groups) do visit(g.id) end end)
	if not ok then return nil, tostring(err) end
	return result
end
-- Scalar channels are separately testable without a Roblox world.
function Evaluator.channels(m, time)
	if time < 0 then return 0, 0, 0, false end
	if time >= m.duration or m.recipe == "Static Reveal" then return 0, 0, 0, true end
	local u = time / m.duration
	local t = math.clamp((u - m.anticipation) / (m.impact - m.anticipation), 0, 1)
	local move, turn = 1 - curve(t, m.moveCurve), 1 - curve(t, m.rotateCurve)
	if u < m.anticipation and m.anticipation > 0 then
		local anticipation = math.sin(math.pi * u / m.anticipation) * 0.035
		move += anticipation; turn += anticipation
	end
	local settle = math.clamp((u - m.impact) / (1 - m.impact), 0, 1)
	local envelope = math.exp(-m.damping * settle) * (1 - smooth(settle))
	local wave = math.sin(settle * math.pi * 2 * m.frequency) * envelope
	-- An angular wobble is an optional lightweight-prop treatment. Rigid room
	-- pieces use the ordinary overshoot above instead: it rebounds along the
	-- actual fold/travel direction, so walls do not look as though they twist
	-- independently after reaching their final orientation.
	local wobbleLead = math.min(0.18, (m.impact - m.anticipation) * 0.32)
	local wobbleStart = math.max(m.anticipation, m.impact - wobbleLead)
	local wobbleLength = math.min(0.34, 1 - wobbleStart)
	local wobbleTime = math.clamp((u - wobbleStart) / math.max(0.001, wobbleLength), 0, 1)
	local wobbleEnvelope = math.exp(-m.damping * wobbleTime * 0.45) * (1 - smooth(wobbleTime))
	local wobbleWave = math.sin(wobbleTime * math.pi * math.max(1, m.frequency)) * wobbleEnvelope
	if u >= m.impact then move = -m.overshoot * wave; turn = -m.overshoot * wave end
	local distance = m.distance * move
	local angle: number = m.angle * turn
	if m.recipe == "Hinge Fold" then distance = 0
	elseif m.recipe == "Rise and Unfold" then distance = -distance
	elseif m.recipe == "Swing and Settle" then
		distance = 0
		angle = m.angle * math.cos(u * math.pi * 2 * m.frequency) * math.exp(-m.damping * u) * (1-smooth(u))
	end
	if m.settleStyle == "Wobble" and u >= wobbleStart then angle += m.wobble * wobbleWave end
	return distance, angle, turn, true
end
function Evaluator.motion(m, time)
	local distance, angle, turn, visible = Evaluator.channels(m, time)
	if not visible or time >= m.duration or m.recipe == "Static Reveal" then return CFrame.identity, visible end
	local direction = vector(m.direction)
	if direction.Magnitude > 0 then direction = direction.Unit end
	local offset = direction * distance
	local axis = m.axis == "X" and Vector3.xAxis or (m.axis == "Y" and Vector3.yAxis or Vector3.zAxis)
	local r = vector(m.rotation or { 0, 0, 0 }) * math.pi / 180
	local orientation = CFrame.identity:Lerp(CFrame.Angles(r.X, r.Y, r.Z), turn)
	return CFrame.new(offset) * orientation * CFrame.fromAxisAngle(axis, math.rad(angle)), visible
end
-- bindings[id] is a world-space rest pivot. Deltas compose in parent order.
function Evaluator.sample(compiled, time, bindings, output)
	local states = output or {}
	for _, node in ipairs(compiled.order) do
		local g = node.data
		local pivot = bindings[g.id] or CFrame.identity
		local delta, visible = Evaluator.motion(g.motion, time - node.start)
		local parent = states[g.parentId]
		local state = states[g.id] or {}
		state.delta = (parent and parent.delta or CFrame.identity) * pivot * delta * pivot:Inverse()
		state.visible = visible and (not parent or parent.visible)
		states[g.id] = state
	end
	return states
end
function Evaluator.camera(compiled, time, destination, fov)
	local c = compiled.definition.camera
	local remaining = 1 - smooth(math.clamp(time / c.duration, 0, 1))
	local rotation = vector(c.rotation) * math.pi / 180
	local opening = CFrame.new(vector(c.offset)) * CFrame.Angles(rotation.X, rotation.Y, rotation.Z)
	return destination * CFrame.identity:Lerp(opening, remaining), math.clamp(fov + c.fovOffset * remaining, 1, 120)
end
return Evaluator
