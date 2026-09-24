-- Walks a chapter: enters scenes, plays intros, waits for interactions in 3D
-- scenes, runs exits and transitions, and keeps the flag table.
--
-- Phases: Idle, Transition, PlayIntro, Await, PlayInteraction, PlayOutro, Ended
--
-- The editor and the shipped game both use this class. Callers hand each new
-- playthrough its own flag table, and may explicitly restore a saved one.

local Signal = require(script.Parent.Parent.Core.Signal)
local Schema = require(script.Parent.Parent.Core.Schema)
local Conditions = require(script.Parent.Conditions)
local SequenceRunner = require(script.Parent.SequenceRunner)

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
	self.consumed = {} -- interactionId -> times completed
	self.generation = 0
	self.active = false
	self.currentInteraction = nil
	self.pendingFinish = nil -- callback for the runner's next Finished

	self.runner = SequenceRunner.new(presenter)

	self.SceneChanged = Signal.new() -- (scene)
	self.SubsceneChanged = Signal.new() -- (subscene)
	self.PhaseChanged = Signal.new() -- (phase)
	self.FlagsChanged = Signal.new() -- (flags, changedIds | nil)
	self.Finished = Signal.new() -- (reason)

	self.runner.Finished:Connect(function()
		self:_onRunnerFinished()
	end)

	self.runner.EventsFired:Connect(function(events)
		self:_onEvents(events)
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
	self.chapter = chapter
	self.scene = nil
	self.subscene = nil
	self.currentInteraction = nil
	self.flags = Schema.normalizeFlagState(chapter, flags)
	self.consumed = {}
	self.FlagsChanged:Fire(self.flags, {})
end

function Director:getFlags()
	return self.flags
end

function Director:setFlags(flags)
	self.flags = Schema.normalizeRuntimeFlagState(self.chapter, self.scene, flags, flags)
	self.FlagsChanged:Fire(self.flags, nil)
	self:_refreshInteractables()
end

function Director:setFlag(flagId, value)
	local definition = Schema.resolveFlag(self.chapter, self.scene, flagId)
	if not definition then
		return false
	end

	local nextValue = Schema.coerceFlagValue(definition, value)
	if self.flags[flagId] == nextValue and type(self.flags[flagId]) == type(nextValue) then
		return false
	end

	self.flags[flagId] = nextValue
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
		subsceneId = self.subscene and self.subscene.id or "",
		flags = Schema.deepCopy(self.flags),
		consumed = Schema.deepCopy(self.consumed),
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
	self.consumed = state.consumed or {}

	local scene = Schema.findScene(chapter, state.sceneId)
	if not scene then
		return self:start()
	end

	self.active = true
	self.generation += 1

	if state.phase == "Await" then
		self:_enterScene(scene.id, nil, { skipIntro = true, sceneFlags = state.flags, subsceneId = state.subsceneId })
	else
		self:_enterScene(scene.id, nil, { sceneFlags = state.flags, subsceneId = state.subsceneId })
	end

	return true
end

--------------------------------------------------------------------------------
-- Flow
--------------------------------------------------------------------------------

function Director:start(sceneId)
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
	self.generation += 1
	self:_enterScene(startId, nil)
	return true
end

function Director:stop()
	self.generation += 1
	self.active = false
	self.currentInteraction = nil
	self.subscene = nil
	self.pendingFinish = nil
	self.runner:stop()
	self.presenter:setInteractables({})
	self.presenter:leaveScene()
	self:_setPhase("Idle")
end

function Director:_finishChapter(reason)
	local generation = self.generation
	self.runner:stop()
	self.presenter:setInteractables({})
	self:_setPhase("Ended")
	self.active = false
	self.Finished:Fire(reason or "end")

	if generation == self.generation then
		self.presenter:leaveScene()
	end
end

function Director:_runnerContext()
	return {
		scene = self.subscene and Schema.subsceneView(self.scene, self.subscene) or self.scene,
		chapter = self.chapter,
		project = self.project,
		flagsAreAuthoritative = true,
		getFlags = function()
			return self.flags
		end,
	}
end

-- Runs a transition preset around an apply callback. Yields until done.
function Director:_transition(transitionId, apply, extra)
	if transitionId == "Merge" then
		if self.scene and self.subscene and extra
			and Schema.isValidMergeBetween(self.scene, self.subscene, extra.targetSubsceneId) then
			apply()
			return
		end
		transitionId = Schema.DEFAULT_FADE
	end
	local preset = Schema.findTransition(self.project, transitionId)

	if not preset then
		apply()
		return
	end

	local context = extra or {}
	context.apply = apply
	context.project = self.project
	context.fromScene = self.presenter.scene or self.scene

	self.presenter:runTransition(preset, context)
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

		self:_transition(transitionId, function()
			if generation ~= self.generation then
				return
			end

			self.scene = scene
			self.subscene = nil
			self.currentInteraction = nil
			-- Scene flags have lexical scene scope: entering normally creates fresh
			-- defaults and drops the previous scene's locals. Restore is the only
			-- path that supplies saved local values.
			self.flags = Schema.normalizeRuntimeFlagState(self.chapter, scene, self.flags, options.sceneFlags)
			self.FlagsChanged:Fire(self.flags, nil)
			self.SceneChanged:Fire(scene)
			self.subscene = entrySubscene
			self.presenter:enterScene(Schema.subsceneView(scene, entrySubscene), self.project)
			-- Prepare the destination environment beneath the overlay. Its dialogue
			-- remains withheld until the transition has fully completed.
			self.runner:setSequence(entrySubscene.sequence, self:_runnerContext(), { silent = true, backgroundOnly = true })
			self.SubsceneChanged:Fire(entrySubscene)
		end, { toScene = Schema.subsceneView(scene, entrySubscene) })

		if generation ~= self.generation then
			return
		end

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
		self:_transition(transitionId, function()
			if generation ~= self.generation then return end
			self.subscene = subscene
			self.currentInteraction = nil
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
			self.runner:setSequence(subscene.sequence, self:_runnerContext(), { silent = true, backgroundOnly = true })
			self.SubsceneChanged:Fire(subscene)
		end, { toScene = Schema.subsceneView(self.scene, subscene), targetSubsceneId = subscene.id })
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

function Director:_await()
	self:_setPhase("Await")
	self.runner:stop()
	self:_refreshInteractables()
	for _, route in ipairs(self.subscene and self.subscene.awaitRoutes or {}) do
		if route.toSubsceneId ~= "" and #route.conditions > 0
			and Conditions.evaluate(route.conditions, self.flags, self.chapter, self.scene) then
			local target = Schema.subsceneIndex(self.scene, route.toSubsceneId)
			if target and target.id ~= self.subscene.id then
				self:_enterSubscene(target, route.transitionId)
				return
			end
		end
	end
end

function Director:_refreshInteractables()
	if self.phase ~= "Await" or not self.scene then
		return
	end

	self.presenter:setInteractables(self:availableInteractions())
end

-- Leaves through the outro (if any) and enters the next scene, or ends.
function Director:_leaveScene(nextSceneId, transitionId)
	local generation = self.generation

	local function proceed()
		if generation ~= self.generation then
			return
		end

		if nextSceneId == nil or nextSceneId == "" then
			self:_finishChapter("end")
			return
		end

		self:_enterScene(nextSceneId, transitionId)
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

function Director:_onEvents(events)
	local flagsChanged = false
	local changedFlagIds = {}
	local gotoParams = nil
	local gotoSubsceneParams = nil
	local endChapter = false

	for _, event in ipairs(events) do
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
		self.FlagsChanged:Fire(self.flags, changedFlagIds)
		self:_refreshInteractables()
	end

	if not self.active then
		return
	end

	if endChapter then
		self.pendingFinish = nil
		self:_finishChapter("end")
	elseif gotoParams then
		self.pendingFinish = nil
		self.runner:stop()
		self:_leaveScene(gotoParams.sceneId, gotoParams.transitionId)
	elseif gotoSubsceneParams then
		local target = Schema.subsceneIndex(self.scene, gotoSubsceneParams.subsceneId)
		if target then
			self.pendingFinish = nil
			self.runner:stop()
			self:_enterSubscene(target, gotoSubsceneParams.transitionId)
		end
	end
end

--------------------------------------------------------------------------------
-- Interactions
--------------------------------------------------------------------------------

function Director:isInteractionAvailable(interaction)
	if not Schema.interactionInSubscene(self.scene, self.subscene, interaction) then return false end
	if interaction.repeatPolicy == "once" and (self.consumed[interaction.id] or 0) > 0 then
		return false
	end

	return Conditions.evaluate(interaction.conditions, self.flags, self.chapter, self.scene)
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

	self.consumed[interaction.id] = (self.consumed[interaction.id] or 0) + 1
	self.currentInteraction = interaction
	self.presenter:setInteractables({})
	self:_setPhase("PlayInteraction")

	local generation = self.generation

	task.spawn(function()
		local hasSequence = #interaction.sequence.segments > 0

		if hasSequence and interaction.transitionId ~= "" then
			self:_setPhase("Transition")
			self:_transition(interaction.transitionId, function() end, {
			targetId = interaction.targetId,
			interaction = interaction,
			direction = "enter",
			})

			if generation ~= self.generation then
				return
			end

			self:_setPhase("PlayInteraction")
		end

		local function complete()
			if generation ~= self.generation then
				return
			end

			self:_completeInteraction(interaction)
		end

		if hasSequence then
			self.pendingFinish = complete
			self.runner:setSequence(interaction.sequence, self:_runnerContext(), { silent = true })
			self.runner:play(true)
		else
			complete()
		end
	end)

	return true
end

function Director:_completeInteraction(interaction)
	local generation = self.generation
	local hasSequence = #interaction.sequence.segments > 0

	-- onComplete flow events (flags, gotoParams, end).
	local gotoParams = nil
	local gotoSubsceneParams = nil
	local endChapter = false
	local flagsChanged = false
	local changedFlagIds = {}

	for _, event in ipairs(interaction.onComplete) do
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

	if #interaction.onComplete > 0 then
		self.presenter:playEvents(interaction.onComplete, { scene = self.scene, project = self.project })
	end

	if flagsChanged then
		self.FlagsChanged:Fire(self.flags, changedFlagIds)
		self:_refreshInteractables()
	end

	task.spawn(function()
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
			self:_finishChapter("end")
		elseif gotoParams then
			self:_leaveScene(gotoParams.sceneId, gotoParams.transitionId)
		elseif gotoSubsceneParams then
			local target = Schema.subsceneIndex(self.scene, gotoSubsceneParams.subsceneId)
			if target then self:_enterSubscene(target, gotoSubsceneParams.transitionId) else self:_await() end
		elseif interaction.kind == "Exit" then
			self:_leaveScene(interaction.exit.sceneId, interaction.exit.transitionId)
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

	if self.phase == "PlayIntro" or self.phase == "PlayInteraction" or self.phase == "PlayOutro" then
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
