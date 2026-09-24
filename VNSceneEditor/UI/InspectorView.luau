-- Property editor for whatever is selected: the scene itself, an interaction,
-- a segment, a dialogue entry (with portrait gallery and keyframes), a single
-- keyframe, or an event (registry driven, with pickers).

local root = script.Parent.Parent
local Schema = require(root.Core.Schema)
local EventRegistry = require(root.Core.EventRegistry)
local ProjectStore = require(root.Core.ProjectStore)
local Tracks = require(root.Runtime.Tracks)

local Theme = require(script.Parent.Theme)
local Widgets = require(script.Parent.Widgets)

local InspectorView = {}
InspectorView.__index = InspectorView

local PORTRAIT_TILE = 56

function InspectorView.new(parent, app)
	local self = setmetatable({}, InspectorView)

	self.app = app
	self.addingPortrait = false
	self.order = 0

	self.panel = Widgets.panel({
		Name = "InspectorPanel",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Theme.Panel,
		BackgroundTransparency = 0.08,
		Parent = parent,
	}, { Widgets.padding(10, 12, 10, 12) })

	self.title = Widgets.sectionTitle("Inspector", self.panel)

	self.body = Widgets.scroll({
		Name = "Fields",
		Position = UDim2.new(0, 0, 0, 20),
		Size = UDim2.new(1, 0, 1, -20),
		Parent = self.panel,
	}, { Widgets.vlist(6), Widgets.padding(0, 6, 0, 0) })

	return self
end

--------------------------------------------------------------------------------
-- Field builders
--------------------------------------------------------------------------------

function InspectorView:_next()
	self.order += 1
	return self.order
end

function InspectorView:_heading(text)
	Widgets.label({
		Text = string.upper(text),
		Size = UDim2.new(1, 0, 0, 18),
		Font = Theme.FontBold,
		TextSize = 10,
		TextColor3 = Theme.Accent,
		LayoutOrder = self:_next(),
		Parent = self.body,
	})
end

function InspectorView:_caption(text)
	Widgets.label({
		Text = text,
		Size = UDim2.new(1, 0, 0, 14),
		TextSize = 11,
		TextColor3 = Theme.TextDim,
		LayoutOrder = self:_next(),
		Parent = self.body,
	})
end

function InspectorView:_hint(text, height)
	local hint = Widgets.hint(text, self.body, height or 34)
	hint.LayoutOrder = self:_next()
end

function InspectorView:_textField(label, value, onCommit, options)
	options = options or {}
	self:_caption(label)

	return Widgets.textBox({
		Text = tostring(value or ""),
		PlaceholderText = options.placeholder or "",
		Size = UDim2.new(1, 0, 0, options.height or 26),
		TextWrapped = options.multiline or false,
		MultiLine = options.multiline or false,
		Font = options.mono and Theme.FontMono or Theme.Font,
		TextYAlignment = options.multiline and Enum.TextYAlignment.Top or Enum.TextYAlignment.Center,
		LayoutOrder = self:_next(),
		OnCommit = onCommit,
		Parent = self.body,
	})
end

function InspectorView:_numberField(label, value, onCommit, options)
	local app = self.app
	self:_textField(label, string.format(options and options.format or "%.2f", value or 0), function(text)
		local parsed = tonumber(text)
		if not parsed then
			app:notify(label .. " needs to be a number.", Theme.Danger)
			app:refresh()
			return
		end
		onCommit(parsed)
	end, { mono = true })
end

function InspectorView:_choiceField(label, choices, value, onPick)
	self:_caption(label)

	local options = {}
	for _, choice in ipairs(choices) do
		table.insert(options, { id = choice, label = choice })
	end

	Widgets.segmented({
		Options = options,
		Value = value,
		OnPick = onPick,
		LayoutOrder = self:_next(),
		Parent = self.body,
	})
end

function InspectorView:_dropdownField(label, items, value, onPick, placeholder)
	if label then
		self:_caption(label)
	end

	return Widgets.dropdown(self.app.gui, {
		Items = items,
		Value = value,
		Placeholder = placeholder,
		OnPick = onPick,
		LayoutOrder = self:_next(),
		Parent = self.body,
	})
end

function InspectorView:_buttonRow(buttons, height)
	local row = Widgets.create("Frame", {
		Size = UDim2.new(1, 0, 0, height or 26),
		BackgroundTransparency = 1,
		LayoutOrder = self:_next(),
		Parent = self.body,
	}, { Widgets.hlist(6) })

	for index, spec in ipairs(buttons) do
		Widgets.button({
			Text = spec.text,
			Size = UDim2.new(spec.scale or (1 / #buttons), -4, 1, 0),
			Color = spec.color or Theme.Button,
			TextSize = 11,
			LayoutOrder = index,
			OnClick = spec.onClick,
			Parent = row,
		})
	end

	return row
end

function InspectorView:_toggleRow(label, value, onToggle)
	local row = Widgets.create("Frame", {
		Size = UDim2.new(1, 0, 0, 22),
		BackgroundTransparency = 1,
		LayoutOrder = self:_next(),
		Parent = self.body,
	})

	Widgets.label({
		Text = label,
		Size = UDim2.new(1, -54, 1, 0),
		TextSize = 11,
		TextColor3 = Theme.TextDim,
		Parent = row,
	})

	Widgets.toggle({
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, 0, 0.5, 0),
		Value = value,
		OnToggle = onToggle,
		Parent = row,
	})
end

--------------------------------------------------------------------------------
-- Scene section
--------------------------------------------------------------------------------

-- Merge is an editor-only pseudo transition. Offer it solely for the exact
-- source → destination pair that has a permanent adjacent Room3D link.
function InspectorView:_subsceneTransitionItems(source, destinationId)
	local items = self.app:pickerItems("transition")
	if Schema.isValidMergeBetween(self.app.scene, source, destinationId) then
		table.insert(items, 1, { id = "Merge", label = "Merge (continuous Room3D)" })
	end
	return items
end

function InspectorView:_renderScene()
	local app = self.app
	local scene = app.scene
	local subscene = app:getActiveSubscene()
	local stage = subscene.stage
	local background = subscene.background
	local project = app:getProject()

	self:_heading("Scene")

	self:_textField("Name", scene.name, function(text)
		local trimmed = Schema.trimName(text)
		scene.name = trimmed ~= "" and trimmed or "Untitled Scene"
		app:markDirty()
	end)

	self:_heading("Current subscene: " .. subscene.name)
	self:_textField("Subscene name", subscene.name, function(text)
		local trimmed = Schema.trimName(text)
		if trimmed ~= "" then subscene.name = trimmed end
		app:markDirty()
	end)
	self:_choiceField("Kind", Schema.SCENE_KINDS, subscene.kind, function(kind)
		subscene.kind = kind
		stage.kind = kind
		if kind ~= "Novel2D" and background.kind ~= "Camera3D" then
			background.kind = "Camera3D"
		end
		app:onSceneStageChanged()
		app:markDirty()
	end)

	if subscene.kind == "Novel2D" then
		self:_hint("Plays its sequence, then continues to the next subscene in this node.")
	elseif subscene.kind == "Room3D" then
		self:_hint("Fixed camera room: after its sequence, waits for interactions or a conditional route.")
	else
		self:_hint("Free roam: after its sequence, waits for interactions or a conditional route.")
	end
	local previous = Schema.previousSubscene(scene, subscene.id)
	if subscene.kind == "Room3D" and previous and previous.kind == "Room3D" then
		self:_buttonRow({ { text = subscene.linkPreviousRoom and "Unlink Previous Room3D" or "Link to Previous Room3D", onClick = function()
			subscene.linkPreviousRoom = not subscene.linkPreviousRoom
			subscene.linkedRoomId = subscene.linkPreviousRoom and previous.id or ""
			if subscene.linkPreviousRoom then previous.nextTransitionId = "Merge" end
			app:markDirty()
		end } })
		if subscene.linkPreviousRoom then self:_hint("Uses the previous Room3D's camera pose and local interactions by reference.") end
	end

	self:_heading("Background")

	self:_choiceField("Type", Schema.BACKGROUND_KINDS, background.kind, function(kind)
		background.kind = kind
		app:onSceneStageChanged()
		app:markDirty()
	end)

	if background.kind == "Color" then
		self:_textField("Colour (r,g,b)", background.value, function(text)
			background.value = text
			app:markDirty()
		end, { mono = true })
	elseif background.kind == "Image" then
		self:_textField("Image id", background.value, function(text)
			background.value = text
			app:markDirty()
		end, { mono = true, placeholder = "rbxassetid://..." })
	end

	if background.kind == "Camera3D" or subscene.kind ~= "Novel2D" then
		if subscene.linkPreviousRoom then
			local pose = Schema.findCameraPose(project, Schema.effectivePoseId(scene, subscene))
			self:_caption("Linked camera pose: " .. (pose and pose.name or "none"))
		else
		self:_renderPoseField("Camera pose", stage.cameraPoseId, function(poseId)
			stage.cameraPoseId = poseId
			background.poseId = poseId
			app:onSceneStageChanged()
			app:markDirty()
		end)
		end
	end

	local nextAutomaticSubscene = Schema.nextAutomaticSubscene(scene, subscene)
	if nextAutomaticSubscene and subscene.kind == "Novel2D" then
		self:_heading("To next subscene")
		self:_dropdownField("Transition", self:_subsceneTransitionItems(subscene, nextAutomaticSubscene.id), subscene.nextTransitionId, function(id)
			subscene.nextTransitionId = id
			app:markDirty()
		end, "Fade to Black")
	elseif subscene.kind ~= "Novel2D" and #scene.subscenes > 1 then
		self:_hint("This " .. subscene.kind .. " subscene enters AWAIT after its sequence. Use a conditional route, Go to Subscene event, or interaction to leave it.")
	end
	if subscene.kind ~= "Novel2D" then self:_renderAwaitRoutes(subscene) end

	if scene.subscenes[#scene.subscenes].kind == "Novel2D" then
		self:_heading("After this scene")

		self:_dropdownField("Next scene", app:pickerItems("scene", scene.id), scene.next.sceneId, function(sceneId)
			scene.next.sceneId = sceneId
			app:markDirty()
		end, "(end of chapter)")

		self:_dropdownField("Transition", app:pickerItems("transition"), scene.next.transitionId, function(transitionId)
			scene.next.transitionId = transitionId
			app:markDirty()
		end, "(cut)")
	elseif subscene.kind ~= "Novel2D" then
		self:_heading("Interactions")
		self:_hint(string.format("%d interaction(s). Manage them in the panel on the left when no sequence is open.", #scene.interactions))
	end

	self:_heading("Ordered subscenes")
	for index, item in ipairs(scene.subscenes) do
		self:_caption(string.format("%d. %s · %s · %d blocks", index, item.name, item.kind, #item.sequence.segments))
		local actions = {
			{ text = "Edit", onClick = function() app:openSequenceOwner("subscene", item.id) end },
			{ text = "Up", onClick = function() app:moveSubscene(item.id, -1) end },
			{ text = "Down", onClick = function() app:moveSubscene(item.id, 1) end },
		}
		if item.role == "custom" then
			table.insert(actions, { text = "Delete", color = Theme.Danger, onClick = function()
				app:showConfirm("Delete " .. item.name .. "?", "Its sequence and local interactions will be removed. Jumps and conditional routes to it will be cleared.", function()
					app:deleteSubscene(item.id)
				end)
			end })
		end
		self:_buttonRow(actions)
	end
	self:_buttonRow({ { text = "+ Empty subscene", color = Theme.Accent, onClick = function() app:addSubscene() end } })

	self:_heading("Project")
	local pose = Schema.findCameraPose(project, Schema.effectivePoseId(scene, subscene))
	self:_caption(string.format("Pose: %s   Lines: %d   Events: %d", pose and pose.name or "none", Schema.countLines(scene), Schema.countEvents(scene)))
end

function InspectorView:_renderAwaitRoutes(subscene)
	local app = self.app
	local scene = app.scene
	self:_heading("On AWAIT")
	self:_hint("Conditions are checked when this subscene first waits and each time an interaction returns it to AWAIT. Routes run top to bottom.")
	local destinations = app:pickerItems("subscene")
	for index, item in ipairs(destinations) do
		if item.id == subscene.id then table.remove(destinations, index) break end
	end
	for routeIndex, route in ipairs(subscene.awaitRoutes) do
		self:_caption("Conditional route " .. routeIndex)
		self:_dropdownField("Destination", destinations, route.toSubsceneId, function(id)
			route.toSubsceneId = id
			route.transitionId = Schema.defaultSubsceneTransition(scene, subscene, id)
			route.transitionExplicit = false
			app:markDirty()
		end, "(unassigned)")
		self:_dropdownField("Transition", self:_subsceneTransitionItems(subscene, route.toSubsceneId), route.transitionId, function(id)
			route.transitionId = id
			route.transitionExplicit = true
			app:markDirty()
		end, "Fade to Black")
		for conditionIndex, condition in ipairs(route.conditions) do
			self:_dropdownField("Flag " .. conditionIndex, app:pickerItems("flag"), condition.flag, function(id)
				condition.flag = id
				app:markDirty()
			end, "(choose flag)")
			self:_choiceField("Operator", Schema.CONDITION_OPS, condition.op, function(op)
				condition.op = op
				app:markDirty()
			end)
			self:_textField("Value", condition.value, function(value)
				condition.value = value
				app:markDirty()
			end)
			self:_buttonRow({ { text = "Remove condition", color = Theme.Danger, onClick = function()
				table.remove(route.conditions, conditionIndex)
				app:markDirty()
			end } })
		end
		self:_buttonRow({
			{ text = "+ Condition", onClick = function()
				local flags = app:pickerItems("flag")
				if #flags == 0 then app:notify("Add a chapter or scene flag first.", Theme.Danger) return end
				table.insert(route.conditions, { flag = flags[1].id, op = "==", value = "true" })
				app:markDirty()
			end },
			{ text = "Delete route", color = Theme.Danger, onClick = function()
				table.remove(subscene.awaitRoutes, routeIndex)
				app:markDirty()
			end },
		})
	end
	self:_buttonRow({ { text = "+ Conditional route", onClick = function()
		local flags = app:pickerItems("flag")
		if #flags == 0 then app:notify("Add a chapter or scene flag first.", Theme.Danger) return end
		table.insert(subscene.awaitRoutes, {
			id = Schema.newId("route"),
			conditions = { { flag = flags[1].id, op = "==", value = "true" } },
			toSubsceneId = "", transitionId = Schema.DEFAULT_FADE, transitionExplicit = false,
		})
		app:markDirty()
	end } })
end

function InspectorView:_renderPoseField(label, poseId, onPick)
	local app = self.app

	self:_dropdownField(label, app:pickerItems("pose"), poseId, onPick, "(no pose: camera stays put)")

	self:_buttonRow({
		{ text = "Capture new pose", color = Theme.Accent, onClick = function()
			app:captureCamera(function(cframeText)
				local pose = ProjectStore.addCameraPose("Pose " .. (#app:getProject().cameraPoses + 1), cframeText)
				onPick(pose.id)
			end)
		end },
		{ text = "Re-capture", onClick = function()
			if poseId == "" then
				app:notify("Pick or capture a pose first.", Theme.Danger)
				return
			end
			app:captureCamera(function(cframeText)
				ProjectStore.updateCameraPose(poseId, { cframe = cframeText })
				app:onSceneStageChanged()
				app:refresh()
			end)
		end },
	})
end

--------------------------------------------------------------------------------
-- Interaction section
--------------------------------------------------------------------------------

function InspectorView:_renderInteraction(interaction)
	local app = self.app
	local scene = app.scene
	local subscene = app:getActiveSubscene()

	self:_heading("Interaction")

	self:_textField("Name", interaction.name, function(text)
		local trimmed = Schema.trimName(text)
		interaction.name = trimmed ~= "" and trimmed or interaction.kind
		app:markDirty()
	end)

	self:_choiceField("Kind", Schema.INTERACTION_KINDS, interaction.kind, function(kind)
		interaction.kind = kind
		if kind == "Exit" then
			interaction.repeatPolicy = "always"
		end
		app:markDirty()
	end)

	if interaction.kind == "Hotspot" then
		self:_hint(subscene.kind == "Explore3D" and "Hotspot: the player gets a proximity prompt on the target." or "Hotspot: the player clicks the target.")
	elseif interaction.kind == "Trigger" then
		self:_hint("Trigger: fires when the player touches the target (Explore3D) or clicks it (Room3D).")
	else
		self:_hint("Exit: leaves this scene for another one after its sequence (if any) plays.")
	end

	self:_heading("Target")
	self:_caption(interaction.targetId ~= "" and ("id: " .. interaction.targetId) or "no target picked yet")
	self:_buttonRow({
		{ text = "Pick target in world", color = Theme.Accent, onClick = function()
			app:pickTarget(function(targetId)
				interaction.targetId = targetId
				app:markDirty()
			end)
		end },
		{ text = "Clear", onClick = function()
			interaction.targetId = ""
			app:markDirty()
		end },
	})

	self:_heading("Availability")
	self:_choiceField("Scope", { "Local", "Shared" }, interaction.scope or "Shared", function(scope)
		interaction.scope = scope
		if scope == "Local" and interaction.subsceneId == "" then interaction.subsceneId = subscene.id end
		app:markDirty()
	end)
	if interaction.scope == "Local" then
		self:_dropdownField("Subscene", app:pickerItems("subscene"), interaction.subsceneId, function(id)
			interaction.subsceneId = id
			app:markDirty()
		end, "(choose subscene)")
	end
	self:_choiceField("Repeat", Schema.REPEAT_POLICIES, interaction.repeatPolicy, function(policy)
		interaction.repeatPolicy = policy
		app:markDirty()
	end)

	self:_caption("Conditions (all must pass)")
	local flagItems = app:pickerItems("flag")

	for index, condition in ipairs(interaction.conditions) do
		local row = Widgets.create("Frame", {
			Size = UDim2.new(1, 0, 0, 24),
			BackgroundTransparency = 1,
			LayoutOrder = self:_next(),
			Parent = self.body,
		}, { Widgets.hlist(4) })

		Widgets.dropdown(app.gui, {
			Items = flagItems,
			Value = condition.flag,
			Placeholder = "flag",
			Size = UDim2.new(0.42, 0, 1, 0),
			LayoutOrder = 1,
			OnPick = function(flagId)
				condition.flag = flagId
				app:markDirty()
			end,
			Parent = row,
		})

		local opItems = {}
		for _, op in ipairs(Schema.CONDITION_OPS) do
			table.insert(opItems, { id = op, label = op })
		end

		Widgets.dropdown(app.gui, {
			Items = opItems,
			Value = condition.op,
			Size = UDim2.new(0.18, 0, 1, 0),
			LayoutOrder = 2,
			OnPick = function(op)
				condition.op = op
				app:markDirty()
			end,
			Parent = row,
		})

		Widgets.textBox({
			Text = tostring(condition.value),
			Size = UDim2.new(0.28, 0, 1, 0),
			TextYAlignment = Enum.TextYAlignment.Center,
			TextSize = 11,
			LayoutOrder = 3,
			OnCommit = function(text)
				condition.value = text
				app:markDirty()
			end,
			Parent = row,
		})

		Widgets.button({
			Text = "x",
			Size = UDim2.new(0.12, -4, 1, 0),
			Color = Theme.Danger,
			TextSize = 11,
			LayoutOrder = 4,
			OnClick = function()
				table.remove(interaction.conditions, index)
				app:markDirty()
			end,
			Parent = row,
		})
	end

	self:_buttonRow({
		{ text = "+ Condition", onClick = function()
			local firstFlag = flagItems[1] and flagItems[1].id or ""
			if firstFlag == "" then
				app:notify("Add a scene flag here or a chapter flag from the flow screen first.", Theme.Danger)
				return
			end
			table.insert(interaction.conditions, { flag = firstFlag, op = "==", value = "true" })
			app:markDirty()
		end },
	})

	self:_heading("When triggered")
	self:_dropdownField("Enter / exit transition", app:pickerItems("transition"), interaction.transitionId, function(transitionId)
		interaction.transitionId = transitionId
		app:markDirty()
	end, "(none)")
	self:_hint("NPC talk zooms on the target and fades the model out while the dialogue plays, then reverses.")

	self:_caption(string.format("Sequence: %d block(s)", #interaction.sequence.segments))
	self:_buttonRow({
		{ text = "Edit sequence", color = Theme.Accent, onClick = function()
			app:openSequenceOwner("interaction", interaction.id)
		end },
	})

	self:_caption(string.format("Completion events: %d (Events panel)", #interaction.onComplete))

	if interaction.kind == "Exit" then
		self:_heading("Leads to")
		self:_dropdownField("Scene", app:pickerItems("scene", scene.id), interaction.exit.sceneId, function(sceneId)
			interaction.exit.sceneId = sceneId
			app:markDirty()
		end, "(end of chapter)")
		self:_dropdownField("Transition", app:pickerItems("transition"), interaction.exit.transitionId, function(transitionId)
			interaction.exit.transitionId = transitionId
			app:markDirty()
		end, "(cut)")
	end
end

--------------------------------------------------------------------------------
-- Segment section
--------------------------------------------------------------------------------

function InspectorView:_renderSegment(segment)
	local app = self.app

	if segment.kind == "Timed" then
		self:_heading("Timed section")
		self:_numberField("Duration (seconds)", segment.duration, function(value)
			segment.duration = math.clamp(value, Schema.MIN_DURATION, Schema.MAX_DURATION)
			app:markDirty()
		end)
		self:_hint("Events on this section fire at their second. Use Show Portrait to bring a character on without dialogue.")
		self:_renderTracks(segment, segment.duration)
	else
		self:_heading("Dialogue block")
		self:_caption(string.format("%d line(s)", #segment.entries))
		self:_dropdownField("Textbox style", app:pickerItems("textbox"), segment.textboxPresetId, function(presetId)
			segment.textboxPresetId = presetId
			app:markDirty()
		end, "(inherit)")
		self:_hint("Pick a line in the panel on the left to edit its text, character and portrait.")
	end
end

--------------------------------------------------------------------------------
-- Entry section
--------------------------------------------------------------------------------

function InspectorView:_renderEntry(entry, segment)
	local app = self.app
	local project = app:getProject()

	self:_heading("Line")

	self:_caption("Character")
	local characterRow = Widgets.create("Frame", {
		Size = UDim2.new(1, 0, 0, 26),
		BackgroundTransparency = 1,
		LayoutOrder = self:_next(),
		Parent = self.body,
	}, { Widgets.hlist(4) })

	Widgets.textBox({
		Text = entry.character,
		PlaceholderText = "(narration)",
		Size = UDim2.new(1, -30, 1, 0),
		TextYAlignment = Enum.TextYAlignment.Center,
		LayoutOrder = 1,
		OnCommit = function(text)
			local trimmed = Schema.trimName(text)
			if trimmed ~= entry.character then
				entry.character = trimmed
				if entry.portrait ~= "" and not table.find(Schema.getCharacterPortraits(project, trimmed), entry.portrait) then
					entry.portrait = ""
				end
				if trimmed ~= "" then
					ProjectStore.addCharacter(trimmed)
				end
				app:markDirty()
			end
		end,
		Parent = characterRow,
	})

	local pickButton
	pickButton = Widgets.button({
		Text = "v",
		Size = UDim2.new(0, 26, 1, 0),
		TextSize = 11,
		LayoutOrder = 2,
		OnClick = function()
			local items = app:pickerItems("character")
			if #items == 0 then
				app:notify("No characters yet. Type a name to create one.", Theme.TextDim)
				return
			end
			Widgets.popupList(app.gui, pickButton, items, function(name)
				entry.character = name
				if entry.portrait ~= "" and not table.find(Schema.getCharacterPortraits(project, name), entry.portrait) then
					entry.portrait = ""
				end
				app:markDirty()
			end)
		end,
		Parent = characterRow,
	})

	self:_textField("Text", entry.text, function(text)
		entry.text = text
		app:markDirty()
	end, { multiline = true, height = 88 })

	self:_toggleRow("Skippable", entry.skippable ~= false, function(value)
		entry.skippable = value
		app:markDirty()
	end)

	self:_toggleRow("Speaking", entry.speaking ~= false, function(value)
		entry.speaking = value
		app:markDirty()
	end)

	if entry.skippable == false then
		self:_numberField("Auto-continue delay (seconds)", entry.autoAdvanceDelay or Schema.DEFAULT_DIALOGUE_AUTO_ADVANCE, function(value)
			entry.autoAdvanceDelay = math.clamp(value, Schema.MIN_DIALOGUE_AUTO_ADVANCE, Schema.MAX_DIALOGUE_AUTO_ADVANCE)
			app:markDirty()
		end, { min = Schema.MIN_DIALOGUE_AUTO_ADVANCE, max = Schema.MAX_DIALOGUE_AUTO_ADVANCE, step = 0.1 })
	end

	self:_renderPortraitGallery(entry)

	self:_heading("Preview time")
	local cursor = app:getCursor()
	local maxTime = 3
	for _, track in ipairs(entry.tracks) do
		for _, key in ipairs(track.keys) do
			maxTime = math.max(maxTime, key.t + 0.5)
		end
	end
	local preset = Schema.findTextboxPreset(project, segment.textboxPresetId ~= "" and segment.textboxPresetId or Schema.DEFAULT_TEXTBOX)
	if preset and preset.typewriterCps > 0 then
		maxTime = math.max(maxTime, (utf8.len(entry.text) or #entry.text) / preset.typewriterCps + 0.5)
	end

	local entryTime = cursor.entryIndex and cursor.entryTime or 0
	local timeLabel = Widgets.label({
		Text = string.format("%.2fs since the line appeared (typewriter and keyframes)", entryTime),
		Size = UDim2.new(1, 0, 0, 14),
		TextSize = 10,
		TextColor3 = Theme.TextFaint,
		LayoutOrder = self:_next(),
		Parent = self.body,
	})

	Widgets.slider({
		Min = 0,
		Max = maxTime,
		Value = entryTime,
		LayoutOrder = self:_next(),
		OnChange = function(value)
			timeLabel.Text = string.format("%.2fs since the line appeared (typewriter and keyframes)", value)
			app:scrubEntryTime(value)
		end,
		OnRelease = function()
			app:refresh()
		end,
		Parent = self.body,
	})

	self:_renderTracks(entry, maxTime)
end

--------------------------------------------------------------------------------
-- Portrait gallery
--------------------------------------------------------------------------------

function InspectorView:_portraitStroke(tile, selected)
	Widgets.stroke(selected and Theme.Accent or Theme.Border, selected and 2 or 1, selected and 0 or 0.4).Parent = tile
end

function InspectorView:_renderPortraitGallery(entry)
	local app = self.app
	local project = app:getProject()
	local character = entry.character

	self:_heading("Portrait")

	if character == "" then
		self:_hint("Give the line a character to choose one of their portraits.")
		return
	end

	local portraits = Schema.getCharacterPortraits(project, character)
	self:_caption(string.format("%s  .  %d portrait(s)  .  right click to remove", character, #portraits))

	local gallery = Widgets.scroll({
		Size = UDim2.new(1, 0, 0, PORTRAIT_TILE + 14),
		Axis = Enum.AutomaticSize.X,
		ScrollBarThickness = 4,
		LayoutOrder = self:_next(),
		Parent = self.body,
	}, { Widgets.hlist(6, Enum.VerticalAlignment.Top), Widgets.padding(0, 0, 8, 0) })

	local noneTile = Widgets.button({
		Text = "None",
		Size = UDim2.fromOffset(PORTRAIT_TILE, PORTRAIT_TILE),
		Color = Theme.Input,
		TextSize = 11,
		TextColor3 = Theme.TextDim,
		Radius = 6,
		LayoutOrder = 1,
		OnClick = function()
			entry.portrait = ""
			app:markDirty()
		end,
		Parent = gallery,
	})
	self:_portraitStroke(noneTile, entry.portrait == "")

	for index, imageId in ipairs(portraits) do
		local selected = entry.portrait == imageId

		local tile = Widgets.create("ImageButton", {
			Name = "Portrait_" .. index,
			Size = UDim2.fromOffset(PORTRAIT_TILE, PORTRAIT_TILE),
			BackgroundColor3 = Theme.Input,
			BorderSizePixel = 0,
			Image = imageId,
			ImageTransparency = 0,
			ScaleType = Enum.ScaleType.Fit,
			ClipsDescendants = true,
			AutoButtonColor = false,
			LayoutOrder = index + 1,
			Parent = gallery,
		}, { Widgets.corner(6) })

		self:_portraitStroke(tile, selected)

		tile.MouseButton1Click:Connect(function()
			entry.portrait = imageId
			app:markDirty()
		end)

		tile.MouseButton2Click:Connect(function()
			app:showConfirm(
				"Remove portrait?",
				"It moves to the recycle bin. Lines using it switch to None.",
				function()
					ProjectStore.recyclePortrait(character, imageId, { app.scene })
					app:markDirty()
				end
			)
		end)
	end

	if self.addingPortrait then
		local box
		box = Widgets.textBox({
			PlaceholderText = "image id",
			Size = UDim2.fromOffset(PORTRAIT_TILE * 2, PORTRAIT_TILE),
			TextYAlignment = Enum.TextYAlignment.Center,
			TextSize = 11,
			Font = Theme.FontMono,
			LayoutOrder = #portraits + 2,
			OnCommit = function(text, enterPressed)
				if not enterPressed then
					self.addingPortrait = false
					app:refresh()
					return
				end

				local added, formatted = ProjectStore.addPortrait(character, text)
				self.addingPortrait = false

				if not added then
					if formatted == "" then
						app:notify("Paste an asset id like 123456789 or rbxassetid://123456789.", Theme.Danger)
					else
						app:notify("That portrait is already in the gallery.", Theme.TextDim)
					end
					app:refresh()
					return
				end

				entry.portrait = formatted
				app:markDirty()
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
			Size = UDim2.fromOffset(PORTRAIT_TILE, PORTRAIT_TILE),
			Color = Theme.Button,
			TextSize = 20,
			Radius = 6,
			LayoutOrder = #portraits + 2,
			OnClick = function()
				self.addingPortrait = true
				app:refresh()
			end,
			Parent = gallery,
		})
	end
end

--------------------------------------------------------------------------------
-- Keyframe tracks
--------------------------------------------------------------------------------

-- owner is a timed segment or a dialogue entry (both carry .tracks).
function InspectorView:_renderTracks(owner, maxTime)
	local app = self.app

	self:_heading("Portrait keyframes")

	local track = nil
	for _, candidate in ipairs(owner.tracks) do
		if candidate.target == "portrait" then
			track = candidate
			break
		end
	end

	local localTime = app:getLocalTime()

	if not track then
		self:_hint("Keyframes move, scale, rotate and fade the portrait over time.")
		self:_buttonRow({
			{ text = "+ Add keyframe track", onClick = function()
				table.insert(owner.tracks, Schema.newTrack("portrait"))
				app:markDirty()
			end },
		})
		return
	end

	self:_caption(string.format("%d key(s)  .  cursor at %.2fs", #track.keys, localTime))

	for index, key in ipairs(track.keys) do
		local selected = app.selection.kind == "key" and app.selection.trackId == track.id and app.selection.keyIndex == index

		local row = Widgets.button({
			Text = string.format("  %.2fs   x %.2f  y %.2f  s %.2f  r %.0f  a %.2f", key.t, key.x, key.y, key.scale, key.rotation, key.alpha),
			Size = UDim2.new(1, 0, 0, 22),
			Color = selected and Theme.Accent or Theme.Row,
			TextColor3 = selected and Theme.Text or Theme.TextDim,
			TextXAlignment = Enum.TextXAlignment.Left,
			Font = Theme.FontMono,
			TextSize = 10,
			Radius = 4,
			LayoutOrder = self:_next(),
			OnClick = function()
				app:selectKey(track.id, index, key.t)
			end,
			Parent = self.body,
		})

		Widgets.button({
			Text = "x",
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -3, 0.5, 0),
			Size = UDim2.new(0, 18, 0, 18),
			Color = Theme.Danger,
			TextSize = 10,
			Radius = 4,
			OnClick = function()
				table.remove(track.keys, index)
				if #track.keys == 0 then
					for trackIndex, candidate in ipairs(owner.tracks) do
						if candidate == track then
							table.remove(owner.tracks, trackIndex)
						end
					end
				end
				local selection = table.clone(app.selection)
				if selection.kind == "key" then
					selection.kind = selection.entryIndex and "entry" or "segment"
					selection.trackId = nil
					selection.keyIndex = nil
				end
				app.selection = selection
				app:markDirty()
			end,
			Parent = row,
		})
	end

	self:_buttonRow({
		{ text = string.format("+ Key at %.2fs", localTime), color = Theme.Accent, onClick = function()
			local transform = Tracks.sampleTrack(track, localTime)
			local key = Tracks.setKey(track, math.round(localTime * 100) / 100, transform)
			local keyIndex = table.find(track.keys, key)
			app:selectKey(track.id, keyIndex, key.t)
			app:markDirty()
		end },
		{ text = "Remove track", color = Theme.Danger, onClick = function()
			for trackIndex, candidate in ipairs(owner.tracks) do
				if candidate == track then
					table.remove(owner.tracks, trackIndex)
				end
			end
			app:markDirty()
		end },
	})

	if app.selection.kind == "key" and app.selection.trackId == track.id then
		local key = track.keys[app.selection.keyIndex]
		if key then
			self:_renderKey(track, key, maxTime)
		end
	end
end

function InspectorView:_renderKey(track, key, maxTime)
	local app = self.app

	self:_heading("Selected key")
	self:_hint("Drag the portrait on the stage to place it. Values below are stage fractions.")

	self:_numberField("Time (s)", key.t, function(value)
		key.t = math.clamp(value, 0, maxTime or 120)
		Tracks.sortKeys(track)
		local index = table.find(track.keys, key)
		app:selectKey(track.id, index, key.t)
		app:markDirty()
	end)

	local grid = Widgets.create("Frame", {
		Size = UDim2.new(1, 0, 0, 26),
		BackgroundTransparency = 1,
		LayoutOrder = self:_next(),
		Parent = self.body,
	}, { Widgets.hlist(4) })

	local function small(label, value, onCommit)
		local holder = Widgets.create("Frame", {
			Size = UDim2.new(0.25, -3, 1, 0),
			BackgroundTransparency = 1,
			Parent = grid,
		})
		Widgets.label({
			Text = label,
			Size = UDim2.new(0, 14, 1, 0),
			TextSize = 10,
			TextColor3 = Theme.TextFaint,
			Parent = holder,
		})
		Widgets.textBox({
			Text = string.format("%.2f", value),
			Position = UDim2.new(0, 14, 0, 0),
			Size = UDim2.new(1, -14, 1, 0),
			TextYAlignment = Enum.TextYAlignment.Center,
			TextSize = 10,
			Font = Theme.FontMono,
			Flat = true,
			OnCommit = function(text)
				local parsed = tonumber(text)
				if parsed then
					onCommit(parsed)
					app:markDirty()
				else
					app:refresh()
				end
			end,
			Parent = holder,
		})
	end

	small("x", key.x, function(value)
		key.x = value
	end)
	small("y", key.y, function(value)
		key.y = value
	end)
	small("s", key.scale, function(value)
		key.scale = math.max(0.05, value)
	end)
	small("a", key.alpha, function(value)
		key.alpha = math.clamp(value, 0, 1)
	end)

	self:_numberField("Rotation (degrees)", key.rotation, function(value)
		key.rotation = value
		app:markDirty()
	end, { format = "%.0f" })

	self:_dropdownField("Easing to next key", self:_easingItems(), key.easing, function(easing)
		key.easing = easing
		app:markDirty()
	end)
end

function InspectorView:_easingItems()
	local items = {}
	for _, easing in ipairs(Schema.EASINGS) do
		table.insert(items, { id = easing, label = easing })
	end
	return items
end

--------------------------------------------------------------------------------
-- Event section
--------------------------------------------------------------------------------

-- A sequence owned by a subscene has a known runtime source. A Local
-- interaction can also name its source. Shared interactions intentionally do
-- not get Merge here: they may be invoked from several subscenes, so there is
-- no single source/destination pair that can be validated at authoring time.
function InspectorView:_eventSourceSubscene()
	local app = self.app
	if app.openSequence.owner == "subscene" then
		return Schema.subsceneIndex(app.scene, app.openSequence.subsceneId)
	end
	if app.openSequence.owner == "interaction" then
		local interaction = Schema.findInteraction(app.scene, app.openSequence.interactionId)
		if interaction and interaction.scope == "Local" then
			return Schema.subsceneIndex(app.scene, interaction.subsceneId)
		end
	end
	return nil
end

function InspectorView:_renderEvent(event, anchorKind, segment)
	local app = self.app
	local gotoSubsceneSource = event.type == "FlowGotoSubscene" and self:_eventSourceSubscene() or nil

	self:_heading(EventRegistry.category(event.type) .. "  .  " .. EventRegistry.displayName(event.type))

	if anchorKind == "Timed" and segment then
		self:_numberField("Fires at (seconds)", event.time, function(value)
			event.time = math.clamp(value, 0, segment.duration)
			app:jumpTo({ segmentIndex = app.selection.segmentIndex, time = event.time }, app.selection)
			app:markDirty()
		end)
	elseif anchorKind == "Dialogue" then
		self:_hint("Fires the moment this line appears.", 18)
	else
		self:_hint("Runs when the interaction's sequence finishes.", 18)
	end
	if event.type == "FlowGotoSubscene" and app.openSequence.owner == "interaction" and not gotoSubsceneSource then
		self:_hint("Merge is unavailable for a Shared interaction because it can run from more than one subscene.")
	end

	if EventRegistry.isDurational(event.type) then
		self:_numberField("Duration (0 = instant)", event.duration, function(value)
			event.duration = math.max(0, value)
			app:markDirty()
		end)

		if event.duration > 0 then
			self:_dropdownField("Easing", self:_easingItems(), event.easing, function(easing)
				event.easing = easing
				app:markDirty()
			end)
		end
	end

	for _, field in ipairs(EventRegistry.fields(event.type)) do
		local value = event.params[field.key]

		if field.kind == "number" then
			self:_numberField(field.label, value, function(parsed)
				event.params[field.key] = parsed
				app:markDirty()
			end)
		elseif field.kind == "choice" then
			self:_choiceField(field.label, field.choices, value, function(choice)
				event.params[field.key] = choice
				app:markDirty()
			end)
		elseif field.kind == "boolean" then
			self:_toggleRow(field.label, value == true, function(next)
				event.params[field.key] = next
				app:markDirty()
			end)
		elseif field.kind == "picker" then
			-- Camera pose only matters for Camera3D backgrounds.
			if not (event.type == "BackgroundChange" and field.key == "poseId" and event.params.kind ~= "Camera3D") then
				local items = app:pickerItems(field.picker)
				if event.type == "FlowGotoSubscene" and field.key == "transitionId" then
					items = self:_subsceneTransitionItems(gotoSubsceneSource, event.params.subsceneId)
				end
				self:_dropdownField(field.label, items, value, function(id)
					event.params[field.key] = id
					if event.type == "FlowGotoSubscene" and field.key == "subsceneId" then
						event.params.transitionId = Schema.defaultSubsceneTransition(app.scene, gotoSubsceneSource, id)
						event.transitionExplicit = false
					elseif event.type == "FlowGotoSubscene" and field.key == "transitionId" then
						event.transitionExplicit = true
					end
					app:markDirty()
				end, "(none)")

				if field.picker == "pose" then
					self:_buttonRow({
						{ text = "Capture new pose", onClick = function()
							app:captureCamera(function(cframeText)
								local pose = ProjectStore.addCameraPose("Pose " .. (#app:getProject().cameraPoses + 1), cframeText)
								event.params[field.key] = pose.id
								app:markDirty()
							end)
						end },
					})
				end
			end
		else
			if not (event.type == "BackgroundChange" and field.key == "value" and event.params.kind == "Camera3D") then
				self:_textField(field.label, value, function(text)
					event.params[field.key] = text
					app:markDirty()
				end, { mono = true })
			end
		end
	end
end

--------------------------------------------------------------------------------
-- Render
--------------------------------------------------------------------------------

function InspectorView:render()
	local app = self.app
	self.order = 0

	Widgets.clearChildren(self.body)

	if not app.scene then
		self.title.Text = "INSPECTOR"
		return
	end

	local selection = app.selection

	if selection.kind == "interaction" then
		local interaction = Schema.findInteraction(app.scene, selection.interactionId)
		if interaction then
			self.title.Text = "INSPECTOR  .  INTERACTION"
			self:_renderInteraction(interaction)
			return
		end
	end

	if selection.kind == "event" then
		local events, anchorKind = app:getAnchor()
		local event = events and Schema.findById(events, selection.eventId)
		if event then
			self.title.Text = "INSPECTOR  .  EVENT"
			self:_renderEvent(event, anchorKind, app:getSelectedSegment())
			return
		end
	end

	if selection.kind == "entry" or selection.kind == "key" then
		local segment = app:getSelectedSegment()
		local entry = app:getSelectedEntry()
		if segment and entry then
			self.title.Text = "INSPECTOR  .  LINE"
			self:_renderEntry(entry, segment)
			return
		elseif segment and segment.kind == "Timed" then
			self.title.Text = "INSPECTOR  .  TIMED"
			self:_renderSegment(segment)
			return
		end
	end

	if selection.kind == "segment" then
		local segment = app:getSelectedSegment()
		if segment then
			self.title.Text = "INSPECTOR  .  " .. string.upper(segment.kind)
			self:_renderSegment(segment)
			return
		end
	end

	self.title.Text = "INSPECTOR  .  SCENE"
	self:_renderScene()
end

return InspectorView
