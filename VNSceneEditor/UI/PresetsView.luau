-- Project wide presets: characters and their portraits, camera poses,
-- textbox styles and transitions. Lives in the project browser.

local root = script.Parent.Parent
local ProjectStore = require(root.Core.ProjectStore)
local Schema = require(root.Core.Schema)
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

function PresetsView:_renderCharacters()
	local app = self.app
	local project = app:getProject()

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

	Widgets.hint("Every character owns a gallery of portraits. Lines pick from the gallery of their character. Right click a portrait to move it to the recycle bin.", self.list, 34).LayoutOrder = self:_next()

	for _, record in ipairs(project.characters) do
		local card = self:_card(110)

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
				Schema.forEachSceneInProject(project, function(scene)
					Schema.forEachEntry(scene, function(entry)
						if entry.character == oldName then
							entry.character = trimmed
						end
					end)
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
			local tile = Widgets.create("ImageButton", {
				Size = UDim2.fromOffset(56, 56),
				BackgroundColor3 = Theme.Input,
				BorderSizePixel = 0,
				Image = imageId,
				ScaleType = Enum.ScaleType.Fit,
				AutoButtonColor = false,
				LayoutOrder = index,
				Parent = gallery,
			}, { Widgets.corner(6), Widgets.stroke(Theme.Border, 1, 0.4) })

			tile.MouseButton2Click:Connect(function()
				app:showConfirm("Remove portrait?", "It moves to the recycle bin.", function()
					ProjectStore.recyclePortrait(record.name, imageId, app.scene and { app.scene } or nil)
					app:refresh()
				end)
			end)
		end

		if self.addingPortraitFor == record.name then
			local box
			box = Widgets.textBox({
				PlaceholderText = "image id",
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

--------------------------------------------------------------------------------
-- Transitions
--------------------------------------------------------------------------------

function PresetsView:_renderTransitions()
	local app = self.app
	local project = app:getProject()

	Widgets.hint("Transitions play between scenes and around NPC interactions. Fade to black hides the swap, cross fade blends backgrounds, camera sweep flies to the next pose, NPC talk zooms on the target and fades it out.", self.list, 34).LayoutOrder = self:_next()

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
	else
		self:_renderTransitions()
	end
end

return PresetsView
