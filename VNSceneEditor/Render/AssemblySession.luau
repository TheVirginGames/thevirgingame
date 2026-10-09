-- Owns ALL temporary state for one preview/runtime assembly. Construction is
-- transactional: validate first, then clone, then hide. close() is idempotent.
local Workspace = game:GetService("Workspace")
local SoundService = game:GetService("SoundService")
local Debris = game:GetService("Debris")
local CollectionService = game:GetService("CollectionService")
local Bindings = require(script.Parent.WorldBindings)
local Evaluator = require(script.Parent.Parent.Runtime.AssemblyEvaluator)
local Session = {}
Session.__index = Session
local function vector(v) return Vector3.new(v[1], v[2], v[3]) end
local function partsOf(instance)
	local parts = {}
	if instance:IsA("BasePart") then table.insert(parts, instance) end
	for _, item in ipairs(instance:GetDescendants()) do if item:IsA("BasePart") then table.insert(parts, item) end end
	return parts
end
local function property(item)
	if item:IsA("BasePart") then return "LocalTransparencyModifier", 1 end
	if item:IsA("Decal") or item:IsA("Texture") then return "Transparency", 1 end
	if item:IsA("LayerCollector") then return "Enabled", false end
	if item:IsA("Light") or item:IsA("ParticleEmitter") or item:IsA("Beam") or item:IsA("Trail") or item:IsA("Smoke") or item:IsA("Fire") or item:IsA("Sparkles") then return "Enabled", false end
	return nil
end
local function appearance(root)
	local list = {}
	local items = root:GetDescendants(); table.insert(items, root)
	for _, item in ipairs(items) do
		local key, hidden = property(item)
		if key then table.insert(list, { item = item, key = key, value = item[key], hidden = hidden }) end
	end
	return list
end
local function visible(list, show)
	for _, entry in ipairs(list) do
		if entry.item.Parent then entry.item[entry.key] = if show then entry.value else entry.hidden end
	end
end
local function sanitize(part)
	for _, item in ipairs(part:GetDescendants()) do
		if item:IsA("SurfaceGui") and item:GetAttribute("VNAssemblyEdgeFade") == true then
			-- Cloned SurfaceGuis otherwise retain their source-part Adornee.
			item.Adornee = part
		elseif item:IsA("BasePart") or item:IsA("LuaSourceContainer") or item:IsA("JointInstance") or item:IsA("Constraint")
			or item:IsA("ClickDetector") or item:IsA("ProximityPrompt") or item:IsA("Sound")
			or item:IsA("Humanoid") or (item:IsA("LayerCollector") and item:GetAttribute("VNAssemblyEdgeFade") ~= true) then item:Destroy() end
	end
	part.Anchored = true; part.CanCollide = false; part.CanTouch = false; part.CanQuery = false
	part:SetAttribute("VNInteractableId", nil); part:SetAttribute("VNCharacterPlacementId", nil)
	part:SetAttribute("VNAssemblyId", nil)
	for _, tag in ipairs(CollectionService:GetTags(part)) do CollectionService:RemoveTag(part, tag) end
end
function Session.create(definition, rig, destination, options)
	local compiled, compileError = Evaluator.compile(definition)
	if not compiled then return nil, compileError end
	options = options or {}
	local self = setmetatable({ compiled = compiled, rig = rig, pieces = {}, sources = {}, originals = {}, pivots = {}, states = {}, sourceSeen = {}, sourceGroup = {}, groupSource = {}, selectionHighlights = {}, time = 0, sounds = {}, warnings = {}, cameraDriven = options.cameraDriven ~= false }, Session)
	local resolved, claimed = {}, {}
	for _, node in ipairs(compiled.order) do
		local g = node.data
		if g.reference then
			local source, err = Bindings.resolveStrict(g.reference)
			if not source then
				-- A stale/ambiguous binding must never leave the assembly workspace
				-- unusable. Keep the remaining components previewable and expose the
				-- broken entry through Validate/Rebind instead of rejecting the whole
				-- visual session (including a group marked Required).
				table.insert(self.warnings, g.name .. ": " .. tostring(err) .. "; skipped for this preview")
			else
				if source:FindFirstChildWhichIsA("Humanoid", true) or source:GetAttribute("VNCharacterPlacementId") then return nil, g.name .. ": characters belong to the character layer" end
				if source:FindFirstChildWhichIsA("LuaSourceContainer", true) then return nil, g.name .. ": select static geometry without scripts" end
				local ancestor = source.Parent
				while ancestor and ancestor ~= Workspace do
					if ancestor:FindFirstChildOfClass("Humanoid") or ancestor.Name == "VNPlacedCharacters" then return nil, g.name .. ": cannot assemble character parts" end
					ancestor = ancestor.Parent
				end
				local parts = partsOf(source)
				if #parts == 0 then return nil, g.name .. ": no geometry" end
				-- A definition can accidentally contain both a Model/Folder and one
				-- of its descendant parts (the marquee picker made that particularly
				-- easy).  That is overlapping geometry, not a fatal renderer error.
				-- The first component owns the visual copy; later overlapping entries
				-- remain editable virtual/group nodes and are reported as warnings.
				local usable, owners = {}, {}
				for _, part in ipairs(parts) do
					if not part.Anchored then return nil, g.name .. ": unanchored parts are not supported" end
					if not part.Archivable then return nil, g.name .. ": part is not Archivable" end
					local owner = claimed[part]
					if owner then
						owners[owner] = (owners[owner] or 0) + 1
					else
						table.insert(usable, part)
					end
				end
				local hasOrdinaryGui = false
				for _, descendant in ipairs(source:GetDescendants()) do
					if descendant:IsA("LayerCollector") and descendant:GetAttribute("VNAssemblyEdgeFade") ~= true then
						hasOrdinaryGui = true
						break
					end
				end
				if hasOrdinaryGui then
					table.insert(self.warnings, g.name .. ": world GUI is hidden during assembly and restored on completion.")
				end
				local subdivisions = g.panels.x * g.panels.z > 1
				-- Splitting only part of an overlapping component would hide geometry
				-- owned by another component.  Safely skip this duplicate instead.
				if #usable < #parts and subdivisions then usable = {} end
				if #usable < #parts then
					local labels = {}
					for owner, count in pairs(owners) do table.insert(labels, owner .. " (" .. count .. ")") end
					table.sort(labels)
					local suffix = subdivisions and "; skipped because panel subdivisions require exclusive geometry" or ""
					table.insert(self.warnings, g.name .. ": overlaps geometry already owned by " .. table.concat(labels, ", ") .. suffix)
				end
				if #usable > 0 then
					for _, part in ipairs(usable) do
						claimed[part] = g.name
						table.insert(self.originals, { part = part, cframe = part.CFrame, size = part.Size })
					end
				end
				if subdivisions then
					if #usable > 0 and (#usable ~= 1 or not source:IsA("Part") or source.Shape ~= Enum.PartType.Block) then return nil, g.name .. ": subdivision requires one rectangular Part" end
					for _, child in ipairs(source:GetChildren()) do
						if #usable > 0 then
							if (child:IsA("Decal") and not child:IsA("Texture")) or child:IsA("DataModelMesh") or child:IsA("SurfaceAppearance") then return nil, g.name .. ": prepare separate pieces for decals/meshes" end
							if child:IsA("Light") or child:IsA("Attachment") or child:IsA("ParticleEmitter") then return nil, g.name .. ": move fixtures/effects to separate components before subdivision" end
						end
					end
				end
				resolved[g.id] = { source = source, parts = usable }
			end
		end
	end
	local extra = {}
	for _, reference in ipairs(definition.hideReferences) do
		local source, err = Bindings.resolveStrict(reference)
		if not source then return nil, "Additional hidden object: " .. tostring(err) end
		table.insert(extra, source)
	end
	self.folder = Instance.new("Folder"); self.folder.Name = "VNRoomAssembly"
	local ok, err = pcall(function()
		for _, node in ipairs(compiled.order) do
			local g, record = node.data, resolved[node.data.id]
			local rest = CFrame.identity
			if record then
				local source = record.source
				-- Folders have no pivot and a skipped overlapping component has no
				-- owned parts.  In that case inherit the parent/destination pivot so
				-- the entry stays a harmless organizational group in the evaluator.
				rest = source:IsA("PVInstance") and source:GetPivot()
					or (record.parts[1] and record.parts[1].CFrame)
					or self.pivots[g.parentId]
					or destination
				self.pivots[g.id] = rest * CFrame.new(vector(g.pivot))
				for _, part in ipairs(record.parts) do
					self.sourceGroup[part] = g.id
					self.groupSource[g.id] = self.groupSource[g.id] or record.source
					for _, entry in ipairs(appearance(part)) do
						if not self.sourceSeen[entry.item] then self.sourceSeen[entry.item] = true; table.insert(self.sources, entry) end
					end
					for x = 1, g.panels.x do for z = 1, g.panels.z do
						local clone = part:Clone(); sanitize(clone)
						local subdivided = g.panels.x * g.panels.z > 1
						local offset = Vector3.new((x-0.5) / g.panels.x - 0.5, 0, (z-0.5) / g.panels.z - 0.5) * part.Size
						clone.Size = Vector3.new(part.Size.X / g.panels.x, part.Size.Y, part.Size.Z / g.panels.z)
						local final = part.CFrame * CFrame.new(offset)
						clone.CFrame = final
						-- Preserve repeating texture phase when splitting a panel.
						for _, texture in ipairs(clone:GetChildren()) do
							if texture:IsA("Texture") then
								local face = texture.Face
								local dx = offset.X + (part.Size.X-clone.Size.X)*0.5
								local dz = offset.Z + (part.Size.Z-clone.Size.Z)*0.5
								texture.OffsetStudsU += (face == Enum.NormalId.Left or face == Enum.NormalId.Right) and dz or dx
								if face == Enum.NormalId.Top or face == Enum.NormalId.Bottom then texture.OffsetStudsV += dz end
							end
						end
						clone.Parent = self.folder
						local sign = g.panels.mirror and x > g.panels.x/2 and -1 or 1
						local motion = table.clone(g.motion); motion.angle *= sign
						local hinge = g.motion.axis == "Z" and Vector3.new(-sign * clone.Size.X/2, 0, 0) or Vector3.new(0, 0, -sign * clone.Size.Z/2)
						table.insert(self.pieces, { clone = clone, final = final, group = g.id, appearance = appearance(clone), subdivided = subdivided,
							pivot = final * CFrame.new(hinge), motion = motion, index = (x-1)*g.panels.z+z-1 })
					end end
				end
			else
				self.pivots[g.id] = (self.pivots[g.parentId] or destination) * CFrame.new(vector(g.pivot))
			end
		end
		for _, source in ipairs(extra) do
			for _, entry in ipairs(appearance(source)) do
				if not self.sourceSeen[entry.item] then self.sourceSeen[entry.item] = true; table.insert(self.sources, entry) end
			end
		end
		self.destination = destination
		if self.cameraDriven then self.lease = assert(rig:acquireLease()) end
		self.fov = self.lease and self.lease.fov or (Workspace.CurrentCamera and Workspace.CurrentCamera.FieldOfView or 70)
		self.folder.Parent = Workspace
		if definition.backdrop and #self.pieces > 0 then
			local minimum, maximum = Vector3.new(math.huge, math.huge, math.huge), Vector3.new(-math.huge, -math.huge, -math.huge)
			for _, piece in ipairs(self.pieces) do
				local r = piece.clone.Size.Magnitude / 2 + 20
				local p = piece.final.Position
				minimum = minimum:Min(p - Vector3.one*r); maximum = maximum:Max(p + Vector3.one*r)
			end
			local size, center = maximum-minimum, (maximum+minimum)/2
			for axis = 1, 3 do for _, sign in ipairs({ -1, 1 }) do
				local wall = Instance.new("Part"); wall.Name = "AssemblyBackdrop"; sanitize(wall)
				wall.Color = Color3.fromRGB(12, 12, 16); wall.Material = Enum.Material.SmoothPlastic
				local dimensions = { size.X, size.Y, size.Z }; dimensions[axis] = 1
				local offsets = { 0, 0, 0 }; offsets[axis] = ({ size.X, size.Y, size.Z })[axis]*sign/2
				wall.Size = Vector3.new(unpack(dimensions)); wall.CFrame = CFrame.new(center + Vector3.new(unpack(offsets))); wall.Parent = self.folder
			end end
		end
		visible(self.sources, false)
		self:seek(0)
	end)
	if not ok then self:close(true); return nil, tostring(err) end
	return self
end
function Session:pieceState(piece, time, states)
	local node = self.compiled.groups[piece.group]
	local state = states[piece.group]
	local delta, show = state.delta, state.visible
	if piece.subdivided then
		local localDelta, localShow = Evaluator.motion(piece.motion, time-node.start-piece.index*node.data.panels.stagger)
		local parent = states[node.data.parentId]
		delta = (parent and parent.delta or CFrame.identity) * piece.pivot * localDelta * piece.pivot:Inverse()
		show = localShow and (not parent or parent.visible)
	end
	return delta, show
end

-- Source geometry is deliberately still ray-queryable while visually hidden.
-- This maps a clicked descendant back to the one component that owns it.
function Session:groupForInstance(instance)
	local current = instance
	while current and current ~= Workspace do
		local groupId = self.sourceGroup[current]
		if groupId then return groupId end
		current = current.Parent
	end
	return nil
end

function Session:setSelectedGroup(groupId)
	if self.selectedVisualGroup == groupId then return end
	self.selectedVisualGroup = groupId
	for _, highlight in ipairs(self.selectionHighlights) do highlight:Destroy() end
	table.clear(self.selectionHighlights)
	if not groupId then return end
	local function belongsToSelection(candidateId)
		local current, seen = candidateId, {}
		while current and current ~= "" and not seen[current] do
			if current == groupId then return true end
			seen[current] = true
			local node = self.compiled.groups[current]
			current = node and node.data.parentId or ""
		end
		return false
	end
	for _, piece in ipairs(self.pieces) do
		if belongsToSelection(piece.group) and piece.clone.Parent then
			local highlight = Instance.new("Highlight")
			highlight.Name = "VNAssemblySelection"
			highlight.Adornee = piece.clone
			highlight.FillColor = Color3.fromRGB(255, 196, 84)
			highlight.FillTransparency = 0.86
			highlight.OutlineColor = Color3.fromRGB(255, 224, 142)
			highlight.OutlineTransparency = 0
			highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
			highlight.Parent = self.folder
			table.insert(self.selectionHighlights, highlight)
		end
	end
end

-- Lets the editor compare the animated construction against the authored room
-- without destroying/rebuilding the session. This is preview-only state.
function Session:setCompareFinal(enabled)
	enabled = enabled == true
	if self.compareFinal == enabled then return end
	self.compareFinal = enabled
	visible(self.sources, enabled)
	for _, piece in ipairs(self.pieces) do
		if piece.clone.Parent then visible(piece.appearance, not enabled) end
	end
	if enabled and self.cameraDriven then
		self.rig:setCFrame(self.destination, self.lease)
		if Workspace.CurrentCamera then Workspace.CurrentCamera.FieldOfView = self.fov end
	end
end
function Session:seek(time, playSounds)
	if self.closed then return end
	if self.compareFinal then self:setCompareFinal(false) end
	for _, original in ipairs(self.originals) do
		if not original.part:IsDescendantOf(Workspace) or original.part.CFrame ~= original.cframe or original.part.Size ~= original.size then
			error("Room geometry changed or streamed out during assembly; restoring the ordinary room.")
		end
	end
	time = math.clamp(time, 0, self.compiled.duration)
	local states = Evaluator.sample(self.compiled, time, self.pivots, self.states)
	for _, piece in ipairs(self.pieces) do
		local node = self.compiled.groups[piece.group]
		local delta, show = self:pieceState(piece, time, states)
		if self.soloGroup then
			local group = node.data
			while group and group.id ~= self.soloGroup and group.parentId ~= "" do group = self.compiled.groups[group.parentId].data end
			show = show and group ~= nil and group.id == self.soloGroup
		end
		piece.clone.CFrame = delta * piece.final
		if show ~= piece.visible then visible(piece.appearance, show); piece.visible = show end
	end
	if self.cameraDriven then
		local pose, fov = Evaluator.camera(self.compiled, time, self.destination, self.fov)
		self.rig:setCFrame(pose, self.lease)
		if Workspace.CurrentCamera then Workspace.CurrentCamera.FieldOfView = fov end
	end
	self:setSelectedGroup(self.selectedGroup)
	if playSounds then
		for _, cue in ipairs(self.compiled.definition.sounds) do
			local previous = self.soundTime or (self.time == 0 and -0.0001 or self.time)
			if cue.time > previous and cue.time <= time and cue.assetId ~= "" then
				local sound = Instance.new("Sound"); sound.SoundId = "rbxassetid://" .. (cue.assetId:match("%d+") or "0")
				sound.Volume = cue.volume; sound.Parent = SoundService; sound:Play(); Debris:AddItem(sound, 30)
				table.insert(self.sounds, sound)
			end
		end
	end
	self.soundTime = if time == 0 then nil else time
	self.time = time
end
function Session:close(restoreCamera)
	if self.closed then return end
	self.closed = true
	self.compareFinal = false
	visible(self.sources, true)
	if self.folder then self.folder:Destroy() end
	for _, sound in ipairs(self.sounds) do sound:Destroy() end
	if self.lease then self.rig:releaseLease(self.lease, restoreCamera) end
end
return Session
