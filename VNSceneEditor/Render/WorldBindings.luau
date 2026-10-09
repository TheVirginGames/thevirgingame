-- Connects scene interactions to the 3D world.
--
-- Targets have a project-persisted Workspace path plus a transient
-- "VNInteractableId" tag/attribute used by fast mouse raycasts. The path is
-- authoritative because client changes to a world's attributes do not survive
-- a Studio play-session reset. Room3D scenes raycast the mouse each frame and
-- click to fire. Explore3D hotspots use the same click model within a short
-- range.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local HttpService = game:GetService("HttpService")

local Signal = require(script.Parent.Parent.Core.Signal)

local WorldBindings = {}
WorldBindings.__index = WorldBindings

WorldBindings.TAG = "VNInteractable"
WorldBindings.ATTRIBUTE = "VNInteractableId"
WorldBindings.CHARACTER_PLACEMENT_ATTRIBUTE = "VNCharacterPlacementId"
WorldBindings.CHARACTER_INTERACTION_ATTRIBUTE = "VNHotspotInteractionId"
WorldBindings.EXPLORE_HOTSPOT_RANGE = 7

local controlsModule = nil

local function getControls()
	if controlsModule then
		return controlsModule
	end

	local ok, result = pcall(function()
		local player = Players.LocalPlayer
		local scripts = player:WaitForChild("PlayerScripts", 5)
		local module = scripts and scripts:FindFirstChild("PlayerModule")
		if not module then
			return nil
		end
		return require(module):GetControls()
	end)

	-- PlayerScripts can be unavailable during early startup or a respawn. Do not
	-- cache that temporary failure; a later phase change can acquire controls.
	if ok and result then
		controlsModule = result
	end
	return controlsModule
end

function WorldBindings.setPlayerControls(enabled)
	local controls = getControls()
	if not controls then
		return
	end

	if enabled then
		controls:Enable()
	else
		controls:Disable()
	end
end

local function encodeWorldPosition(position)
	return string.format("%.4f,%.4f,%.4f", position.X, position.Y, position.Z)
end

local function decodeWorldPosition(text)
	if type(text) ~= "string" then return nil end
	local x, y, z = text:match("^%s*([%+%-]?[%d%.]+),%s*([%+%-]?[%d%.]+),%s*([%+%-]?[%d%.]+)%s*$")
	x, y, z = tonumber(x), tonumber(y), tonumber(z)
	return x and y and z and Vector3.new(x, y, z) or nil
end

local function worldPositionOf(instance)
	if instance:IsA("BasePart") then
		return instance.Position
	end
	if instance:IsA("Model") then
		local ok, pivot = pcall(function() return instance:GetPivot() end)
		return ok and pivot.Position or nil
	end
	return nil
end

local function childAt(parent, name, className, ordinal, worldPosition)
	local matches = {}
	for _, child in ipairs(parent:GetChildren()) do
		if child.Name == name and (className == "" or child.ClassName == className) then
			table.insert(matches, child)
		end
	end

	if #matches == 0 then return nil end
	local expectedPosition = decodeWorldPosition(worldPosition)
	if expectedPosition then
		local nearest = nil
		local nearestDistance = math.huge
		for _, child in ipairs(matches) do
			local position = worldPositionOf(child)
			if position then
				local distance = (position - expectedPosition).Magnitude
				if distance < nearestDistance then
					nearest = child
					nearestDistance = distance
				end
			end
		end
		if nearest then return nearest end
	end

	return matches[ordinal]
end

-- A name/class path plus each part/model's saved world position survives the
-- ordinary cloning that happens when Studio begins a playtest. The ordinal is
-- retained only as a legacy fallback when a path segment has no position.
function WorldBindings.referenceFor(instance)
	if not instance or not instance:IsDescendantOf(Workspace) then return nil end
	local path = {}
	local current = instance
	while current and current ~= Workspace do
		local parent = current.Parent
		if not parent then return nil end
		local ordinal = 0
		for _, sibling in ipairs(parent:GetChildren()) do
			if sibling.Name == current.Name and sibling.ClassName == current.ClassName then
				ordinal += 1
				if sibling == current then break end
			end
		end
		if ordinal == 0 then return nil end
		local segment = { name = current.Name, className = current.ClassName, ordinal = ordinal }
		local position = worldPositionOf(current)
		if position then
			segment.worldPosition = encodeWorldPosition(position)
		end
		table.insert(path, 1, segment)
		current = parent
	end
	return current == Workspace and { path = path } or nil
end

function WorldBindings.resolveReference(reference)
	if type(reference) ~= "table" or type(reference.path) ~= "table" or #reference.path == 0 then
		return nil
	end
	local current = Workspace
	for _, segment in ipairs(reference.path) do
		if type(segment) ~= "table" or type(segment.name) ~= "string" then return nil end
		current = childAt(
			current,
			segment.name,
			type(segment.className) == "string" and segment.className or "",
			tonumber(segment.ordinal) or 1,
			segment.worldPosition
		)
		if not current then return nil end
	end
	return current
end

-- Assembly must never silently choose a similarly named structural component.
-- Position disambiguates legacy paths only when it uniquely identifies a part.
function WorldBindings.resolveStrict(reference)
	if type(reference) ~= "table" or type(reference.path) ~= "table" or #reference.path == 0 then
		return nil, "Missing world reference"
	end
	if reference.durableId then
		local found
		for _, item in ipairs(Workspace:GetDescendants()) do
			if item:GetAttribute("VNAssemblyId") == reference.durableId then
				if found then
					-- A copied world object can retain an attribute. Fall through to
					-- the recorded hierarchy instead of making the whole assembly
					-- impossible to preview.
					found = nil
					break
				end
				found = item
			end
		end
		if found then return found end
		-- Attributes written during a local playtest may not persist back to the
		-- authored place. The saved path/ordinal remains a valid fallback on the
		-- next test run.
	end
	local current = Workspace
	for _, segment in ipairs(reference.path) do
		if type(segment) ~= "table" then return nil, "Invalid reference path" end
		local candidates = {}
		for _, child in ipairs(current:GetChildren()) do
			if child.Name == segment.name and child.ClassName == segment.className then table.insert(candidates, child) end
		end
		if #candidates == 0 then return nil, "Missing object: " .. tostring(segment.name) end
		if #candidates > 1 then
			local expected = decodeWorldPosition(segment.worldPosition)
			local matches = {}
			if expected then
				for _, child in ipairs(candidates) do
					local position = worldPositionOf(child)
					if position and (position - expected).Magnitude < 0.05 then table.insert(matches, child) end
				end
			end
			if #matches == 1 then
				current = matches[1]
			else
				-- A hierarchy ordinal is recorded when the component is picked. It
				-- is deterministic across ordinary playtest clones and is the only
				-- useful fallback when intentionally stacked/named-identically
				-- parts share the same world position. Keep durable IDs preferred,
				-- but do not make a valid saved assembly unopenable here.
				local ordinal = math.floor(tonumber(segment.ordinal) or 0)
				local fallback = ordinal > 0 and candidates[ordinal] or nil
				if not fallback then return nil, "Ambiguous object: " .. tostring(segment.name) end
				current = fallback
			end
		else current = candidates[1] end
	end
	return current
end

function WorldBindings.assignAssemblyId(instance)
	if not instance then return nil end
	local durableId = instance:GetAttribute("VNAssemblyId")
	if type(durableId) ~= "string" or durableId == "" then
		durableId = "assembly_world_" .. HttpService:GenerateGUID(false):gsub("-", "")
		instance:SetAttribute("VNAssemblyId", durableId)
	end
	return durableId
end

function WorldBindings.assemblyReferenceFor(instance, assignDurableId)
	local reference = WorldBindings.referenceFor(instance)
	local durableId = assignDurableId and WorldBindings.assignAssemblyId(instance) or instance:GetAttribute("VNAssemblyId")
	if reference and type(durableId) == "string" and durableId ~= "" then reference.durableId = durableId end
	return reference
end

function WorldBindings.resolveId(targetId)
	if not targetId or targetId == "" then return nil end
	for _, instance in ipairs(CollectionService:GetTagged(WorldBindings.TAG)) do
		if instance:GetAttribute(WorldBindings.ATTRIBUTE) == targetId then return instance end
	end
	return nil
end

function WorldBindings.resolve(targetId, targetRef)
	-- Prefer the persisted path. It prevents an old or duplicated temporary id
	-- from binding an interaction to the wrong object after a reset.
	local referenced = WorldBindings.resolveReference(targetRef)
	if referenced then
		if targetId and targetId ~= "" then WorldBindings.assignId(referenced, targetId) end
		return referenced
	end

	return WorldBindings.resolveId(targetId)
end

function WorldBindings.countForId(targetId)
	if not targetId or targetId == "" then return 0 end
	local count = 0
	for _, instance in ipairs(CollectionService:GetTagged(WorldBindings.TAG)) do
		if instance:GetAttribute(WorldBindings.ATTRIBUTE) == targetId then count += 1 end
	end
	return count
end

function WorldBindings.assignId(instance, targetId)
	instance:SetAttribute(WorldBindings.ATTRIBUTE, targetId)
	if not CollectionService:HasTag(instance, WorldBindings.TAG) then
		CollectionService:AddTag(instance, WorldBindings.TAG)
	end
end

-- Nearest tagged ancestor (or self) of a hit part.
function WorldBindings.ownerOf(instance)
	local current = instance
	while current and current ~= Workspace do
		if current:GetAttribute(WorldBindings.ATTRIBUTE) ~= nil then
			return current
		end
		current = current.Parent
	end
	return nil
end

-- Placed character clones expose their binding through attributes so regular
-- game scripts can inspect an NPC without taking a dependency on the editor.
function WorldBindings.characterPlacementIdOf(instance)
	local current = instance
	while current and current ~= Workspace do
		local placementId = current:GetAttribute(WorldBindings.CHARACTER_PLACEMENT_ATTRIBUTE)
		if placementId then return placementId end
		current = current.Parent
	end
	return nil
end

function WorldBindings.boundInteractionIdOf(instance)
	local current = instance
	while current and current ~= Workspace do
		local interactionId = current:GetAttribute(WorldBindings.CHARACTER_INTERACTION_ATTRIBUTE)
		if interactionId then return interactionId end
		current = current.Parent
	end
	return nil
end

-- Public convenience alias for gameplay scripts. Given a hit part or the
-- placed model itself, this returns the authored Hotspot id (or nil).
WorldBindings.getInteractionIdForCharacterModel = WorldBindings.boundInteractionIdOf

local function basePartsOf(instance)
	local parts = {}
	if instance:IsA("BasePart") then
		table.insert(parts, instance)
	end
	for _, descendant in ipairs(instance:GetDescendants()) do
		if descendant:IsA("BasePart") then
			table.insert(parts, descendant)
		end
	end
	return parts
end

local function distanceFromPartSurface(part, point)
	local localPoint = part.CFrame:PointToObjectSpace(point)
	local halfSize = part.Size * 0.5
	local closestLocal = Vector3.new(
		math.clamp(localPoint.X, -halfSize.X, halfSize.X),
		math.clamp(localPoint.Y, -halfSize.Y, halfSize.Y),
		math.clamp(localPoint.Z, -halfSize.Z, halfSize.Z)
	)
	local closestWorld = part.CFrame:PointToWorldSpace(closestLocal)
	return (point - closestWorld).Magnitude
end

local function distanceFromTarget(instance, point)
	if not instance then
		return math.huge
	end

	local distance = math.huge
	for _, part in ipairs(basePartsOf(instance)) do
		distance = math.min(distance, distanceFromPartSurface(part, point))
	end
	return distance
end

function WorldBindings.centerOf(instance)
	if not instance then
		return nil
	end
	if instance:IsA("BasePart") then
		return instance.Position
	end
	if instance:IsA("Model") then
		local ok, cframe = pcall(function()
			return instance:GetPivot()
		end)
		if ok then
			return cframe.Position
		end
	end
	local parts = basePartsOf(instance)
	if #parts > 0 then
		return parts[1].Position
	end
	return nil
end

-- Camera transitions need both the authored facing direction and the visual
-- bounds. A Model's pivot supplies its orientation while GetBoundingBox gives
-- a stable center/size for positioning the camera outside its geometry.
function WorldBindings.geometryOf(instance)
	if not instance then
		return nil
	end
	if instance:IsA("BasePart") then
		return instance.CFrame, instance.Position, instance.Size
	end
	if instance:IsA("Model") then
		local pivotOk, pivot = pcall(function() return instance:GetPivot() end)
		local boundsOk, boundsCFrame, size = pcall(function() return instance:GetBoundingBox() end)
		if pivotOk and boundsOk then
			return pivot, boundsCFrame.Position, size
		end
	end
	local parts = basePartsOf(instance)
	if #parts > 0 then
		local part = parts[1]
		return part.CFrame, part.Position, part.Size
	end
	return nil
end

function WorldBindings.new()
	local self = setmetatable({}, WorldBindings)

	self.mode = nil
	self.enabled = true
	self.entries = {} -- targetId -> { interaction, available, instance }
	self.connections = {}
	self.instances = {} -- transient world instances we create
	self.hoverId = nil
	self.hoverHighlight = nil
	self.touchDebounce = {}

	self.InteractionRequested = Signal.new() -- (interactionId)
	self.HoverChanged = Signal.new() -- (interactionId | nil)

	return self
end

function WorldBindings:setEnabled(enabled)
	self.enabled = enabled
	if not enabled then
		self:_setHover(nil)
	end
end

function WorldBindings:_disconnectAll()
	for _, connection in ipairs(self.connections) do
		connection:Disconnect()
	end
	table.clear(self.connections)

	for _, instance in ipairs(self.instances) do
		instance:Destroy()
	end
	table.clear(self.instances)

	self:_setHover(nil)
	if self.hoverHighlight then
		self.hoverHighlight:Destroy()
		self.hoverHighlight = nil
	end
end

function WorldBindings:clear()
	self:_disconnectAll()
	self.mode = nil
	table.clear(self.entries)
	UserInputService.MouseIconEnabled = true
end

function WorldBindings:_index(list)
	table.clear(self.entries)
	for _, item in ipairs(list or {}) do
		local interaction = item.interaction
		local regularTargetId = type(interaction.targetId) == "string" and interaction.targetId or ""
		local characterPlacementId = type(interaction.targetCharacterModelId) == "string"
			and interaction.targetCharacterModelId or ""
		if regularTargetId ~= "" or characterPlacementId ~= "" then
			-- Older picker builds could produce the same time/name-based id for
			-- different objects. A persisted path lets us repair that collision for
			-- this run without changing the authored interaction record.
			local bindingId = characterPlacementId ~= ""
				and ("character_model_" .. characterPlacementId)
				or regularTargetId
			if self.entries[bindingId] and interaction.targetRef then
				bindingId = "target_runtime_" .. interaction.id
			end
			local instance = characterPlacementId ~= ""
				and WorldBindings.resolveId(bindingId)
				or WorldBindings.resolve(regularTargetId, interaction.targetRef)
			if instance and bindingId ~= regularTargetId then
				WorldBindings.assignId(instance, bindingId)
			end
			self.entries[bindingId] = {
				interaction = interaction,
				available = item.available,
				instance = instance,
			}
		end
	end
end

function WorldBindings:getEntries()
	return self.entries
end

--------------------------------------------------------------------------------
-- Room mode: mouse raycast
--------------------------------------------------------------------------------

function WorldBindings:_setHover(targetId)
	if self.hoverId == targetId then
		return
	end

	self.hoverId = targetId

	if not self.hoverHighlight then
		self.hoverHighlight = Instance.new("Highlight")
		self.hoverHighlight.Name = "VNHover"
		self.hoverHighlight.FillTransparency = 0.7
		self.hoverHighlight.OutlineTransparency = 0
		self.hoverHighlight.FillColor = Color3.fromRGB(255, 220, 120)
		self.hoverHighlight.OutlineColor = Color3.fromRGB(255, 236, 160)
		self.hoverHighlight.Parent = Workspace
	end

	local entry = targetId and self.entries[targetId]
	if entry and entry.instance then
		self.hoverHighlight.Adornee = entry.instance
		self.hoverHighlight.Enabled = true
	else
		self.hoverHighlight.Adornee = nil
		self.hoverHighlight.Enabled = false
	end

	self.HoverChanged:Fire(entry and entry.interaction.id or nil)
end

function WorldBindings:_raycastMouse()
	local cam = Workspace.CurrentCamera
	if not cam then
		return nil
	end

	local location = UserInputService:GetMouseLocation()
	local ray = cam:ViewportPointToRay(location.X, location.Y)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude

	local character = Players.LocalPlayer and Players.LocalPlayer.Character
	params.FilterDescendantsInstances = character and { character } or {}

	local result = Workspace:Raycast(ray.Origin, ray.Direction * 500, params)
	if not result then
		return nil
	end

	local owner = WorldBindings.ownerOf(result.Instance)
	if not owner then
		return nil
	end

	return owner:GetAttribute(WorldBindings.ATTRIBUTE)
end

function WorldBindings:setRoomMode(list)
	self:_disconnectAll()
	self.mode = "Room"
	self:_index(list)
	UserInputService.MouseIconEnabled = true

	table.insert(self.connections, RunService.RenderStepped:Connect(function()
		if not self.enabled then
			return
		end

		local targetId = self:_raycastMouse()
		local entry = targetId and self.entries[targetId]
		self:_setHover(entry and entry.available and targetId or nil)
	end))

	table.insert(self.connections, UserInputService.InputBegan:Connect(function(input, processed)
		if processed or not self.enabled then
			return
		end

		if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end

		local targetId = self:_raycastMouse()
		local entry = targetId and self.entries[targetId]
		if entry and entry.available then
			self.InteractionRequested:Fire(entry.interaction.id)
		end
	end))
end

--------------------------------------------------------------------------------
-- Explore mode: range-limited hotspot clicks
--------------------------------------------------------------------------------

function WorldBindings:_exploreHotspotAvailable(entry)
	if not entry or not entry.available or entry.interaction.kind ~= "Hotspot" or not entry.instance then
		return false
	end

	local player = Players.LocalPlayer
	local character = player and player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return false
	end

	return distanceFromTarget(entry.instance, root.Position) <= WorldBindings.EXPLORE_HOTSPOT_RANGE
end

function WorldBindings:setExploreMode(list)
	self:_disconnectAll()
	self.mode = "Explore"
	self:_index(list)
	UserInputService.MouseIconEnabled = true

	table.insert(self.connections, RunService.RenderStepped:Connect(function()
		if not self.enabled then
			return
		end

		local targetId = self:_raycastMouse()
		local entry = targetId and self.entries[targetId]
		self:_setHover(self:_exploreHotspotAvailable(entry) and targetId or nil)
	end))

	table.insert(self.connections, UserInputService.InputBegan:Connect(function(input, processed)
		if processed or not self.enabled then
			return
		end

		if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end

		local targetId = self:_raycastMouse()
		local entry = targetId and self.entries[targetId]
		if self:_exploreHotspotAvailable(entry) then
			self.InteractionRequested:Fire(entry.interaction.id)
		end
	end))

end

function WorldBindings:destroy()
	self:clear()
	self.InteractionRequested:DisconnectAll()
	self.HoverChanged:DisconnectAll()
end

return WorldBindings
