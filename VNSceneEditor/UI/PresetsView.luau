-- Project wide presets: characters and their portraits, camera poses,
-- textbox styles and transitions. Lives in the project browser.

local root = script.Parent.Parent
local ProjectStore = require(root.Core.ProjectStore)
local Schema = require(root.Core.Schema)
local WorldBindings = require(root.Render.WorldBindings)
local UserInputService = game:GetService("UserInputService")

local Theme = require(script.Parent.Theme)
local Widgets = require(script.Parent.Widgets)

local PresetsView = {}
PresetsView.__index = PresetsView

local TABS = {
	{ id = "characters", label = "Characters" },
	{ id = "poses", label = "Camera poses" },
	{ id = "textboxes", label = "Textbox styles" },
	{ id = "transitions", label = "Transitions" },
	{ id = "sequences", label = "Sequence Presets" },
	{ id = "system", label = "System" },
	{ id = "assembly", label = "Room Assembly" },
}

function PresetsView.new(parent, app)
	local self = setmetatable({}, PresetsView)

	self.app = app
	self.tab = "characters"
	self.addingPortraitFor = nil
	self.addingCharacter = false
	self.portraitLayoutEditor = false
	self.portraitLayoutDraft = nil
	self.selectedLayoutPortrait = nil
	self.layoutConnections = {}
	self.order = 0

	self.panel = Widgets.create("Frame", {
		Name = "Presets",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Visible = false,
		Parent = parent,
	})

	self.tabs = Widgets.create("Frame", {
		Size = UDim2.new(1, 0, 0, 26),
		BackgroundTransparency = 1,
		Parent = self.panel,
	})

	self.list = Widgets.scroll({
		Position = UDim2.new(0, 0, 0, 34),
		Size = UDim2.new(1, 0, 1, -34),
		Parent = self.panel,
	}, { Widgets.vlist(6), Widgets.padding(0, 6, 0, 0) })

	return self
end

function PresetsView:setVisible(visible)
	self.panel.Visible = visible
	if not visible then
		self:_clearLayoutConnections()
	end
end

function PresetsView:_clearLayoutConnections()
	for _, connection in ipairs(self.layoutConnections) do
		connection:Disconnect()
	end
	table.clear(self.layoutConnections)
end

function PresetsView:_layoutConnect(signal, callback)
	local connection = signal:Connect(callback)
	table.insert(self.layoutConnections, connection)
	return connection
end

function PresetsView:_next()
	self.order += 1
	return self.order
end

function PresetsView:_card(height)
	return Widgets.create("Frame", {
		Size = UDim2.new(1, -6, 0, height),
		BackgroundColor3 = Theme.Row,
		BorderSizePixel = 0,
		LayoutOrder = self:_next(),
		Parent = self.list,
	}, { Widgets.corner(6), Widgets.padding(8, 10, 8, 10) })
end

function PresetsView:_addButton(text, onClick)
	Widgets.button({
		Text = text,
		Size = UDim2.new(0, 200, 0, 28),
		Color = Theme.Accent,
		TextSize = 11,
		LayoutOrder = self:_next(),
		OnClick = onClick,
		Parent = self.list,
	})
end

--------------------------------------------------------------------------------
-- Characters
--------------------------------------------------------------------------------

local function isCharacterTemplate(model)
	return model and model:IsA("Model")
		and model:FindFirstChildOfClass("Humanoid") ~= nil
		and model:FindFirstChild("HumanoidRootPart") ~= nil
		and model.HumanoidRootPart:IsA("BasePart")
end

local function modelPreviewFront(model)
	local head = model and model:FindFirstChild("Head", true)
	if head and head:IsA("BasePart") then
		return head.CFrame.LookVector
	end
	return model and model:GetPivot().LookVector or Vector3.new(0, 0, -1)
end

local function characterModelPreview(parent, reference)
	local frame = Widgets.create("ViewportFrame", {
		Size = UDim2.fromOffset(64, 64),
		BackgroundColor3 = Theme.Input,
		BorderSizePixel = 0,
		Ambient = Color3.fromRGB(180, 180, 180),
		LightColor = Color3.new(1, 1, 1),
		Parent = parent,
	}, { Widgets.corner(6), Widgets.stroke(Theme.Border, 1, 0.35) })
	local template = WorldBindings.resolveReference(reference)
	if not isCharacterTemplate(template) then
		Widgets.label({
			Text = "?", Size = UDim2.fromScale(1, 1), TextXAlignment = Enum.TextXAlignment.Center,
			TextYAlignment = Enum.TextYAlignment.Center, Font = Theme.FontBold, TextSize = 22,
			TextColor3 = Theme.TextFaint, Parent = frame,
		})
		return false
	end
	local ok, clone = pcall(function() return template:Clone() end)
	if not ok or not clone then return false end
	for _, descendant in ipairs(clone:GetDescendants()) do
		if descendant:IsA("Script") or descendant:IsA("LocalScript") then descendant:Destroy() end
	end
	clone.Parent = frame
	local camera = Instance.new("Camera")
	camera.Parent = frame
	frame.CurrentCamera = camera
	local bounds, size = clone:GetBoundingBox()
	local distance = math.max(2.5, size.Magnitude * 0.95)
	local front = modelPreviewFront(clone)
	camera.CFrame = CFrame.lookAt(bounds.Position + front * distance + Vector3.new(0, size.Y * 0.1, 0), bounds.Position)
	return true
end

function PresetsView:_renderCharacters()
	local app = self.app
	local project = app:getProject()
	local mainCharacterCard = self:_card(58)
	Widgets.label({
		Text = "MAIN CHARACTER",
		Position = UDim2.new(0, 0, 0, 0),
		Size = UDim2.new(1, 0, 0, 14),
		Font = Theme.FontBold,
		TextSize = 10,
		TextColor3 = Theme.TextFaint,
		Parent = mainCharacterCard,
	})
	local mainCharacterItems = { { id = "", label = "(no default character)" } }
	for _, record in ipairs(project.characters) do
		table.insert(mainCharacterItems, { id = record.name, label = record.name })
	end
	Widgets.dropdown(app.gui, {
		Items = mainCharacterItems,
		Value = project.mainCharacter,
		Placeholder = "(no default character)",
		Position = UDim2.new(0, 0, 0, 22),
		Size = UDim2.new(1, 0, 0, 26),
		OnPick = function(name)
			project.mainCharacter = name
			ProjectStore.markChanged()
			app:refresh()
		end,
		Parent = mainCharacterCard,
	})

	Widgets.button({
		Text = "Edit portrait placement & size",
		Size = UDim2.new(0, 240, 0, 28),
		Color = Theme.Accent,
		TextSize = 11,
		LayoutOrder = self:_next(),
		OnClick = function()
			self.portraitLayoutDraft = Schema.normalizePortraitLayout(project.portraitLayout)
			self.selectedLayoutPortrait = nil
			for _, character in ipairs(project.characters) do
				if character.portraits[1] then
					self.selectedLayoutPortrait = character.portraits[1]
					break
				end
			end
			self.portraitLayoutEditor = true
			self:render()
		end,
		Parent = self.list,
	})

	Widgets.hint("Every character owns a portrait gallery. Left click a portrait to make it the default (gold). Right click the default to clear it; right click another portrait to recycle it.", self.list, 34).LayoutOrder = self:_next()

	for _, record in ipairs(project.characters) do
		local card = self:_card(184)

		Widgets.textBox({
			Text = record.name,
			Size = UDim2.new(0, 220, 0, 24),
			TextYAlignment = Enum.TextYAlignment.Center,
			Font = Theme.FontBold,
			OnCommit = function(text)
				local trimmed = Schema.trimName(text)
				if trimmed == "" or trimmed == record.name then
					app:refresh()
					return
				end
				if Schema.findCharacter(project, trimmed) then
					app:notify("A character with that name already exists.", Theme.Danger)
					app:refresh()
					return
				end
				-- Rename everywhere.
				local oldName = record.name
				record.name = trimmed
				if project.mainCharacter == oldName then
					project.mainCharacter = trimmed
				end
				Schema.forEachSceneInProject(project, function(scene)
					Schema.forEachEntry(scene, function(entry)
						if entry.character == oldName then
							entry.character = trimmed
						end
					end)
					for _, placement in ipairs(scene.characterModels or {}) do
						if placement.character == oldName then placement.character = trimmed end
					end
				end)
				ProjectStore.markChanged()
				app:refresh()
			end,
			Parent = card,
		})

		Widgets.button({
			Text = "Remove character",
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, 0, 0, 0),
			Size = UDim2.new(0, 130, 0, 24),
			Color = Theme.Danger,
			TextSize = 11,
			OnClick = function()
				app:showConfirm("Remove " .. record.name .. "?", "Their portraits go to the recycle bin. Lines keep the name.", function()
					ProjectStore.removeCharacter(record.name)
					app:refresh()
				end)
			end,
			Parent = card,
		})

		local gallery = Widgets.scroll({
			Position = UDim2.new(0, 0, 0, 32),
			Size = UDim2.new(1, 0, 0, 66),
			Axis = Enum.AutomaticSize.X,
			ScrollBarThickness = 4,
			Parent = card,
		}, { Widgets.hlist(6, Enum.VerticalAlignment.Top) })

		for index, imageId in ipairs(record.portraits) do
			local isPriority = Schema.getCharacterPriorityPortrait(project, record.name) == imageId
			local tile = Widgets.create("ImageButton", {
				Size = UDim2.fromOffset(56, 56),
				BackgroundColor3 = Theme.Input,
				BorderSizePixel = 0,
				Image = imageId,
				ScaleType = Enum.ScaleType.Fit,
				AutoButtonColor = false,
				LayoutOrder = index,
				Parent = gallery,
			}, { Widgets.corner(6), Widgets.stroke(isPriority and Theme.Gold or Theme.Border, isPriority and 2 or 1, isPriority and 0 or 0.4) })

			tile.MouseButton1Click:Connect(function()
				if not isPriority and Schema.setCharacterPriorityPortrait(project, record.name, imageId) then
					ProjectStore.markChanged()
					app:refresh()
				end
			end)

			tile.MouseButton2Click:Connect(function()
				if isPriority then
					Schema.setCharacterPriorityPortrait(project, record.name, false)
					ProjectStore.markChanged()
					app:refresh()
					return
				end
				app:showConfirm("Remove portrait?", "It moves to the recycle bin.", function()
					ProjectStore.recyclePortrait(record.name, imageId, app.scene and { app.scene } or nil)
					app:refresh()
				end)
			end)
		end

		if self.addingPortraitFor == record.name then
			local box
			box = Widgets.textBox({
				-- Roblox otherwise renders its class-name placeholder ("TextBox")
				-- before the author has entered an image asset id.
				Text = "",
				PlaceholderText = "image id or rbxassetid://...",
				Size = UDim2.fromOffset(120, 56),
				TextYAlignment = Enum.TextYAlignment.Center,
				Font = Theme.FontMono,
				TextSize = 11,
				LayoutOrder = #record.portraits + 1,
				OnCommit = function(text, enterPressed)
					self.addingPortraitFor = nil
					if enterPressed then
						local added, formatted = ProjectStore.addPortrait(record.name, text)
						if not added then
							app:notify(formatted == "" and "Paste an asset id." or "Already in the gallery.", Theme.Danger)
						end
					end
					app:refresh()
				end,
				Parent = gallery,
			})
			task.defer(function()
				if box.Parent then
					box:CaptureFocus()
				end
			end)
		else
			Widgets.button({
				Text = "+",
				Size = UDim2.fromOffset(56, 56),
				TextSize = 20,
				LayoutOrder = #record.portraits + 1,
				OnClick = function()
					self.addingPortraitFor = record.name
					app:refresh()
				end,
				Parent = gallery,
			})
		end

		local modelSection = Widgets.create("Frame", {
			Position = UDim2.new(0, 0, 0, 106), Size = UDim2.new(1, 0, 0, 68),
			BackgroundTransparency = 1, Parent = card,
		})
		local validModel = characterModelPreview(modelSection, record.modelRef)
		Widgets.label({
			Text = "3D MODEL", Position = UDim2.fromOffset(72, 0), Size = UDim2.new(1, -72, 0, 14),
			Font = Theme.FontBold, TextSize = 10, TextColor3 = Theme.TextFaint, Parent = modelSection,
		})
		Widgets.label({
			Text = record.modelRef and (validModel and "Template selected" or "Template missing or invalid") or "No template selected",
			Position = UDim2.fromOffset(72, 15), Size = UDim2.new(1, -72, 0, 14),
			TextSize = 11, TextColor3 = validModel and Theme.TextDim or Theme.TextFaint, Parent = modelSection,
		})
		Widgets.button({
			Text = record.modelRef and "Replace model" or "Pick model",
			Position = UDim2.fromOffset(72, 34), Size = UDim2.fromOffset(112, 26), Color = Theme.Accent, TextSize = 10,
			OnClick = function()
				app:pickTarget(function(_, target, targetRef)
					if isCharacterTemplate(target) then
						ProjectStore.setCharacterModel(record.name, targetRef)
						app:refresh()
					end
				end, {
					assignId = false,
					prompt = "Click a character Model with a Humanoid and HumanoidRootPart to use as this character's 3D template.",
					invalidPrompt = "Choose a Model containing both a Humanoid and HumanoidRootPart.",
					validate = function(target)
						return isCharacterTemplate(target) and not target:GetAttribute("VNCharacterPlacementId")
					end,
				})
			end,
			Parent = modelSection,
		})
		if record.modelRef then
			Widgets.button({
				Text = "Clear", Position = UDim2.fromOffset(190, 34), Size = UDim2.fromOffset(58, 26),
				Color = Theme.Danger, TextSize = 10,
				OnClick = function() ProjectStore.setCharacterModel(record.name, nil); app:refresh() end,
				Parent = modelSection,
			})
		end
	end

	if self.addingCharacter then
		local box
		box = Widgets.textBox({
			PlaceholderText = "character name",
			Size = UDim2.new(0, 200, 0, 28),
			TextYAlignment = Enum.TextYAlignment.Center,
			LayoutOrder = self:_next(),
			OnCommit = function(text, enterPressed)
				self.addingCharacter = false
				if enterPressed and not ProjectStore.addCharacter(text) then
					app:notify("Character names must be unique and not empty.", Theme.Danger)
				end
				app:refresh()
			end,
			Parent = self.list,
		})
		task.defer(function()
			if box.Parent then
				box:CaptureFocus()
			end
		end)
	else
		self:_addButton("+ New character", function()
			self.addingCharacter = true
			app:refresh()
		end)
	end
end

--------------------------------------------------------------------------------
-- Shared portrait placement
--------------------------------------------------------------------------------

function PresetsView:_renderPortraitLayoutEditor()
	local app = self.app
	local project = app:getProject()
	local draft = self.portraitLayoutDraft or Schema.normalizePortraitLayout(project.portraitLayout)
	self.portraitLayoutDraft = draft

	local portraits = {}
	for _, character in ipairs(project.characters) do
		for _, imageId in ipairs(character.portraits) do
			table.insert(portraits, {
				character = character.name,
				imageId = imageId,
			})
		end
	end

	if not self.selectedLayoutPortrait and portraits[1] then
		self.selectedLayoutPortrait = portraits[1].imageId
	end

	Widgets.button({
		Text = "← Back",
		Position = UDim2.fromOffset(0, 0),
		Size = UDim2.fromOffset(84, 26),
		TextSize = 11,
		OnClick = function()
			self.portraitLayoutEditor = false
			self.portraitLayoutDraft = nil
			self.selectedLayoutPortrait = nil
			self:render()
		end,
		Parent = self.tabs,
	})

	Widgets.button({
		Text = "Apply to all portraits",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 0, 0, 0),
		Size = UDim2.fromOffset(154, 26),
		Color = Theme.Good,
		TextSize = 11,
		OnClick = function()
			project.portraitLayout = Schema.normalizePortraitLayout(draft)
			self.portraitLayoutEditor = false
			self.portraitLayoutDraft = nil
			self.selectedLayoutPortrait = nil
			ProjectStore.markChanged()
			app:refresh()
		end,
		Parent = self.tabs,
	})

	local editor = Widgets.create("Frame", {
		Size = UDim2.new(1, -6, 0, 490),
		BackgroundColor3 = Theme.Row,
		BorderSizePixel = 0,
		LayoutOrder = self:_next(),
		Parent = self.list,
	}, { Widgets.corner(6), Widgets.padding(8, 10, 8, 10) })

	Widgets.label({
		Text = "Portrait placement",
		Size = UDim2.new(1, 0, 0, 20),
		Font = Theme.FontBold,
		TextSize = 13,
		Parent = editor,
	})

	Widgets.label({
		Text = "Drag the image to move it. Use the edge and corner handles to stretch width and height independently; the center ⤢ handle keeps proportional resizing. Apply saves this shared transform for every character portrait.",
		Position = UDim2.fromOffset(0, 22),
		Size = UDim2.new(1, 0, 0, 34),
		TextSize = 10,
		TextColor3 = Theme.TextFaint,
		TextWrapped = true,
		TextTruncate = Enum.TextTruncate.None,
		Parent = editor,
	})

	-- Portrait sizes are expressed in screen-scale units. Keep this canvas at
	-- the same aspect ratio as StageView's actual full-screen root; a square
	-- editor canvas makes a 0.28 x 0.72 portrait look misleadingly tall.
	local stageSize = app.presenter:getStage().root.AbsoluteSize
	local screenAspect = stageSize.Y > 0 and stageSize.X / stageSize.Y or 16 / 9
	local previewY = 62
	local availableWidth = math.max(320, self.list.AbsoluteSize.X - 26)
	local previewHeight = math.min(330, availableWidth / screenAspect)
	local previewWidth = previewHeight * screenAspect
	local portraitsY = previewY + previewHeight + 8
	local shelfY = portraitsY + 20

	-- This editor is laid out after the actual canvas dimensions are known, so
	-- the portrait shelf never overlaps a wide-screen preview on larger windows.
	editor.Size = UDim2.new(1, -6, 0, shelfY + 68)

	local preview = Widgets.create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, previewY),
		Size = UDim2.fromOffset(previewWidth, previewHeight),
		BackgroundColor3 = Theme.Backdrop,
		BorderSizePixel = 0,
		ClipsDescendants = true,
		Parent = editor,
	}, { Widgets.corner(5), Widgets.stroke(Theme.Border, 1, 0.25) })

	Widgets.label({
		Text = string.format("Player screen preview  (%.2f:1)", screenAspect),
		Position = UDim2.fromOffset(8, 6),
		Size = UDim2.fromOffset(120, 16),
		TextSize = 10,
		TextColor3 = Theme.TextFaint,
		Parent = preview,
	})

	local portrait = Widgets.create("ImageLabel", {
		Name = "PortraitPreview",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.fromScale(draft.x, draft.y),
		Size = UDim2.fromScale(0.28 * draft.scaleX, 0.72 * draft.scaleY),
		BackgroundTransparency = 1,
		Image = self.selectedLayoutPortrait or "",
		-- Match the runtime portrait rectangle exactly. A fitted square image is
		-- vertically centered in a tall box, which creates a false lower limit.
		ScaleType = Enum.ScaleType.Stretch,
		Active = true,
		Parent = preview,
	})

	-- Keep the drag surface below the resize control. That makes a press on the
	-- handle unambiguously resize instead of also starting a move drag.
	local moveSurface = Widgets.create("TextButton", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Text = "",
		AutoButtonColor = false,
		ZIndex = 1,
		Parent = portrait,
	})


	local function resizeHandle(label, anchorPoint, position)
		return Widgets.button({
			Text = label,
			AnchorPoint = anchorPoint,
			Position = position,
			Size = UDim2.fromOffset(18, 18),
			Color = Theme.Accent,
			TextSize = 11,
			ZIndex = 2,
			Parent = portrait,
		})
	end

	-- Each handle modifies a real edge of the transform rectangle. They are
	-- deliberately children of the portrait so they remain attached while a
	-- resize changes its dimensions.
	local handles = {
		left = resizeHandle("↔", Vector2.new(1, 0.5), UDim2.fromScale(0, 0.5)),
		right = resizeHandle("↔", Vector2.new(0, 0.5), UDim2.fromScale(1, 0.5)),
		top = resizeHandle("↕", Vector2.new(0.5, 1), UDim2.fromScale(0.5, 0)),
		bottom = resizeHandle("↕", Vector2.new(0.5, 0), UDim2.fromScale(0.5, 1)),
		topLeft = resizeHandle("↖", Vector2.new(1, 1), UDim2.fromScale(0, 0)),
		topRight = resizeHandle("↗", Vector2.new(0, 1), UDim2.fromScale(1, 0)),
		bottomLeft = resizeHandle("↙", Vector2.new(1, 0), UDim2.fromScale(0, 1)),
		bottomRight = resizeHandle("↘", Vector2.new(0, 0), UDim2.fromScale(1, 1)),
		uniform = resizeHandle("⤢", Vector2.new(0.5, 0.5), UDim2.fromScale(0.5, 0.5)),
	}

	local valueLabel = Widgets.label({
		Position = UDim2.new(0, 8, 1, -24),
		Size = UDim2.new(1, -16, 0, 18),
		TextSize = 10,
		TextColor3 = Theme.TextFaint,
		TextXAlignment = Enum.TextXAlignment.Center,
		Parent = preview,
	})

	local function syncPreview()
		portrait.Position = UDim2.fromScale(draft.x, draft.y)
		portrait.Size = UDim2.fromScale(0.28 * draft.scaleX, 0.72 * draft.scaleY)
		valueLabel.Text = string.format(
			"X %.2f   Y %.2f   Width %.2fx   Height %.2fx",
			draft.x,
			draft.y,
			draft.scaleX,
			draft.scaleY
		)
	end

	local function clampPosition(value)
		return math.clamp(value, -1, 2)
	end

	local function clampScale(value)
		return math.clamp(
			value,
			Schema.MIN_PORTRAIT_LAYOUT_SCALE,
			Schema.MAX_PORTRAIT_LAYOUT_SCALE
		)
	end

	local function beginDrag(mode, input)
		if input.UserInputType ~= Enum.UserInputType.MouseButton1
			and input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end

		local origin = input.Position
		local original = table.clone(draft)
		local originalWidth = 0.28 * original.scaleX
		local originalHeight = 0.72 * original.scaleY
		local originalLeft = original.x - originalWidth / 2
		local originalRight = original.x + originalWidth / 2
		local originalTop = original.y - originalHeight
		local originalBottom = original.y
		local moveConnection
		local endConnection

		moveConnection = UserInputService.InputChanged:Connect(function(changed)
			if changed ~= input and changed.UserInputType ~= Enum.UserInputType.MouseMovement then
				return
			end

			local size = preview.AbsoluteSize
			if size.X <= 0 or size.Y <= 0 then
				return
			end

			local delta = changed.Position - origin
			local deltaX = delta.X / size.X
			local deltaY = delta.Y / size.Y

			if mode == "move" then
				draft.x = clampPosition(original.x + deltaX)
				draft.y = clampPosition(original.y + deltaY)
			elseif mode == "uniform" then
				-- Retains the former proportional control without competing with the
				-- independent edge/corner transform handles.
				local multiplier = math.max(0.05, 1 + deltaX * 2)
				draft.scaleX = clampScale(original.scaleX * multiplier)
				draft.scaleY = clampScale(original.scaleY * multiplier)
			else
				local left = originalLeft
				local right = originalRight
				local top = originalTop
				local bottom = originalBottom

				if mode == "left" or mode == "topLeft" or mode == "bottomLeft" then
					left += deltaX
				elseif mode == "right" or mode == "topRight" or mode == "bottomRight" then
					right += deltaX
				end

				if mode == "top" or mode == "topLeft" or mode == "topRight" then
					top += deltaY
				elseif mode == "bottom" or mode == "bottomLeft" or mode == "bottomRight" then
					bottom += deltaY
				end

				local minimumWidth = 0.28 * Schema.MIN_PORTRAIT_LAYOUT_SCALE
				local minimumHeight = 0.72 * Schema.MIN_PORTRAIT_LAYOUT_SCALE
				local maximumWidth = 0.28 * Schema.MAX_PORTRAIT_LAYOUT_SCALE
				local maximumHeight = 0.72 * Schema.MAX_PORTRAIT_LAYOUT_SCALE
				if right - left < minimumWidth then
					if mode == "left" or mode == "topLeft" or mode == "bottomLeft" then
						left = right - minimumWidth
					else
						right = left + minimumWidth
					end
				end
				if right - left > maximumWidth then
					if mode == "left" or mode == "topLeft" or mode == "bottomLeft" then
						left = right - maximumWidth
					else
						right = left + maximumWidth
					end
				end
				if bottom - top < minimumHeight then
					if mode == "top" or mode == "topLeft" or mode == "topRight" then
						top = bottom - minimumHeight
					else
						bottom = top + minimumHeight
					end
				end
				if bottom - top > maximumHeight then
					if mode == "top" or mode == "topLeft" or mode == "topRight" then
						top = bottom - maximumHeight
					else
						bottom = top + maximumHeight
					end
				end

				draft.x = clampPosition((left + right) / 2)
				draft.y = clampPosition(bottom)
				draft.scaleX = clampScale((right - left) / 0.28)
				draft.scaleY = clampScale((bottom - top) / 0.72)
			end
			syncPreview()
		end)

		endConnection = UserInputService.InputEnded:Connect(function(ended)
			if ended == input or ended.UserInputType == Enum.UserInputType.MouseButton1 then
				moveConnection:Disconnect()
				endConnection:Disconnect()
			end
		end)

		table.insert(self.layoutConnections, moveConnection)
		table.insert(self.layoutConnections, endConnection)
	end

	self:_layoutConnect(moveSurface.InputBegan, function(input)
		beginDrag("move", input)
	end)
	for mode, handle in pairs(handles) do
		local resizeMode = mode
		self:_layoutConnect(handle.InputBegan, function(input)
			beginDrag(resizeMode, input)
		end)
	end

	Widgets.label({
		Text = "Portraits",
		Position = UDim2.fromOffset(0, portraitsY),
		Size = UDim2.new(1, 0, 0, 16),
		Font = Theme.FontBold,
		TextSize = 10,
		TextColor3 = Theme.TextFaint,
		Parent = editor,
	})

	local shelf = Widgets.scroll({
		Position = UDim2.fromOffset(0, shelfY),
		Size = UDim2.new(1, 0, 0, 58),
		Axis = Enum.AutomaticSize.X,
		ScrollBarThickness = 4,
		Parent = editor,
	}, { Widgets.hlist(5, Enum.VerticalAlignment.Top) })

	if #portraits == 0 then
		Widgets.label({
			Text = "Add a character portrait first to preview its shared placement.",
			Size = UDim2.new(1, 0, 1, 0),
			TextSize = 10,
			TextColor3 = Theme.TextFaint,
			Parent = shelf,
		})
	else
		for index, record in ipairs(portraits) do
			local selected = record.imageId == self.selectedLayoutPortrait
			local tile = Widgets.create("ImageButton", {
				Size = UDim2.fromOffset(52, 52),
				BackgroundColor3 = selected and Theme.Accent or Theme.Input,
				BorderSizePixel = 0,
				Image = record.imageId,
				ScaleType = Enum.ScaleType.Fit,
				AutoButtonColor = false,
				LayoutOrder = index,
				Parent = shelf,
			}, { Widgets.corner(5), Widgets.stroke(Theme.Border, 1, 0.35) })

			self:_layoutConnect(tile.MouseButton1Click, function()
				self.selectedLayoutPortrait = record.imageId
				self:render()
			end)
		end
	end

	syncPreview()
end

--------------------------------------------------------------------------------
-- Camera poses
--------------------------------------------------------------------------------

function PresetsView:_renderPoses()
	local app = self.app
	local project = app:getProject()

	Widgets.hint("Camera poses are fixed viewpoints on your map. Capture flies the camera (WASD, Q/E, right drag to look, Shift for speed); press Capture when it looks right.", self.list, 34).LayoutOrder = self:_next()

	for _, pose in ipairs(project.cameraPoses) do
		local card = self:_card(64)

		Widgets.textBox({
			Text = pose.name,
			Size = UDim2.new(0, 220, 0, 24),
			TextYAlignment = Enum.TextYAlignment.Center,
			Font = Theme.FontBold,
			OnCommit = function(text)
				local trimmed = Schema.trimName(text)
				if trimmed ~= "" then
					ProjectStore.updateCameraPose(pose.id, { name = trimmed })
				end
				app:refresh()
			end,
			Parent = card,
		})

		local cframe = Schema.decodeCFrame(pose.cframe)
		Widgets.label({
			Text = cframe and string.format("at %.1f, %.1f, %.1f", cframe.X, cframe.Y, cframe.Z) or "invalid",
			Position = UDim2.new(0, 0, 0, 28),
			Size = UDim2.new(0, 220, 0, 16),
			TextSize = 10,
			Font = Theme.FontMono,
			TextColor3 = Theme.TextFaint,
			Parent = card,
		})

		local actions = Widgets.create("Frame", {
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, 0, 0, 0),
			Size = UDim2.new(0, 0, 0, 24),
			AutomaticSize = Enum.AutomaticSize.X,
			BackgroundTransparency = 1,
			Parent = card,
		}, { Widgets.hlist(6) })

		Widgets.button({
			Text = "Look through",
			Size = UDim2.new(0, 100, 1, 0),
			TextSize = 11,
			LayoutOrder = 1,
			OnClick = function()
				app:previewPose(pose)
			end,
			Parent = actions,
		})

		Widgets.button({
			Text = "Re-capture",
			Size = UDim2.new(0, 90, 1, 0),
			TextSize = 11,
			LayoutOrder = 2,
			OnClick = function()
				app:captureCamera(function(cframeText)
					ProjectStore.updateCameraPose(pose.id, { cframe = cframeText })
					app:refresh()
				end, cframe)
			end,
			Parent = actions,
		})

		Widgets.button({
			Text = "x",
			Size = UDim2.new(0, 24, 1, 0),
			Color = Theme.Danger,
			TextSize = 11,
			LayoutOrder = 3,
			OnClick = function()
				app:showConfirm("Delete pose?", "Scenes and events pointing at it will fall back to no pose.", function()
					ProjectStore.removeCameraPose(pose.id)
					app:refresh()
				end)
			end,
			Parent = actions,
		})
	end

	self:_addButton("+ Capture new pose", function()
		app:captureCamera(function(cframeText)
			ProjectStore.addCameraPose("Pose " .. (#project.cameraPoses + 1), cframeText)
			app:refresh()
		end)
	end)
end

--------------------------------------------------------------------------------
-- Textbox presets
--------------------------------------------------------------------------------

function PresetsView:_animEditor(parent, y, label, anim, onChange)
	local app = self.app

	Widgets.label({
		Text = label,
		Position = UDim2.new(0, 0, 0, y),
		Size = UDim2.new(0, 90, 0, 22),
		TextSize = 11,
		TextColor3 = Theme.TextDim,
		Parent = parent,
	})

	local kindItems = {}
	for _, kind in ipairs(Schema.ANIM_KINDS) do
		table.insert(kindItems, { id = kind, label = kind })
	end

	Widgets.dropdown(app.gui, {
		Items = kindItems,
		Value = anim.inKind,
		Position = UDim2.new(0, 96, 0, y),
		Size = UDim2.new(0, 110, 0, 22),
		OnPick = function(kind)
			anim.inKind = kind
			onChange()
		end,
		Parent = parent,
	})

	Widgets.label({
		Text = "in",
		Position = UDim2.new(0, 210, 0, y),
		Size = UDim2.new(0, 20, 0, 22),
		TextSize = 10,
		TextColor3 = Theme.TextFaint,
		Parent = parent,
	})

	Widgets.dropdown(app.gui, {
		Items = kindItems,
		Value = anim.outKind,
		Position = UDim2.new(0, 232, 0, y),
		Size = UDim2.new(0, 110, 0, 22),
		OnPick = function(kind)
			anim.outKind = kind
			onChange()
		end,
		Parent = parent,
	})

	Widgets.label({
		Text = "out",
		Position = UDim2.new(0, 346, 0, y),
		Size = UDim2.new(0, 24, 0, 22),
		TextSize = 10,
		TextColor3 = Theme.TextFaint,
		Parent = parent,
	})

	Widgets.textBox({
		Text = string.format("%.2f", anim.duration),
		Position = UDim2.new(0, 374, 0, y),
		Size = UDim2.new(0, 50, 0, 22),
		TextYAlignment = Enum.TextYAlignment.Center,
		Font = Theme.FontMono,
		TextSize = 10,
		Flat = true,
		OnCommit = function(text)
			anim.duration = math.max(0, tonumber(text) or anim.duration)
			onChange()
		end,
		Parent = parent,
	})

	Widgets.label({
		Text = "s",
		Position = UDim2.new(0, 426, 0, y),
		Size = UDim2.new(0, 12, 0, 22),
		TextSize = 10,
		TextColor3 = Theme.TextFaint,
		Parent = parent,
	})

	Widgets.textBox({
		Text = string.format("%.2f", anim.delay),
		Position = UDim2.new(0, 444, 0, y),
		Size = UDim2.new(0, 50, 0, 22),
		TextYAlignment = Enum.TextYAlignment.Center,
		Font = Theme.FontMono,
		TextSize = 10,
		Flat = true,
		OnCommit = function(text)
			anim.delay = math.max(0, tonumber(text) or anim.delay)
			onChange()
		end,
		Parent = parent,
	})

	Widgets.label({
		Text = "delay",
		Position = UDim2.new(0, 496, 0, y),
		Size = UDim2.new(0, 40, 0, 22),
		TextSize = 10,
		TextColor3 = Theme.TextFaint,
		Parent = parent,
	})

	local easingItems = {}
	for _, easing in ipairs(Schema.EASINGS) do
		table.insert(easingItems, { id = easing, label = easing })
	end

	Widgets.dropdown(app.gui, {
		Items = easingItems,
		Value = anim.easing,
		Position = UDim2.new(0, 540, 0, y),
		Size = UDim2.new(0, 90, 0, 22),
		OnPick = function(easing)
			anim.easing = easing
			onChange()
		end,
		Parent = parent,
	})
end

function PresetsView:_renderTextboxes()
	local app = self.app
	local project = app:getProject()

	Widgets.hint("Textbox styles control how each element of the dialogue box animates in and out, and the typewriter speed. Dialogue blocks and the Textbox Style event pick a style.", self.list, 34).LayoutOrder = self:_next()

	for _, preset in ipairs(project.textboxPresets) do
		-- Keep room for every configurable element as the textbox-style schema
		-- grows; SPEAKING is now an independent top-bar animation slot.
		local card = self:_card(34 + #Schema.TEXTBOX_ELEMENTS * 28 + 8)

		Widgets.textBox({
			Text = preset.name,
			Size = UDim2.new(0, 220, 0, 24),
			TextYAlignment = Enum.TextYAlignment.Center,
			Font = Theme.FontBold,
			OnCommit = function(text)
				local trimmed = Schema.trimName(text)
				if trimmed ~= "" then
					preset.name = trimmed
					ProjectStore.markChanged()
				end
				app:refresh()
			end,
			Parent = card,
		})

		Widgets.label({
			Text = "typewriter chars/sec",
			Position = UDim2.new(0, 232, 0, 0),
			Size = UDim2.new(0, 120, 0, 24),
			TextSize = 10,
			TextColor3 = Theme.TextFaint,
			Parent = card,
		})

		Widgets.textBox({
			Text = tostring(preset.typewriterCps),
			Position = UDim2.new(0, 354, 0, 0),
			Size = UDim2.new(0, 60, 0, 24),
			TextYAlignment = Enum.TextYAlignment.Center,
			Font = Theme.FontMono,
			TextSize = 11,
			OnCommit = function(text)
				preset.typewriterCps = math.max(0, tonumber(text) or preset.typewriterCps)
				ProjectStore.markChanged()
				app:refresh()
			end,
			Parent = card,
		})

		if preset.id ~= Schema.DEFAULT_TEXTBOX then
			Widgets.button({
				Text = "x",
				AnchorPoint = Vector2.new(1, 0),
				Position = UDim2.new(1, 0, 0, 0),
				Size = UDim2.new(0, 24, 0, 24),
				Color = Theme.Danger,
				TextSize = 11,
				OnClick = function()
					ProjectStore.removeTextboxPreset(preset.id)
					app:refresh()
				end,
				Parent = card,
			})
		end

		local y = 34
		local labels = {
			box = "Box",
			namePlate = "Name plate",
			speaking = "Speaking",
			body = "Text",
			continueHint = "Continue hint",
		}
		for _, elementName in ipairs(Schema.TEXTBOX_ELEMENTS) do
			self:_animEditor(card, y, labels[elementName], preset.elements[elementName], function()
				ProjectStore.markChanged()
				app:refresh()
			end)
			y += 28
		end
	end

	self:_addButton("+ New textbox style", function()
		ProjectStore.addTextboxPreset("Style " .. (#project.textboxPresets + 1))
		app:refresh()
	end)
end

-- System
--------------------------------------------------------------------------------

function PresetsView:_renderSystem()
	local app = self.app
	local project = app:getProject()
	project.exploreMovement = Schema.normalizeExploreMovementSettings(project.exploreMovement)
	project.speakerSweep = Schema.normalizeSpeakerSweepSettings(project.speakerSweep)
	project.hotspotZoom = Schema.normalizeHotspotZoomSettings(project.hotspotZoom)
	project.portraitTiming = Schema.normalizePortraitTimingSettings(project.portraitTiming)
	local settings = project.exploreMovement
	local sweepSettings = project.speakerSweep
	local zoomSettings = project.hotspotZoom
	local portraitTiming = project.portraitTiming

	Widgets.hint("Project-wide movement and dialogue-camera feel. Explore3D sprinting, camera bob, and the one-shot footstep sample apply only while Explore3D is in AWAIT.", self.list, 40).LayoutOrder = self:_next()
	local card = self:_card(266)
	Widgets.label({
		Text = "EXPLORE3D MOVEMENT", Position = UDim2.fromOffset(0, 0), Size = UDim2.new(1, 0, 0, 18),
		Font = Theme.FontBold, TextSize = 11, TextColor3 = Theme.TextDim, Parent = card,
	})

	local function numberField(label, y, value, minimum, maximum, onCommit)
		Widgets.label({
			Text = label, Position = UDim2.fromOffset(0, y), Size = UDim2.new(1, -92, 0, 24),
			TextSize = 11, TextColor3 = Theme.TextFaint, Parent = card,
		})
		Widgets.textBox({
			Text = string.format("%.2f", value), Position = UDim2.new(1, -84, 0, y), Size = UDim2.fromOffset(84, 24),
			TextYAlignment = Enum.TextYAlignment.Center, Font = Theme.FontMono, TextSize = 11,
			OnCommit = function(text)
				local parsed = tonumber(text)
				if parsed then onCommit(math.clamp(parsed, minimum, maximum)) end
				ProjectStore.markChanged()
				app:refresh()
			end,
			Parent = card,
		})
	end

	numberField("Sprint multiplier", 28, settings.sprintMultiplier, 1, 4, function(value)
		settings.sprintMultiplier = value
	end)
	numberField("Camera bob intensity", 58, settings.bobIntensity, 0, 0.35, function(value)
		settings.bobIntensity = value
	end)
	numberField("Camera bob rate", 88, settings.bobSpeed, 0.1, 3, function(value)
		settings.bobSpeed = value
	end)
	Widgets.label({
		Text = "Auto footstep timing", Position = UDim2.fromOffset(0, 118), Size = UDim2.new(1, -62, 0, 24),
		TextSize = 11, TextColor3 = Theme.TextFaint, Parent = card,
	})
	Widgets.toggle({
		Value = settings.footstepAuto,
		Position = UDim2.new(1, -50, 0, 118), Size = UDim2.fromOffset(50, 24),
		OnToggle = function(value)
			settings.footstepAuto = value
			ProjectStore.markChanged()
			app:refresh()
		end,
		Parent = card,
	})
	if settings.footstepAuto then
		numberField("Footstep delay (seconds)", 148, settings.footstepDelay, -1, 2, function(value)
			settings.footstepDelay = value
		end)
	else
		numberField("Footstep spacing (studs)", 148, settings.footstepStride, 0.5, 12, function(value)
			settings.footstepStride = value
		end)
	end
	numberField("Footstep volume", 178, settings.footstepVolume, 0, 2, function(value)
		settings.footstepVolume = value
	end)

	Widgets.label({
		Text = "Footstep sound id", Position = UDim2.fromOffset(0, 210), Size = UDim2.new(1, 0, 0, 16),
		TextSize = 11, TextColor3 = Theme.TextFaint, Parent = card,
	})
	Widgets.textBox({
		Text = settings.footstepSoundId, Position = UDim2.fromOffset(0, 230), Size = UDim2.new(1, 0, 0, 24),
		TextYAlignment = Enum.TextYAlignment.Center, Font = Theme.FontMono, TextSize = 11,
		OnCommit = function(text)
			local assetId = Schema.formatImageId(text)
			if assetId ~= "" then settings.footstepSoundId = assetId end
			ProjectStore.markChanged()
			app:refresh()
		end,
		Parent = card,
	})

	local sweepCard = self:_card(198)
	Widgets.label({
		Text = "PORTRAIT CAMERA SWEEPS", Position = UDim2.fromOffset(0, 0), Size = UDim2.new(1, 0, 0, 18),
		Font = Theme.FontBold, TextSize = 11, TextColor3 = Theme.TextDim, Parent = sweepCard,
	})
	Widgets.label({
		Text = "Side and backward distance form the diagonal sweep arc. Applies to Room3D and Explore3D.", Position = UDim2.fromOffset(0, 18), Size = UDim2.new(1, 0, 0, 16),
		TextSize = 10, TextColor3 = Theme.TextFaint, Parent = sweepCard,
	})
	local function sweepNumberField(label, y, value, minimum, maximum, onCommit)
		Widgets.label({
			Text = label, Position = UDim2.fromOffset(0, y), Size = UDim2.new(1, -92, 0, 24),
			TextSize = 11, TextColor3 = Theme.TextFaint, Parent = sweepCard,
		})
		Widgets.textBox({
			Text = string.format("%.2f", value), Position = UDim2.new(1, -84, 0, y), Size = UDim2.fromOffset(84, 24),
			TextYAlignment = Enum.TextYAlignment.Center, Font = Theme.FontMono, TextSize = 11,
			OnCommit = function(text)
				local parsed = tonumber(text)
				if parsed then onCommit(math.clamp(parsed, minimum, maximum)) end
				ProjectStore.markChanged()
				app:refresh()
			end,
			Parent = sweepCard,
		})
	end
	sweepNumberField("Turn angle (degrees)", 40, sweepSettings.yawDegrees, 0, 90, function(value)
		sweepSettings.yawDegrees = value
	end)
	sweepNumberField("Side distance (studs)", 70, sweepSettings.sideDistance, 0, 20, function(value)
		sweepSettings.sideDistance = value
	end)
	sweepNumberField("Backward distance (studs)", 100, sweepSettings.backwardDistance, 0, 20, function(value)
		sweepSettings.backwardDistance = value
	end)
	sweepNumberField("Sweep duration (seconds)", 130, sweepSettings.duration, 0.05, 2.5, function(value)
		sweepSettings.duration = value
	end)
	Widgets.label({
		Text = "Sweep easing", Position = UDim2.fromOffset(0, 162), Size = UDim2.new(1, -92, 0, 24),
		TextSize = 11, TextColor3 = Theme.TextFaint, Parent = sweepCard,
	})
	local easingItems = {}
	for _, easing in ipairs(Schema.EASINGS) do
		table.insert(easingItems, { id = easing, label = easing })
	end
	Widgets.dropdown(app.gui, {
		Items = easingItems,
		Value = sweepSettings.easing,
		Position = UDim2.new(1, -84, 0, 162),
		Size = UDim2.fromOffset(84, 24),
		OnPick = function(value)
			sweepSettings.easing = value
			ProjectStore.markChanged()
			app:refresh()
		end,
		Parent = sweepCard,
	})

	local zoomCard = self:_card(230)
	Widgets.label({
		Text = "HOTSPOT ZOOM", Position = UDim2.fromOffset(0, 0), Size = UDim2.new(1, 0, 0, 18),
		Font = Theme.FontBold, TextSize = 11, TextColor3 = Theme.TextDim, Parent = zoomCard,
	})
	Widgets.label({
		Text = "Controls the look, push, return, and placed-model fades for every Hotspot Zoom transition.", Position = UDim2.fromOffset(0, 18), Size = UDim2.new(1, 0, 0, 16),
		TextSize = 10, TextColor3 = Theme.TextFaint, Parent = zoomCard,
	})
	local function zoomNumberField(label, y, key, minimum, maximum)
		Widgets.label({
			Text = label, Position = UDim2.fromOffset(0, y), Size = UDim2.new(1, -92, 0, 24),
			TextSize = 11, TextColor3 = Theme.TextFaint, Parent = zoomCard,
		})
		Widgets.textBox({
			Text = string.format("%.2f", zoomSettings[key]), Position = UDim2.new(1, -84, 0, y), Size = UDim2.fromOffset(84, 24),
			TextYAlignment = Enum.TextYAlignment.Center, Font = Theme.FontMono, TextSize = 11,
			OnCommit = function(text)
				local parsed = tonumber(text)
				if parsed then zoomSettings[key] = math.clamp(parsed, minimum, maximum) end
				ProjectStore.markChanged()
				app:refresh()
			end,
			Parent = zoomCard,
		})
	end
	zoomNumberField("Initial look (seconds)", 40, "lookDuration", 0, 3)
	zoomNumberField("Zoom in (seconds)", 70, "zoomInDuration", 0.05, 5)
	zoomNumberField("Zoom out (seconds)", 100, "zoomOutDuration", 0.05, 5)
	zoomNumberField("Model fade out (seconds)", 130, "modelFadeOutDuration", 0, 5)
	zoomNumberField("Model fade in (seconds)", 160, "modelFadeInDuration", 0, 5)
	Widgets.label({
		Text = "Zoom easing", Position = UDim2.fromOffset(0, 192), Size = UDim2.new(1, -92, 0, 24),
		TextSize = 11, TextColor3 = Theme.TextFaint, Parent = zoomCard,
	})
	Widgets.dropdown(app.gui, {
		Items = easingItems,
		Value = zoomSettings.easing,
		Position = UDim2.new(1, -84, 0, 192),
		Size = UDim2.fromOffset(84, 24),
		OnPick = function(value)
			zoomSettings.easing = value
			ProjectStore.markChanged()
			app:refresh()
		end,
		Parent = zoomCard,
	})

	local portraitCard = self:_card(226)
	Widgets.label({
		Text = "PORTRAIT TRANSITIONS", Position = UDim2.fromOffset(0, 0), Size = UDim2.new(1, 0, 0, 18),
		Font = Theme.FontBold, TextSize = 11, TextColor3 = Theme.TextDim, Parent = portraitCard,
	})
	Widgets.label({
		Text = "Shared timing for portrait swaps and normal entrance/exit fades.", Position = UDim2.fromOffset(0, 18), Size = UDim2.new(1, 0, 0, 16),
		TextSize = 10, TextColor3 = Theme.TextFaint, Parent = portraitCard,
	})
	local function portraitNumberField(label, y, key, minimum, maximum)
		Widgets.label({
			Text = label, Position = UDim2.fromOffset(0, y), Size = UDim2.new(1, -92, 0, 24),
			TextSize = 11, TextColor3 = Theme.TextFaint, Parent = portraitCard,
		})
		Widgets.textBox({
			Text = string.format("%.2f", portraitTiming[key]), Position = UDim2.new(1, -84, 0, y), Size = UDim2.fromOffset(84, 24),
			TextYAlignment = Enum.TextYAlignment.Center, Font = Theme.FontMono, TextSize = 11,
			OnCommit = function(text)
				local parsed = tonumber(text)
				if parsed then portraitTiming[key] = math.clamp(parsed, minimum or 0.05, maximum or 3) end
				ProjectStore.markChanged()
				app:refresh()
			end,
			Parent = portraitCard,
		})
	end
	portraitNumberField("Crossfade (seconds)", 42, "crossfadeDuration")
	portraitNumberField("Fade in (seconds)", 72, "fadeInDuration")
	portraitNumberField("Fade out (seconds)", 102, "fadeOutDuration")
	Widgets.label({
		Text = "Crossfade black flash", Position = UDim2.fromOffset(0, 138), Size = UDim2.new(1, -62, 0, 24),
		TextSize = 11, TextColor3 = Theme.TextFaint, Parent = portraitCard,
	})
	Widgets.toggle({
		Value = portraitTiming.blackFlashEnabled,
		Position = UDim2.new(1, -50, 0, 138), Size = UDim2.fromOffset(50, 24),
		OnToggle = function(value)
			portraitTiming.blackFlashEnabled = value
			ProjectStore.markChanged()
			app:refresh()
		end,
		Parent = portraitCard,
	})
	portraitNumberField("Blackness (0–1)", 168, "blackFlashStrength", 0, 1)
	portraitNumberField("Colour reveal (seconds)", 198, "blackFlashDuration")
end

--------------------------------------------------------------------------------
-- Transitions
--------------------------------------------------------------------------------

function PresetsView:_renderTransitions()
	local app = self.app
	local project = app:getProject()

	Widgets.hint("Transitions play between scenes and around interactions. Fade to black hides the swap, cross fade blends backgrounds, camera sweep flies to the next pose, and Zoom moves toward a target while keeping it visible.", self.list, 34).LayoutOrder = self:_next()

	for _, preset in ipairs(project.transitionPresets) do
		local card = self:_card(66)

		Widgets.textBox({
			Text = preset.name,
			Size = UDim2.new(0, 200, 0, 24),
			TextYAlignment = Enum.TextYAlignment.Center,
			Font = Theme.FontBold,
			OnCommit = function(text)
				local trimmed = Schema.trimName(text)
				if trimmed ~= "" then
					preset.name = trimmed
					ProjectStore.markChanged()
				end
				app:refresh()
			end,
			Parent = card,
		})

		Widgets.label({
			Text = preset.kind,
			Position = UDim2.new(0, 210, 0, 0),
			Size = UDim2.new(0, 100, 0, 24),
			TextSize = 11,
			TextColor3 = Theme.Accent,
			Font = Theme.FontBold,
			Parent = card,
		})

		local x = 0
		local keys = {}
		for key in pairs(preset.params) do
			table.insert(keys, key)
		end
		table.sort(keys)

		for _, key in ipairs(keys) do
			Widgets.label({
				Text = key,
				Position = UDim2.new(0, x, 0, 30),
				Size = UDim2.new(0, 70, 0, 20),
				TextSize = 10,
				TextColor3 = Theme.TextFaint,
				Parent = card,
			})
			if type(preset.params[key]) == "string" then
				local items = {}
				for _, easing in ipairs(Schema.EASINGS) do
					table.insert(items, { id = easing, label = easing })
				end
				Widgets.dropdown(app.gui, {
					Items = items,
					Value = preset.params[key],
					Position = UDim2.new(0, x + 72, 0, 28),
					Size = UDim2.new(0, 90, 0, 22),
					OnPick = function(value)
						preset.params[key] = value
						ProjectStore.markChanged()
						app:refresh()
					end,
					Parent = card,
				})
			else
				Widgets.textBox({
					Text = string.format("%.2f", preset.params[key]),
					Position = UDim2.new(0, x + 72, 0, 28),
					Size = UDim2.new(0, 56, 0, 22),
					TextYAlignment = Enum.TextYAlignment.Center,
					Font = Theme.FontMono,
					TextSize = 10,
					Flat = true,
					OnCommit = function(text)
						preset.params[key] = math.max(0, tonumber(text) or preset.params[key])
						ProjectStore.markChanged()
						app:refresh()
					end,
					Parent = card,
				})
			end
			x += 140
		end

		Widgets.button({
			Text = "x",
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, 0, 0, 0),
			Size = UDim2.new(0, 24, 0, 24),
			Color = Theme.Danger,
			TextSize = 11,
			OnClick = function()
				ProjectStore.removeTransitionPreset(preset.id)
				app:refresh()
			end,
			Parent = card,
		})
	end

	local row = Widgets.create("Frame", {
		Size = UDim2.new(1, 0, 0, 28),
		BackgroundTransparency = 1,
		LayoutOrder = self:_next(),
		Parent = self.list,
	}, { Widgets.hlist(6) })

	for index, kind in ipairs(Schema.TRANSITION_KINDS) do
		Widgets.button({
			Text = "+ " .. kind,
			Size = UDim2.new(0, 130, 1, 0),
			Color = Theme.Accent,
			TextSize = 11,
			LayoutOrder = index,
			OnClick = function()
				ProjectStore.addTransitionPreset(kind, kind)
				app:refresh()
			end,
			Parent = row,
		})
	end
end

--------------------------------------------------------------------------------
-- Render
--------------------------------------------------------------------------------

function PresetsView:_renderSequencePresets()
	local app = self.app
	local project = app:getProject()
	Widgets.hint("Reusable timelines. Room3D exits select one sequence for Exitable and another for Non-exitable. The Yes / No buttons belong to the Room3D exit flow.", self.list, 38).LayoutOrder = self:_next()
	for index, preset in ipairs(project.sequencePresets) do
		local card = self:_card(54)
		Widgets.textBox({
			Text = preset.name,
			Size = UDim2.new(0.48, 0, 0, 26),
			TextYAlignment = Enum.TextYAlignment.Center,
			Font = Theme.FontBold,
			OnCommit = function(text)
				local name = Schema.trimName(text)
				if name ~= "" then preset.name = name; ProjectStore.markChanged() end
				self:render()
			end,
			Parent = card,
		})
		Widgets.label({
			Text = string.format("%d block(s)", #preset.sequence.segments),
			Position = UDim2.new(0, 0, 0, 30), Size = UDim2.new(0, 150, 0, 16),
			TextSize = 10, TextColor3 = Theme.TextDim, Parent = card,
		})
		Widgets.button({
			Text = "Edit sequence", AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -36, 0, 0), Size = UDim2.new(0, 126, 0, 26),
			Color = Theme.Accent, TextSize = 11,
			OnClick = function() app:openSequencePreset(preset.id) end,
			Parent = card,
		})
		if preset.id ~= Schema.DEFAULT_ROOM_EXIT and preset.id ~= Schema.DEFAULT_ROOM_BLOCKED then
			Widgets.button({
				Text = "x", AnchorPoint = Vector2.new(1, 0),
				Position = UDim2.new(1, 0, 0, 0), Size = UDim2.new(0, 28, 0, 26),
				Color = Theme.Danger, TextSize = 11,
				OnClick = function()
					for _, chapter in ipairs(project.chapters) do
						for _, scene in ipairs(chapter.scenes) do
							for _, subscene in ipairs(scene.subscenes or {}) do
								local exiting = subscene.exiting
								if exiting and (exiting.exitablePresetId == preset.id or exiting.blockedPresetId == preset.id) then
									app:notify("This preset is used by a Room3D. Reassign it before deleting.", Theme.Danger)
									return
								end
							end
						end
					end
					table.remove(project.sequencePresets, index)
					ProjectStore.markChanged()
					self:render()
				end,
				Parent = card,
			})
		end
	end
	self:_addButton("+ New sequence preset", function()
		local preset = Schema.newSequencePreset("Sequence preset " .. (#project.sequencePresets + 1))
		table.insert(project.sequencePresets, preset)
		ProjectStore.markChanged()
		app:openSequencePreset(preset.id)
	end)
end

function PresetsView:_renderAssemblies()
	local Assembly = require(root.Core.RoomAssembly)
	local project = self.app:getProject()
	Widgets.hint("Reusable role-based choreography and motion presets. Room bindings live in room definitions, not in templates.",self.list,38).LayoutOrder=self:_next()
	self:_addButton("Preview pop-up room benchmark",function()
		local camera=workspace.CurrentCamera
		if not camera then return end
		local look=camera.CFrame.LookVector * Vector3.new(1,0,1)
		if look.Magnitude<0.01 then look=Vector3.new(0,0,-1) end
		local position=camera.CFrame.Position+look.Unit*45-Vector3.new(0,5,0)
		local origin=CFrame.lookAt(position,position+look.Unit)
		local definition,destination,cleanup=require(root.Core.AssemblyBenchmark).create(origin)
		self.app.assemblyWorkspace:open(definition,destination,cleanup)
	end)
	for _, library in ipairs({ { key="roomDefinitions", title="Room definitions" }, { key="assemblyPresets", title="Reusable templates" } }) do
		Widgets.sectionTitle(library.title,self.list).LayoutOrder=self:_next()
		for index, definition in ipairs(project[library.key]) do
			local card=self:_card(38)
			Widgets.label({Text=definition.name,Size=UDim2.new(0.55,0,1,0),Parent=card})
			Widgets.button({Text="Edit",Position=UDim2.new(0.58,0,0,0),Size=UDim2.new(0.2,-4,0,26),OnClick=function() self.app.assemblyWorkspace:open(definition) end,Parent=card})
			Widgets.button({Text="Delete",Position=UDim2.new(0.8,0,0,0),Size=UDim2.new(0.2,0,0,26),Color=Theme.Danger,OnClick=function()
				if library.key=="roomDefinitions" then
					for _,chapter in ipairs(project.chapters) do for _,scene in ipairs(chapter.scenes) do for _,subscene in ipairs(scene.subscenes or {}) do
						if subscene.roomDefinitionId==definition.id then self.app:notify("Reassign this room definition before deleting it.",Theme.Danger); return end
					end end end
				end
				self.app:showConfirm("Delete assembly",definition.name,function() table.remove(project[library.key],index); ProjectStore.markChanged(); self:render() end)
			end,Parent=card})
		end
	end
	self:_addButton("+ New choreography template",function()
		local definition=Assembly.new("Assembly template")
		for _,role in ipairs(Assembly.ROLES) do local g=Assembly.group(role); g.role=role; table.insert(definition.groups,g) end
		Assembly.generate(definition); table.insert(project.assemblyPresets,definition); ProjectStore.markChanged(); self.app.assemblyWorkspace:open(definition)
	end)
end

function PresetsView:render()
	self.order = 0
	self:_clearLayoutConnections()
	Widgets.clearChildren(self.tabs)
	Widgets.clearChildren(self.list)

	if self.portraitLayoutEditor then
		self:_renderPortraitLayoutEditor()
		return
	end

	Widgets.segmented({
		Options = TABS,
		Value = self.tab,
		Size = UDim2.new(1, 0, 1, 0),
		OnPick = function(id)
			self.tab = id
			self:render()
		end,
		Parent = self.tabs,
	})

	if self.tab == "characters" then
		self:_renderCharacters()
	elseif self.tab == "poses" then
		self:_renderPoses()
	elseif self.tab == "textboxes" then
		self:_renderTextboxes()
	elseif self.tab == "sequences" then
		self:_renderSequencePresets()
	elseif self.tab == "system" then
		self:_renderSystem()
	elseif self.tab == "assembly" then
		self:_renderAssemblies()
	else
		self:_renderTransitions()
	end
end

return PresetsView
