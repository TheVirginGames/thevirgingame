-- The editor shell. Three screens:
--
--   browser  chapters, presets, recycle bin
--   flow     one chapter's scenes as a graph, plus its flags
--   scene    the stage preview with the timeline / dialogue / inspector / events
--            panels docked at the bottom
--
-- Plus a full screen "play" state where the Director runs a chapter from a
-- fresh copy of its saved flag defaults. The Presenter is shared by everything.

local UserInputService = game:GetService("UserInputService")

local root = script.Parent.Parent
local ProjectStore = require(root.Core.ProjectStore)
local Schema = require(root.Core.Schema)
local JSONCodec = require(root.Core.JSONCodec)
local SequenceState = require(root.Runtime.SequenceState)
local SequenceRunner = require(root.Runtime.SequenceRunner)
local Director = require(root.Runtime.Director)
local Presenter = require(root.Render.Presenter)

local Theme = require(script.Parent.Theme)
local Widgets = require(script.Parent.Widgets)
local ProjectBrowserView = require(script.Parent.ProjectBrowserView)
local ChapterFlowView = require(script.Parent.ChapterFlowView)
local TimelineView = require(script.Parent.TimelineView)
local DialogueListView = require(script.Parent.DialogueListView)
local InteractionListView = require(script.Parent.InteractionListView)
local InspectorView = require(script.Parent.InspectorView)
local EventLayerView = require(script.Parent.EventLayerView)
local PreviewStateView = require(script.Parent.PreviewStateView)
local StageGizmos = require(script.Parent.StageGizmos)
local WorldPicker = require(script.Parent.WorldPicker)
local FlyCam = require(script.Parent.FlyCam)

local EditorApp = {}
EditorApp.__index = EditorApp

function EditorApp.new(playerGui)
	local self = setmetatable({}, EditorApp)

	self.mode = "browser"
	self.chapterId = nil
	self.scene = nil
	self.dirty = false
	self.selection = { kind = "scene" }
	self.openSequence = { owner = "subscene" }
	self.sceneSettingsDefault = true
	self.previewFlags = {}
	self.previewFlagOverrides = {}
	self.runtimeFlags = {}
	self.previewStateOpen = false
	self.modal = nil
	self.playing = false
	self.capturing = false
	-- ALT toggles the lightweight editor/playtest status overlays. Keep this
	-- on the app rather than on a particular scene so the preference survives
	-- scene changes and entering/leaving a chapter playtest.
	self.statusOverlayVisible = true

	self.gui = Widgets.create("ScreenGui", {
		Name = "VNSceneEditor",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		DisplayOrder = 100,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Enabled = false,
		Parent = playerGui,
	})

	self.hintGui = Widgets.create("ScreenGui", {
		Name = "VNSceneEditorHint",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		DisplayOrder = 99,
		Enabled = true,
		Parent = playerGui,
	})

	Widgets.label({
		Text = "F4   VN Chapter Editor",
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -14, 1, -14),
		Size = UDim2.new(0, 190, 0, 26),
		BackgroundColor3 = Theme.Panel,
		BackgroundTransparency = 0.25,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextColor3 = Theme.TextDim,
		Font = Theme.FontBold,
		TextSize = 12,
		Parent = self.hintGui,
	})

	self.presenter = Presenter.new(self.gui, { editor = true })
	self.runner = SequenceRunner.new(self.presenter)
	self.director = Director.new(self.presenter, ProjectStore.getProject())

	self:_buildTopBar()
	self:_buildBottomPanel()
	self:_buildPlayHud()

	self.toast = Widgets.label({
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 58),
		Size = UDim2.new(0, 640, 0, 26),
		BackgroundColor3 = Theme.Panel,
		BackgroundTransparency = 0.08,
		TextXAlignment = Enum.TextXAlignment.Center,
		Font = Theme.FontBold,
		TextSize = 13,
		Visible = false,
		ZIndex = 90,
		Parent = self.gui,
	})
	Widgets.corner(6).Parent = self.toast

	self.browserView = ProjectBrowserView.new(self.gui, self)
	self.flowView = ChapterFlowView.new(self.gui, self)
	self.timelineView = TimelineView.new(self.timelineHolder, self)
	self.dialogueListView = DialogueListView.new(self.dialogueHolder, self)
	self.interactionListView = InteractionListView.new(self.dialogueHolder, self)
	self.inspectorView = InspectorView.new(self.inspectorHolder, self)
	self.eventLayerView = EventLayerView.new(self.eventHolder, self)
	self.previewStateView = PreviewStateView.new(self.gui, self)
	self.gizmos = StageGizmos.new(self.gui, self)
	self.worldPicker = WorldPicker.new(self.gui, self)
	self.flyCam = FlyCam.new(self.gui, self)

	self:_connectSignals()

	self.presenter:getStage():clear()
	self:_applyMode()

	return self
end

--------------------------------------------------------------------------------
-- Chrome
--------------------------------------------------------------------------------

function EditorApp:_buildTopBar()
	self.topBar = Widgets.create("Frame", {
		Name = "TopBar",
		Size = UDim2.new(1, 0, 0, 48),
		BackgroundColor3 = Theme.Backdrop,
		BackgroundTransparency = 0.08,
		BorderSizePixel = 0,
		ZIndex = 10,
		Visible = false,
		Parent = self.gui,
	}, { Widgets.padding(9, 14, 9, 14) })

	local left = Widgets.create("Frame", {
		Size = UDim2.new(0.5, 0, 1, 0),
		BackgroundTransparency = 1,
		Parent = self.topBar,
	}, { Widgets.hlist(8) })

	Widgets.button({
		Text = "< Flow",
		Size = UDim2.new(0, 80, 1, 0),
		LayoutOrder = 1,
		OnClick = function()
			self:closeScene()
		end,
		Parent = left,
	})

	self.sceneLabel = Widgets.label({
		Size = UDim2.new(0, 220, 1, 0),
		Font = Theme.FontBold,
		TextSize = 14,
		LayoutOrder = 2,
		Parent = left,
	})

	self.sequenceHolder = Widgets.create("Frame", {
		Size = UDim2.new(0, 200, 1, 0),
		BackgroundTransparency = 1,
		LayoutOrder = 3,
		Parent = left,
	})

	Widgets.button({
		Text = "Scene settings",
		Size = UDim2.new(0, 110, 1, 0),
		TextSize = 11,
		LayoutOrder = 4,
		OnClick = function()
			self:setSelection({ kind = "scene" })
		end,
		Parent = left,
	})

	self.cursorLabel = Widgets.label({
		Size = UDim2.new(0, 220, 1, 0),
		TextSize = 11,
		TextColor3 = Theme.TextFaint,
		Font = Theme.FontMono,
		LayoutOrder = 5,
		Parent = left,
	})

	local right = Widgets.create("Frame", {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 0, 0, 0),
		Size = UDim2.new(0.5, 0, 1, 0),
		BackgroundTransparency = 1,
		Parent = self.topBar,
	}, { Widgets.hlist(8) })

	local layout = right:FindFirstChildOfClass("UIListLayout")
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Right

	self.dirtyLabel = Widgets.label({
		Size = UDim2.new(0, 160, 1, 0),
		TextSize = 11,
		TextColor3 = Theme.TextDim,
		TextXAlignment = Enum.TextXAlignment.Right,
		LayoutOrder = 1,
		Parent = right,
	})

	Widgets.button({
		Text = "Flags",
		Size = UDim2.new(0, 60, 1, 0),
		TextSize = 11,
		LayoutOrder = 2,
		OnClick = function()
			self:togglePreviewState()
		end,
		Parent = right,
	})

	Widgets.button({
		Text = "Play Sequence",
		Size = UDim2.new(0, 110, 1, 0),
		Color = Theme.Good,
		TextSize = 11,
		LayoutOrder = 3,
		OnClick = function()
			self:playSequence(true)
		end,
		Parent = right,
	})

	Widgets.button({
		Text = "Play Here",
		Size = UDim2.new(0, 84, 1, 0),
		TextSize = 11,
		LayoutOrder = 4,
		OnClick = function()
			self:playSequence(false)
		end,
		Parent = right,
	})

	Widgets.button({
		Text = "Play Chapter Here",
		Size = UDim2.new(0, 130, 1, 0),
		Color = Theme.Accent,
		TextSize = 11,
		LayoutOrder = 5,
		OnClick = function()
			self:playChapter(self.chapterId, self.scene and self.scene.id)
		end,
		Parent = right,
	})

	Widgets.button({
		Text = "Export",
		Size = UDim2.new(0, 66, 1, 0),
		TextSize = 11,
		LayoutOrder = 6,
		OnClick = function()
			self:exportScene()
		end,
		Parent = right,
	})

	Widgets.button({
		Text = "Save",
		Size = UDim2.new(0, 80, 1, 0),
		Color = Theme.Good,
		LayoutOrder = 7,
		OnClick = function()
			self:save()
		end,
		Parent = right,
	})
end

function EditorApp:_buildBottomPanel()
	self.bottomPanel = Widgets.panel({
		Name = "EditorPanel",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, 0),
		Size = UDim2.new(1, 0, Theme.PanelHeight, 0),
		BackgroundColor3 = Theme.Backdrop,
		BackgroundTransparency = 0.04,
		Radius = 0,
		ZIndex = 10,
		Visible = false,
		Parent = self.gui,
	})

	Widgets.create("Frame", {
		Name = "AccentLine",
		Size = UDim2.new(1, 0, 0, 2),
		BackgroundColor3 = Theme.Accent,
		BorderSizePixel = 0,
		Parent = self.bottomPanel,
	})

	local content = Widgets.create("Frame", {
		Name = "Content",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Parent = self.bottomPanel,
	}, { Widgets.padding(12, 14, 12, 14) })

	self.timelineHolder = Widgets.create("Frame", {
		Name = "TimelineHolder",
		Size = UDim2.new(1, 0, 0, 142),
		BackgroundTransparency = 1,
		Parent = content,
	})

	local lower = Widgets.create("Frame", {
		Name = "LowerHolder",
		Position = UDim2.new(0, 0, 0, 152),
		Size = UDim2.new(1, 0, 1, -152),
		BackgroundTransparency = 1,
		Parent = content,
	})

	self.dialogueHolder = Widgets.create("Frame", {
		Name = "DialogueHolder",
		Size = UDim2.new(0.34, -6, 1, 0),
		BackgroundTransparency = 1,
		Parent = lower,
	})

	self.inspectorHolder = Widgets.create("Frame", {
		Name = "InspectorHolder",
		Position = UDim2.new(0.34, 6, 0, 0),
		Size = UDim2.new(0.36, -12, 1, 0),
		BackgroundTransparency = 1,
		Parent = lower,
	})

	self.eventHolder = Widgets.create("Frame", {
		Name = "EventHolder",
		Position = UDim2.new(0.70, 6, 0, 0),
		Size = UDim2.new(0.30, -6, 1, 0),
		BackgroundTransparency = 1,
		Parent = lower,
	})
end

function EditorApp:_buildPlayHud()
	self.stopButton = Widgets.button({
		Text = "Stop   (Esc)",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -16, 0, 16),
		Size = UDim2.new(0, 128, 0, 32),
		Color = Theme.Accent,
		ZIndex = 50,
		Visible = false,
		OnClick = function()
			self:stop()
		end,
		Parent = self.gui,
	})

	self.playLabel = Widgets.label({
		AnchorPoint = Vector2.new(0, 0),
		Position = UDim2.new(0, 16, 0, 16),
		Size = UDim2.new(0, 520, 0, 32),
		BackgroundColor3 = Theme.Panel,
		BackgroundTransparency = 0.35,
		TextSize = 12,
		TextColor3 = Theme.TextDim,
		Font = Theme.FontMono,
		ZIndex = 50,
		Visible = false,
		Parent = self.gui,
	})
	Widgets.corner(6).Parent = self.playLabel
	Widgets.padding(0, 10, 0, 10).Parent = self.playLabel
end

--------------------------------------------------------------------------------
-- Signals
--------------------------------------------------------------------------------

function EditorApp:_connectSignals()
	self.runner.CursorChanged:Connect(function(cursor)
		if self.scene and self.mode == "scene" then
			self.cursorLabel.Text = SequenceState.describeCursor(self:getSequence(), cursor)
		end
	end)

	self.runner.PlayingChanged:Connect(function(playing)
		self.playing = playing
		self:_applyMode()

		if not playing and self.mode == "scene" then
			self:refresh()
		end
	end)

	self.runner.Finished:Connect(function()
		if self.mode == "scene" and not self.director:isActive() then
			self:notify("Sequence finished.", Theme.TextDim)
		end
	end)

	self.director.SceneChanged:Connect(function(scene)
		self.playLabel.Text = string.format("Playing  .  %s", scene.name)
	end)
	self.director.SubsceneChanged:Connect(function(subscene)
		self.playLabel.Text = string.format("Playing  .  %s / %s  (%s)", self.director:getScene().name, subscene.name, subscene.kind)
	end)

	self.director.PhaseChanged:Connect(function(phase)
		if self.director:isActive() and self.director:getScene() then
			local scene = self.director:getScene()
			local subscene = self.director:getSubscene()
			self.playLabel.Text = string.format("Playing  .  %s / %s  (%s)  .  %s", scene.name,
				subscene and subscene.name or "...", subscene and subscene.kind or "...", phase)
			self.presenter:setAdvanceHint(phase == "Await" and "" or "click to continue")
		end
	end)

	self.director.FlagsChanged:Connect(function(flags)
		-- Runtime progression belongs to the Director. Keep a read-only copy for
		-- diagnostics without overwriting the editor's chosen starting preview
		-- state for the next playthrough.
		self.runtimeFlags = Schema.deepCopy(flags)
	end)

	self.director.Finished:Connect(function(reason)
		if self.mode == "play" then
			self:notify(reason == "end" and "Chapter finished." or ("Chapter stopped: " .. tostring(reason)), Theme.TextDim)
			task.delay(0.6, function()
				if self.mode == "play" then
					self:stop()
				end
			end)
		end
	end)

	ProjectStore.Changed:Connect(function(project)
		self.director:setProject(project)
		self:_reconcilePreviewFlags()
		if self.mode == "browser" then
			self.browserView:render()
		elseif self.mode == "flow" then
			self.flowView:render()
		end
	end)

	ProjectStore.PersistStatus:Connect(function()
		if self.mode == "browser" then
			self.browserView:render()
		elseif self.mode == "scene" then
			self:_refreshTopBar()
		end
	end)

	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if not self.gui.Enabled then
			return
		end

		if input.KeyCode == Enum.KeyCode.Escape then
			if self.flyCam:isActive() or self.worldPicker:isActive() then
				return
			end
			if self.mode == "play" or self.playing then
				self:stop()
			end
			return
		end

		if input.KeyCode == Enum.KeyCode.LeftAlt or input.KeyCode == Enum.KeyCode.RightAlt then
			self.statusOverlayVisible = not self.statusOverlayVisible
			self:_applyMode()
			return
		end

		if gameProcessed then
			return
		end

		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			if self.flyCam:isActive() or self.worldPicker:isActive() then
				return
			end

			if self.mode == "play" then
				self.director:advance()
			elseif self.mode == "scene" and self.playing then
				self.runner:advance()
			end
		elseif input.KeyCode == Enum.KeyCode.Space then
			if self.mode == "play" then
				self.director:advance()
			elseif self.mode == "scene" and self.playing then
				self.runner:advance()
			end
		end
	end)
end

--------------------------------------------------------------------------------
-- Modes
--------------------------------------------------------------------------------

function EditorApp:_applyMode()
	local mode = self.mode
	local sceneEditing = mode == "scene" and not self.playing and not self.capturing

	self.browserView:setVisible(mode == "browser")
	self.flowView:setVisible(mode == "flow")
	self.topBar.Visible = sceneEditing
	self.bottomPanel.Visible = sceneEditing
	self.gizmos:setVisible(sceneEditing)
	self.previewStateView:setVisible(sceneEditing and self.previewStateOpen)

	local playingSomething = mode == "play" or (mode == "scene" and self.playing)
	self.stopButton.Visible = self.statusOverlayVisible and playingSomething
	self.playLabel.Visible = self.statusOverlayVisible and mode == "play"

	self.presenter:getStage():setVisible(mode == "scene" or mode == "play" or self.capturing)
	self.presenter:getStage():setDebugVisible(
		self.statusOverlayVisible
			and not self.capturing
			and (mode == "scene" or mode == "play")
	)
	self.presenter:setSafeAreaBottom(sceneEditing and Theme.PanelHeight or 0)
	self.presenter:setInteractive(mode == "play")

	if mode == "scene" then
		self.presenter:setAdvanceHint(self.playing and "click to continue" or "")
	end
end

function EditorApp:_refreshTopBar()
	if not self.scene then
		return
	end

	local chapter = self:getChapter()
	self.sceneLabel.Text = string.format("%s  /  %s", chapter and chapter.name or "?", self.scene.name)

	local status, message = ProjectStore.getPersistStatus()
	if self.dirty then
		self.dirtyLabel.Text = "unsaved changes"
		self.dirtyLabel.TextColor3 = Theme.Accent
	else
		self.dirtyLabel.Text = status == "saved" and "saved" or (status == "offline" and "saved (database offline)" or (message or ""))
		self.dirtyLabel.TextColor3 = status == "error" and Theme.Danger or Theme.TextFaint
	end

	self.cursorLabel.Text = SequenceState.describeCursor(self:getSequence(), self.runner:getCursor())

	Widgets.clearChildren(self.sequenceHolder)
	local items = {}
	for _, item in ipairs(Schema.sequencesOf(self.scene)) do
		table.insert(items, {
			id = item.owner .. ":" .. (item.interactionId or item.subsceneId or ""),
			label = item.label .. string.format("  (%d)", #item.sequence.segments),
		})
	end

	Widgets.dropdown(self.gui, {
		Items = items,
		Value = self.openSequence.owner .. ":" .. (self.openSequence.interactionId or self.openSequence.subsceneId or ""),
		Size = UDim2.new(1, 0, 1, 0),
		OnPick = function(id)
			local owner, interactionId = id:match("^(%w+):(.*)$")
			self:openSequenceOwner(owner, interactionId ~= "" and interactionId or nil)
		end,
		Parent = self.sequenceHolder,
	})
end

function EditorApp:refresh()
	if self.mode == "browser" then
		self.browserView:render()
		return
	end

	if self.mode == "flow" then
		self.flowView:render()
		return
	end

	if self.mode ~= "scene" or not self.scene then
		return
	end

	self:_normalizeSelection()

	self.runner:setContext(self:_runnerContext())
	self.runner:refresh()

	self:_refreshTopBar()
	self.timelineView:render()

	local activeSubscene = self:getActiveSubscene()
	local showInteractions = activeSubscene and activeSubscene.kind ~= "Novel2D" and (self.selection.kind == "scene" or self.selection.kind == "interaction")
	self.interactionListView:setVisible(showInteractions)
	self.dialogueListView:setVisible(not showInteractions)

	if showInteractions then
		self.interactionListView:render()
	else
		self.dialogueListView:render()
	end

	self.inspectorView:render()
	self.eventLayerView:render()
	self.previewStateView:render()
	self.gizmos:update()
end

--------------------------------------------------------------------------------
-- Navigation
--------------------------------------------------------------------------------

function EditorApp:showBrowser()
	self:stop()
	self.mode = "browser"
	self.presenter:leaveScene()
	self:_applyMode()
	self:refresh()
end

function EditorApp:openChapter(chapterId)
	self:stop()
	self.chapterId = chapterId
	self.flowView:setChapter(chapterId)
	self.mode = "flow"
	self.presenter:leaveScene()
	self:resetPreviewFlags(true)
	self:_applyMode()
	self:refresh()
end

function EditorApp:openScene(chapterId, sceneId)
	local scene = ProjectStore.checkout(chapterId, sceneId)
	if not scene then
		self:notify("That scene no longer exists.", Theme.Danger)
		return
	end

	self:stop()

	if self.chapterId ~= chapterId then
		self.chapterId = chapterId
		self.flowView:setChapter(chapterId)
		self:resetPreviewFlags(true)
	end

	self.scene = scene
	Schema.ensureSubscenes(scene)
	self.lastSubsceneId = scene.subscenes[1].id
	self.dirty = false
	self.mode = "scene"
	self.selection = { kind = "scene" }
	self.openSequence = { owner = "subscene", subsceneId = scene.subscenes[1].id }
	self.sceneSettingsDefault = true

	self.presenter:enterScene(Schema.subsceneView(scene, scene.subscenes[1]), self:getProject())
	self.runner:setSequence(self:getSequence(), self:_runnerContext(), { silent = true })

	self:_applyMode()
	self:refresh()
	for _, warning in ipairs(Schema.takeWarnings(scene.id)) do self:notify(warning, Theme.Danger) end
end

-- Used by flow-graph links to reveal the exact timeline/on-completion effect
-- that owns a Go To Scene or End Chapter marker.
function EditorApp:openFlowEvent(chapterId, sceneId, link)
	self:openScene(chapterId, sceneId)
	if not self.scene or self.scene.id ~= sceneId then
		return
	end

	self:openSequenceOwner(link.owner or "subscene", link.interactionId or link.subsceneId)

	local anchor = link.anchor or {}
	local selection = {
		kind = "event",
		eventId = link.eventId,
		segmentIndex = anchor.segmentIndex,
		entryIndex = anchor.entryIndex,
	}
	-- interactionId marks the separate onComplete event list. Events inside an
	-- interaction sequence use that sequence's normal segment/entry anchor.
	if anchor.kind == "Complete" then
		selection.interactionId = link.interactionId
	end
	local cursor = {
		segmentIndex = anchor.segmentIndex or 1,
		entryIndex = anchor.entryIndex or 1,
		time = anchor.kind == "Timed" and (link.eventTime or 0) or 0,
	}

	self:jumpTo(cursor, selection)
end

function EditorApp:openInteraction(chapterId, sceneId, interactionId)
	self:openScene(chapterId, sceneId)
	if self.scene and self.scene.id == sceneId then
		self:setSelection({ kind = "interaction", interactionId = interactionId })
	end
end

function EditorApp:closeScene()
	if not self.scene then
		self:showBrowser()
		return
	end

	if self.dirty then
		self:showConfirm("Unsaved changes", "Save this scene before going back to the flow?", function()
			self:save()
			self:_exitToFlow()
		end, {
			{ text = "Discard", color = Theme.Danger, onClick = function()
				self:_exitToFlow()
			end },
		})
		return
	end

	self:_exitToFlow()
end

function EditorApp:_exitToFlow()
	self:stop()
	self.scene = nil
	self.dirty = false
	self.selection = { kind = "scene" }
	self.mode = "flow"
	self.presenter:leaveScene()
	self:_applyMode()
	self:refresh()
end

function EditorApp:save()
	if self.scene and self.chapterId then
		ProjectStore.commit(self.chapterId, self.scene)
		self.dirty = false
	end

	self:saveNow()
end

function EditorApp:saveNow()
	if not ProjectStore.isPersistEnabled() then
		local _, message = ProjectStore.getPersistStatus()
		self:notify("Saved in this session only. " .. (message or ""), Theme.Danger)
		self:refresh()
		return
	end

	task.spawn(function()
		local ok, err = ProjectStore.flush()
		if ok then
			self:notify("Saved to your database.", Theme.Good)
		else
			self:notify("Database save failed: " .. tostring(err), Theme.Danger)
		end
		self:refresh()
	end)
end

function EditorApp:markDirty()
	if self.scene then
		for _, warning in ipairs(Schema.reconcileSubscenes(self.scene)) do
			self:notify(warning, Theme.Danger)
		end
		Schema.takeWarnings(self.scene.id)
	end
	self.dirty = true
	self:refresh()
end

--------------------------------------------------------------------------------
-- Project accessors and pickers
--------------------------------------------------------------------------------

function EditorApp:getProject()
	return ProjectStore.getProject()
end

function EditorApp:getChapter()
	return ProjectStore.getChapter(self.chapterId)
end

function EditorApp:pickerItems(kind, excludeId)
	local project = self:getProject()
	local items = {}

	if kind == "scene" then
		local chapter = self:getChapter()
		for _, scene in ipairs(chapter and chapter.scenes or {}) do
			if scene.id ~= excludeId then
				table.insert(items, { id = scene.id, label = scene.name })
			end
		end
	elseif kind == "subscene" then
		for _, subscene in ipairs(self.scene and self.scene.subscenes or {}) do
			table.insert(items, { id = subscene.id, label = subscene.name .. " · " .. subscene.kind })
		end
	elseif kind == "flag" then
		local chapter = self:getChapter()
		for _, flag in ipairs(self.scene and self.scene.flags or {}) do
			table.insert(items, {
				id = Schema.sceneFlagRef(flag.id),
				label = "Scene  .  " .. flag.id .. " (" .. flag.kind .. ")",
			})
		end
		for _, flag in ipairs(chapter and chapter.flags or {}) do
			table.insert(items, { id = flag.id, label = "Chapter  .  " .. flag.id .. " (" .. flag.kind .. ")" })
		end
	elseif kind == "pose" then
		for _, pose in ipairs(project.cameraPoses) do
			table.insert(items, { id = pose.id, label = pose.name })
		end
	elseif kind == "transition" then
		for _, preset in ipairs(project.transitionPresets) do
			table.insert(items, { id = preset.id, label = preset.name })
		end
	elseif kind == "textbox" then
		for _, preset in ipairs(project.textboxPresets) do
			table.insert(items, { id = preset.id, label = preset.name })
		end
	elseif kind == "character" then
		for _, record in ipairs(project.characters) do
			table.insert(items, { id = record.name, label = record.name })
		end
	end

	return items
end

function EditorApp:resolvePicker(kind, id)
	if id == nil or id == "" then
		return nil
	end

	for _, item in ipairs(self:pickerItems(kind)) do
		if item.id == id then
			return item.label
		end
	end

	return nil
end

--------------------------------------------------------------------------------
-- Sequences and selection
--------------------------------------------------------------------------------

function EditorApp:getSequence()
	if not self.scene then
		return { segments = {} }
	end

	local sequence = Schema.getSequence(self.scene, self.openSequence.owner, self.openSequence.interactionId or self.openSequence.subsceneId)
	if not sequence then
		self.openSequence = { owner = "subscene", subsceneId = self.scene.subscenes[1].id }
		sequence = self.scene.subscenes[1].sequence
	end

	return sequence
end

function EditorApp:getSequenceLabel()
	if self.openSequence.owner == "subscene" then
		local subscene = self:getActiveSubscene()
		return subscene and subscene.name or "Subscene"
	end
	if self.openSequence.owner == "interaction" then
		local interaction = Schema.findInteraction(self.scene, self.openSequence.interactionId)
		return interaction and interaction.name or "Interaction"
	end
	return self.openSequence.owner == "outro" and "Outro" or "Intro"
end

function EditorApp:getActiveSubscene()
	if not self.scene then return nil end
	if self.openSequence.owner == "subscene" then
		return Schema.subsceneIndex(self.scene, self.openSequence.subsceneId) or self.scene.subscenes[1]
	end
	local interaction = Schema.findInteraction(self.scene, self.openSequence.interactionId)
	return (interaction and Schema.subsceneIndex(self.scene, interaction.subsceneId))
		or Schema.subsceneIndex(self.scene, self.lastSubsceneId) or self.scene.subscenes[1]
end

function EditorApp:openSequenceOwner(owner, interactionId)
	if self.openSequence.owner == "subscene" then self.lastSubsceneId = self.openSequence.subsceneId end
	self.openSequence = owner == "subscene"
		and { owner = owner, subsceneId = interactionId }
		or { owner = owner, interactionId = interactionId }
	self.sceneSettingsDefault = false

	local sequence = self:getSequence()
	local subscene = self:getActiveSubscene()
	if subscene then self.presenter:enterScene(Schema.subsceneView(self.scene, subscene), self:getProject()) end
	local first = sequence.segments[1]
	self.selection = first and { kind = "segment", segmentIndex = 1 } or { kind = "scene" }

	self.runner:setSequence(sequence, self:_runnerContext(), { silent = true })
	self:refresh()
end

function EditorApp:addSubscene()
	local current = self:getActiveSubscene()
	local subscene = Schema.newSubscene("Subscene " .. (#self.scene.subscenes + 1), current and current.kind or "Novel2D")
	local index = nil
	if current then
		local found
		found, index = Schema.subsceneIndex(self.scene, current.id)
	end
	local insertionIndex = (index or #self.scene.subscenes) + 1
	if current and current.role == "outro" and index == #self.scene.subscenes then
		-- Preserve the familiar Intro … Outro ordering when adding from the
		-- default last entry; authors can still move either role afterward.
		insertionIndex = index
	end
	local predecessor = self.scene.subscenes[insertionIndex - 1]
	if predecessor and predecessor.nextTransitionId == "" then
		predecessor.nextTransitionId = Schema.DEFAULT_FADE
	end
	table.insert(self.scene.subscenes, insertionIndex, subscene)
	self:openSequenceOwner("subscene", subscene.id)
	self:markDirty()
end

function EditorApp:moveSubscene(subsceneId, offset)
	local subscene, index = Schema.subsceneIndex(self.scene, subsceneId)
	local target = index and index + offset
	if not target or target < 1 or target > #self.scene.subscenes then return end
	table.remove(self.scene.subscenes, index)
	table.insert(self.scene.subscenes, target, subscene)
	self:markDirty()
end

function EditorApp:deleteSubscene(subsceneId)
	local subscene, index = Schema.subsceneIndex(self.scene, subsceneId)
	if not subscene or type(index) ~= "number" or #self.scene.subscenes <= 1 or subscene.role ~= "custom" then return end
	local wasActive = self:getActiveSubscene().id == subsceneId
	-- Keep the replacement record before mutating the ordered list. This avoids
	-- depending on the removed item's former numeric index after deletion.
	local replacement = self.scene.subscenes[index + 1] or self.scene.subscenes[index - 1]
	table.remove(self.scene.subscenes, index)
	Schema.clearSubsceneDestinations(self.scene, subsceneId)
	if wasActive or (self.openSequence.owner == "interaction"
		and not Schema.findInteraction(self.scene, self.openSequence.interactionId)) then
		if replacement then
			self:openSequenceOwner("subscene", replacement.id)
		end
	end
	self:markDirty()
end

function EditorApp:_runnerContext()
	local cursor = self.runner:getCursor()
	return {
		scene = self:getActiveSubscene() and Schema.subsceneView(self.scene, self:getActiveSubscene()) or self.scene,
		chapter = self:getChapter(),
		project = self:getProject(),
		editor = true,
		scrubbing = cursor ~= nil and (cursor.entryTime or 0) > 0,
		getFlags = function()
			return self:getPreviewFlags()
		end,
	}
end

function EditorApp:getCursor()
	return self.runner:getCursor() or {}
end

function EditorApp:getLocalTime()
	return SequenceState.localTime(self.runner:getCursor())
end

function EditorApp:jumpTo(cursor, selection)
	if selection then
		self.selection = selection
		self.sceneSettingsDefault = selection.kind == "scene"
	end

	self.runner:pause()
	self.runner:setCursor(cursor, { fire = false, silent = true })
	self:refresh()
end

function EditorApp:setSelection(selection)
	self.selection = selection
	self.sceneSettingsDefault = selection.kind == "scene"
	self:refresh()
end

function EditorApp:isSceneFlagsInspectorActive()
	return self.scene ~= nil and self.selection.kind == "scene" and self.sceneSettingsDefault == true
end

function EditorApp:getSelectedSegment()
	if not self.scene or not self.selection.segmentIndex then
		return nil
	end

	return self:getSequence().segments[self.selection.segmentIndex]
end

function EditorApp:getSelectedEntry()
	local segment = self:getSelectedSegment()

	if not segment or segment.kind ~= "Dialogue" or not self.selection.entryIndex then
		return nil
	end

	return segment.entries[self.selection.entryIndex]
end

-- Returns events, anchorKind ("Timed" | "Dialogue" | "Complete"), anchorName.
function EditorApp:getAnchor()
	if self.selection.kind == "interaction" then
		local interaction = Schema.findInteraction(self.scene, self.selection.interactionId)
		if interaction then
			return interaction.onComplete, "Complete", interaction.name
		end
		return nil
	end

	if self.selection.kind == "event" and self.selection.interactionId then
		local interaction = Schema.findInteraction(self.scene, self.selection.interactionId)
		if interaction then
			return interaction.onComplete, "Complete", interaction.name
		end
	end

	local segment = self:getSelectedSegment()
	if not segment then
		return nil
	end

	if segment.kind == "Timed" then
		return segment.events, "Timed", string.format("timed section %d", self.selection.segmentIndex)
	end

	local entry = self:getSelectedEntry()
	if entry then
		return entry.events, "Dialogue", string.format("line %d", self.selection.entryIndex)
	end

	return nil
end

function EditorApp:_normalizeSelection()
	local selection = self.selection
	local sequence = self:getSequence()

	if selection.kind == "scene" then
		return
	end

	if selection.kind == "interaction" then
		if not Schema.findInteraction(self.scene, selection.interactionId) then
			self.selection = { kind = "scene" }
			self.sceneSettingsDefault = true
		end
		return
	end

	if selection.kind == "event" and selection.interactionId then
		local interaction = Schema.findInteraction(self.scene, selection.interactionId)
		if not interaction or not Schema.findById(interaction.onComplete, selection.eventId) then
			self.selection = interaction and { kind = "interaction", interactionId = interaction.id } or { kind = "scene" }
			if not interaction then
				self.sceneSettingsDefault = true
			end
		end
		return
	end

	if not selection.segmentIndex or not sequence.segments[selection.segmentIndex] then
		local cursor = self.runner:getCursor()
		if cursor and sequence.segments[cursor.segmentIndex] then
			self.selection = { kind = "segment", segmentIndex = cursor.segmentIndex }
		else
			self.selection = { kind = "scene" }
			self.sceneSettingsDefault = true
		end
		return
	end

	local segment = sequence.segments[selection.segmentIndex]

	if selection.entryIndex and (segment.kind ~= "Dialogue" or not segment.entries[selection.entryIndex]) then
		self.selection = { kind = "segment", segmentIndex = selection.segmentIndex }
		return
	end

	if selection.kind == "event" then
		local events = self:getAnchor()
		if not events or not Schema.findById(events, selection.eventId) then
			self.selection = {
				kind = selection.entryIndex and "entry" or "segment",
				segmentIndex = selection.segmentIndex,
				entryIndex = selection.entryIndex,
			}
		end
	elseif selection.kind == "key" then
		local owner = self:getSelectedEntry() or segment
		local track = owner and Schema.findById(owner.tracks or {}, selection.trackId)
		if not track or not track.keys[selection.keyIndex] then
			self.selection = {
				kind = selection.entryIndex and "entry" or "segment",
				segmentIndex = selection.segmentIndex,
				entryIndex = selection.entryIndex,
			}
		end
	end
end

--------------------------------------------------------------------------------
-- Keyframes and scrubbing
--------------------------------------------------------------------------------

function EditorApp:selectKey(trackId, keyIndex, t)
	self.selection = {
		kind = "key",
		segmentIndex = self.selection.segmentIndex,
		entryIndex = self.selection.entryIndex,
		trackId = trackId,
		keyIndex = keyIndex,
	}

	local cursor = table.clone(self.runner:getCursor() or {})
	cursor.segmentIndex = self.selection.segmentIndex
	if self.selection.entryIndex then
		cursor.entryIndex = self.selection.entryIndex
		cursor.entryTime = t
		cursor.time = nil
	else
		cursor.time = t
		cursor.entryIndex = nil
		cursor.entryTime = nil
	end

	self:jumpTo(cursor)
end

function EditorApp:scrubEntryTime(value)
	local cursor = self.runner:getCursor()
	if not cursor or not cursor.entryIndex then
		return
	end

	cursor.entryTime = value
	self.runner:setContext(self:_runnerContext())
	self.runner.context.scrubbing = true
	self.runner:setCursor(cursor, { silent = true })
	self.cursorLabel.Text = SequenceState.describeCursor(self:getSequence(), cursor)
	self.gizmos:update()
end

function EditorApp:previewKeyDrag()
	self.dirty = true
	self.runner:refresh()
	self.gizmos:update()
end

--------------------------------------------------------------------------------
-- Preview flags
--------------------------------------------------------------------------------

-- Chapter defaults remain live until the user explicitly changes a value in
-- the editor-only preview panel. This avoids an old default silently surviving
-- after the flag definition is edited.
function EditorApp:_reconcilePreviewFlags()
	local chapter = self:getChapter()
	if not chapter then
		self.previewFlags = {}
		self.previewFlagOverrides = {}
		return
	end

	local defaults = Schema.defaultFlags(chapter)
	local nextFlags = {}
	local nextOverrides = {}

	for _, flag in ipairs(chapter.flags) do
		if self.previewFlagOverrides[flag.id] and self.previewFlags[flag.id] ~= nil then
			nextFlags[flag.id] = Schema.coerceFlagValue(flag, self.previewFlags[flag.id])
			nextOverrides[flag.id] = true
		else
			nextFlags[flag.id] = defaults[flag.id]
		end
	end

	self.previewFlags = nextFlags
	self.previewFlagOverrides = nextOverrides
end

function EditorApp:getPreviewFlags()
	self:_reconcilePreviewFlags()
	return Schema.normalizeRuntimeFlagState(self:getChapter(), self.scene, self.previewFlags, nil)
end

function EditorApp:setPreviewFlag(flagId, value)
	local chapter = self:getChapter()
	local definition = chapter and Schema.findFlag(chapter, flagId)
	if not definition then
		return
	end

	self.previewFlags[flagId] = Schema.coerceFlagValue(definition, value)
	self.previewFlagOverrides[flagId] = true
	self:refresh()
end

function EditorApp:resetPreviewFlags(silent)
	self.previewFlags = Schema.defaultFlags(self:getChapter())
	self.previewFlagOverrides = {}
	if not silent then
		self:refresh()
	end
end

function EditorApp:togglePreviewState(visible)
	if visible == nil then
		visible = not self.previewStateOpen
	end
	self.previewStateOpen = visible
	self:_applyMode()
	if visible then
		self.previewStateView:render()
	end
end

--------------------------------------------------------------------------------
-- Stage, camera and world tools
--------------------------------------------------------------------------------

function EditorApp:onSceneStageChanged()
	if self.scene then
		local subscene = self:getActiveSubscene()
		self.presenter:enterScene(Schema.subsceneView(self.scene, subscene), self:getProject())
	end
end

function EditorApp:captureCamera(callback, startCFrame)
	if not startCFrame and self.scene then
		local subscene = self:getActiveSubscene()
		local pose = Schema.findCameraPose(self:getProject(), Schema.effectivePoseId(self.scene, subscene))
		startCFrame = pose and Schema.decodeCFrame(pose.cframe) or nil
	end

	self.capturing = true
	self:_applyMode()
	self.presenter:getStage():setVisible(false)

	self.flyCam:start(function(cframeText)
		callback(cframeText)
	end, startCFrame)
end

function EditorApp:onCameraCaptureEnded()
	self.capturing = false
	self:_applyMode()

	if self.mode == "scene" and self.scene then
		self.presenter:enterScene(Schema.subsceneView(self.scene, self:getActiveSubscene()), self:getProject())
	elseif self.mode ~= "play" then
		self.presenter:getRig():release()
	end

	self:refresh()
end

function EditorApp:previewPose(pose)
	self.presenter:getRig():setPose(pose)
	self:notify("Camera is looking through '" .. pose.name .. "'. It goes back to normal when you open a scene or play.", Theme.TextDim)
end

function EditorApp:pickTarget(callback)
	self.worldPicker:start(function(targetId)
		callback(targetId)
	end)
end

--------------------------------------------------------------------------------
-- Playback
--------------------------------------------------------------------------------

function EditorApp:playSequence(fromStart)
	if not self.scene then
		return
	end

	if self.runner:isEmpty() then
		self:notify("This sequence has no blocks to play.", Theme.Danger)
		return
	end

	self.runner:setContext(self:_runnerContext())
	self.runner.context.scrubbing = false
	self.runner:play(fromStart)
end

function EditorApp:playChapter(chapterId, sceneId)
	local chapter = ProjectStore.getChapter(chapterId)
	if not chapter then
		return
	end

	if self.mode == "scene" and self.scene and self.dirty then
		ProjectStore.commit(self.chapterId, self.scene)
		self.dirty = false
	end

	self.runner:stop()
	self.returnMode = self.mode
	self.mode = "play"
	self:_applyMode()
	self.playLabel.Text = "Playing  .  " .. chapter.name

	-- A chapter playtest is a new playthrough. Never seed it from the editor's
	-- condition-preview overrides or from the Director's previous run: both can
	-- legitimately differ from the defaults saved in the Chapter Flags panel.
	local startingFlags = Schema.defaultFlags(chapter)
	self.runtimeFlags = Schema.deepCopy(startingFlags)
	self.director:setProject(self:getProject())
	self.director:setChapter(chapter, startingFlags)

	local ok, err = self.director:start(sceneId)
	if not ok then
		self:notify(err or "Could not start the chapter.", Theme.Danger)
		self:stop()
	end
end

function EditorApp:stop()
	local wasPlaying = self.mode == "play"

	if self.director:isActive() or wasPlaying then
		self.director:stop()
	end

	self.runner:stop()
	self.playing = false
	-- Runtime flag changes belong only to the playthrough that just ended. The
	-- next playChapter call constructs another state from chapter defaults.
	self.runtimeFlags = {}

	if wasPlaying then
		self.mode = self.returnMode or "browser"
		self.returnMode = nil

		if self.mode == "scene" and self.scene then
			self.presenter:enterScene(Schema.subsceneView(self.scene, self:getActiveSubscene()), self:getProject())
			self.runner:setSequence(self:getSequence(), self:_runnerContext(), { silent = true, cursor = self.runner:getCursor() })
		else
			self.presenter:leaveScene()
		end
	elseif self.mode == "scene" and self.scene then
		self.presenter:getStage():clearForeground()
	end

	self:_applyMode()
	self:refresh()
end

--------------------------------------------------------------------------------
-- Toast and modals
--------------------------------------------------------------------------------

function EditorApp:notify(text, color)
	self.toast.Text = text
	self.toast.TextColor3 = color or Theme.Text
	self.toast.Visible = true

	self._toastToken = (self._toastToken or 0) + 1
	local token = self._toastToken

	task.delay(4, function()
		if self._toastToken == token then
			self.toast.Visible = false
		end
	end)
end

function EditorApp:closeModal()
	if self.modal then
		self.modal:Destroy()
		self.modal = nil
	end
end

function EditorApp:_openModal(title, hint, width, height)
	self:closeModal()

	local overlay = Widgets.create("Frame", {
		Name = "Modal",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Color3.new(0, 0, 0),
		BackgroundTransparency = 0.4,
		BorderSizePixel = 0,
		ZIndex = 80,
		Parent = self.gui,
	})

	self.modal = overlay

	local panel = Widgets.panel({
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(width, 0, height, 0),
		BackgroundColor3 = Theme.Panel,
		ZIndex = 81,
		Parent = overlay,
	}, {
		Widgets.padding(18),
		Widgets.stroke(Theme.Border, 1, 0.15),
	})

	Widgets.label({
		Text = title,
		Size = UDim2.new(1, 0, 0, 22),
		Font = Theme.FontBold,
		TextSize = 16,
		ZIndex = 82,
		Parent = panel,
	})

	local hintHeight = 0

	if hint and hint ~= "" then
		hintHeight = 34

		Widgets.label({
			Text = hint,
			Position = UDim2.new(0, 0, 0, 26),
			Size = UDim2.new(1, 0, 0, hintHeight),
			TextColor3 = Theme.TextDim,
			TextSize = 12,
			TextWrapped = true,
			TextTruncate = Enum.TextTruncate.None,
			TextYAlignment = Enum.TextYAlignment.Top,
			ZIndex = 82,
			Parent = panel,
		})
	end

	local bodyTop = 28 + hintHeight

	local body = Widgets.create("Frame", {
		Name = "Body",
		Position = UDim2.new(0, 0, 0, bodyTop),
		Size = UDim2.new(1, 0, 1, -(bodyTop + 50)),
		BackgroundTransparency = 1,
		ZIndex = 82,
		Parent = panel,
	})

	local buttonRow = Widgets.create("Frame", {
		Name = "Buttons",
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, 0, 1, 0),
		Size = UDim2.new(0, 0, 0, 34),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundTransparency = 1,
		ZIndex = 82,
		Parent = panel,
	}, { Widgets.hlist(8) })

	return body, buttonRow
end

function EditorApp:_addModalButtons(buttonRow, actions, closeText, getText)
	for index, action in ipairs(actions or {}) do
		Widgets.button({
			Text = action.Text,
			Size = UDim2.new(0, action.Width or 150, 1, 0),
			Color = action.Color or Theme.Button,
			ZIndex = 83,
			LayoutOrder = index,
			OnClick = function()
				action.Handler(getText and getText() or nil)
			end,
			Parent = buttonRow,
		})
	end

	Widgets.button({
		Text = closeText or "Close",
		Size = UDim2.new(0, 100, 1, 0),
		ZIndex = 83,
		LayoutOrder = 100,
		OnClick = function()
			self:closeModal()
		end,
		Parent = buttonRow,
	})
end

-- showConfirm(title, body, onConfirm, extraButtons?)
-- extraButtons = { { text, color, onClick }, ... }
function EditorApp:showConfirm(title, body, onConfirm, extraButtons)
	local content, buttonRow = self:_openModal(title, nil, 0.4, 0.26)

	Widgets.label({
		Text = body or "",
		Size = UDim2.fromScale(1, 1),
		TextWrapped = true,
		TextTruncate = Enum.TextTruncate.None,
		TextYAlignment = Enum.TextYAlignment.Top,
		TextColor3 = Theme.TextDim,
		ZIndex = 83,
		Parent = content,
	})

	local actions = {
		{
			Text = "Yes",
			Color = Theme.Accent,
			Width = 110,
			Handler = function()
				self:closeModal()
				onConfirm()
			end,
		},
	}

	for _, extra in ipairs(extraButtons or {}) do
		table.insert(actions, {
			Text = extra.text,
			Color = extra.color,
			Width = 110,
			Handler = function()
				self:closeModal()
				extra.onClick()
			end,
		})
	end

	self:_addModalButtons(buttonRow, actions, "Cancel")
end

function EditorApp:showJsonModal(title, hint, bodyText, placeholder, actions)
	local body, buttonRow = self:_openModal(title, hint, 0.74, 0.8)

	local scroll = Widgets.scroll({
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Theme.Input,
		BackgroundTransparency = 0,
		ZIndex = 83,
		Parent = body,
	}, { Widgets.corner(6), Widgets.padding(8) })

	local box = Widgets.textBox({
		Size = UDim2.new(1, -12, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		MultiLine = true,
		TextWrapped = true,
		ClearTextOnFocus = false,
		Font = Theme.FontMono,
		TextSize = 12,
		Text = bodyText or "",
		PlaceholderText = placeholder or "",
		Flat = true,
		ZIndex = 84,
		Parent = scroll,
	})

	self:_addModalButtons(buttonRow, actions, "Close", function()
		return box.Text
	end)

	return box
end

--------------------------------------------------------------------------------
-- JSON export, import, publish
--------------------------------------------------------------------------------

function EditorApp:exportProject()
	local project = self:getProject()
	local text, err = JSONCodec.encodeProject(project)

	if not text then
		self:notify(err, Theme.Danger)
		return
	end

	self:showJsonModal(
		"Export project as JSON",
		"Content only, no scripts or UI. Click inside the box, press Ctrl+A then Ctrl+C, and paste it into a .json file to keep a backup. "
			.. #project.chapters
			.. " chapter(s) exported.",
		text
	)
end

function EditorApp:exportChapter(chapterId)
	local chapter = ProjectStore.getChapter(chapterId)
	if not chapter then
		return
	end

	local text, err = JSONCodec.encodeChapter(self:getProject(), chapter)
	if not text then
		self:notify(err, Theme.Danger)
		return
	end

	self:showJsonModal("Export '" .. chapter.name .. "' as JSON", "One chapter with the presets it uses. Import it into another project with Import JSON > Add.", text)
end

function EditorApp:exportScene()
	if not self.scene then
		return
	end

	local project = self:getProject()
	local chapter = self:getChapter()
	local wrapper = Schema.deepCopy(chapter)
	wrapper.scenes = { Schema.deepCopy(self.scene) }
	wrapper.startSceneId = self.scene.id

	local text, err = JSONCodec.encodeChapter(project, wrapper)
	if not text then
		self:notify(err, Theme.Danger)
		return
	end

	self:showJsonModal("Export '" .. self.scene.name .. "' as JSON", "The scene as it sits in the editor, including unsaved edits, wrapped in a one scene chapter.", text)
end

function EditorApp:showImport()
	local function runImport(text, replace)
		local project, err, skipped = JSONCodec.decodeProject(text)

		if not project then
			self:notify(err, Theme.Danger)
			return
		end

		if replace then
			ProjectStore.replaceProject(project)
		else
			ProjectStore.mergeProject(project)
		end

		self:closeModal()

		local message = string.format("%s %d chapter(s).", replace and "Replaced the project with" or "Added", #project.chapters)
		if skipped and skipped > 0 then
			message = message .. string.format(" %d unreadable chapter(s) were skipped.", skipped)
		end

		self:notify(message, Theme.Good)
		self:refresh()
	end

	self:showJsonModal(
		"Import from JSON",
		"Paste JSON exported earlier (old single scene exports are upgraded automatically). Replace swaps the whole project; Add appends the chapters.",
		"",
		"Paste exported JSON here...",
		{
			{
				Text = "Replace Project",
				Color = Theme.Danger,
				Handler = function(text)
					runImport(text, true)
				end,
			},
			{
				Text = "Add Chapters",
				Color = Theme.Good,
				Handler = function(text)
					runImport(text, false)
				end,
			},
		}
	)
end

function EditorApp:publishChapter(chapterId)
	local chapter = ProjectStore.getChapter(chapterId)
	if not chapter then
		return
	end

	self:notify("Publishing '" .. chapter.name .. "'...", Theme.TextDim)

	task.spawn(function()
		local ok, err = ProjectStore.publishChapter(chapterId)
		if ok then
			self:notify("Published. The game can load it with ChapterRuntime.playPublished(\"" .. chapter.id .. "\").", Theme.Good)
		else
			self:notify("Publish failed: " .. tostring(err), Theme.Danger)
		end
	end)
end

--------------------------------------------------------------------------------
-- Show and hide
--------------------------------------------------------------------------------

function EditorApp:open()
	self.gui.Enabled = true
	self.hintGui.Enabled = false
	self:_applyMode()
	self:refresh()
end

function EditorApp:close()
	self:stop()
	self.flyCam:stop()
	self.worldPicker:stop()
	self.gui.Enabled = false
	self.hintGui.Enabled = true
	self.presenter:leaveScene()
end

function EditorApp:toggle()
	if self.gui.Enabled then
		self:close()
	else
		self:open()
	end
end

return EditorApp
