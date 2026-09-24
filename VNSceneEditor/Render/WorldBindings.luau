-- Connects scene interactions to the 3D world.
--
-- Targets are instances tagged "VNInteractable" with a string attribute
-- "VNInteractableId" (the WorldPicker assigns both). Room3D scenes raycast the
-- mouse each frame and click to fire; Explore3D scenes attach ProximityPrompts
-- to hotspots and Touched handlers to triggers and exits.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Signal = require(script.Parent.Parent.Core.Signal)

local WorldBindings = {}
WorldBindings.__index = WorldBindings

WorldBindings.TAG = "VNInteractable"
WorldBindings.ATTRIBUTE = "VNInteractableId"

local controlsModule = nil

local function getControls()
	if controlsModule ~= nil then
		return controlsModule or nil
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

	controlsModule = ok and result or false
	return controlsModule or nil
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

function WorldBindings.resolve(targetId)
	if not targetId or targetId == "" then
		return nil
	end

	for _, instance in ipairs(CollectionService:GetTagged(WorldBindings.TAG)) do
		if instance:GetAttribute(WorldBindings.ATTRIBUTE) == targetId then
			return instance
		end
	end

	return nil
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

function WorldBindings.new()
	local self = setmetatable({}, WorldBindings)

	self.mode = nil
	self.enabled = true
	self.entries = {} -- targetId -> { interaction, available, instance }
	self.connections = {}
	self.instances = {} -- prompts, highlights we created
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
		if interaction.targetId ~= "" then
			self.entries[interaction.targetId] = {
				interaction = interaction,
				available = item.available,
				instance = WorldBindings.resolve(interaction.targetId),
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
-- Explore mode: prompts and touch zones
--------------------------------------------------------------------------------

function WorldBindings:setExploreMode(list)
	self:_disconnectAll()
	self.mode = "Explore"
	self:_index(list)

	local localPlayer = Players.LocalPlayer

	for targetId, entry in pairs(self.entries) do
		local instance = entry.instance
		if instance and entry.available then
			local interaction = entry.interaction

			if interaction.kind == "Hotspot" then
				local parts = basePartsOf(instance)
				local host = instance:IsA("BasePart") and instance or (instance:IsA("Model") and instance.PrimaryPart) or parts[1]

				if host then
					local prompt = Instance.new("ProximityPrompt")
					prompt.Name = "VNPrompt"
					prompt.ActionText = interaction.name
					prompt.ObjectText = ""
					prompt.MaxActivationDistance = 12
					prompt.RequiresLineOfSight = false
					prompt.Parent = host
					table.insert(self.instances, prompt)

					table.insert(self.connections, prompt.Triggered:Connect(function()
						if self.enabled then
							self.InteractionRequested:Fire(interaction.id)
						end
					end))
				end
			else
				for _, part in ipairs(basePartsOf(instance)) do
					table.insert(self.connections, part.Touched:Connect(function(hit)
						if not self.enabled then
							return
						end

						local character = localPlayer and localPlayer.Character
						if not character or not hit:IsDescendantOf(character) then
							return
						end

						local now = os.clock()
						if (self.touchDebounce[targetId] or 0) > now then
							return
						end
						self.touchDebounce[targetId] = now + 1.5

						self.InteractionRequested:Fire(interaction.id)
					end))
				end
			end
		end
	end
end

function WorldBindings:destroy()
	self:clear()
	self.InteractionRequested:DisconnectAll()
	self.HoverChanged:DisconnectAll()
end

return WorldBindings
