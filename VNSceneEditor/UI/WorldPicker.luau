-- Click a part or model in the world to make it an interaction target.
-- Assigns a VNInteractableId attribute (and the VNInteractable tag) when the
-- object does not have one yet, then hands the id back.

local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local root = script.Parent.Parent
local WorldBindings = require(root.Render.WorldBindings)

local Theme = require(script.Parent.Theme)
local Widgets = require(script.Parent.Widgets)

local WorldPicker = {}
WorldPicker.__index = WorldPicker

function WorldPicker.new(parent, app)
	local self = setmetatable({}, WorldPicker)

	self.app = app
	self.active = false
	self.callback = nil
	self.connections = {}
	self.hovered = nil

	self.overlay = Widgets.panel({
		Name = "WorldPicker",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 20),
		Size = UDim2.new(0, 520, 0, 64),
		BackgroundColor3 = Theme.Panel,
		BackgroundTransparency = 0.05,
		ZIndex = 60,
		Visible = false,
		Parent = parent,
	}, { Widgets.stroke(Theme.Accent, 2, 0), Widgets.padding(10, 14, 10, 14) })

	self.label = Widgets.label({
		Text = "",
		Size = UDim2.new(1, -110, 1, 0),
		TextWrapped = true,
		TextTruncate = Enum.TextTruncate.None,
		TextSize = 12,
		ZIndex = 61,
		Parent = self.overlay,
	})

	Widgets.button({
		Text = "Cancel  (Esc)",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, 0, 0.5, 0),
		Size = UDim2.new(0, 100, 0, 28),
		Color = Theme.Danger,
		TextSize = 11,
		ZIndex = 61,
		OnClick = function()
			self:stop()
		end,
		Parent = self.overlay,
	})

	self.highlight = Instance.new("Highlight")
	self.highlight.Name = "VNPickerHighlight"
	self.highlight.FillColor = Color3.fromRGB(255, 59, 127)
	self.highlight.FillTransparency = 0.6
	self.highlight.OutlineColor = Color3.fromRGB(255, 255, 255)
	self.highlight.Enabled = false
	self.highlight.Parent = Workspace

	return self
end

function WorldPicker:isActive()
	return self.active
end

local function pickTarget(instance)
	-- Prefer an already tagged ancestor, then a model, then the part.
	local tagged = WorldBindings.ownerOf(instance)
	if tagged then
		return tagged
	end

	local model = instance:FindFirstAncestorOfClass("Model")
	if model and model ~= Workspace and not Players:GetPlayerFromCharacter(model) then
		return model
	end

	return instance
end

function WorldPicker:_raycast()
	local camera = Workspace.CurrentCamera
	if not camera then
		return nil
	end

	local location = UserInputService:GetMouseLocation()
	local ray = camera:ViewportPointToRay(location.X, location.Y)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local character = Players.LocalPlayer and Players.LocalPlayer.Character
	params.FilterDescendantsInstances = character and { character } or {}

	local result = Workspace:Raycast(ray.Origin, ray.Direction * 1000, params)
	if not result then
		return nil
	end

	return pickTarget(result.Instance)
end

function WorldPicker:start(callback, options)
	options = options or {}
	self:stop()

	self.active = true
	self.callback = callback
	self.overlay.Visible = true
	self.label.Text = options.prompt or "Click a part or model in the world to use it as the target. Hover shows what will be picked."

	table.insert(self.connections, RunService.RenderStepped:Connect(function()
		local target = self:_raycast()
		self.hovered = target
		self.highlight.Adornee = target
		self.highlight.Enabled = target ~= nil

		if target then
			local existing = target:GetAttribute(WorldBindings.ATTRIBUTE)
			self.label.Text = string.format("%s%s\nclick to pick", target:GetFullName(), existing and ("   (id " .. tostring(existing) .. ")") or "")
		end
	end))

	table.insert(self.connections, UserInputService.InputBegan:Connect(function(input, processed)
		if input.KeyCode == Enum.KeyCode.Escape then
			self:stop()
			return
		end

		if processed then
			return
		end

		if input.UserInputType == Enum.UserInputType.MouseButton1 and self.hovered then
			local target = self.hovered
			local id = target:GetAttribute(WorldBindings.ATTRIBUTE)

			if type(id) ~= "string" or id == "" then
				local cleanName = (target.Name:gsub("[^%w]", ""))
				id = string.format("%s_%x", cleanName ~= "" and cleanName or "target", os.time() % 0xFFFFF)
				WorldBindings.assignId(target, id)
			end

			local done = self.callback
			self:stop()
			if done then
				done(id, target)
			end
		end
	end))
end

function WorldPicker:stop()
	self.active = false
	self.callback = nil
	self.overlay.Visible = false
	self.highlight.Enabled = false
	self.highlight.Adornee = nil
	self.hovered = nil

	for _, connection in ipairs(self.connections) do
		connection:Disconnect()
	end
	table.clear(self.connections)
end

function WorldPicker:destroy()
	self:stop()
	self.highlight:Destroy()
	self.overlay:Destroy()
end

return WorldPicker
