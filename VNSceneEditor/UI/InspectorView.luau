-- Property editor for whatever is selected: the scene itself, an interaction,
-- a segment, a dialogue entry (with portrait gallery and keyframes), a single
-- keyframe, or an event (registry driven, with pickers).

local root = script.Parent.Parent
local Schema = require(root.Core.Schema)
local EventRegistry = require(root.Core.EventRegistry)
local ProjectStore = require(root.Core.ProjectStore)
local Tracks = require(root.Runtime.Tracks)
local WorldBindings = require(root.Render.WorldBindings)

local Theme = require(script.Parent.Theme)
local Widgets = require(script.Parent.Widgets)

local InspectorView = {}
InspectorView.__index = InspectorView

local PORTRAIT_TILE = 56

local function modelPreviewFront(model)
	local head = model and model:FindFirstChild("Head", true)
	if head and head:IsA("BasePart") then
		-- Roblox character heads conventionally point their Front face along the
		-- part LookVector, which is also where the face decal is authored.
		return head.CFrame.LookVector
	end
	return model and model:GetPivot().LookVector or Vector3.new(0, 0, -1)
end

local function characterModelViewport(parent, project, characterName)
	local viewport = Widgets.create("ViewportFrame", {
		Size = UDim2.fromOffset(48, 48), BackgroundColor3 = Theme.Input, BorderSizePixel = 0,
		Ambient = Color3.fromRGB(180, 180, 180), LightColor = Color3.new(1, 1, 1), Parent = parent,
	}, { Widgets.corner(5), Widgets.stroke(Theme.Border, 1, 0.4) })
	local record = Schema.findCharacter(project, characterName)
	local template = record and WorldBindings.resolveReference(record.modelRef)
	if not (template and template:IsA("Model")) then
		Widgets.label({ Text = "?", Size = UDim2.fromScale(1, 1), TextXAlignment = Enum.TextXAlignment.Center,
			TextYAlignment = Enum.TextYAlignment.Center, TextSize = 18, Font = Theme.FontBold, TextColor3 = Theme.TextFaint, Parent = viewport })
		return
	end
	local ok, clone = pcall(function() return template:Clone() end)
	if not ok or not clone then return end
	for _, item in ipairs(clone:GetDescendants()) do
		if item:IsA("Script") or item:IsA("LocalScript") then item:Destroy() end
	end
	clone.Parent = viewport
	local camera = Instance.new("Camera")
	camera.Parent = viewport
	viewport.CurrentCamera = camera
	local bounds, size = clone:GetBoundingBox()
	local distance = math.max(2.5, size.Magnitude * 0.95)
	local front = modelPreviewFront(clone)
	camera.CFrame = CFrame.lookAt(bounds.Position + front * distance + Vector3.new(0, size.Y * 0.1, 0), bounds.Position)
end

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

function InspectorView:_spacer(height)
	Widgets.create("Frame", {
		Size = UDim2.new(1, 0, 0, height or 6),
		BackgroundTransparency = 1,
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
	if label and label ~= "" then
		self:_caption(label)
	end

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

function InspectorView:_dropdownField(label, items, value, onPick, placeholder, options)
	if label then
		self:_caption(label)
	end

	return Widgets.dropdown(self.app.gui, {
		Items = items,
		Value = value,
		Placeholder = placeholder,
		MapPick = options and options.mapPick,
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

-- Conditions are authored against either chapter or scene flags.  Boolean
-- flags have exactly two valid comparison values, so expose them as a toggle
-- rather than making the author type "true" or "false" into a text box.
function InspectorView:_conditionFlagDefinition(condition)
	return Schema.resolveFlag(self.app:getChapter(), self.app.scene, condition.flag)
end

function InspectorView:_isBooleanCondition(condition)
	local definition = self:_conditionFlagDefinition(condition)
	return definition ~= nil and definition.kind == "bool", definition
end

function InspectorView:_conditionValueField(condition)
	local app = self.app
	local isBoolean, definition = self:_isBooleanCondition(condition)
	if not isBoolean then
		self:_textField("Value", condition.value, function(value)
			condition.value = value
			app:markDirty()
		end)
		return
	end

	self:_caption("Value")
	local current = Schema.coerceFlagValue(definition, condition.value)
	local button = Widgets.button({
		Text = current and "true" or "false",
		Size = UDim2.new(1, 0, 0, 26),
		Color = Theme.Input,
		Radius = 4,
		TextSize = 13,
		TextXAlignment = Enum.TextXAlignment.Left,
		LayoutOrder = self:_next(),
		OnClick = function()
			condition.value = current and "false" or "true"
			app:markDirty()
		end,
		Parent = self.body,
	})
	Widgets.stroke(Theme.Border, 1, 0.4).Parent = button
end

function InspectorView:_inlineConditionValueField(condition, parent, layoutOrder)
	local app = self.app
	local isBoolean, definition = self:_isBooleanCondition(condition)
	if isBoolean then
		local current = Schema.coerceFlagValue(definition, condition.value)
		local button = Widgets.button({
			Text = current and "true" or "false",
			Size = UDim2.new(0.28, 0, 1, 0),
			Color = Theme.Input,
			Radius = 4,
			TextSize = 11,
			TextXAlignment = Enum.TextXAlignment.Center,
			LayoutOrder = layoutOrder,
			OnClick = function()
				condition.value = current and "false" or "true"
				app:markDirty()
			end,
			Parent = parent,
		})
		Widgets.stroke(Theme.Border, 1, 0.4).Parent = button
		return
	end

	Widgets.textBox({
		Text = tostring(condition.value), Size = UDim2.new(0.28, 0, 1, 0),
		TextYAlignment = Enum.TextYAlignment.Center, TextSize = 11, LayoutOrder = layoutOrder,
		OnCommit = function(text) condition.value = text; app:markDirty() end,
		Parent = parent,
	})
end

--------------------------------------------------------------------------------
-- Scene section
--------------------------------------------------------------------------------

-- Merge and Enter are contextual pseudo-transitions, never general presets.
-- Merge belongs to one concrete linked Room3D pair; Enter belongs only to a
-- Go To event authored inside a Hotspot interaction sequence.
function InspectorView:_subsceneTransitionItems(source, destinationId, allowEnter)
	local items = self.app:pickerItems("transition")
	local insertAt = 1
	if allowEnter then
		table.insert(items, insertAt, { id = "Enter", label = "Enter (Hotspot)" })
		insertAt += 1
	end
	if Schema.isValidMergeBetween(self.app.scene, source, destinationId) then
		table.insert(items, insertAt, { id = "Merge", label = "Merge (continuous Room3D)" })
	end
	return items
end

-- A cross-scene Go To can use Hotspot Enter, but cannot use Merge: Merge only
-- makes sense between adjacent Room3Ds in this same scene node.
function InspectorView:_sceneTransitionItems(allowEnter)
	local items = self.app:pickerItems("transition")
	if allowEnter then
		table.insert(items, 1, { id = "Enter", label = "Enter (Hotspot)" })
	end
	return items
end

function InspectorView:_focusWorldPosition(positionText)
	local position = Schema.decodePosition(positionText)
	if not position then
		self.app:notify("Pick a world position first.", Theme.Danger)
		return
	end
	-- Place the editor camera just above and behind the point, looking into it.
	-- This makes a direct position useful to inspect without embedding the
	-- camera in the selected floor or wall surface.
	self.app.presenter:getRig():setCFrame(CFrame.lookAt(position + Vector3.new(0, 3, 8), position))
	self.app:notify("Camera moved to the saved world position.", Theme.TextDim)
end

function InspectorView:_pickWorldPosition(destinationScene, destinationSubscene, prompt, onPicked)
	local previewScene = destinationScene and destinationSubscene
		and Schema.subsceneView(destinationScene, destinationSubscene) or nil
	self.app:pickTarget(function(_, _, _, hit)
		if hit then
			onPicked(Schema.encodePosition(hit.Position))
		end
	end, {
		assignId = false,
		partOnly = true,
		previewScene = previewScene,
		prompt = prompt,
	})
end

function InspectorView:_gotoDestination(event)
	local chapter = self.app:getChapter()
	if event.type == "FlowGotoSubscene" then
		return self.app.scene, Schema.subsceneIndex(self.app.scene, event.params.subsceneId)
	end
	if event.type == "FlowGoto" then
		local scene = Schema.findScene(chapter, event.params.sceneId)
		return scene, scene and scene.subscenes and scene.subscenes[1] or nil
	end
	return nil, nil
end

function InspectorView:_renderExploreArrival(event, source, destinationScene, destination)
	if not (source and source.kind == "Room3D" and destination and destination.kind == "Explore3D") then
		return
	end

	local app = self.app
	local params = event.params
	local mode = params.exploreArrivalMode or "Exit"
	self:_heading("Explore3D arrival")
	self:_choiceField("Arrival position", { "Auto", "Exit", "Manual" }, mode, function(nextMode)
		params.exploreArrivalMode = nextMode
		app:markDirty()
	end)
	if mode == "Auto" then
		self:_hint("Uses the destination Explore3D's normal spawn position.", 22)
		return
	end
	if mode == "Exit" then
		self:_hint("Uses this Room3D's automatic exit return position. If this room has no attributed Explore3D return point, the destination's normal spawn is used.", 38)
		return
	end

	self:_caption(params.exploreReturnPosition ~= "" and ("Arrival position: " .. params.exploreReturnPosition) or "Arrival position: not picked")
	self:_buttonRow({
		{ text = "Pick position", color = Theme.Accent, onClick = function()
			self:_pickWorldPosition(destinationScene, destination,
				"Click the exact world position where the player should arrive in this Explore3D.", function(positionText)
					params.exploreReturnPosition = positionText
					app:markDirty()
				end)
		end },
		{ text = "Go", onClick = function()
			self:_focusWorldPosition(params.exploreReturnPosition)
		end },
		{ text = "Clear", onClick = function()
			params.exploreReturnPosition = ""
			app:markDirty()
		end },
	})
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
			if subscene.linkPreviousRoom then
				subscene.linkLocalInteractions = true
				subscene.linkLocalCharacterModels = true
				previous.nextTransitionId = "Merge"
			end
			-- A Room link changes which local character copies are visible in the
			-- editor preview immediately; rebuild that lightweight stage layer now.
			app:onSceneStageChanged()
			app:markDirty()
		end } })
		if subscene.linkPreviousRoom then
			self:_buttonRow({ { text = subscene.linkLocalInteractions ~= false and "Unlink local interactions" or "Link local interactions", onClick = function()
				subscene.linkLocalInteractions = not (subscene.linkLocalInteractions ~= false)
				app:markDirty()
			end } })
			self:_hint(subscene.linkLocalInteractions ~= false
				and "Uses the previous Room3D's camera pose and local interactions by reference."
				or "Uses the previous Room3D's camera pose only; local interactions stay separate.")
			self:_buttonRow({ { text = subscene.linkLocalCharacterModels ~= false and "Unlink local 3D models" or "Link local 3D models", onClick = function()
				subscene.linkLocalCharacterModels = not (subscene.linkLocalCharacterModels ~= false)
				app:refreshCharacterModelPlacements()
				app:markDirty()
			end } })
			self:_hint(subscene.linkLocalCharacterModels ~= false
				and "Also shows the previous Room3D's local placed character models."
				or "Keeps local placed character models separate.")
		end
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

	-- Explore3D is player-led: its spawn point establishes the entry view, so a
	-- fixed cinematic pose would be both misleading and unused.
	if subscene.kind ~= "Explore3D" and (background.kind == "Camera3D" or subscene.kind ~= "Novel2D") then
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

	if subscene.kind == "Explore3D" then
		self:_renderExploreSpawn(subscene)
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
	if subscene.kind == "Room3D" then
		self:_heading("Room Assembly")
		local owner = Schema.assemblyOwner(scene, subscene)
		self:_toggleRow("Enabled", owner.assemblyEnabled == true, function(value)
			owner.assemblyEnabled = value; app:markDirty()
		end)
		local definitions = { { id = "", label = "(none)" } }
		for _, definition in ipairs(project.roomDefinitions or {}) do table.insert(definitions, { id = definition.id, label = definition.name }) end
		self:_dropdownField("Room definition", definitions, owner.roomDefinitionId or "", function(id) owner.roomDefinitionId = id; app:markDirty() end)
		self:_buttonRow({ { text = owner ~= subscene and "Edit linked assembly" or "Edit Room Assembly", onClick = function()
			local definition = Schema.findById(project.roomDefinitions, owner.roomDefinitionId)
			if not definition then
				definition = require(script.Parent.Parent.Core.RoomAssembly).new(owner.name)
				table.insert(project.roomDefinitions, definition); owner.roomDefinitionId = definition.id
				app.dirty = true
			end
			app.assemblyWorkspace:open(definition)
		end } })
		self:_hint("Normal entry assembles before dialogue. Merge skips assembly. Crossfades/camera transitions use Fade to Black.")
		self:_renderRoomExiting(subscene)
	end
	if subscene.kind ~= "Novel2D" then self:_renderCharacterModels(subscene) end

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
		if #scene.subscenes > 1 then
			table.insert(actions, { text = "Delete", color = Theme.Danger, onClick = function()
				app:showConfirm("Delete " .. item.name .. "?", "Its sequence, local interactions, and local 3D character models will be removed. Jumps and conditional routes to it will be cleared.", function()
					app:deleteSubscene(item.id)
				end)
			end })
		end
		self:_buttonRow(actions)
	end
	self:_buttonRow({ { text = "+ Empty subscene", color = Theme.Accent, onClick = function() app:addSubscene() end } })

	self:_heading("Project")
	if subscene.kind == "Explore3D" then
		self:_caption(string.format("Spawn: %s   Lines: %d   Events: %d",
			subscene.spawnPosition ~= "" and "picked" or "not picked",
			Schema.countLines(scene), Schema.countEvents(scene)))
	else
		local pose = Schema.findCameraPose(project, Schema.effectivePoseId(scene, subscene))
		self:_caption(string.format("Pose: %s   Lines: %d   Events: %d", pose and pose.name or "none", Schema.countLines(scene), Schema.countEvents(scene)))
	end
end

function InspectorView:_renderCharacterModels(subscene)
	local app = self.app
	local scene = app.scene
	local project = app:getProject()
	self:_heading("3D Character Models")
	self:_hint("Place reusable character templates in this Room3D or Explore3D. Local copies can follow a linked Room3D when local 3D models are linked.")
	local choices = {}
	for _, character in ipairs(project.characters or {}) do
		if character.modelRef then table.insert(choices, { id = character.name, label = character.name }) end
	end
	if #choices == 0 then
		self:_caption("Assign a 3D model template in Presets → Characters first.")
	else
		self:_dropdownField("Place character", choices, "", function(characterName)
			app:placeCharacterModel(characterName)
		end, "(choose character)")
	end

	local placements = scene.characterModels or {}
	if #placements == 0 then
		self:_caption("No character models placed in this scene.")
		return
	end
	for _, placement in ipairs(placements) do
		local row = Widgets.create("Frame", {
			Name = "CharacterModel_" .. placement.id,
			Size = UDim2.new(1, 0, 0, 54), BackgroundColor3 = Theme.Row, BorderSizePixel = 0,
			LayoutOrder = self:_next(), Parent = self.body,
		}, { Widgets.corner(5), Widgets.padding(3, 4, 3, 4) })
		if self.pendingCharacterModelPlacementId == placement.id then
			self.pendingCharacterModelPlacementId = nil
			task.defer(function()
				if row.Parent == self.body then
					local y = row.AbsolutePosition.Y - self.body.AbsolutePosition.Y + self.body.CanvasPosition.Y - 8
					self.body.CanvasPosition = Vector2.new(0, math.max(0, y))
				end
			end)
		end
		characterModelViewport(row, project, placement.character)
		Widgets.label({
			Text = placement.character .. "  ·  " .. (placement.scope or "Local"),
			Position = UDim2.fromOffset(56, 2), Size = UDim2.new(1, -56, 0, 16),
			Font = Theme.FontBold, TextSize = 11, Parent = row,
		})
		Widgets.button({
			Text = placement.scope == "Shared" and "Shared" or "Local", Position = UDim2.fromOffset(56, 23),
			Size = UDim2.fromOffset(52, 24), TextSize = 9, Color = placement.scope == "Shared" and Theme.Accent or Theme.Button,
			OnClick = function()
				placement.scope = placement.scope == "Shared" and "Local" or "Shared"
				if placement.scope == "Local" then placement.subsceneId = subscene.id end
				app:refreshCharacterModelPlacements()
				app:markDirty()
			end, Parent = row,
		})
		Widgets.button({
			Text = "Go", Position = UDim2.fromOffset(112, 23), Size = UDim2.fromOffset(38, 24), TextSize = 9,
			OnClick = function() app:focusCharacterModelPlacement(placement.id) end, Parent = row,
		})
		Widgets.button({
			Text = "Move", Position = UDim2.fromOffset(154, 23), Size = UDim2.fromOffset(42, 24), TextSize = 9, Color = Theme.Accent,
			OnClick = function() app:moveCharacterModelPlacement(placement.id) end, Parent = row,
		})
		Widgets.button({
			Text = "Remove", Position = UDim2.fromOffset(200, 23), Size = UDim2.fromOffset(58, 24), TextSize = 9, Color = Theme.Danger,
			OnClick = function()
				app:showConfirm("Remove placed model?", "Any Hotspot targeting it will become unbound.", function()
					app:removeCharacterModelPlacement(placement.id)
				end)
			end, Parent = row,
		})
	end
end

function InspectorView:scrollToCharacterModelPlacement(placementId)
	self.pendingCharacterModelPlacementId = placementId
end

function InspectorView:_renderExploreSpawn(subscene)
	local app = self.app
	self:_heading("Explore3D spawn")
	self:_hint("Used on normal entry. Click an exact world point; the current camera direction becomes the default player facing. A Room3D return position can override this location for one arrival.")
	self:_caption(subscene.spawnPosition ~= "" and ("Spawn: " .. subscene.spawnPosition .. (subscene.spawnCFrame ~= "" and "  ·  facing saved" or "")) or "Spawn position: not picked")
	self:_buttonRow({
		{ text = "Pick Spawn in World", color = Theme.Accent, onClick = function()
			self:_pickWorldPosition(nil, nil, "Click the exact world position for this Explore3D player spawn.", function(positionText)
				subscene.spawnPosition = positionText
				local camera = workspace.CurrentCamera
				if camera then
					subscene.spawnCFrame = Schema.encodeCFrame(CFrame.new(Schema.decodePosition(positionText)) * camera.CFrame.Rotation)
				else
					subscene.spawnCFrame = ""
				end
				app:markDirty()
			end)
		end },
		{ text = "Go", onClick = function()
			self:_focusWorldPosition(subscene.spawnPosition)
		end },
		{ text = "Clear", onClick = function()
			subscene.spawnPosition = ""
			subscene.spawnCFrame = ""
			app:markDirty()
		end },
	})
end

function InspectorView:_renderRoomExiting(subscene)
	local app = self.app
	local exiting = subscene.exiting
	self:_heading("Exiting · R")
	self:_toggleRow("Exitable", exiting.exitable ~= false, function(value)
		exiting.exitable = value
		app:markDirty()
	end)
	if exiting.exitable == false then
		self:_hint("Enable exiting to configure its conditions, destination, transition, and sequence preset.")
		return
	end
	self:_hint("Press R while this Room3D is waiting. Conditions are evaluated against live flags for every attempt.")
	self:_renderConditions(exiting.conditions, "Exiting conditions")
	if #exiting.conditions > 0 then
		self:_choiceField("When conditions match, Exitable is", { "true", "false" }, tostring(exiting.conditionResult ~= false), function(value)
			exiting.conditionResult = value == "true"
			app:markDirty()
		end)
	end

	self:_heading("Exit destination")
	self:_choiceField("Destination mode", { "Auto", "Manual" }, exiting.destinationMode or "Auto", function(mode)
		exiting.destinationMode = mode
		app:markDirty()
	end)
	if exiting.destinationMode == "Manual" then
		local sceneItems = {}
		for _, candidate in ipairs(app:getChapter().scenes) do
			table.insert(sceneItems, { id = candidate.id, label = candidate.name })
		end
		local selectedSceneId = exiting.sceneId ~= "" and exiting.sceneId or app.scene.id
		self:_dropdownField("Scene", sceneItems, selectedSceneId, function(id)
			exiting.sceneId = id
			exiting.subsceneId = ""
			exiting.returnPosition = ""
			app:markDirty()
		end, "(choose scene)")
		local selectedScene = selectedSceneId == app.scene.id and app.scene
			or Schema.findScene(app:getChapter(), selectedSceneId)
		local subsceneItems = {}
		for _, candidate in ipairs(selectedScene and selectedScene.subscenes or {}) do
			table.insert(subsceneItems, { id = candidate.id, label = candidate.name .. " · " .. candidate.kind })
		end
		self:_dropdownField("Subscene", subsceneItems, exiting.subsceneId, function(id)
			exiting.subsceneId = id
			exiting.returnPosition = ""
			app:markDirty()
		end, "(choose subscene)")
		local destination = selectedScene and Schema.subsceneIndex(selectedScene, exiting.subsceneId)
		if destination and destination.kind == "Explore3D" then
			self:_caption(exiting.returnPosition ~= "" and ("Return position: " .. exiting.returnPosition) or "Return position: not picked")
			self:_buttonRow({
				{ text = "Pick Target in World", color = Theme.Accent, onClick = function()
					app:pickTarget(function(_, target)
						if target and target:IsA("BasePart") then
							exiting.returnPosition = Schema.encodePosition(target.Position)
							app:markDirty()
						end
					end, {
						assignId = false, partOnly = true,
						previewScene = Schema.subsceneView(selectedScene, destination),
						prompt = "Click a part in the destination Explore3D. Only its world position is saved.",
					})
				end },
				{ text = "Clear", onClick = function()
					exiting.returnPosition = ""
					app:markDirty()
				end },
			})
		end
	else
		self:_hint("Auto returns to the source remembered from the latest Hotspot Enter transition. An Explore3D source restores a point two studs in front of the Hotspot's front face.")
	end
	self:_dropdownField("Exit transition", app:pickerItems("transition"), exiting.transitionId, function(id)
		exiting.transitionId = id
		app:markDirty()
	end, "Fade to black")
	self:_dropdownField("Exitable sequence preset", app:pickerItems("sequencePreset"), exiting.exitablePresetId, function(id)
		exiting.exitablePresetId = id
		app:markDirty()
	end)
	self:_buttonRow({ { text = "Edit Exiting Sequence", color = Theme.Accent, onClick = function()
		app:openSequencePreset(exiting.exitablePresetId)
	end } })
	self:_dropdownField("Non-exitable sequence preset", app:pickerItems("sequencePreset"), exiting.blockedPresetId, function(id)
		exiting.blockedPresetId = id
		app:markDirty()
	end)
end

function InspectorView:_renderAwaitRoutes(subscene)
	local app = self.app
	local scene = app.scene
	self:_heading("On AWAIT")
	self:_hint("Routes are checked when this subscene first waits and each time an interaction returns it to AWAIT. They run top to bottom; a route with no conditions always runs, so keep it last as a fallback.")
	local destinations = app:pickerItems("subscene")
	for index, item in ipairs(destinations) do
		if item.id == subscene.id then table.remove(destinations, index) break end
	end
	for routeIndex, route in ipairs(subscene.awaitRoutes) do
		self:_caption(#route.conditions == 0 and ("Unconditional route " .. routeIndex) or ("Conditional route " .. routeIndex))
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
			self:_conditionValueField(condition)
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
	self:_buttonRow({ { text = "+ AWAIT route", onClick = function()
		table.insert(subscene.awaitRoutes, {
			id = Schema.newId("route"),
			conditions = {},
			toSubsceneId = "", transitionId = Schema.DEFAULT_FADE, transitionExplicit = false,
		})
		app:markDirty()
	end } })
end

function InspectorView:_renderPoseField(label, poseId, onPick)
	local app = self.app

	self:_dropdownField(label, app:pickerItems("pose"), poseId, onPick, "(no pose: camera stays put)", {
		mapPick = function(mousePosition)
			return app.gizmos:cameraPoseIdAt(mousePosition)
		end,
	})

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

function InspectorView:_renderConditions(conditions, label, options)
	options = options or {}
	local app = self.app
	local flagItems = app:pickerItems("flag")
	if label and label ~= "" then
		self:_caption(label .. (options.compact and "" or " (all must pass)"))
	end

	for index, condition in ipairs(conditions) do
		local row = Widgets.create("Frame", {
			Size = UDim2.new(1, 0, 0, 24),
			BackgroundTransparency = 1,
			LayoutOrder = self:_next(),
			Parent = self.body,
		}, { Widgets.hlist(4) })

		Widgets.dropdown(app.gui, {
			Items = flagItems, Value = condition.flag, Placeholder = "flag",
			Size = UDim2.new(0.42, 0, 1, 0), LayoutOrder = 1,
			OnPick = function(flagId) condition.flag = flagId; app:markDirty() end,
			Parent = row,
		})
		local opItems = {}
		for _, op in ipairs(Schema.CONDITION_OPS) do table.insert(opItems, { id = op, label = op }) end
		Widgets.dropdown(app.gui, {
			Items = opItems, Value = condition.op, Size = UDim2.new(0.18, 0, 1, 0), LayoutOrder = 2,
			OnPick = function(op) condition.op = op; app:markDirty() end,
			Parent = row,
		})
		self:_inlineConditionValueField(condition, row, 3)
		Widgets.button({
			Text = "x", Size = UDim2.new(0.12, -4, 1, 0), Color = Theme.Danger, TextSize = 11, LayoutOrder = 4,
			OnClick = function() table.remove(conditions, index); app:markDirty() end,
			Parent = row,
		})
	end

	self:_buttonRow({ {
		text = "+ Condition",
		onClick = function()
			local firstFlag = flagItems[1] and flagItems[1].id or ""
			if firstFlag == "" then
				app:notify("Add a scene flag here or a chapter flag from the flow screen first.", Theme.Danger)
				return
			end
			table.insert(conditions, { flag = firstFlag, op = "==", value = "true" })
			app:markDirty()
		end,
	} })
end

function InspectorView:_renderInteraction(interaction, options)
	options = options or {}
	local app = self.app
	local scene = app.scene
	local project = app:getProject()
	local subscene = app:getActiveSubscene()
	local isTimelineSnapshot = options.timelineSnapshot == true
	local openResponse = options.openResponse or function(responseId)
		app:openSequenceOwner("interaction", interaction.id, responseId)
	end
	local isEditingResponse = options.isEditingResponse or function(responseId)
		return app.openSequence.owner == "interaction" and app.openSequence.interactionId == interaction.id
			and app.openSequence.responseId == responseId
	end

	self:_heading(isTimelineSnapshot and "Timeline interaction snapshot" or "Interaction")

	self:_textField("Name", interaction.name, function(text)
		local trimmed = Schema.trimName(text)
		interaction.name = trimmed ~= "" and trimmed or interaction.kind
		app:markDirty()
	end)

	self:_toggleRow("Enabled", interaction.enabled ~= false, function(enabled)
		interaction.enabled = enabled
		app:markDirty()
	end)

	self:_hint(subscene.kind == "Explore3D" and "Hotspot: the player clicks the target while within 7 studs." or "Hotspot: the player clicks the target.")

	self:_heading("Target")
	local characterPlacement = Schema.characterModelForInteraction(scene, interaction)
	self:_caption(characterPlacement and ("placed character model · " .. characterPlacement.character)
		or (interaction.targetId ~= "" and (interaction.targetRef and "target saved" or "legacy target id only — pick once to repair") or "no target picked yet"))
	if characterPlacement then
		local targetCard = Widgets.create("Frame", {
			Size = UDim2.new(1, 0, 0, 54), BackgroundColor3 = Theme.Row, BorderSizePixel = 0,
			LayoutOrder = self:_next(), Parent = self.body,
		}, { Widgets.corner(5), Widgets.padding(3, 4, 3, 4) })
		characterModelViewport(targetCard, project, characterPlacement.character)
		Widgets.label({
			Text = characterPlacement.character .. "  ·  placed 3D target",
			Position = UDim2.fromOffset(56, 3), Size = UDim2.new(1, -60, 0, 16),
			Font = Theme.FontBold, TextSize = 11, Parent = targetCard,
		})
		Widgets.button({
			Text = "Go to model", Position = UDim2.fromOffset(56, 23), Size = UDim2.fromOffset(84, 24),
			TextSize = 9, Color = Theme.Accent,
			OnClick = function() app:goToCharacterModelPlacement(characterPlacement.id) end,
			Parent = targetCard,
		})
	end
	self:_buttonRow({
		{ text = isTimelineSnapshot and "Pick target in world" or "Pick target in world (T)", color = Theme.Accent, onClick = function()
			if options.pickTarget then
				options.pickTarget(interaction)
			else
				app:pickTarget(function(targetId, target, targetRef)
					app:setInteractionTarget(interaction, targetId, target, targetRef)
				end, { interactionId = interaction.id })
			end
		end },
		{ text = "Clear", onClick = function() app:clearInteractionTarget(interaction) end },
	})

	self:_heading("Scope")
	if isTimelineSnapshot then
		self:_hint("This is a saved timeline invocation. Its world scope is not used here; its conditions and response order are evaluated when this block runs.")
	else
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
	end
	self:_heading("When triggered")
	self:_dropdownField("Enter / exit transition", app:pickerItems("transition"), interaction.transitionId, function(transitionId)
		interaction.transitionId = transitionId
		app:markDirty()
	end, "(none)")
	self:_hint("Zoom moves toward the target while the sequence plays, keeps it visible, then returns the camera.")

	self:_heading("Responses")
	self:_hint("Conditional responses are checked from top to bottom. The first match plays; Default response is used when none match.")
	for index, response in ipairs(interaction.responses or {}) do
		self:_caption(string.format("%d. Conditional response (priority %d)", index, index))
		self:_textField(nil, response.name, function(text)
			response.name = Schema.trimName(text) ~= "" and Schema.trimName(text) or "Conditional response"
			app:markDirty()
		end, { placeholder = "Response name" })
		self:_renderConditions(response.conditions, "Conditions", { compact = true })
		self:_buttonRow({
			{ text = "Edit", color = Theme.Accent, onClick = function()
				openResponse(response.id)
			end },
			{ text = "Up", onClick = function()
				if index > 1 then
					interaction.responses[index], interaction.responses[index - 1] = interaction.responses[index - 1], interaction.responses[index]
					app:markDirty()
				end
			end },
			{ text = "Down", onClick = function()
				if index < #interaction.responses then
					interaction.responses[index], interaction.responses[index + 1] = interaction.responses[index + 1], interaction.responses[index]
					app:markDirty()
				end
			end },
			{ text = response.repeatPolicy == "once" and "Once" or "Always", color = response.repeatPolicy == "once" and Theme.Gold or Theme.Button, onClick = function()
				response.repeatPolicy = response.repeatPolicy == "once" and "always" or "once"
				app:markDirty()
			end },
			{ text = "Delete", color = Theme.Danger, onClick = function()
				app:showConfirm("Delete conditional response?", "Its sequence is removed from this interaction.", function()
					table.remove(interaction.responses, index)
					if isEditingResponse(response.id) then
						openResponse("default")
					end
					app:markDirty()
				end)
			end },
		})
		self:_spacer(6)
	end
	if #(interaction.responses or {}) > 0 then self:_spacer(2) end
	self:_buttonRow({ { text = "+ Conditional response", onClick = function()
		local flagItems = app:pickerItems("flag")
		local firstFlag = flagItems[1] and flagItems[1].id or ""
		if firstFlag == "" then
			app:notify("Add a scene flag here or a chapter flag from the flow screen first.", Theme.Danger)
			return
		end
		local response = Schema.newInteractionResponse("Conditional response " .. (#interaction.responses + 1))
		local targetPlacement = Schema.characterModelForInteraction(scene, interaction)
		if targetPlacement then
			response.sequence = { segments = {
				Schema.newDialogueSegment(app:getProject(), {
					character = targetPlacement.character,
					portrait = Schema.getCharacterPriorityPortrait(app:getProject(), targetPlacement.character),
				}),
			} }
		end
		table.insert(response.conditions, { flag = firstFlag, op = "==", value = "true" })
		table.insert(interaction.responses, response)
		openResponse(response.id)
		app:markDirty()
	end } })

	self:_caption(string.format("Default response: %d block(s) · always used if no conditional response matches", #interaction.sequence.segments))
	self:_buttonRow({
		{ text = "Edit default response", color = Theme.Accent, onClick = function()
			openResponse("default")
		end },
	})

	-- This deliberately copies only after confirmation. While it is active the
	-- interaction list and its world markers become a multi-select surface, so
	-- authors cannot accidentally open another inspector halfway through.
	if not isTimelineSnapshot then
		if app:isApplyingDefaultResponse() then
			local batch = app.defaultResponseApply
			if batch and batch.sourceInteractionId == interaction.id then
				self:_caption(string.format("Select interactions in the list or preview · %d selected", app:defaultResponseApplyCount()))
				self:_buttonRow({
					{ text = "✓", color = Theme.Good, onClick = function()
						app:confirmDefaultResponseApply()
					end },
					{ text = "x", color = Theme.Danger, onClick = function()
						app:cancelDefaultResponseApply()
					end },
				})
			end
		else
			self:_buttonRow({
				{ text = "Apply default response to...", onClick = function()
					app:beginDefaultResponseApply(interaction.id)
				end },
			})
		end
	end

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

-- A timeline Interaction block owns a detached copy of its source. The source
-- may disappear later, so the inspector never depends on it being present to
-- edit or play the copy. Refreshing is intentionally manual.
function InspectorView:_renderTimelineInteraction(segment, subscene)
	local app = self.app
	local data = segment.interaction or {}
	local snapshot = data.snapshot
	if not snapshot then
		self:_heading("Timeline interaction")
		self:_hint("This block has no usable snapshot. Delete it or update it from a linked source.")
		return
	end

	local source = Schema.findInteraction(app.scene, data.sourceInteractionId)
	local sourceRevision = source and Schema.interactionRevision and Schema.interactionRevision(source) or nil
	local isStale = source ~= nil and sourceRevision ~= nil and data.sourceRevision ~= nil
		and sourceRevision ~= data.sourceRevision

	self:_heading("Linked source")
	if not source then
		self:_caption("Source interaction is missing")
		self:_hint("This timeline block remains playable and editable as its saved snapshot.")
	else
		self:_caption(source.name .. (isStale and " · changed since this copy" or " · snapshot current"))
		self:_buttonRow({
			{ text = "Update from Original", color = isStale and Theme.Accent or Theme.Button, onClick = function()
				-- Refreshing deliberately gives copied response records fresh ids. If
				-- one of those responses is open, its old sequence object is no
				-- longer part of the snapshot, so re-open the durable default response
				-- below to reset both the selection and runner to current data.
				local wasEditingThisCopy = app.openSequence.owner == "timelineInteraction"
					and app.openSequence.subsceneId == subscene.id
					and app.openSequence.segmentId == segment.id
				if Schema.refreshInteractionSegment then
					Schema.refreshInteractionSegment(segment, source)
				else
					data.snapshot = Schema.deepCopy(source)
					data.sourceInteractionId = source.id
					data.sourceRevision = Schema.interactionRevision and Schema.interactionRevision(source) or ""
				end
				if wasEditingThisCopy then
					app:openTimelineInteractionSequence(subscene.id, segment.id, "default")
				end
				app:markDirty()
			end },
			{ text = "Open Original", onClick = function()
				local sourceSubscene = Schema.subsceneIndex(app.scene, source.subsceneId)
				app:openSequenceOwner("subscene", sourceSubscene and sourceSubscene.id or subscene.id)
				app:setSelection({ kind = "interaction", interactionId = source.id })
			end },
		})
		self:_hint(isStale
			and "The source changed after this block was added. Update deliberately replaces this block's copied settings and responses."
			or "This block is a saved copy. It will not change automatically when the source interaction changes.")
	end

	self:_renderInteraction(snapshot, {
		timelineSnapshot = true,
		pickTarget = function(interaction)
			app:pickTarget(function(targetId, _, targetRef)
				interaction.targetId = targetId
				interaction.targetRef = targetRef
				app:markDirty()
			end)
		end,
		openResponse = function(responseId)
			app:openTimelineInteractionSequence(subscene.id, segment.id, responseId)
		end,
		isEditingResponse = function(responseId)
			return app.openSequence.owner == "timelineInteraction"
				and app.openSequence.subsceneId == subscene.id
				and app.openSequence.segmentId == segment.id
				and app.openSequence.responseId == responseId
		end,
	})
end

--------------------------------------------------------------------------------
-- Segment section
--------------------------------------------------------------------------------

function InspectorView:_renderSegment(segment)
	local app = self.app

	if segment.kind == "Interaction" then
		-- A move/reorder action can leave a generic segment selection on this
		-- block. Treat it exactly like clicking the yellow block itself instead
		-- of falling through to the Dialogue-only fields below.
		self:_renderTimelineInteraction(segment, app:getActiveSubscene())
		return
	elseif segment.kind == "Timed" then
		self:_heading("Timed section")
		self:_numberField("Duration (seconds)", segment.duration, function(value)
			segment.duration = math.clamp(value, Schema.MIN_DURATION, Schema.MAX_DURATION)
			app:markDirty()
		end)
		self:_hint("Events on this section fire at their second. Use Show Portrait to bring a character on without dialogue.")
		self:_renderTracks(segment, segment.duration, "portrait")
		self:_renderTracks(segment, segment.duration, "background")
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
				if trimmed ~= "" then
					ProjectStore.addCharacter(trimmed)
				end
				Schema.assignDialogueCharacter(project, entry, trimmed)
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
				Schema.assignDialogueCharacter(project, entry, name)
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

	self:_toggleRow("Crossfade next portrait", entry.crossfadeNextPortrait == true, function(value)
		entry.crossfadeNextPortrait = value
		app:markDirty()
	end)
	self:_hint("Uses a black-to-colour portrait crossfade on the next distinct portrait instead of sweeping the camera.", 30)

	if entry.skippable == false then
		self:_numberField("Auto-continue delay (seconds)", entry.autoAdvanceDelay or Schema.DEFAULT_DIALOGUE_AUTO_ADVANCE, function(value)
			entry.autoAdvanceDelay = math.clamp(value, Schema.MIN_DIALOGUE_AUTO_ADVANCE, Schema.MAX_DIALOGUE_AUTO_ADVANCE)
			app:markDirty()
		end, { min = Schema.MIN_DIALOGUE_AUTO_ADVANCE, max = Schema.MAX_DIALOGUE_AUTO_ADVANCE, step = 0.1 })
	end

	self:_renderPortraitGallery(entry, segment)

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

	self:_renderTracks(entry, maxTime, "portrait")
	self:_renderTracks(entry, maxTime, "background")
end

--------------------------------------------------------------------------------
-- Portrait gallery
--------------------------------------------------------------------------------

function InspectorView:_portraitStroke(tile, selected)
	Widgets.stroke(selected and Theme.Accent or Theme.Border, selected and 2 or 1, selected and 0 or 0.4).Parent = tile
end

function InspectorView:_renderPortraitGallery(entry, segment)
	local app = self.app
	local project = app:getProject()
	local character = entry.character

	self:_heading("Portrait")

	if character == "" then
		self:_hint("Give the line a character to choose one of their portraits.")
		return
	end

	local portraits = Schema.getCharacterPortraits(project, character)
	local previousPortrait = ""
	local previousCharacter = ""
	local isMainCharacter = character ~= ""
		and character == Schema.trimName(project.mainCharacter)
	if isMainCharacter and segment and segment.kind == "Dialogue" then
		local index = table.find(segment.entries, entry)
		local previousEntry = index and segment.entries[index - 1] or nil
		if previousEntry and type(previousEntry.portrait) == "string" then
			previousPortrait = previousEntry.portrait
			previousCharacter = previousEntry.character or ""
		end
	end
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

	local portraitOrderStart = 2
	if previousPortrait ~= "" then
		local selected = entry.portrait == previousPortrait
		local previousTile = Widgets.create("ImageButton", {
			Name = "PreviousPortrait",
			Size = UDim2.fromOffset(PORTRAIT_TILE, PORTRAIT_TILE),
			BackgroundColor3 = Theme.Input,
			BorderSizePixel = 0,
			Image = previousPortrait,
			ImageTransparency = 0,
			ScaleType = Enum.ScaleType.Fit,
			ClipsDescendants = true,
			AutoButtonColor = false,
			LayoutOrder = portraitOrderStart,
			Parent = gallery,
		}, { Widgets.corner(6) })
		self:_portraitStroke(previousTile, selected)
		Widgets.label({
			Text = previousCharacter ~= "" and "PREVIOUS" or "PREVIOUS LINE",
			Position = UDim2.new(0, 2, 1, -14),
			Size = UDim2.new(1, -4, 0, 12),
			TextSize = 7,
			Font = Theme.FontBold,
			TextColor3 = Theme.Text,
			TextXAlignment = Enum.TextXAlignment.Center,
			BackgroundColor3 = Theme.Panel,
			BackgroundTransparency = 0.15,
			BorderSizePixel = 0,
			Parent = previousTile,
		}, { Widgets.corner(3) })
		previousTile.MouseButton1Click:Connect(function()
			entry.portrait = previousPortrait
			app:markDirty()
		end)
		portraitOrderStart += 1
	end

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
			LayoutOrder = index + portraitOrderStart - 1,
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
			LayoutOrder = #portraits + portraitOrderStart,
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
			LayoutOrder = #portraits + portraitOrderStart,
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
function InspectorView:_renderTracks(owner, maxTime, target)
	local app = self.app
	target = target or "portrait"
	local backgroundTrack = target == "background"

	self:_heading(backgroundTrack and "Background image keyframes" or "Portrait keyframes")

	local track = nil
	for _, candidate in ipairs(owner.tracks) do
		if candidate.target == target then
			track = candidate
			break
		end
	end

	local localTime = app:getLocalTime()

	if not track then
		self:_hint(backgroundTrack
			and "Keyframes move, scale, rotate and fade whichever image background is active here, including a Background event that switches to Image."
			or "Keyframes move, scale, rotate and fade the portrait over time.")
		self:_buttonRow({
			{ text = "+ Add keyframe track", onClick = function()
				table.insert(owner.tracks, Schema.newTrack(target))
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
			self:_renderKey(track, key, maxTime, target)
		end
	end
end

function InspectorView:_renderKey(track, key, maxTime, target)
	local app = self.app

	self:_heading("Selected key")
	self:_hint(target == "background"
		and "Values below position the active image background as stage fractions."
		or "Drag the portrait on the stage to place it. Values below are stage fractions.")

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
	if app.openSequence.owner == "timelineInteraction" then
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

function InspectorView:_eventInteraction(anchorKind)
	local app = self.app
	if anchorKind == "Complete" then
		return nil
	end
	if app.openSequence.owner == "timelineInteraction" then
		return app:getTimelineInteractionSnapshot(app.openSequence.subsceneId, app.openSequence.segmentId)
	end
	if app.openSequence.owner ~= "interaction" then
		return nil
	end
	return Schema.findInteraction(app.scene, app.openSequence.interactionId)
end

function InspectorView:_renderEvent(event, anchorKind, segment)
	local app = self.app
	local isGotoEvent = event.type == "FlowGotoSubscene" or event.type == "FlowGoto"
	local gotoSource = isGotoEvent and self:_eventSourceSubscene() or nil
	local gotoInteraction = isGotoEvent and self:_eventInteraction(anchorKind) or nil
	local allowEnter = Schema.canUseEnterTransition(gotoInteraction, anchorKind)

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
	if event.type == "FlowGotoSubscene" and app.openSequence.owner == "interaction" and not gotoSource then
		self:_hint("Merge is unavailable for a Shared interaction because it can run from more than one subscene.")
	end

	self:_numberField("Delay (seconds)", event.delay or 0, function(value)
		event.delay = math.max(0, value)
		app:markDirty()
	end)

	if EventRegistry.isDurational(event.type) then
		local durationLabel = event.type == "ImageFocusShow"
			and "Display duration (0 = until hidden)"
			or "Duration (0 = instant)"
		self:_numberField(durationLabel, event.duration, function(value)
			event.duration = math.max(0, value)
			app:markDirty()
		end)

		if event.duration > 0 and event.type ~= "ImageFocusShow" then
			self:_dropdownField("Easing", self:_easingItems(), event.easing, function(easing)
				event.easing = easing
				app:markDirty()
			end)
		end
	end

	local previousFieldGroup = nil
	for _, field in ipairs(EventRegistry.fields(event.type)) do
		if field.hidden then continue end
		if field.group and field.group ~= previousFieldGroup then
			self:_heading(event.type == "ScreenShake" and field.group .. " Shake" or field.group)
			previousFieldGroup = field.group
		end
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
					items = self:_subsceneTransitionItems(gotoSource, event.params.subsceneId, allowEnter)
				elseif event.type == "FlowGoto" and field.key == "transitionId" then
					items = self:_sceneTransitionItems(allowEnter)
				end
				self:_dropdownField(field.label, items, value, function(id)
					event.params[field.key] = id
					if event.type == "FlowGotoSubscene" and field.key == "subsceneId" then
						event.params.transitionId = Schema.defaultGotoSubsceneTransition(
							app.scene,
							gotoSource,
							id,
							gotoInteraction,
							anchorKind
						)
						event.params.exploreArrivalMode = "Exit"
						event.params.exploreReturnPosition = ""
						event.transitionExplicit = false
					elseif event.type == "FlowGoto" and field.key == "sceneId" then
						event.params.transitionId = Schema.defaultGotoSceneTransition(gotoInteraction, anchorKind)
						event.params.exploreArrivalMode = "Exit"
						event.params.exploreReturnPosition = ""
						event.transitionExplicit = false
					elseif isGotoEvent and field.key == "transitionId" then
						event.transitionExplicit = true
					end
					app:markDirty()
				end, "(none)", field.picker == "pose" and {
					mapPick = function(mousePosition)
						return app.gizmos:cameraPoseIdAt(mousePosition)
					end,
				} or nil)

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

	if isGotoEvent then
		local destinationScene, destination = self:_gotoDestination(event)
		-- A Shared interaction has no single authoring source, but it can still
		-- run from the Room3D currently being edited. Let that concrete editor
		-- context expose the arrival controls; runtime still verifies the actual
		-- active subscene before applying an Exit return point.
		local arrivalSource = gotoSource
		if not arrivalSource and app.openSequence.owner == "interaction" then
			local active = app:getActiveSubscene()
			if active and active.kind == "Room3D" then arrivalSource = active end
		end
		self:_renderExploreArrival(event, arrivalSource, destinationScene, destination)
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

	if selection.kind == "timelineInteraction" then
		local segment, _, subscene = app:getTimelineInteractionSegment(
			selection.timelineSubsceneId,
			selection.timelineSegmentId
		)
		if segment and subscene then
			self.title.Text = "INSPECTOR  .  TIMELINE HOTSPOT"
			self:_renderTimelineInteraction(segment, subscene)
			return
		end
	end

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
