-- Editor overlays on the stage: hotspot labels projected from the 3D world,
-- and a drag handle on the portrait while a keyframe is selected.

local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local root = script.Parent.Parent
local Schema = require(root.Core.Schema)
local WorldBindings = require(root.Render.WorldBindings)

local Theme = require(script.Parent.Theme)
local Widgets = require(script.Parent.Widgets)

local StageGizmos = {}
StageGizmos.__index = StageGizmos

local KIND_COLORS = {
	Hotspot = Color3.fromRGB(255, 196, 84),
}

local CAMERA_POSE_COLOR = Theme.Timed

function StageGizmos.new(parent, app)
	local self = setmetatable({}, StageGizmos)

	self.app = app
	self.enabled = false
	self.dragging = false
	self.labels = {}
	self.worldMarkers = {}

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
		RunService.RenderStepped:Connect(function()
			if not self.layer.Visible then
				return
			end
			-- Marker instances stay alive; only their projection is updated here.
			-- This keeps labels glued to the 3D world at the display frame rate.
			self:_positionWorldMarkers()
		end),
	}

	return self
end

function StageGizmos:setVisible(visible)
	self.layer.Visible = visible
	if visible then
		self:_rebuildWorldMarkers()
	end
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
	local key, track = self:_selectedKey()
	if not key or not track or track.target ~= "portrait" then
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
	local key, track = self:_selectedKey()
	local stage = self.app.presenter:getStage()

	if key and track and track.target == "portrait" and stage.portrait.Visible then
		self.handle.Visible = true
		local layerPos = self.layer.AbsolutePosition
		local pos = stage.portrait.AbsolutePosition - layerPos
		self.handle.Position = UDim2.fromOffset(pos.X, pos.Y)
		self.handle.Size = UDim2.fromOffset(stage.portrait.AbsoluteSize.X, stage.portrait.AbsoluteSize.Y)
	else
		self.handle.Visible = false
	end
	self:_rebuildWorldMarkers()
end

--------------------------------------------------------------------------------
-- World markers
--------------------------------------------------------------------------------

function StageGizmos:_clearWorldMarkers()
	for _, marker in pairs(self.worldMarkers) do
		marker.tag:Destroy()
		marker.dot:Destroy()
	end
	table.clear(self.worldMarkers)
end

function StageGizmos:_addWorldMarker(key, text, color, positionProvider, onClick, selected, poseId)
	local tag = Widgets.create("TextButton", {
		Name = key .. "Label",
		Text = "  " .. text .. "  ",
		AnchorPoint = Vector2.new(0.5, 1),
		Size = UDim2.new(0, 0, 0, 20),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundColor3 = Theme.Panel,
		BackgroundTransparency = 0.15,
		BorderSizePixel = 0,
		AutoButtonColor = false,
		Font = Theme.FontBold,
		TextSize = 11,
		TextColor3 = color,
		ZIndex = 8,
		Parent = self.hotspotLayer,
	}, { Widgets.corner(4), Widgets.stroke(selected and Theme.Accent or color, selected and 2 or 1, selected and 0 or 0.5) })

	tag.MouseButton1Click:Connect(onClick)

	local dot = Widgets.create("Frame", {
		Name = key .. "Dot",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(10, 10),
		BackgroundColor3 = color,
		BorderSizePixel = 0,
		ZIndex = 8,
		Parent = self.hotspotLayer,
	}, { Widgets.corner(5) })

	self.worldMarkers[key] = {
		tag = tag,
		dot = dot,
		positionProvider = positionProvider,
		poseId = poseId,
		screenPosition = nil,
	}
end

function StageGizmos:_addInteractionMarkers(scene, subscene)
	local app = self.app
	if subscene.kind == "Novel2D" then
		return
	end

	for _, interaction in ipairs(scene.interactions) do
		if not Schema.interactionInSubscene(scene, subscene, interaction) then continue end
		local color = KIND_COLORS[interaction.kind] or Theme.Interaction
		local applyingDefaultResponse = app:isApplyingDefaultResponse()
		local selected = (applyingDefaultResponse and app:isDefaultResponseTarget(interaction.id))
			or (not applyingDefaultResponse and app.selection.kind == "interaction" and app.selection.interactionId == interaction.id)
		self:_addWorldMarker(
			"Interaction_" .. interaction.id,
			interaction.name .. (interaction.enabled == false and "  (disabled)" or ""),
			color,
			function()
				local placementId = type(interaction.targetCharacterModelId) == "string" and interaction.targetCharacterModelId or ""
				local target = placementId ~= ""
					and app.presenter:getCharacterModels():resolveTarget(placementId)
					or WorldBindings.resolve(interaction.targetId, interaction.targetRef)
				return WorldBindings.centerOf(target)
			end,
			function()
				if app:isApplyingDefaultResponse() then
					app:toggleDefaultResponseTarget(interaction.id)
				else
					app:setSelection({ kind = "interaction", interactionId = interaction.id })
				end
			end,
			selected
		)
	end
end

function StageGizmos:_addCameraPoseMarkers()
	local app = self.app
	local chapter = app:getChapter()
	local project = app:getProject()
	if not chapter or not project then return end

	local usersByPose = {}
	for _, storedScene in ipairs(chapter.scenes or {}) do
		-- Use the currently open scene copy so unsaved pose assignments are still
		-- represented by its marker.
		local scene = app.scene and app.scene.id == storedScene.id and app.scene or storedScene
		for _, subscene in ipairs(scene.subscenes or {}) do
			-- Explore3D enters from its player spawn rather than a fixed camera
			-- preset, so it must not create a misleading blue pose marker.
			local poseId = subscene.kind ~= "Explore3D" and Schema.effectivePoseId(scene, subscene) or ""
			if poseId ~= "" then
				usersByPose[poseId] = usersByPose[poseId] or {}
				table.insert(usersByPose[poseId], {
					sceneId = scene.id,
					sceneName = scene.name,
					subsceneId = subscene.id,
					subsceneName = subscene.name,
					subsceneKind = subscene.kind,
				})
			end
		end
	end

	for poseId, users in pairs(usersByPose) do
		local pose = Schema.findCameraPose(project, poseId)
		local cframe = pose and Schema.decodeCFrame(pose.cframe)
		if cframe then
			self:_addWorldMarker(
				"CameraPose_" .. poseId,
				pose.name,
				CAMERA_POSE_COLOR,
				function() return cframe.Position end,
				function() app:openCameraPoseUsers(pose.name, users) end,
				false,
				poseId
			)
		end
	end
end

function StageGizmos:_rebuildWorldMarkers()
	self:_clearWorldMarkers()
	local scene = self.app.scene
	local subscene = self.app:getActiveSubscene()
	if not scene or not subscene then return end
	self:_addInteractionMarkers(scene, subscene)
	self:_addCameraPoseMarkers()
	self:_positionWorldMarkers()
end

function StageGizmos:_positionWorldMarkers()
	local camera = Workspace.CurrentCamera
	if not camera then return end
	local layerPos = self.hotspotLayer.AbsolutePosition
	for _, marker in pairs(self.worldMarkers) do
		local position = marker.positionProvider()
		local point = Vector3.zero
		local onScreen = false
		if position then
			point, onScreen = camera:WorldToViewportPoint(position)
		end
		marker.tag.Visible = onScreen == true
		marker.dot.Visible = onScreen == true
		if onScreen then
			local x = point.X - layerPos.X
			local y = point.Y - layerPos.Y
			marker.tag.Position = UDim2.fromOffset(x, y - 8)
			marker.dot.Position = UDim2.fromOffset(x, y)
			marker.screenPosition = Vector2.new(x + layerPos.X, y + layerPos.Y)
		else
			marker.screenPosition = nil
		end
	end
end

-- Popup dropdowns sit above the world-marker layer, so direct button clicks
-- cannot reach it while a list is open.  The dropdown asks this hit-test for
-- a blue pose marker at the clicked screen point and uses its pose id instead.
function StageGizmos:cameraPoseIdAt(mousePosition)
	for _, marker in pairs(self.worldMarkers) do
		if marker.poseId and marker.screenPosition then
			local dotDistance = (mousePosition - marker.screenPosition).Magnitude
			local tagPosition = marker.tag.AbsolutePosition
			local tagSize = marker.tag.AbsoluteSize
			local onTag = mousePosition.X >= tagPosition.X and mousePosition.X <= tagPosition.X + tagSize.X
				and mousePosition.Y >= tagPosition.Y and mousePosition.Y <= tagPosition.Y + tagSize.Y
			if dotDistance <= 18 or onTag then
				return marker.poseId
			end
		end
	end
	return nil
end

function StageGizmos:destroy()
	for _, connection in ipairs(self.connections) do
		connection:Disconnect()
	end
	self.layer:Destroy()
end

return StageGizmos
