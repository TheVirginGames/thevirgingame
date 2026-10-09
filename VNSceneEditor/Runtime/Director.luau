-- Walks a chapter: enters scenes, plays intros, waits for interactions in 3D
-- scenes, runs exits and transitions, and keeps the flag table.
--
-- Phases: Idle, Transition, PlayIntro, Await, PlayInteraction,
-- PlayRoomExit, PlayOutro, Ended
--
-- The editor and the shipped game both use this class. Callers hand each new
-- playthrough its own flag table, and may explicitly restore a saved one.

local Signal = require(script.Parent.Parent.Core.Signal)
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Schema = require(script.Parent.Parent.Core.Schema)
local Conditions = require(script.Parent.Conditions)
local SequenceRunner = require(script.Parent.SequenceRunner)
local SequenceState = require(script.Parent.SequenceState)
local WorldBindings = require(script.Parent.Parent.Render.WorldBindings)

local Director = {}
Director.__index = Director

function Director.new(presenter, project)
	local self = setmetatable({}, Director)

	self.presenter = presenter
	self.project = project
	self.chapter = nil
	self.scene = nil
	self.subscene = nil
	self.phase = "Idle"
	self.flags = {}
	self.initialChapterFlags = {}
	self.consumedResponses = {} -- interactionId -> responseId -> true
	self.sceneFlagStates = {} -- sceneId -> scene-local flag state for this run
	self.generation = 0
	self.delayedEventGeneration = 0
	self.active = false
	self.currentInteraction = nil
	-- Stack frames preserve a parent timeline while an Interaction segment runs
	-- its own snapshot response sequence. A response may itself contain another
	-- Interaction block, so this is intentionally a stack rather than one slot.
	self.timelineInteractionStack = {}
	self.entryAttributions = {} -- sceneId:roomId -> most recent Enter source
	self.hiddenCharacterModels = {} -- placementId -> true, scoped to this chapter run
	-- A Merge reached from inside a Zooming Hotspot response continues into the
	-- linked Room3D before its normal Zoom-out can run.
	self.deferredInteractionExit = nil
	self.pendingFinish = nil -- callback for the runner's next Finished
	self.roomExitExitable = false
	self.roomExitSequence = nil

	self.runner = SequenceRunner.new(presenter)

	self.SceneChanged = Signal.new() -- (scene)
	self.SubsceneChanged = Signal.new() -- (subscene)
	self.PhaseChanged = Signal.new() -- (phase)
	self.FlagsChanged = Signal.new() -- (flags, changedIds | nil)
	self.Finished = Signal.new() -- (reason)

	self.runner.Finished:Connect(function()
		self:_onRunnerFinished()
	end)

	self.runner.EventsFired:Connect(function(events, eventContext)
		self:_onEvents(events, eventContext and eventContext.interaction)
	end)
	self.runner.BlockEntered:Connect(function(segment, cursor, sequence)
		self:_onTimelineInteractionBlock(segment, cursor, sequence)
	end)
	self.runner.CursorChanged:Connect(function(cursor)
		self:_updateRoomExitChoices(cursor)
	end)

	self.interactionConnection = presenter.InteractionRequested:Connect(function(interactionId)
		self:tryInteraction(interactionId)
	end)

	return self
end

--------------------------------------------------------------------------------
-- Setup and state
--------------------------------------------------------------------------------

function Director:setProject(project)
	self.project = project
end

function Director:setChapter(chapter, flags)
	self.presenter:forgetInteractionTransition(self.currentInteraction)
	self.presenter:forgetInteractionTransition(self.deferredInteractionExit)
	self.deferredInteractionExit = nil
	self.chapter = chapter
	self.scene = nil
	self.subscene = nil
	self.currentInteraction = nil
	self:_clearTimelineInteractionStack()
	self.entryAttributions = {}
	self.hiddenCharacterModels = {}
	self.presenter:setHiddenCharacterModels(self.hiddenCharacterModels)
	self.initialChapterFlags = Schema.normalizeFlagState(chapter, flags)
	self.flags = Schema.deepCopy(self.initialChapterFlags)
	self.consumedResponses = {}
	self.sceneFlagStates = {}
	self.FlagsChanged:Fire(self.flags, {})
end

function Director:getFlags()
	return self.flags
end

-- Scene flags belong to the scene node, and retain their live values for the
-- duration of this Director run. The public flag table always contains the
-- chapter values plus the active scene's local values.
function Director:_storeActiveSceneFlags()
	if not self.scene then return end
	local state = {}
	for _, flag in ipairs(self.scene.flags or {}) do
		local flagRef = Schema.sceneFlagRef(flag.id)
		if self.flags[flagRef] ~= nil then
			state[flagRef] = self.flags[flagRef]
		end
	end
	self.sceneFlagStates[self.scene.id] = state
end

function Director:setFlags(flags)
	self.flags = Schema.normalizeRuntimeFlagState(self.chapter, self.scene, flags, flags)
	self:_storeActiveSceneFlags()
	self.FlagsChanged:Fire(self.flags, nil)
	self:_refreshInteractables()
end

function Director:setFlag(flagId, value)
	local definition, scope = Schema.resolveFlag(self.chapter, self.scene, flagId)
	if not definition then
		return false
	end

	local nextValue = Schema.coerceFlagValue(definition, value)
	if self.flags[flagId] == nextValue and type(self.flags[flagId]) == type(nextValue) then
		return false
	end

	self.flags[flagId] = nextValue
	if scope == "scene" and self.scene then
		local state = self.sceneFlagStates[self.scene.id] or {}
		state[flagId] = nextValue
		self.sceneFlagStates[self.scene.id] = state
	end
	self.FlagsChanged:Fire(self.flags, { [flagId] = true })
	self:_refreshInteractables()
	return true
end

function Director:getPhase()
	return self.phase
end

function Director:getScene()
	return self.scene
end

function Director:getSubscene()
	return self.subscene
end

function Director:getRunner()
	return self.runner
end

function Director:isActive()
	return self.active
end

function Director:_setPhase(phase)
	-- Presenter owns the concrete movement/camera policy. Re-apply even when the
	-- phase string is unchanged because the active subscene may have changed.
	self.presenter:setRuntimePhase(phase)
	if self.phase ~= phase then
		self.phase = phase
		self.PhaseChanged:Fire(phase)
	end
end

function Director:serialize()
	return {
		chapterId = self.chapter and self.chapter.id or "",
		sceneId = self.scene and self.scene.id or "",
		phase = self.phase,
		assemblyTime = self.presenter.assemblySession and self.presenter.assemblySession.time or nil,
		subsceneId = self.subscene and self.subscene.id or "",
		flags = Schema.deepCopy(self.flags),
		consumedResponses = Schema.deepCopy(self.consumedResponses),
		sceneFlagStates = Schema.deepCopy(self.sceneFlagStates),
		entryAttributions = Schema.deepCopy(self.entryAttributions),
		hiddenCharacterModels = Schema.deepCopy(self.hiddenCharacterModels),
	}
end

-- Resume a saved game. Awaiting scenes come back at their idle state, others
-- restart their intro.
function Director:restore(state)
	local chapter = Schema.findChapter(self.project, state.chapterId)
	if not chapter then
		return false, "Chapter not found."
	end

	self:setChapter(chapter, state.flags)
	self.consumedResponses = type(state.consumedResponses) == "table" and state.consumedResponses or {}
	self.sceneFlagStates = type(state.sceneFlagStates) == "table" and state.sceneFlagStates or {}
	self.entryAttributions = type(state.entryAttributions) == "table" and state.entryAttributions or {}
	self.hiddenCharacterModels = type(state.hiddenCharacterModels) == "table" and state.hiddenCharacterModels or {}
	self.presenter:setHiddenCharacterModels(self.hiddenCharacterModels)

	local scene = Schema.findScene(chapter, state.sceneId)
	if not scene then
		return self:start()
	end

	self.active = true
	self.generation += 1

	-- Older saved states only carried the active scene's local flags. Preserve
	-- those on restore even though new saves retain every visited scene.
	if self.sceneFlagStates[scene.id] == nil then
		self.sceneFlagStates[scene.id] = Schema.deepCopy(state.flags or {})
	end

	if state.phase == "Await" then
		self:_enterScene(scene.id, nil, { skipIntro = true, skipAssembly = true, sceneFlags = state.flags, subsceneId = state.subsceneId, preserveAttribution = true })
	else
		self:_enterScene(scene.id, nil, { assemblyTime = state.assemblyTime, sceneFlags = state.flags, subsceneId = state.subsceneId, preserveAttribution = true })
	end

	return true
end

--------------------------------------------------------------------------------
-- Flow
--------------------------------------------------------------------------------

-- options.subsceneId starts a playthrough at that ordered subscene instead of
-- always replaying the scene's first one. This is used by editor play-here and
-- sequence previews; ordinary chapter runtime still omits the option.
function Director:start(sceneId, options)
	options = options or {}
	if not self.chapter then
		return false, "No chapter loaded."
	end

	local startId = sceneId or self.chapter.startSceneId
	if not Schema.findScene(self.chapter, startId) then
		startId = self.chapter.scenes[1] and self.chapter.scenes[1].id
	end

	if not startId then
		return false, "Chapter has no scenes."
	end

	self.active = true
	self.presenter:forgetInteractionTransition(self.currentInteraction)
	self.currentInteraction = nil
	self.presenter:forgetInteractionTransition(self.deferredInteractionExit)
	self.deferredInteractionExit = nil
	self.flags = Schema.deepCopy(self.initialChapterFlags)
	self.consumedResponses = {}
	self.sceneFlagStates = {}
	self.hiddenCharacterModels = {}
	self.presenter:setHiddenCharacterModels(self.hiddenCharacterModels)
	self.generation += 1
	self.delayedEventGeneration += 1
	self:_clearTimelineInteractionStack()
	self.runner:cancelDelayedEvents()
	self:_enterScene(startId, nil, { subsceneId = options.subsceneId })
	return true
end

function Director:stop()
	self.presenter:closeAssembly(true)
	self.generation += 1
	self.delayedEventGeneration += 1
	self.active = false
	self.presenter:forgetInteractionTransition(self.currentInteraction)
	self.presenter:forgetInteractionTransition(self.deferredInteractionExit)
	self.currentInteraction = nil
	self.deferredInteractionExit = nil
	self:_clearTimelineInteractionStack()
	self.entryAttributions = {}
	self.consumedResponses = {}
	self.sceneFlagStates = {}
	self.hiddenCharacterModels = {}
	self.presenter:setHiddenCharacterModels(self.hiddenCharacterModels)
	self.subscene = nil
	self.pendingFinish = nil
	self.presenter:showRoomExitChoices(nil)
	self.roomExitSequence = nil
	self.runner:stop()
	self.runner:cancelDelayedEvents()
	self.presenter:setInteractables({})
	self.presenter:leaveScene()
	self:_setPhase("Idle")
end

function Director:_finishChapter(reason)
	local generation = self.generation
	self.runner:stop()
	self:_clearTimelineInteractionStack()
	self.presenter:forgetInteractionTransition(self.currentInteraction)
	self.currentInteraction = nil
	self.presenter:setInteractables({})
	self.presenter:showRoomExitChoices(nil)
	self.roomExitSequence = nil
	self.presenter:forgetInteractionTransition(self.deferredInteractionExit)
	self.deferredInteractionExit = nil
	self.consumedResponses = {}
	self.sceneFlagStates = {}
	self.hiddenCharacterModels = {}
	self.presenter:setHiddenCharacterModels(self.hiddenCharacterModels)
	self:_setPhase("Ended")
	self.active = false
	self.Finished:Fire(reason or "end")

	if generation == self.generation then
		self.presenter:leaveScene()
	end
end

function Director:_runnerContext(interaction)
	return {
		scene = self.subscene and Schema.subsceneView(self.scene, self.subscene) or self.scene,
		chapter = self.chapter,
		project = self.project,
		flagsAreAuthoritative = true,
		getFlags = function()
			return self.flags
		end,
		interaction = interaction,
	}
end

local function roomKey(scene, subscene)
	return scene.id .. ":" .. subscene.id
end

local function teleportPlayer(positionText, facingCFrame)
	local position = Schema.decodePosition(positionText)
	if not position then return false end
	local player = Players.LocalPlayer
	if not player then return false end

	-- Chapter play can begin before Roblox has finished restoring the player's
	-- character from the editor preview. Do not let an opening interaction read
	-- the old preview camera before the requested Explore3D spawn is in place.
	local character = player.Character
	local deadline = os.clock() + 3
	while (not character or not character:FindFirstChild("HumanoidRootPart")) and os.clock() < deadline do
		task.wait()
		character = player.Character
	end
	if not character or not character:FindFirstChild("HumanoidRootPart") then return false end

	-- Lift the character above the picked part so the root does not spawn
	-- inside its collision geometry.
	local destination = position + Vector3.new(0, 3, 0)
	local facing = facingCFrame and Vector3.new(facingCFrame.LookVector.X, 0, facingCFrame.LookVector.Z)
	if facing and facing.Magnitude > 0.001 then
		character:PivotTo(CFrame.lookAt(destination, destination + facing.Unit))
	else
		character:PivotTo(CFrame.new(destination))
	end
	-- Let the normal player camera consume the new root transform before an
	-- immediate timeline Hotspot captures its Zoom start pose.
	RunService.Heartbeat:Wait()
	return true
end

-- An explicit return location (for example, a Room3D exit back into Explore3D)
-- wins over the subscene's ordinary spawn point for this one arrival.
local function teleportIntoExplore(subscene, returnPosition)
	local position = returnPosition
	if not Schema.decodePosition(position) then
		position = subscene and subscene.spawnPosition or ""
	end
	local facing = subscene and Schema.decodeCFrame(subscene.spawnCFrame) or nil
	return teleportPlayer(position, facing)
end

-- Timeline Interaction segments persist a copy of an interaction rather than
-- a live reference to its world binding. Keep this decoder forgiving for a
-- project that was saved during an earlier editor build, but the canonical
-- shape is segment.interaction.snapshot.
local function interactionSnapshotFromSegment(segment)
	if type(segment) ~= "table" then return nil end

	local block = type(segment.interaction) == "table" and segment.interaction or nil
	local params = type(segment.params) == "table" and segment.params or nil
	local snapshot = block and block.snapshot
	if type(snapshot) ~= "table" then snapshot = segment.snapshot end
	if type(snapshot) ~= "table" and params then snapshot = params.snapshot end
	-- A small compatibility affordance for experiments that stored the copied
	-- interaction directly in segment.interaction instead of beneath snapshot.
	if type(snapshot) ~= "table" and block and (block.sequence or block.responses or block.kind) then
		snapshot = block
	end
	if type(snapshot) ~= "table" then return nil end

	local interaction = Schema.deepCopy(snapshot)
	local sourceId = (block and block.sourceInteractionId) or segment.sourceInteractionId or ""
	local blockId = segment.id or sourceId
	if type(blockId) ~= "string" or blockId == "" then blockId = "anonymous" end
	-- Do not share Zoom camera state with the real world interaction this block
	-- was originally copied from, or with another copy of that block.
	interaction.id = "timeline_block_" .. blockId
	interaction.kind = interaction.kind or "Hotspot"
	interaction.targetId = interaction.targetId or ""
	interaction.transitionId = interaction.transitionId or ""
	interaction.responses = type(interaction.responses) == "table" and interaction.responses or {}
	interaction.sequence = type(interaction.sequence) == "table" and interaction.sequence or { segments = {} }
	interaction.onComplete = type(interaction.onComplete) == "table" and interaction.onComplete or {}
	return interaction
end

function Director:_clearTimelineInteractionStack(preserveInteraction)
	for _, frame in ipairs(self.timelineInteractionStack) do
		-- A flow event can leave an interaction block via a valid Room3D Merge.
		-- Keep its Zoom state until the linked Room3D completes so the normal
		-- interaction exit can bring the camera back out.
		if frame.interaction ~= preserveInteraction then
			self.presenter:forgetInteractionTransition(frame.interaction)
		end
	end
	table.clear(self.timelineInteractionStack)
end

function Director:_resumeTimelineInteraction(frame)
	if frame.generation ~= self.generation or not self.active then return end
	if self.timelineInteractionStack[#self.timelineInteractionStack] ~= frame then return end

	table.remove(self.timelineInteractionStack)
	self.currentInteraction = frame.parentInteraction
	self.pendingFinish = frame.parentFinish

	if not frame.resumeCursor then
		-- A normal runner finish would invoke the parent callback at exactly this
		-- point. We are replacing its sequence to play a child, so reproduce that
		-- final handoff rather than restarting the parent from its beginning.
		self.pendingFinish = nil
		if frame.parentFinish then
			frame.parentFinish()
		else
			self:_onSubsceneFinished()
		end
		return
	end

	self:_setPhase(frame.parentPhase or "PlayIntro")
	self.runner:setSequence(frame.parentSequence, self:_runnerContext(), {
		cursor = frame.resumeCursor,
		silent = true,
	})
	self.runner:play(false)
end

-- SequenceRunner calls this after it has paused on a timeline Interaction
-- segment. A copied Hotspot always invokes; enabled state and per-response
-- repeat policy determine which response sequence it resolves to.
function Director:_onTimelineInteractionBlock(segment, cursor, parentSequence)
	if not self.active or not self.scene then
		warn("[VNSceneEditor] Ignoring an interaction timeline block outside active chapter flow.")
		self.runner:stop()
		return
	end
	if not cursor or parentSequence ~= self.runner:getSequence() then
		-- A stale signal can only be produced after another flow path already
		-- replaced the runner. Do not disturb that newer sequence.
		warn("[VNSceneEditor] Ignoring a stale interaction timeline block callback.")
		return
	end

	local interaction = interactionSnapshotFromSegment(segment)
	if not interaction then
		warn("[VNSceneEditor] Interaction timeline block has no saved interaction snapshot; skipping it.")
		self.runner:skipInteractionBlock()
		return
	end

	local frame = {
		generation = self.generation,
		parentSequence = parentSequence,
		resumeCursor = SequenceState.nextCursor(parentSequence, cursor),
		parentPhase = self.phase,
		parentFinish = self.pendingFinish,
		parentInteraction = self.currentInteraction,
		interaction = interaction,
		segment = segment,
	}
	table.insert(self.timelineInteractionStack, frame)

	-- Snapshot its matching response now. A Set Flag inside the response should
	-- influence the next block/interaction invocation, never switch this active
	-- response halfway through playback.
	local response = self:resolveInteractionResponse(interaction)
	self:_consumeInteractionResponse(interaction, response)
	local responseSequence = Schema.getInteractionSequence(interaction, response and response.id)
	if type(responseSequence) ~= "table" then responseSequence = { segments = {} } end

	self.currentInteraction = interaction
	self.presenter:setInteractables({})
	self:_setPhase("PlayInteraction")

	local generation = self.generation
	task.spawn(function()
		if generation ~= self.generation or self.timelineInteractionStack[#self.timelineInteractionStack] ~= frame then
			return
		end
		local hasSequence = type(responseSequence.segments) == "table" and #responseSequence.segments > 0

		local function complete()
			if generation ~= self.generation or self.timelineInteractionStack[#self.timelineInteractionStack] ~= frame then
				return
			end
			self:_completeInteraction(interaction, responseSequence, { timelineFrame = frame })
		end

		local sequenceStarted = false
		local function startSequence()
			if sequenceStarted or generation ~= self.generation
				or self.timelineInteractionStack[#self.timelineInteractionStack] ~= frame then
				return
			end
			sequenceStarted = true
			self:_setPhase("PlayInteraction")
			self.pendingFinish = complete
			self.runner:setSequence(responseSequence, self:_runnerContext(interaction), { silent = true })
			self.runner:play(true)
		end

		if hasSequence and interaction.transitionId ~= "" then
			self:_setPhase("Transition")
			self:_transition(interaction.transitionId, function() end, {
				targetId = interaction.targetId,
				interaction = interaction,
				direction = "enter",
				onZoomPushStarted = startSequence,
			})
		end

		if generation ~= self.generation or self.timelineInteractionStack[#self.timelineInteractionStack] ~= frame then
			return
		end

		if hasSequence then
			startSequence()
		else
			complete()
		end
	end)
end

-- Runs a transition preset around an apply callback. Yields until done.
function Director:_transition(transitionId, apply, extra)
	local transitionGeneration = self.generation
	extra = extra or {}
	local destinationApplied = false
	local function applyDestination()
		if destinationApplied then return end
		destinationApplied = true
		apply()
		-- Destination preparation is normally hidden under a transition. Let a
		-- Room Assembly begin its clock at that exact handoff instead of leaving
		-- its opening frame frozen until Fade to Black has fully faded back out.
		if extra.onDestinationApplied then extra.onDestinationApplied() end
	end
	extra.cancelled = extra.cancelled or function()
		return transitionGeneration ~= self.generation
	end
	if transitionId == "Merge" then
		if self.scene and self.subscene and extra
			and Schema.isValidMergeBetween(self.scene, self.subscene, extra.targetSubsceneId) then
			applyDestination()
			return
		end
		transitionId = Schema.DEFAULT_FADE
	elseif transitionId == "Enter" then
		-- Enter is valid only for a Go To event currently executing
		-- inside a Hotspot's sequence. It is synthetic rather than a reusable
		-- project preset so it cannot leak into unrelated transition pickers.
		if extra and extra.allowEnter and extra.interaction
			and extra.interaction.kind == "Hotspot" then
			local context = extra
			context.apply = applyDestination
			context.project = self.project
			context.fromScene = self.presenter.scene or self.scene
			self.presenter:runTransition({
				id = "Enter",
				name = "Enter",
				kind = "Enter",
				params = {},
			}, context)
			return
		end
		transitionId = Schema.DEFAULT_FADE
	end
	local preset = Schema.findTransition(self.project, transitionId)
	if extra.toScene and extra.toScene.assemblyEnabled and preset
		and preset.kind ~= "FadeBlack" and preset.kind ~= "Cut" then
		warn("[Room Assembly] " .. tostring(preset.kind) .. " uses Fade to Black for an assembling room.")
		preset = Schema.findTransition(self.project, Schema.DEFAULT_FADE)
	end

	if not preset then
		applyDestination()
		return
	end

	local context = extra
	context.apply = applyDestination
	context.project = self.project
	context.fromScene = self.presenter.scene or self.scene

	self.presenter:runTransition(preset, context)
end

function Director:_prepareAssembly(options)
	if options.skipAssembly or not self.subscene or self.subscene.kind ~= "Room3D" then return end
	local view = Schema.subsceneView(self.scene, self.subscene)
	if not view.assemblyEnabled then return end
	local definition = Schema.findById(self.project.roomDefinitions, view.roomDefinitionId)
	if not definition then warn("[Room Assembly] Missing room definition; showing the finished room."); return end
	local session, err = self.presenter:prepareAssembly(definition)
	if not session then warn("[Room Assembly] " .. tostring(err)); return end
	for _, warning in ipairs(session.warnings) do warn("[Room Assembly] " .. warning) end
	if options.assemblyTime then session:seek(tonumber(options.assemblyTime) or 0) end
end

function Director:finishAssembly()
	local session = self.presenter.assemblySession
	if self.phase == "Assembly" and session then
		local ok, err = pcall(function() session:seek(session.compiled.duration) end)
		if not ok then warn("[Room Assembly] " .. tostring(err)); self.presenter:closeAssembly(false) end
	end
end

function Director:_playAssembly(generation)
	local session = self.presenter.assemblySession
	if not session then return end
	self:_setPhase("Assembly")
	local started = os.clock() - session.time
	local ok, err = pcall(function()
		while generation == self.generation and not session.closed and session.time < session.compiled.duration do
			RunService.RenderStepped:Wait()
			if generation ~= self.generation or session.closed then break end
			session:seek(os.clock() - started, true)
		end
	end)
	if not ok then warn("[Room Assembly] " .. tostring(err)) end
	if generation == self.generation then
		if not session.closed then
			local settled, settleError = pcall(function() session:seek(session.compiled.duration) end)
			if not settled then warn("[Room Assembly] " .. tostring(settleError)); self.presenter:getRig():setCFrame(session.destination, session.lease) end
		end
		self.presenter:closeAssembly(false)
	end
end

-- Starts a prepared Room Assembly without waiting for the incoming transition
-- to finish. The caller still waits for this task before it starts sequence
-- content, so only construction overlaps the fade -- never dialogue or input.
function Director:_startAssemblyDuringTransition(generation, state)
	if state.started or not self.presenter.assemblySession then return end
	state.started = true
	task.spawn(function()
		self:_playAssembly(generation)
		state.done = true
	end)
end

function Director:_waitForPreparedAssembly(generation, state)
	if not state.started then
		self:_playAssembly(generation)
		return
	end
	while generation == self.generation and not state.done do
		RunService.Heartbeat:Wait()
	end
end

function Director:_enterScene(sceneId, transitionId, options)
	options = options or {}

	local scene = Schema.findScene(self.chapter, sceneId)
	if not scene then
		self:_finishChapter("missing-scene")
		return
	end
	Schema.ensureSubscenes(scene)
	local entrySubscene = Schema.subsceneIndex(scene, options.subsceneId) or scene.subscenes[1]

	local generation = self.generation
	self.runner:stop()
	self.presenter:setInteractables({})
	self:_setPhase("Transition")

	task.spawn(function()
		-- One frame between scenes so a chain of instant cuts through empty
		-- intros can never spin the client.
		task.wait()

		if generation ~= self.generation then
			return
		end

		local assemblyState = { started = false, done = false }
		self:_transition(transitionId, function()
			if generation ~= self.generation then
				return
			end

			self.scene = scene
			self.subscene = nil
			self.currentInteraction = nil
			-- Keep one local state table for each scene visited in this chapter run.
			-- Explicit restore data wins; otherwise re-entry uses the remembered
			-- values and first entry falls back to the scene flag defaults.
			local sceneFlags = options.sceneFlags
			if sceneFlags == nil then sceneFlags = self.sceneFlagStates[scene.id] end
			self.flags = Schema.normalizeRuntimeFlagState(self.chapter, scene, self.flags, sceneFlags)
			self:_storeActiveSceneFlags()
			self.FlagsChanged:Fire(self.flags, nil)
			self.SceneChanged:Fire(scene)
			self.subscene = entrySubscene
			if entrySubscene.kind == "Room3D" and not options.preserveAttribution then
				self.entryAttributions[roomKey(scene, entrySubscene)] = options.entryAttribution
			end
			self.presenter:enterScene(Schema.subsceneView(scene, entrySubscene), self.project)
			if entrySubscene.kind == "Explore3D" then
				teleportIntoExplore(entrySubscene, options.returnPosition)
			end
			-- Prepare the destination environment beneath the overlay. Its dialogue
			-- remains withheld until the transition has fully completed.
			self.runner:setSequence(entrySubscene.sequence, self:_runnerContext(), { silent = true, backgroundOnly = true })
			self:_prepareAssembly(options)
			self.SubsceneChanged:Fire(entrySubscene)
		end, {
			toScene = Schema.subsceneView(scene, entrySubscene),
			targetId = options.transitionInteraction and options.transitionInteraction.targetId or nil,
			interaction = options.transitionInteraction,
			allowEnter = options.allowEnter == true,
			onDestinationApplied = function()
				self:_startAssemblyDuringTransition(generation, assemblyState)
			end,
		})

		if generation ~= self.generation then
			return
		end

		self:_waitForPreparedAssembly(generation, assemblyState)
		if generation ~= self.generation then return end
		local subscene = self.subscene
		if options.skipIntro or #subscene.sequence.segments == 0 then
			self:_onSubsceneFinished()
		else
			self:_setPhase("PlayIntro")
			self.pendingFinish = function() self:_onSubsceneFinished() end
			self.runner:play(true)
		end
	end)
end

function Director:_enterSubscene(subscene, transitionId, options)
	options = options or {}
	if not subscene then return false end
	local generation = self.generation
	local previousSnapshot = self.runner:getSnapshot()
	self.runner:stop()
	self.presenter:setInteractables({})
	self:_setPhase("Transition")
	task.spawn(function()
		if transitionId ~= "Merge" then task.wait() end
		if generation ~= self.generation then return end
		local previous = self.subscene
		local merging = transitionId == "Merge" and previous ~= nil
			and Schema.isValidMergeBetween(self.scene, previous, subscene)
		local assemblyState = { started = false, done = false }
		self:_transition(transitionId, function()
			if generation ~= self.generation then return end
			self.subscene = subscene
			self.currentInteraction = nil
			if subscene.kind == "Room3D" then
				-- Every entry replaces the prior source, including entries that did
				-- not use Enter, except a return from a nested room: that room's
				-- earlier source is still needed for a subsequent exit.
				if not options.preserveAttribution then
					self.entryAttributions[roomKey(self.scene, subscene)] = options.entryAttribution
				end
			end
			local view = Schema.subsceneView(self.scene, subscene)
			if merging then
				-- A Merge keeps the visible environment produced by the previous
				-- sequence, including any background or camera events it ran.
				if previousSnapshot then
					view.background = {
						kind = previousSnapshot.background.kind,
						value = previousSnapshot.background.value,
						poseId = previousSnapshot.background.poseId,
					}
					view.stage.cameraPoseId = previousSnapshot.cameraPoseId or ""
				end
				self.presenter:refreshScene(view, self.project)
				self.presenter:getWorld():clear()
			else
				self.presenter:enterScene(view, self.project)
			end
			if subscene.kind == "Explore3D" then
				teleportIntoExplore(subscene, options.returnPosition)
			end
			self.runner:setSequence(subscene.sequence, self:_runnerContext(), { silent = true, backgroundOnly = true })
			if not merging then self:_prepareAssembly(options) end
			self.SubsceneChanged:Fire(subscene)
		end, {
			toScene = Schema.subsceneView(self.scene, subscene),
			targetSubsceneId = subscene.id,
			targetId = options.transitionInteraction and options.transitionInteraction.targetId or nil,
			interaction = options.transitionInteraction,
			allowEnter = options.allowEnter == true,
			onDestinationApplied = function()
				self:_startAssemblyDuringTransition(generation, assemblyState)
			end,
		})
		if generation ~= self.generation then return end
		self:_waitForPreparedAssembly(generation, assemblyState)
		if generation ~= self.generation then return end
		if options.skipSequence or #subscene.sequence.segments == 0 then
			self:_onSubsceneFinished()
		else
			self:_setPhase("PlayIntro")
			self.pendingFinish = function() self:_onSubsceneFinished() end
			self.runner:play(true)
		end
	end)
	return true
end

function Director:_onSubsceneFinished()
	if not self.scene or not self.subscene then return end
	-- A sequence may end directly from its final dialogue line, leaving no next
	-- cursor render to clear that line's portrait. Foreground state belongs to
	-- sequence content, not AWAIT or the transition that follows it.
	self.presenter:clearStage()
	if self:_finishDeferredInteractionExit() then
		return
	end
	if self.subscene.kind ~= "Novel2D" then
		self:_await()
		return
	end
	local nextSubscene = Schema.nextAutomaticSubscene(self.scene, self.subscene)
	if nextSubscene then
		self:_enterSubscene(nextSubscene, self.subscene.nextTransitionId)
	else
		self:_leaveScene(self.scene.next.sceneId, self.scene.next.transitionId)
	end
end

-- A Go to Subscene event normally abandons the interaction response that
-- emitted it. For a Merge, abandoning a Zoom would leave the camera in its
-- close-up pose. Hold that interaction until the destination subscene ends,
-- then run its normal exit transition before resuming scene flow.
function Director:_finishDeferredInteractionExit()
	local interaction = self.deferredInteractionExit
	if not interaction then return false end
	self.deferredInteractionExit = nil
	local generation = self.generation
	self:_setPhase("Transition")
	task.spawn(function()
		if interaction.transitionId ~= "" then
			self:_transition(interaction.transitionId, function()
				if generation == self.generation then
					self.runner:stop()
					self.presenter:clearStage()
				end
			end, {
				targetId = interaction.targetId,
				interaction = interaction,
				direction = "exit",
			})
		else
			self.runner:stop()
			self.presenter:clearStage()
		end

		self.presenter:forgetInteractionTransition(interaction)
		if generation == self.generation and self.active then
			self:_onSubsceneFinished()
		end
	end)
	return true
end

function Director:_await()
	self.runner:stop()
	for _, route in ipairs(self.subscene and self.subscene.awaitRoutes or {}) do
		-- Conditions.evaluate intentionally treats an empty list as true.  That
		-- makes a route with no conditions an explicit unconditional AWAIT route,
		-- while preserving ordered, first-match-wins behavior for mixed routes.
		if route.toSubsceneId ~= ""
			and Conditions.evaluate(route.conditions, self.flags, self.chapter, self.scene) then
			local target = Schema.subsceneIndex(self.scene, route.toSubsceneId)
			if target and target.id ~= self.subscene.id then
				self:_enterSubscene(target, route.transitionId)
				return
			end
		end
	end
	-- Publish AWAIT only after ruling out an immediate AWAIT route. This
	-- prevents Explore3D controls/camera from being released for a single frame
	-- before another transition begins.
	self:_setPhase("Await")
	self:_refreshInteractables()
end

function Director:_refreshInteractables()
	if self.phase ~= "Await" or not self.scene then
		return
	end

	self.presenter:setInteractables(self:availableInteractions())
end

function Director:_roomIsExitable()
	local exiting = self.subscene and self.subscene.exiting or {}
	local conditions = exiting.conditions or {}
	if #conditions == 0 then return exiting.exitable ~= false end
	local matched = Conditions.evaluate(conditions, self.flags, self.chapter, self.scene)
	if matched then return exiting.conditionResult ~= false end
	return exiting.exitable ~= false
end

-- Linked Room3Ds are one continuous room for Auto exit purposes. Walk the
-- valid immediate-previous links back to the root Room3D, whose entry
-- attribution is the one that describes where this whole linked room began.
function Director:_autoExitSourceRoom()
	local room = self.subscene
	while room and room.linkPreviousRoom and Schema.isValidRoomLink(self.scene, room) do
		room = Schema.previousSubscene(self.scene, room.id)
	end
	return room
end

function Director:_resolveRoomExit()
	local exiting = self.subscene.exiting or {}
	if exiting.destinationMode == "Manual" then
		local scene = Schema.findScene(self.chapter, exiting.sceneId ~= "" and exiting.sceneId or self.scene.id)
		local subscene = scene and Schema.subsceneIndex(scene, exiting.subsceneId)
		if not subscene then return nil end
		if subscene.kind == "Explore3D" and not Schema.decodePosition(exiting.returnPosition) then return nil end
		return scene, subscene, subscene.kind == "Explore3D" and exiting.returnPosition or nil
	end
	return self:_resolveAutomaticRoomExit()
end

-- Resolve only the attribution-backed automatic exit. Flow events use this to
-- borrow the return point without inheriting a Room3D's manual exit override.
function Director:_resolveAutomaticRoomExit()
	local rootRoom = self:_autoExitSourceRoom()
	-- Prefer the linked chain's original entrance. A direct Enter to a linked
	-- continuation still owns a current-room attribution, so preserve that as a
	-- safe fallback instead of losing its return destination.
	local source = rootRoom and self.entryAttributions[roomKey(self.scene, rootRoom)]
		or self.entryAttributions[roomKey(self.scene, self.subscene)]
	if not source then return nil end
	local scene = Schema.findScene(self.chapter, source.sceneId)
	local subscene = scene and Schema.subsceneIndex(scene, source.subsceneId)
	if not subscene then return nil end
	if subscene.kind == "Explore3D" and not Schema.decodePosition(source.position) then return nil end
	return scene, subscene, subscene.kind == "Explore3D" and source.position or nil
end

-- Go To events can enter Explore3D at its ordinary spawn, the current
-- Room3D's automatic exit point, or a directly authored world position. An
-- invalid Exit/Manual point deliberately returns nil: teleportIntoExplore then
-- uses the destination's normal spawn as the safe fallback.
function Director:_exploreArrivalReturnPosition(params, destination)
	if not (destination and destination.kind == "Explore3D") then return nil end
	local mode = params and params.exploreArrivalMode or "Exit"
	if mode == "Manual" then
		local position = params and params.exploreReturnPosition or ""
		return Schema.decodePosition(position) and position or nil
	end
	if mode == "Exit" and self.subscene and self.subscene.kind == "Room3D" then
		local _, exitSubscene, position = self:_resolveAutomaticRoomExit()
		if exitSubscene and exitSubscene.kind == "Explore3D" and Schema.decodePosition(position) then
			return position
		end
	end
	return nil
end

function Director:_enterAttribution(target, transitionId, interaction)
	if transitionId ~= "Enter" or not (target and target.kind == "Room3D") then return nil end
	if not (interaction and interaction.kind == "Hotspot") then return nil end
	if not (self.subscene and (self.subscene.kind == "Explore3D" or self.subscene.kind == "Room3D")) then return nil end

	local attribution = { sceneId = self.scene.id, subsceneId = self.subscene.id, kind = self.subscene.kind }
	if self.subscene.kind == "Explore3D" then
		local targetInstance = self:_interactionTarget(interaction)
		local targetCFrame, center, size = WorldBindings.geometryOf(targetInstance)
		if targetCFrame and center and size then
			-- Auto return locations sit just beyond the *front surface* of the
			-- Hotspot, not inside its bounding box. This also gives Go To events
			-- using Exit exactly the same attribution-based position as Room exit.
			local halfDepth = math.max(0.25, size.Z * 0.5)
			local position = center + targetCFrame.LookVector * (halfDepth + 2)
			attribution.position = Schema.encodePosition(position)
		end
	end
	return attribution
end

function Director:_gotoSceneOptions(params, interaction)
	local destinationScene = Schema.findScene(self.chapter, params and params.sceneId)
	local destination = destinationScene and destinationScene.subscenes and destinationScene.subscenes[1] or nil
	local transitionId = params and params.transitionId or ""
	return {
		returnPosition = self:_exploreArrivalReturnPosition(params, destination),
		transitionInteraction = interaction,
		allowEnter = interaction ~= nil and interaction.kind == "Hotspot",
		entryAttribution = self:_enterAttribution(destination, transitionId, interaction),
	}
end

function Director:_cancelRoomExit()
	self.presenter:showRoomExitChoices(nil)
	self.roomExitSequence = nil
	self.pendingFinish = nil
	self.runner:stop()
	self.presenter:clearStage()
	self:_await()
end

function Director:_confirmRoomExit(confirmed)
	if self.phase ~= "PlayRoomExit" then return end
	if not confirmed then self:_cancelRoomExit(); return end
	local destinationScene, destinationSubscene, returnPosition = self:_resolveRoomExit()
	if not destinationScene then
		warn("[VNSceneEditor] Room3D exit has no valid destination or Explore3D return position.")
		self:_cancelRoomExit()
		return
	end
	self.presenter:showRoomExitChoices(nil)
	self.roomExitSequence = nil
	self.pendingFinish = nil
	self.runner:stop()
	self.entryAttributions[roomKey(self.scene, self.subscene)] = nil
	local rootRoom = self:_autoExitSourceRoom()
	if rootRoom then
		self.entryAttributions[roomKey(self.scene, rootRoom)] = nil
	end
	local transitionId = (self.subscene.exiting and self.subscene.exiting.transitionId) or Schema.DEFAULT_FADE
	local preserveAttribution = self.subscene.exiting and self.subscene.exiting.destinationMode ~= "Manual"
	if destinationScene.id == self.scene.id then
		self:_enterSubscene(destinationSubscene, transitionId, {
			returnPosition = returnPosition,
			preserveAttribution = preserveAttribution,
		})
	else
		self:_enterScene(destinationScene.id, transitionId, {
			subsceneId = destinationSubscene.id,
			returnPosition = returnPosition,
			preserveAttribution = preserveAttribution,
		})
	end
end

function Director:_updateRoomExitChoices(cursor)
	if self.phase ~= "PlayRoomExit" or not self.roomExitExitable or not self.roomExitSequence or not cursor then
		return
	end
	local segment = SequenceState.segmentAt(self.roomExitSequence, cursor)
	if segment and segment.kind == "Dialogue" and not SequenceState.nextCursor(self.roomExitSequence, cursor)
		and not self.presenter:isRevealing() then
		self.presenter:showRoomExitChoices(function(yes)
			self:_confirmRoomExit(yes)
		end)
	end
end

function Director:tryRoomExit()
	if not self.active or self.phase ~= "Await" or not self.subscene or self.subscene.kind ~= "Room3D" then
		return false
	end
	local exitable = self:_roomIsExitable()
	local exiting = self.subscene.exiting or {}
	local presetId = exitable and exiting.exitablePresetId or exiting.blockedPresetId
	local preset = Schema.findSequencePreset(self.project, presetId)
		or Schema.findSequencePreset(self.project, exitable and Schema.DEFAULT_ROOM_EXIT or Schema.DEFAULT_ROOM_BLOCKED)
	local sequence = preset and preset.sequence or Schema.newSequence(false)
	self.roomExitExitable = exitable
	self.roomExitSequence = sequence
	self.presenter:setInteractables({})
	self:_setPhase("PlayRoomExit")
	local generation = self.generation
	self.pendingFinish = function()
		if generation ~= self.generation then return end
		if not exitable then
			self:_cancelRoomExit()
		else
			self.presenter:showRoomExitChoices(function(yes)
				self:_confirmRoomExit(yes)
			end)
		end
		-- An exitable room keeps the final dialogue visible under Yes / No.
	end
	self.runner:setSequence(sequence, self:_runnerContext(), { silent = true })
	self.runner:play(true)
	return true
end

-- Leaves through the outro (if any) and enters the next scene, or ends.
function Director:_leaveScene(nextSceneId, transitionId, options)
	local generation = self.generation

	local function proceed()
		if generation ~= self.generation then
			return
		end

		if nextSceneId == nil or nextSceneId == "" then
			self:_finishChapter("end")
			return
		end

		self:_enterScene(nextSceneId, transitionId, options)
	end

	self.presenter:setInteractables({})

	local legacyOutro = self.scene and self.scene.subscenes and #self.scene.subscenes == 2
		and self.scene.subscenes[2].role == "outro" and self.subscene == self.scene.subscenes[1]
		and self.subscene.kind ~= "Novel2D" and self.scene.subscenes[2]
	if legacyOutro and #legacyOutro.sequence.segments > 0 then
		self:_setPhase("PlayOutro")
		self.pendingFinish = proceed
		self.runner:setSequence(legacyOutro.sequence, self:_runnerContext(), { silent = true })
		self.runner:play(true)
	else
		proceed()
	end
end

function Director:_onRunnerFinished()
	local callback = self.pendingFinish
	self.pendingFinish = nil

	if callback then
		callback()
	end
end

--------------------------------------------------------------------------------
-- Events fired by sequences
--------------------------------------------------------------------------------

function Director:_onEvents(events, sourceInteraction)
	local flagsChanged = false
	local changedFlagIds = {}
	local gotoParams = nil
	local gotoSubsceneParams = nil
	local endChapter = false

	sourceInteraction = sourceInteraction or self.currentInteraction
	for _, event in ipairs(events) do
		if event.type == "PortraitHide" and event.params
			and event.params.removeTargetCharacterModel == true
			and sourceInteraction and type(sourceInteraction.targetCharacterModelId) == "string"
			and sourceInteraction.targetCharacterModelId ~= "" then
			-- Deliberately remove only the copy that initiated this interaction.
			-- A generic portrait hide remains portrait-only by design.
			local placementId = sourceInteraction.targetCharacterModelId
			self.hiddenCharacterModels[placementId] = true
			self.presenter:removeCharacterModel(placementId)
		end
		if Conditions.applyEvent(self.flags, event, self.chapter, self.scene) then
			flagsChanged = true
			changedFlagIds[event.params.flag] = true
		elseif event.type == "FlowGoto" then
			gotoParams = event.params
		elseif event.type == "FlowGotoSubscene" then
			gotoSubsceneParams = event.params
		elseif event.type == "FlowEndChapter" then
			endChapter = true
		end
	end

	if flagsChanged then
		self:_storeActiveSceneFlags()
		self.FlagsChanged:Fire(self.flags, changedFlagIds)
		self:_refreshInteractables()
	end

	if not self.active then
		return
	end

		if endChapter then
			self:_clearTimelineInteractionStack()
			self.presenter:forgetInteractionTransition(self.currentInteraction)
			self.presenter:forgetInteractionTransition(self.deferredInteractionExit)
			self.deferredInteractionExit = nil
		self.presenter:showRoomExitChoices(nil)
		self.roomExitSequence = nil
		self.pendingFinish = nil
		self:_finishChapter("end")
		elseif gotoParams then
			self:_clearTimelineInteractionStack()
			self.presenter:forgetInteractionTransition(self.currentInteraction)
			self.presenter:forgetInteractionTransition(self.deferredInteractionExit)
			self.deferredInteractionExit = nil
		self.presenter:showRoomExitChoices(nil)
		self.roomExitSequence = nil
		self.pendingFinish = nil
		self.runner:stop()
		self:_leaveScene(gotoParams.sceneId, gotoParams.transitionId, self:_gotoSceneOptions(gotoParams, sourceInteraction))
	elseif gotoSubsceneParams then
		local target = Schema.subsceneIndex(self.scene, gotoSubsceneParams.subsceneId)
		if target then
			local transitionInteraction = sourceInteraction or self.currentInteraction
			local preserveInteractionExit = transitionInteraction
				and gotoSubsceneParams.transitionId == "Merge"
				and self.subscene
				and Schema.isValidMergeBetween(self.scene, self.subscene, target)
			self:_clearTimelineInteractionStack(preserveInteractionExit and transitionInteraction or nil)
			self.presenter:showRoomExitChoices(nil)
			self.roomExitSequence = nil
			local attribution = self:_enterAttribution(target, gotoSubsceneParams.transitionId, transitionInteraction)
			-- A Merge from an active Hotspot response retains its entry camera
			-- memory until the linked destination has completed, so Zoom can unwind
			-- from the same camera state rather than leaving the player close-up.
			if preserveInteractionExit then
				self.deferredInteractionExit = transitionInteraction
			else
				self.presenter:forgetInteractionTransition(transitionInteraction)
			end
			self.pendingFinish = nil
			self.runner:stop()
			self:_enterSubscene(target, gotoSubsceneParams.transitionId, {
				transitionInteraction = transitionInteraction,
				allowEnter = transitionInteraction ~= nil and transitionInteraction.kind == "Hotspot",
				entryAttribution = attribution,
				returnPosition = self:_exploreArrivalReturnPosition(gotoSubsceneParams, target),
			})
		end
	end
end

--------------------------------------------------------------------------------
-- Interactions
--------------------------------------------------------------------------------

function Director:isInteractionAvailable(interaction)
	return Schema.interactionInSubscene(self.scene, self.subscene, interaction)
end

function Director:_interactionTarget(interaction)
	if interaction and type(interaction.targetCharacterModelId) == "string" and interaction.targetCharacterModelId ~= "" then
		return self.presenter:getCharacterModels():resolveTarget(interaction.targetCharacterModelId)
	end
	return interaction and WorldBindings.resolve(interaction.targetId, interaction.targetRef) or nil
end

function Director:_hasConsumedInteractionResponse(interaction, response)
	local responses = interaction and self.consumedResponses[interaction.id]
	return responses ~= nil and response ~= nil and responses[response.id] == true
end

function Director:_consumeInteractionResponse(interaction, response)
	if not interaction or not response or response.repeatPolicy ~= "once" then return end
	local responses = self.consumedResponses[interaction.id] or {}
	responses[response.id] = true
	self.consumedResponses[interaction.id] = responses
end

-- An interaction is always triggerable while in scope. Disabled interactions
-- intentionally bypass every conditional response and use their fallback.
-- Otherwise the first matching response that has not exhausted Once wins.
function Director:resolveInteractionResponse(interaction)
	if not interaction or interaction.enabled == false then return nil end
	for _, response in ipairs(interaction.responses or {}) do
		if not self:_hasConsumedInteractionResponse(interaction, response)
			and Conditions.evaluate(response.conditions, self.flags, self.chapter, self.scene) then
			return response
		end
	end
	return nil
end

-- { { interaction, available }, ... } for the presenter's world bindings.
function Director:availableInteractions()
	local list = {}

	if not self.scene then
		return list
	end

	for _, interaction in ipairs(self.scene.interactions) do
		if Schema.interactionInSubscene(self.scene, self.subscene, interaction) then
			table.insert(list, {
				interaction = interaction,
				available = self:isInteractionAvailable(interaction),
			})
		end
	end

	return list
end

function Director:tryInteraction(interactionId)
	if not self.active or self.phase ~= "Await" or not self.scene then
		return false
	end

	local interaction = Schema.findInteraction(self.scene, interactionId)
	if not interaction or not self:isInteractionAvailable(interaction) then
		return false
	end
	-- Snapshot the response now. Flag changes during its own sequence must not
	-- cause the active timeline to switch underneath the player.
	local response = self:resolveInteractionResponse(interaction)
	local sequence = Schema.getInteractionSequence(interaction, response and response.id)

	self:_consumeInteractionResponse(interaction, response)
	self.currentInteraction = interaction
	self.presenter:setInteractables({})
	self:_setPhase("PlayInteraction")

	local generation = self.generation

	task.spawn(function()
		local hasSequence = #sequence.segments > 0
		local function complete()
			if generation ~= self.generation then
				return
			end

			self:_completeInteraction(interaction, sequence)
		end

		local sequenceStarted = false
		local function startSequence()
			if sequenceStarted or generation ~= self.generation then return end
			sequenceStarted = true
			self:_setPhase("PlayInteraction")
			self.pendingFinish = complete
			self.runner:setSequence(sequence, self:_runnerContext(interaction), { silent = true })
			self.runner:play(true)
		end

		if hasSequence and interaction.transitionId ~= "" then
			self:_setPhase("Transition")
			self:_transition(interaction.transitionId, function() end, {
				targetId = interaction.targetId,
				interaction = interaction,
				direction = "enter",
				onZoomPushStarted = startSequence,
			})

			if generation ~= self.generation then
				return
			end
		end

		if hasSequence then
			startSequence()
		else
			complete()
		end
	end)

	return true
end

-- options.timelineFrame is present when the interaction originated from an
-- Interaction segment in another sequence. In that case a normal completion
-- returns to the saved parent cursor instead of putting the whole subscene into
-- AWAIT; any explicit flow event still wins and abandons the parent stack.
function Director:_completeInteraction(interaction, sequence, options)
	options = options or {}
	local timelineFrame = options.timelineFrame
	local generation = self.generation
	local hasSequence = #(sequence or interaction.sequence).segments > 0

	-- onComplete flow events (flags, gotoParams, end).
	local gotoParams = nil
	local gotoSubsceneParams = nil
	local endChapter = false
	local flagsChanged = false
	local changedFlagIds = {}
	local immediateEvents = {}
	local delayedEventGeneration = self.delayedEventGeneration

	for _, event in ipairs(interaction.onComplete) do
		local delay = math.max(0, tonumber(event.delay) or 0)
		if delay > 0 then
			-- Completion events do not pass through SequenceRunner, but obey the
			-- same rule: their delay never holds the interaction/subscene open.
			task.delay(delay, function()
				if delayedEventGeneration ~= self.delayedEventGeneration then return end
				self.presenter:playEvents({ event }, { scene = self.scene, project = self.project })
				self:_onEvents({ event }, interaction)
			end)
		elseif Conditions.applyEvent(self.flags, event, self.chapter, self.scene) then
			flagsChanged = true
			changedFlagIds[event.params.flag] = true
		elseif event.type == "FlowGoto" then
			gotoParams = event.params
		elseif event.type == "FlowGotoSubscene" then
			gotoSubsceneParams = event.params
		elseif event.type == "FlowEndChapter" then
			endChapter = true
		end
		if delay <= 0 then
			table.insert(immediateEvents, event)
		end
	end

	if #immediateEvents > 0 then
		self.presenter:playEvents(immediateEvents, { scene = self.scene, project = self.project })
	end

	if flagsChanged then
		self:_storeActiveSceneFlags()
		self.FlagsChanged:Fire(self.flags, changedFlagIds)
		self:_refreshInteractables()
	end

	task.spawn(function()
		if generation ~= self.generation or (timelineFrame and self.timelineInteractionStack[#self.timelineInteractionStack] ~= timelineFrame) then
			return
		end
		if hasSequence and interaction.transitionId ~= "" then
			self:_setPhase("Transition")
			self:_transition(interaction.transitionId, function()
				if generation == self.generation then
					self.runner:stop()
					self.presenter:clearStage()
				end
			end, {
				targetId = interaction.targetId,
				interaction = interaction,
				direction = "exit",
			})
		else
			self.runner:stop()
			self.presenter:clearStage()
		end

		if generation ~= self.generation then
			return
		end

		self.currentInteraction = nil

		if endChapter then
			self:_clearTimelineInteractionStack()
			self:_finishChapter("end")
		elseif gotoParams then
			self:_clearTimelineInteractionStack()
			self:_leaveScene(gotoParams.sceneId, gotoParams.transitionId, self:_gotoSceneOptions(gotoParams, interaction))
		elseif gotoSubsceneParams then
			local target = Schema.subsceneIndex(self.scene, gotoSubsceneParams.subsceneId)
			if target then
				self:_clearTimelineInteractionStack()
				self:_enterSubscene(target, gotoSubsceneParams.transitionId, {
					returnPosition = self:_exploreArrivalReturnPosition(gotoSubsceneParams, target),
				})
			elseif timelineFrame then
				self:_resumeTimelineInteraction(timelineFrame)
			else
				self:_await()
			end
		elseif timelineFrame then
			self:_resumeTimelineInteraction(timelineFrame)
		else
			self:_await()
		end
	end)
end

--------------------------------------------------------------------------------
-- Input
--------------------------------------------------------------------------------

-- Click anywhere on the stage.
function Director:advance()
	if not self.active then
		return
	end
	if self.phase == "Assembly" then self:finishAssembly(); return end

	if self.phase == "PlayRoomExit" and self.presenter.roomExitChoices.Visible then return end
	if self.phase == "PlayIntro" or self.phase == "PlayInteraction" or self.phase == "PlayOutro"
		or self.phase == "PlayRoomExit" then
		self.runner:advance()
	end
end

function Director:destroy()
	self:stop()
	if self.interactionConnection then
		self.interactionConnection:Disconnect()
	end
	self.runner:destroy()
	self.SceneChanged:DisconnectAll()
	self.SubsceneChanged:DisconnectAll()
	self.PhaseChanged:DisconnectAll()
	self.FlagsChanged:DisconnectAll()
	self.Finished:DisconnectAll()
end

return Director
