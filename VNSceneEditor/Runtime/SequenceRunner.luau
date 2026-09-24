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

	self.CursorChanged = Signal.new() -- (cursor)
	self.PlayingChanged = Signal.new() -- (isPlaying)
	self.EventsFired = Signal.new() -- (events)
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

function SequenceRunner:_fire(events)
	if #events == 0 then
		return
	end

	self.presenter:playEvents(events, {
		scene = self.context.scene,
		project = self.context.project,
	})

	self.EventsFired:Fire(events)
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
	self.generation += 1
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
	self.Finished:Fire()
end

function SequenceRunner:_moveNext()
	local nextCursor = SequenceState.nextCursor(self.sequence, self.cursor)

	if not nextCursor then
		self.cursor = SequenceState.normalizeCursor(self.sequence, self.cursor)
		self:_finish()
		return
	end

	self:setCursor(nextCursor, { fire = true })
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
	self.CursorChanged:DisconnectAll()
	self.PlayingChanged:DisconnectAll()
	self.EventsFired:DisconnectAll()
	self.Finished:DisconnectAll()
end

return SequenceRunner
