-- Click a part or model in the world to make it an interaction target.
-- Assigns each picked interaction target a fresh VNInteractableId plus a
-- durable Workspace reference, then hands both back to the editor.

local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local HttpService = game:GetService("HttpService")

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
	self.hoverResult = nil
	self.placementGhost = nil
	self.placementCFrame = nil
	self.placementFootOffset = nil
	self.placementRotation = nil
	self.placementFacesCamera = false
	self.placementFacingInitialized = false
	self.marqueeStart = nil
	self.marqueeDragging = false

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
			self:stop(false)
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

	self.marqueeBox = Widgets.create("Frame", {
		Name = "VNPickerMarquee",
		BackgroundColor3 = Theme.Accent,
		BackgroundTransparency = 0.82,
		BorderSizePixel = 0,
		Visible = false,
		ZIndex = 59,
		Parent = parent,
	}, { Widgets.stroke(Theme.Accent, 2, 0), Widgets.corner(2) })

	return self
end

function WorldPicker:isActive()
	return self.active
end

local function newTargetId()
	return "target_" .. (HttpService:GenerateGUID(false):gsub("-", ""))
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
	local excluded = {}
	local character = Players.LocalPlayer and Players.LocalPlayer.Character
	if character then table.insert(excluded, character) end
	-- Explicitly exclude the placement preview even if an experience overrides
	-- CanQuery on character parts. Otherwise the ray starts hitting its own
	-- ghost each frame and continually drags the model toward the camera.
	if self.placementGhost then
		table.insert(excluded, self.placementGhost)
		-- Repositioning a placed character should raycast the actual room/map,
		-- not collide with its old copy (or any other placed character) on the
		-- way. The generated layer is only excluded during model placement;
		-- normal interaction target picking can still select these models.
		local placedCharacters = Workspace:FindFirstChild("VNPlacedCharacters")
		if placedCharacters then table.insert(excluded, placedCharacters) end
	end
	params.FilterDescendantsInstances = excluded

	local result = Workspace:Raycast(ray.Origin, ray.Direction * 1000, params)
	if not result then
		return nil
	end

	local target = self.options and self.options.partOnly and result.Instance or pickTarget(result.Instance)
	if self.options and self.options.allowAncestors then
		for _ = 1, self.pickDepth or 0 do
			if target.Parent and target.Parent ~= Workspace then target = target.Parent end
		end
	end
	return target, result
end

function WorldPicker:_updateMarquee(point)
	local start = self.marqueeStart
	if not start then return end
	local minX, minY = math.min(start.X, point.X), math.min(start.Y, point.Y)
	local width, height = math.abs(point.X - start.X), math.abs(point.Y - start.Y)
	self.marqueeDragging = self.marqueeDragging or width >= 7 or height >= 7
	self.marqueeBox.Visible = self.marqueeDragging
	if self.marqueeDragging then
		self.marqueeBox.Position = UDim2.fromOffset(minX, minY)
		self.marqueeBox.Size = UDim2.fromOffset(width, height)
		self.highlight.Enabled = false
	end
end

function WorldPicker:_marqueeTargets()
	local camera = Workspace.CurrentCamera
	if not camera or not self.marqueeStart then return {} end
	local point = UserInputService:GetMouseLocation()
	local minX, maxX = math.min(self.marqueeStart.X, point.X), math.max(self.marqueeStart.X, point.X)
	local minY, maxY = math.min(self.marqueeStart.Y, point.Y), math.max(self.marqueeStart.Y, point.Y)
	local character = Players.LocalPlayer and Players.LocalPlayer.Character
	local targets, seen = {}, {}
	for _, instance in ipairs(Workspace:GetDescendants()) do
		if instance:IsA("BasePart") and instance.CanQuery and not (character and instance:IsDescendantOf(character))
			and not instance:FindFirstAncestor("VNRoomAssembly")
			and not instance:FindFirstAncestor("VNPlacedCharacters") then
			local target = self.options.partOnly and instance or pickTarget(instance)
			if self.options.allowAncestors then
				for _ = 1, self.pickDepth or 0 do
					if target.Parent and target.Parent ~= Workspace then target = target.Parent end
				end
			end
			local position
			if target:IsA("PVInstance") then position = target:GetPivot().Position
			elseif target:IsA("BasePart") then position = target.Position end
			if position and not seen[target] then
				local screen, onScreen = camera:WorldToViewportPoint(position)
				if onScreen and screen.X >= minX and screen.X <= maxX and screen.Y >= minY and screen.Y <= maxY
					and (not self.options.validate or self.options.validate(target)) then
					seen[target] = true
					table.insert(targets, target)
				end
			end
		end
	end
	return targets
end

function WorldPicker:_completeSinglePick()
	if not self.hovered then return end
	local target = self.hovered
	if self.options.validate and not self.options.validate(target) then
		self.label.Text = self.options.invalidPrompt or "That is not a valid target for this picker."
		return
	end
	local id = target:GetAttribute(WorldBindings.ATTRIBUTE)

	-- Generated character placements already carry a stable runtime binding.
	-- Re-tagging one here would break its placement-id resolver until reload.
	local isPlacedCharacter = target:GetAttribute("VNCharacterPlacementId") ~= nil
	if self.options.assignId ~= false and not isPlacedCharacter then
		-- Each explicit pick creates a fresh identity. Reusing a value found
		-- on an object can silently bind two separate interactions together.
		id = newTargetId()
		WorldBindings.assignId(target, id)
	end

	local done = self.callback
	local hit = self.hoverResult
	self:stop(true)
	if done then done(id, target, WorldBindings.referenceFor(target), hit) end
end

local function preparePlacementGhost(template)
	local ok, ghost = pcall(function() return template:Clone() end)
	if not ok or not ghost then return nil end
	ghost.Name = "VNCharacterPlacementGhost"
	for _, descendant in ipairs(ghost:GetDescendants()) do
		if descendant:IsA("Script") or descendant:IsA("LocalScript") then
			descendant:Destroy()
		elseif descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanTouch = false
			descendant.CanQuery = false
			descendant.Transparency = math.max(descendant.Transparency, 0.55)
		end
	end
	ghost.Parent = Workspace
	return ghost
end

function WorldPicker:_updatePlacementGhost(result)
	if not self.placementGhost or not result then
		self.placementCFrame = nil
		return
	end
	if not self.placementFootOffset or not self.placementRotation then return end
	if self.placementFacesCamera and not self.placementFacingInitialized then
		local camera = Workspace.CurrentCamera
		local towardCamera = camera and camera.CFrame.Position - result.Position or Vector3.zero
		towardCamera = Vector3.new(towardCamera.X, 0, towardCamera.Z)
		if towardCamera.Magnitude > 0.001 then
			-- Fresh characters start with their authored front aimed at the active
			-- Room3D/Explore3D view. R/F remains available for deliberate changes.
			self.placementRotation = CFrame.lookAt(Vector3.zero, towardCamera).Rotation
		end
		self.placementFacingInitialized = true
	end
	self.placementCFrame = CFrame.new(result.Position + Vector3.new(0, self.placementFootOffset, 0))
		* self.placementRotation
	self.placementGhost:PivotTo(self.placementCFrame)
end

function WorldPicker:start(callback, options)
	options = options or {}
	self:stop()

	self.active = true
	self.callback = callback
	self.options = options
	self.pickDepth = 0
	if options.placementTemplate then
		self.placementGhost = preparePlacementGhost(options.placementTemplate)
		if not self.placementGhost then
			self:stop(false)
			return false
		end
		local ok, bounds, size = pcall(function()
			local boundsCFrame, boundingSize = self.placementGhost:GetBoundingBox()
			return boundsCFrame, boundingSize
		end)
		if not ok then
			self:stop(false)
			return false
		end
		local pivot = self.placementGhost:GetPivot()
		self.placementFootOffset = pivot.Position.Y - (bounds.Position.Y - size.Y * 0.5)
		-- Repositioning starts from the model's authored orientation. Fresh
		-- placements use the template's orientation instead.
		self.placementRotation = typeof(options.placementRotation) == "CFrame"
			and options.placementRotation.Rotation or pivot.Rotation
		self.placementFacesCamera = options.faceCamera == true and typeof(options.placementRotation) ~= "CFrame"
		self.placementFacingInitialized = false
	end
	self.overlay.Visible = true
	self.label.Text = options.prompt or "Click a part or model in the world to use it as the target. Hover shows what will be picked."

	table.insert(self.connections, RunService.RenderStepped:Connect(function()
		local target, result = self:_raycast()
		self.hovered = target
		self.hoverResult = result
		if self.placementGhost then
			self:_updatePlacementGhost(result)
			self.highlight.Enabled = false
			self.label.Text = result
				and "Click to place. R / F rotate 15°. Esc cancels."
				or "Point at a surface to place the character model. R / F rotate 15°."
			return
		end
		if options.marquee and self.marqueeStart then
			self:_updateMarquee(UserInputService:GetMouseLocation())
			if self.marqueeDragging then
				self.label.Text = "Release to add every valid component inside the selection box. Esc cancels."
				return
			end
		end
		self.highlight.Adornee = target
		self.highlight.Enabled = target ~= nil

		if target then
			local existing = target:GetAttribute(WorldBindings.ATTRIBUTE)
			self.label.Text = string.format("%s%s\n%s", target:GetFullName(), existing and ("   (id " .. tostring(existing) .. ")") or "", options.marquee and "click to pick / drag to add a selection" or "click to pick")
		end
		if target and options.allowAncestors then self.label.Text ..= " / Tab: parent / Esc: cancel" end
	end))

	table.insert(self.connections, UserInputService.InputBegan:Connect(function(input, processed)
		if input.KeyCode == Enum.KeyCode.Escape then
			self:stop(false)
			return
		end

		if options.allowAncestors and input.KeyCode == Enum.KeyCode.Tab then
			self.pickDepth = ((self.pickDepth or 0) + 1) % 6
			return
		end
		if processed then
			return
		end

		if self.placementGhost and (input.KeyCode == Enum.KeyCode.R or input.KeyCode == Enum.KeyCode.F) then
			local direction = input.KeyCode == Enum.KeyCode.R and 1 or -1
			self.placementRotation = self.placementRotation * CFrame.Angles(0, math.rad(15 * direction), 0)
			self:_updatePlacementGhost(self.hoverResult)
			return
		end

		if input.UserInputType == Enum.UserInputType.MouseButton1 and self.placementGhost then
			if self.placementCFrame then
				local done = self.callback
				local cframe = self.placementCFrame
				self:stop(true)
				if done then done(cframe) end
			end
			return
		end

		if input.UserInputType == Enum.UserInputType.MouseButton1 and options.marquee then
			self.marqueeStart = UserInputService:GetMouseLocation()
			self.marqueeDragging = false
			return
		end

		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			self:_completeSinglePick()
		end
	end))

	table.insert(self.connections, UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType ~= Enum.UserInputType.MouseButton1 or not options.marquee or not self.marqueeStart then return end
		local dragged = self.marqueeDragging
		if not dragged then
			self.marqueeStart = nil
			self.marqueeDragging = false
			self.marqueeBox.Visible = false
			self:_completeSinglePick()
			return
		end
		local targets = self:_marqueeTargets()
		self.marqueeStart = nil
		self.marqueeDragging = false
		self.marqueeBox.Visible = false
		if #targets == 0 then
			self.label.Text = "No valid components were inside that selection. Try again or press Esc."
			return
		end
		local onMarqueePick = options.onMarqueePick
		self:stop(true)
		if onMarqueePick then onMarqueePick(targets) end
	end))
end

function WorldPicker:stop(picked)
	local onStop = self.active and self.options and self.options.onStop
	self.active = false
	self.callback = nil
	self.options = nil
	self.overlay.Visible = false
	self.highlight.Enabled = false
	self.highlight.Adornee = nil
	self.hovered = nil
	self.hoverResult = nil
	self.placementCFrame = nil
	self.placementFootOffset = nil
	self.placementRotation = nil
	self.placementFacesCamera = false
	self.placementFacingInitialized = false
	self.marqueeStart = nil
	self.marqueeDragging = false
	self.marqueeBox.Visible = false
	if self.placementGhost then
		self.placementGhost:Destroy()
		self.placementGhost = nil
	end

	for _, connection in ipairs(self.connections) do
		connection:Disconnect()
	end
	table.clear(self.connections)
	if onStop then onStop(picked == true) end
end

function WorldPicker:destroy()
	self:stop()
	self.highlight:Destroy()
	self.marqueeBox:Destroy()
	self.overlay:Destroy()
end

return WorldPicker
