-- Drives a cursor through one sequence and asks the presenter to draw it.
--
-- Timed segments advance themselves. Dialogue entries wait: the first click
-- while text is still typing reveals it all when the entry is skippable; the
-- next click plays the textbox out-animation and then moves on. The editor
-- uses the same runner for scrubbing by calling setCursor with playback
-- paused.

local RunService = game:GetService("RunService")

local Signal = require(script.Parent.Parent.Core.Signal)
local SequenceState = require(script.Parent.SequenceState)

local SequenceRunner = {}
SequenceRunner.__index = SequenceRunner

local function isInteractionBlock(segment)
	return segment ~= nil and (segment.kind == "Interaction" or segment.kind == "InteractionBlock")
end

function SequenceRunner.new(presenter)
	local self = setmetatable({}, SequenceRunner)

	self.presenter = presenter
	self.sequence = { segments = {} }
	self.context = {}
	self.cursor = nil
	self.snapshot = nil
	self.playing = false
	self.advancing = false
	self.ended = false
	self.connection = nil
	self.generation = 0
	self.dialogueWaitTime = 0
	self.dialogueWaitEntryId = nil
	-- Interaction timeline blocks pause the parent sequence here. Director then
	-- temporarily swaps in the block's response sequence and resumes the saved
	-- parent cursor when that child finishes.
	self.waitingForInteraction = false
	-- Delayed events survive ordinary sequence/subscene completion. An explicit
	-- caller stop can cancel them with cancelDelayedEvents().
	self.delayedEventGeneration = 0

	self.CursorChanged = Signal.new() -- (cursor)
	self.PlayingChanged = Signal.new() -- (isPlaying)
	self.EventsFired = Signal.new() -- (events)
	self.BlockEntered = Signal.new() -- (interactionSegment, cursor, sequence)
	self.Finished = Signal.new() -- ()

	return self
end

--------------------------------------------------------------------------------
-- Setup
--------------------------------------------------------------------------------

-- context = { scene, project, flags | getFlags }
function SequenceRunner:setSequence(sequence, context, options)
	options = options or {}
	self:stop()

	self.sequence = sequence or { segments = {} }
	self.context = context or {}
	self.ended = false
	self.advancing = false
	self.generation += 1

	local cursor = options.cursor or SequenceState.startCursor(self.sequence)
	self:setCursor(cursor, {
		fire = options.fire,
		silent = options.silent,
		render = options.render,
		backgroundOnly = options.backgroundOnly,
	})
end

function SequenceRunner:setContext(context)
	self.context = context or {}
end

function SequenceRunner:_flags()
	if self.context.getFlags then
		return self.context.getFlags()
	end
	return self.context.flags or {}
end

function SequenceRunner:getCursor()
	return self.cursor
end

function SequenceRunner:getSnapshot()
	return self.snapshot
end

function SequenceRunner:isPlaying()
	return self.playing
end

function SequenceRunner:hasEnded()
	return self.ended
end

function SequenceRunner:isEmpty()
	return #self.sequence.segments == 0
end

function SequenceRunner:getSequence()
	return self.sequence
end

--------------------------------------------------------------------------------
-- Rendering
--------------------------------------------------------------------------------

function SequenceRunner:_render(backgroundOnly)
	local renderContext = {
		scene = self.context.scene,
		project = self.context.project,
		playing = self.playing,
		editor = self.context.editor,
		scrubbing = self.context.scrubbing,
	}

	self.snapshot = SequenceState.compute(self.sequence, self.cursor, {
		scene = self.context.scene,
		chapter = self.context.chapter,
		flags = self:_flags(),
		flagsAreAuthoritative = self.context.flagsAreAuthoritative == true,
	})
	if backgroundOnly then
		-- The transition needs the destination environment underneath its overlay,
		-- but not a prematurely visible portrait or dialogue box. Keep the same
		-- computed background/camera state that normal playback will use.
		self.snapshot.portrait = nil
		self.snapshot.dialogue = nil
	end

	self.presenter:render(self.snapshot, renderContext)
end

function SequenceRunner:refresh()
	if self.cursor then
		self.cursor = SequenceState.normalizeCursor(self.sequence, self.cursor)
	end

	if not self.cursor then
		self.cursor = SequenceState.startCursor(self.sequence)
	end

	self:_render()
end

function SequenceRunner:_dispatchEvents(events, context)
	if #events == 0 then return end
	self.presenter:playEvents(events, context)
	-- Preserve the source context for delayed events. Runtime consumers need it
	-- to know which Hotspot authored an effect after the active sequence moves on.
	self.EventsFired:Fire(events, context)
end

function SequenceRunner:_fire(events)
	if #events == 0 then return end

	local immediate = {}
	local context = {
		scene = self.context.scene,
		project = self.context.project,
		interaction = self.context.interaction,
	}
	local delayedGeneration = self.delayedEventGeneration

	for _, event in ipairs(events) do
		local delay = math.max(0, tonumber(event.delay) or 0)
		if delay <= 0 then
			table.insert(immediate, event)
		else
			-- Do not tie this callback to SequenceRunner.generation: moving to the
			-- next subscene must not cancel an event whose delay outlasts the source.
			task.delay(delay, function()
				if delayedGeneration == self.delayedEventGeneration then
					self:_dispatchEvents({ event }, context)
				end
			end)
		end
	end

	self:_dispatchEvents(immediate, context)
end

function SequenceRunner:cancelDelayedEvents()
	self.delayedEventGeneration += 1
end

-- options: fire (bool) plays the anchor's events, silent skips CursorChanged,
-- render=false records the cursor without drawing. backgroundOnly prepares a
-- destination's background/camera beneath a transition while withholding its
-- foreground UI. Playback's first full render performs the normal entrance.
function SequenceRunner:setCursor(cursor, options)
	options = options or {}

	self.cursor = SequenceState.normalizeCursor(self.sequence, cursor)
	self.ended = self.cursor == nil
	self.dialogueWaitTime = 0
	self.dialogueWaitEntryId = nil
	self.waitingForInteraction = false

	if options.render ~= false then
		self:_render(options.backgroundOnly == true)
	end

	if options.fire and self.cursor then
		self:_fire(SequenceState.eventsAtCursor(self.sequence, self.cursor))
	end

	if not options.silent then
		self.CursorChanged:Fire(self.cursor)
	end
end

--------------------------------------------------------------------------------
-- Playback
--------------------------------------------------------------------------------

function SequenceRunner:_setPlaying(playing)
	if self.playing == playing then
		return
	end

	self.playing = playing
	self.PlayingChanged:Fire(playing)
end

function SequenceRunner:play(fromStart)
	if self:isEmpty() then
		self.ended = true
		self:_setPlaying(false)
		self.Finished:Fire()
		return
	end

	if fromStart or not self.cursor then
		self.cursor = SequenceState.startCursor(self.sequence)
	end

	self.ended = false
	self.advancing = false
	self:_setPlaying(true)

	local generation = self.generation
	self:setCursor(self.cursor, { fire = true })
	if generation ~= self.generation or not self.playing then return end

	if self.connection then
		self.connection:Disconnect()
	end

	self.connection = RunService.Heartbeat:Connect(function(dt)
		self:_step(dt)
	end)
end

function SequenceRunner:playFrom(cursor)
	self.cursor = cursor
	self:play(false)
end

function SequenceRunner:pause()
	if self.connection then
		self.connection:Disconnect()
		self.connection = nil
	end

	self:_setPlaying(false)
end

function SequenceRunner:stop()
	self:pause()
	self.advancing = false
	self.waitingForInteraction = false
	self.generation += 1
	if self.presenter.clearImageFocus then self.presenter:clearImageFocus(true) end
end

-- Called only while the parent runner sits on an Interaction segment. Do not
-- advance it automatically: a Director listener owns the nested response and
-- decides when (or whether) the parent gets to continue.
function SequenceRunner:_enterInteractionBlock(segment)
	if self.waitingForInteraction then
		return
	end

	self.waitingForInteraction = true

	-- Standalone editor runners deliberately do not own chapter flow. Rather
	-- than leaving their preview frozen forever, make a malformed/unhandled block
	-- visible in output and move past it safely.
	if #self.BlockEntered._handlers == 0 then
		warn("[VNSceneEditor] Interaction timeline block has no Director handler; skipping it.")
		self.waitingForInteraction = false
		self:_moveNext()
		return
	end

	self:pause()
	self.BlockEntered:Fire(segment, self.cursor, self.sequence)
end

-- A public escape hatch for a caller that intentionally wants to discard the
-- current block. Director uses it for malformed, unavailable, or already
-- consumed snapshots; a completed nested interaction instead restores its
-- saved parent cursor.
function SequenceRunner:skipInteractionBlock()
	local segment = SequenceState.segmentAt(self.sequence, self.cursor)
	if isInteractionBlock(segment) then
		self.waitingForInteraction = false
		-- `play(false)` below fires the destination anchor as playback resumes.
		-- Do not fire it here as well, or a gated/skipped block duplicates every
		-- event at the next dialogue line or timed segment's zero point.
		self:_moveNext({ fire = false, silent = true })
		-- Director pauses before it asks for a nested response. If it rejects a
		-- malformed block, continue the parent instead of leaving that runner
		-- paused on the following anchor.
		if not self.ended and not self.playing then
			self:play(false)
		end
		return true
	end
	return false
end

function SequenceRunner:_step(dt)
	if not self.cursor or self.advancing then
		return
	end

	local segment = SequenceState.segmentAt(self.sequence, self.cursor)
	if not segment then
		self:_finish()
		return
	end

	if isInteractionBlock(segment) then
		self:_enterInteractionBlock(segment)
		return
	end

	if segment.kind == "Timed" then
		local previous = self.cursor.time
		local nextTime = previous + dt
		local generation = self.generation

		if nextTime >= segment.duration then
			self.cursor.time = segment.duration
			self:_render()
			self:_fire(SequenceState.eventsBetween(segment, previous, segment.duration))
			if generation ~= self.generation then return end
			self:_moveNext()
			return
		end

		self.cursor.time = nextTime
		self:_render()
		self:_fire(SequenceState.eventsBetween(segment, previous, nextTime))
		if generation ~= self.generation then return end
		self.CursorChanged:Fire(self.cursor)
	else
		self.cursor.entryTime += dt
		self:_render()
		self.CursorChanged:Fire(self.cursor)

		local entry = segment.entries[self.cursor.entryIndex or 1]
		local revealing = self.presenter.isRevealing and self.presenter:isRevealing()
		if entry and entry.skippable == false and not revealing then
			if self.dialogueWaitEntryId ~= entry.id then
				self.dialogueWaitEntryId = entry.id
				self.dialogueWaitTime = 0
			end

			self.dialogueWaitTime += dt
			if self.dialogueWaitTime >= (entry.autoAdvanceDelay or 2.5) then
				self:advance(true)
			end
		end
	end
end

function SequenceRunner:_finish()
	self:pause()
	self.ended = true
	-- Image Focus is scoped to the sequence that showed it. A manual Hide event
	-- plays the same outro; reaching the natural end does too.
	if self.presenter.hideImageFocus then self.presenter:hideImageFocus() end
	self.Finished:Fire()
end

function SequenceRunner:_moveNext(options)
	options = options or {}
	local nextCursor = SequenceState.nextCursor(self.sequence, self.cursor)

	if not nextCursor then
		self.cursor = SequenceState.normalizeCursor(self.sequence, self.cursor)
		self:_finish()
		return
	end

	self:setCursor(nextCursor, {
		fire = options.fire ~= false,
		silent = options.silent == true,
	})
end

local function nextAnchorHasPortrait(sequence, cursor)
	local nextCursor = SequenceState.nextCursor(sequence, cursor)
	local nextSegment = nextCursor and SequenceState.segmentAt(sequence, nextCursor)
	if not nextSegment then return false end

	if nextSegment.kind == "Dialogue" then
		local nextEntry = nextSegment.entries[nextCursor.entryIndex or 1]
		if not nextEntry then return false end
		if nextEntry.portrait ~= "" then return true end
		for _, event in ipairs(nextEntry.events or {}) do
			if event.type == "PortraitSet" and (tonumber(event.delay) or 0) <= 0 then
				return true
			end
		end
		return false
	end

	-- A portrait event at the start of a timed segment replaces the outgoing
	-- portrait immediately. A delayed event is not an immediate replacement.
	for _, event in ipairs(nextSegment.events or {}) do
		if event.type == "PortraitSet" and (event.time or 0) <= 0
			and (tonumber(event.delay) or 0) <= 0 then
			return true
		end
	end
	return false
end

-- Click / continue.
function SequenceRunner:advance(automatic)
	if self.advancing or not self.cursor then
		return
	end

	local segment = SequenceState.segmentAt(self.sequence, self.cursor)
	if not segment then
		return
	end

	if isInteractionBlock(segment) then
		-- The block is already paused awaiting Director. A click must not let a
		-- player bypass a scripted interaction response.
		return
	end

	if segment.kind == "Dialogue" then
		local entry = segment.entries[self.cursor.entryIndex or 1]
		if self.presenter.isRevealing and self.presenter:isRevealing() then
			-- Clicking while a line is typing is the dialogue skip mechanic. A
			-- non-skippable line must finish naturally instead of being revealed
			-- immediately by the click.
			if entry and entry.skippable == false then
				return
			end

			self.presenter:revealAll()
			return
		end

		if entry and entry.skippable == false and not automatic then
			return
		end

		local merge = nil
		local nextCursor = SequenceState.nextCursor(self.sequence, self.cursor)
		local nextSegment = nextCursor and SequenceState.segmentAt(self.sequence, nextCursor)
		if nextSegment and nextSegment.kind == "Dialogue" then
			local nextEntry = nextSegment.entries[nextCursor.entryIndex or 1]
			if nextEntry then
				merge = {
					sameSpeaker = (entry and entry.character or "") == (nextEntry.character or ""),
					fromSpeaking = entry and entry.speaking ~= false,
					toSpeaking = nextEntry.speaking ~= false,
				}
			end
		end

		local wait = 0
		if self.presenter.requestAdvance then
			wait = self.presenter:requestAdvance(merge) or 0
		end
		if not nextAnchorHasPortrait(self.sequence, self.cursor) and self.presenter.fadePortraitOut then
			wait = math.max(wait, self.presenter:fadePortraitOut() or 0)
		end

		if wait > 0 then
			self.advancing = true
			local generation = self.generation

			task.delay(wait, function()
				if generation ~= self.generation then
					return
				end
				self.advancing = false
				self:_moveNext()
			end)
			return
		end
	end

	self:_moveNext()
end

-- Skip straight to the next anchor without animations.
function SequenceRunner:skip()
	if self.cursor then
		local segment = SequenceState.segmentAt(self.sequence, self.cursor)
		if isInteractionBlock(segment) then
			return
		end
		if segment and segment.kind == "Dialogue" then
			local entry = segment.entries[self.cursor.entryIndex or 1]
			if entry and entry.skippable == false then
				return
			end
		end

		self:_moveNext()
	end
end

function SequenceRunner:destroy()
	self:stop()
	self:cancelDelayedEvents()
	self.CursorChanged:DisconnectAll()
	self.PlayingChanged:DisconnectAll()
	self.EventsFired:DisconnectAll()
	self.BlockEntered:DisconnectAll()
	self.Finished:DisconnectAll()
end

return SequenceRunner
