-- Editor overlays on the stage: hotspot labels projected from the 3D world,
-- and a drag handle on the portrait while a keyframe is selected.

local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local root = script.Parent.Parent
local Schema = require(root.Core.Schema)
local Conditions = require(root.Runtime.Conditions)
local WorldBindings = require(root.Render.WorldBindings)

local Theme = require(script.Parent.Theme)
local Widgets = require(script.Parent.Widgets)

local StageGizmos = {}
StageGizmos.__index = StageGizmos

local KIND_COLORS = {
	Hotspot = Color3.fromRGB(255, 196, 84),
	Trigger = Color3.fromRGB(96, 214, 200),
	Exit = Color3.fromRGB(255, 120, 120),
}

function StageGizmos.new(parent, app)
	local self = setmetatable({}, StageGizmos)

	self.app = app
	self.enabled = false
	self.dragging = false
	self.labels = {}

	self.layer = Widgets.create("Frame", {
		Name = "Gizmos",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		ZIndex = 7,
		Visible = false,
		Parent = parent,
	})

	self.hotspotLayer = Widgets.create("Frame", {
		Name = "Hotspots",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		ZIndex = 7,
		Parent = self.layer,
	})

	self.handle = Widgets.create("TextButton", {
		Name = "PortraitHandle",
		Text = "drag portrait",
		AutoButtonColor = false,
		BackgroundColor3 = Theme.Accent,
		BackgroundTransparency = 0.7,
		BorderSizePixel = 0,
		Font = Theme.FontBold,
		TextSize = 11,
		TextColor3 = Theme.Text,
		TextYAlignment = Enum.TextYAlignment.Bottom,
		Visible = false,
		ZIndex = 8,
		Parent = self.layer,
	}, { Widgets.corner(6), Widgets.stroke(Theme.Accent, 2, 0) })

	self.handle.MouseButton1Down:Connect(function()
		self.dragging = true
	end)

	self.connections = {
		UserInputService.InputEnded:Connect(function(input)
			if self.dragging and input.UserInputType == Enum.UserInputType.MouseButton1 then
				self.dragging = false
				app:markDirty()
			end
		end),
		UserInputService.InputChanged:Connect(function(input)
			if self.dragging and input.UserInputType == Enum.UserInputType.MouseMovement then
				self:_dragTo(UserInputService:GetMouseLocation())
			end
		end),
		RunService.RenderStepped:Connect(function(dt)
			if not self.layer.Visible then
				return
			end

			-- Labels are rebuilt, not moved, so throttle to ~10 Hz.
			self.hotspotClock = (self.hotspotClock or 0) + dt
			if self.hotspotClock >= 0.1 then
				self.hotspotClock = 0
				self:_updateHotspots()
			end
		end),
	}

	return self
end

function StageGizmos:setVisible(visible)
	self.layer.Visible = visible
end

--------------------------------------------------------------------------------
-- Portrait drag
--------------------------------------------------------------------------------

function StageGizmos:_selectedKey()
	local app = self.app
	if app.selection.kind ~= "key" then
		return nil
	end

	local owner = app:getSelectedEntry() or app:getSelectedSegment()
	if not owner or not owner.tracks then
		return nil
	end

	local track = Schema.findById(owner.tracks, app.selection.trackId)
	return track and track.keys[app.selection.keyIndex] or nil, track
end

function StageGizmos:_dragTo(mousePosition)
	local key = self:_selectedKey()
	if not key then
		return
	end

	local layer = self.app.presenter:getStage().characterLayer
	local size = layer.AbsoluteSize
	if size.X <= 0 or size.Y <= 0 then
		return
	end

	local relative = Vector2.new(mousePosition.X, mousePosition.Y) - layer.AbsolutePosition
	key.x = math.clamp(relative.X / size.X, -0.5, 1.5)
	key.y = math.clamp(relative.Y / size.Y, 0, 1.5)

	self.app:previewKeyDrag()
end

-- Called after every render so the handle follows the portrait.
function StageGizmos:update()
	local key = self:_selectedKey()
	local stage = self.app.presenter:getStage()

	if key and stage.portrait.Visible then
		self.handle.Visible = true
		local layerPos = self.layer.AbsolutePosition
		local pos = stage.portrait.AbsolutePosition - layerPos
		self.handle.Position = UDim2.fromOffset(pos.X, pos.Y)
		self.handle.Size = UDim2.fromOffset(stage.portrait.AbsoluteSize.X, stage.portrait.AbsoluteSize.Y)
	else
		self.handle.Visible = false
	end
end

--------------------------------------------------------------------------------
-- Hotspot labels
--------------------------------------------------------------------------------

function StageGizmos:_updateHotspots()
	local app = self.app
	local scene = app.scene
	Widgets.clearChildren(self.hotspotLayer)

	local subscene = app:getActiveSubscene()
	if not scene or not subscene or subscene.kind == "Novel2D" then
		return
	end

	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end

	local flags = app:getPreviewFlags()
	local chapter = app:getChapter()
	local layerPos = self.hotspotLayer.AbsolutePosition

	for _, interaction in ipairs(scene.interactions) do
		if not Schema.interactionInSubscene(scene, subscene, interaction) then continue end
		local target = WorldBindings.resolve(interaction.targetId)
		local center = WorldBindings.centerOf(target)

		if center then
			local point, onScreen = camera:WorldToViewportPoint(center)
			if onScreen then
				local available = Conditions.evaluate(interaction.conditions, flags, chapter, scene)
				local color = KIND_COLORS[interaction.kind]
				local selected = app.selection.kind == "interaction" and app.selection.interactionId == interaction.id

				local tag = Widgets.create("TextButton", {
					Text = "  " .. interaction.name .. (available and "" or "  (locked)") .. "  ",
					AnchorPoint = Vector2.new(0.5, 1),
					Position = UDim2.fromOffset(point.X - layerPos.X, point.Y - layerPos.Y - 8),
					Size = UDim2.new(0, 0, 0, 20),
					AutomaticSize = Enum.AutomaticSize.X,
					BackgroundColor3 = Theme.Panel,
					BackgroundTransparency = available and 0.15 or 0.5,
					BorderSizePixel = 0,
					AutoButtonColor = false,
					Font = Theme.FontBold,
					TextSize = 11,
					TextColor3 = available and color or Theme.TextFaint,
					ZIndex = 8,
					Parent = self.hotspotLayer,
				}, { Widgets.corner(4), Widgets.stroke(selected and Theme.Accent or color, selected and 2 or 1, selected and 0 or 0.5) })

				tag.MouseButton1Click:Connect(function()
					app:setSelection({ kind = "interaction", interactionId = interaction.id })
				end)

				Widgets.create("Frame", {
					AnchorPoint = Vector2.new(0.5, 0.5),
					Position = UDim2.fromOffset(point.X - layerPos.X, point.Y - layerPos.Y),
					Size = UDim2.fromOffset(10, 10),
					BackgroundColor3 = color,
					BorderSizePixel = 0,
					ZIndex = 8,
					Parent = self.hotspotLayer,
				}, { Widgets.corner(5) })
			end
		end
	end
end

function StageGizmos:destroy()
	for _, connection in ipairs(self.connections) do
		connection:Disconnect()
	end
	self.layer:Destroy()
end

return StageGizmos
