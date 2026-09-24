-- Pure function from (sequence, cursor, context) to a snapshot of what should
-- be on screen. No instances, no side effects; the editor scrubs by calling
-- this with a different cursor and the game plays by advancing the cursor.
--
-- Cursor:
--   { segmentIndex, time }                    inside a Timed segment
--   { segmentIndex, entryIndex, entryTime }   inside a Dialogue segment
--
-- Snapshot:
--   {
--     localTime,                       seconds on the current anchor's clock
--     background = { kind, value, poseId, from?, start, duration, easing },
--     cameraPoseId, cameraTween = { fromPoseId, start, duration, easing }?,
--     portrait = { name, imageId, transform, start, duration, hiding }?,
--     dialogue = { character, text, skippable, speaking, autoAdvanceDelay, presetId, entryTime, entryId, segmentId }?,
--     textboxPresetId, flags, music, fired = { Event }, ended
--   }
--
-- Durational events on the current anchor keep `from` + `start` so the
-- renderer can interpolate; older anchors are folded to their final value.

local Schema = require(script.Parent.Parent.Core.Schema)
local EventRegistry = require(script.Parent.Parent.Core.EventRegistry)
local Conditions = require(script.Parent.Conditions)
local Tracks = require(script.Parent.Tracks)

local SequenceState = {}

local EPSILON = 0.001

--------------------------------------------------------------------------------
-- Cursors
--------------------------------------------------------------------------------

function SequenceState.startCursor(sequence)
	local first = sequence.segments[1]

	if not first then
		return nil
	end

	if first.kind == "Dialogue" then
		return { segmentIndex = 1, entryIndex = 1, entryTime = 0 }
	end

	return { segmentIndex = 1, time = 0 }
end

function SequenceState.cursorForSegment(sequence, segmentIndex)
	local segment = sequence.segments[segmentIndex]
	if not segment then
		return nil
	end

	if segment.kind == "Dialogue" then
		return { segmentIndex = segmentIndex, entryIndex = 1, entryTime = 0 }
	end

	return { segmentIndex = segmentIndex, time = 0 }
end

function SequenceState.normalizeCursor(sequence, cursor)
	if not cursor then
		return SequenceState.startCursor(sequence)
	end

	local segmentIndex = math.clamp(cursor.segmentIndex or 1, 1, math.max(1, #sequence.segments))
	local segment = sequence.segments[segmentIndex]

	if not segment then
		return nil
	end

	if segment.kind == "Dialogue" then
		return {
			segmentIndex = segmentIndex,
			entryIndex = math.clamp(cursor.entryIndex or 1, 1, math.max(1, #segment.entries)),
			entryTime = math.max(0, cursor.entryTime or 0),
		}
	end

	return {
		segmentIndex = segmentIndex,
		time = math.clamp(cursor.time or 0, 0, segment.duration),
	}
end

function SequenceState.segmentAt(sequence, cursor)
	return cursor and sequence.segments[cursor.segmentIndex] or nil
end

function SequenceState.entryAt(sequence, cursor)
	local segment = SequenceState.segmentAt(sequence, cursor)
	if segment and segment.kind == "Dialogue" then
		return segment.entries[cursor.entryIndex]
	end
	return nil
end

-- Anchor = the timed segment or dialogue entry the cursor sits in.
function SequenceState.anchorAt(sequence, cursor)
	local segment = SequenceState.segmentAt(sequence, cursor)
	if not segment then
		return nil
	end
	if segment.kind == "Dialogue" then
		return segment.entries[cursor.entryIndex]
	end
	return segment
end

function SequenceState.localTime(cursor)
	if not cursor then
		return 0
	end
	return cursor.entryTime or cursor.time or 0
end

-- Cursor after the current anchor, or nil at the end.
function SequenceState.nextCursor(sequence, cursor)
	local segment = SequenceState.segmentAt(sequence, cursor)
	if not segment then
		return nil
	end

	if segment.kind == "Dialogue" and cursor.entryIndex < #segment.entries then
		return { segmentIndex = cursor.segmentIndex, entryIndex = cursor.entryIndex + 1, entryTime = 0 }
	end

	return SequenceState.cursorForSegment(sequence, cursor.segmentIndex + 1)
end

function SequenceState.describeCursor(sequence, cursor)
	local segment = SequenceState.segmentAt(sequence, cursor)

	if not segment then
		return "End"
	end

	if segment.kind == "Dialogue" then
		return string.format("Dialogue %d / line %d (%.1fs)", cursor.segmentIndex, cursor.entryIndex, cursor.entryTime or 0)
	end

	return string.format("Timed %d / %.2fs", cursor.segmentIndex, cursor.time or 0)
end

-- Timeline offset of a cursor for the scrubber. Dialogue entries count one
-- second each so they get visible width.
function SequenceState.segmentLength(segment)
	if segment.kind == "Dialogue" then
		return math.max(1, #segment.entries)
	end
	return segment.duration
end

function SequenceState.totalLength(sequence)
	local total = 0
	for _, segment in ipairs(sequence.segments) do
		total += SequenceState.segmentLength(segment)
	end
	return total
end

--------------------------------------------------------------------------------
-- Events crossing
--------------------------------------------------------------------------------

-- Events whose time is in (fromTime, toTime] inside a timed segment. When
-- fromTime is nil, includes events at exactly 0.
function SequenceState.eventsBetween(segment, fromTime, toTime)
	local fired = {}

	for _, event in ipairs(segment.events) do
		local after = fromTime == nil and event.time <= toTime + EPSILON or (event.time > fromTime + EPSILON and event.time <= toTime + EPSILON)
		if after then
			table.insert(fired, event)
		end
	end

	return fired
end

-- Events that belong to the anchor the cursor lands on (entry events, or
-- timed events at exactly cursor.time).
function SequenceState.eventsAtCursor(sequence, cursor)
	local segment = SequenceState.segmentAt(sequence, cursor)
	if not segment then
		return {}
	end

	if segment.kind == "Dialogue" then
		local entry = segment.entries[cursor.entryIndex]
		return entry and entry.events or {}
	end

	local fired = {}
	for _, event in ipairs(segment.events) do
		if math.abs(event.time - cursor.time) < EPSILON then
			table.insert(fired, event)
		end
	end
	return fired
end

--------------------------------------------------------------------------------
-- Snapshot
--------------------------------------------------------------------------------

local function emptySnapshot(context)
	local scene = context and context.scene
	local background = scene and scene.background or { kind = "Color", value = "40,44,72", poseId = "" }

	local cameraPoseId = ""
	if scene then
		cameraPoseId = scene.stage.cameraPoseId ~= "" and scene.stage.cameraPoseId or background.poseId or ""
	end

	local flags = {}
	if context and context.flags then
		for key, value in pairs(context.flags) do
			flags[key] = value
		end
	end

	return {
		localTime = 0,
		background = {
			kind = background.kind,
			value = background.value,
			poseId = background.poseId or "",
			from = nil,
			start = 0,
			duration = 0,
			easing = "Quad",
		},
		cameraPoseId = cameraPoseId,
		cameraTween = nil,
		portrait = nil,
		dialogue = nil,
		textboxPresetId = Schema.DEFAULT_TEXTBOX,
		flags = flags,
		_flagChapter = context and context.chapter,
		_flagScene = context and context.scene,
		_replayFlagEvents = not (context and context.flagsAreAuthoritative),
		music = nil,
		fired = {},
		ended = false,
	}
end

SequenceState.emptySnapshot = emptySnapshot

-- fold: { current = bool, start = number } describes where on the current
-- anchor's clock the event began, or current=false for an older anchor.
local function applyEvent(snapshot, event, fold)
	local params = event.params
	local durational = fold.current and EventRegistry.isDurational(event.type) and (event.duration or 0) > 0

	if event.type == "BackgroundChange" then
		local previous = snapshot.background
		snapshot.background = {
			kind = params.kind,
			value = params.value,
			poseId = params.poseId or "",
			from = durational and { kind = previous.kind, value = previous.value, poseId = previous.poseId } or nil,
			start = fold.start,
			duration = durational and event.duration or 0,
			easing = event.easing,
		}

		if params.kind == "Camera3D" and params.poseId ~= "" then
			if durational then
				snapshot.cameraTween = { fromPoseId = snapshot.cameraPoseId, start = fold.start, duration = event.duration, easing = event.easing }
			else
				snapshot.cameraTween = nil
			end
			snapshot.cameraPoseId = params.poseId
		end
	elseif event.type == "CameraMoveTo" then
		if params.poseId ~= "" then
			if durational then
				snapshot.cameraTween = { fromPoseId = snapshot.cameraPoseId, start = fold.start, duration = event.duration, easing = event.easing }
			else
				snapshot.cameraTween = nil
			end
			snapshot.cameraPoseId = params.poseId
		end
	elseif event.type == "PortraitSet" then
		local imageId = Schema.formatImageId(params.imageId)
		if imageId ~= "" then
			snapshot.portrait = {
				name = params.character or "",
				imageId = imageId,
				transform = Tracks.defaultTransform(),
				start = fold.start,
				duration = durational and event.duration or 0,
				hiding = false,
			}
		end
	elseif event.type == "PortraitHide" then
		if snapshot.portrait then
			if durational then
				snapshot.portrait.hiding = true
				snapshot.portrait.start = fold.start
				snapshot.portrait.duration = event.duration
			else
				snapshot.portrait = nil
			end
		end
	elseif event.type == "TextboxSetPreset" then
		if params.presetId ~= "" then
			snapshot.textboxPresetId = params.presetId
		end
	elseif event.type == "PlayMusic" then
		snapshot.music = {
			trackId = params.trackId,
			volume = params.volume,
			speed = params.speed,
			fade = params.fade,
		}
	elseif event.type == "StopMusic" then
		snapshot.music = nil
	elseif event.type == "FlowSetFlag" or event.type == "FlowIncrement" then
		if snapshot._replayFlagEvents then
			Conditions.applyEvent(snapshot.flags, event, snapshot._flagChapter, snapshot._flagScene)
		end
	end
	-- Sound, shake, flash, goto and end chapter are transient: the runner hands
	-- them to the presenter / director at fire time.
end

local function applyEntry(snapshot, entry, segment, fold)
	if entry.portrait ~= "" then
		snapshot.portrait = {
			name = entry.character,
			imageId = entry.portrait,
			transform = Tracks.defaultTransform(),
			start = 0,
			duration = 0,
			hiding = false,
		}
	else
		snapshot.portrait = nil
	end

	for _, event in ipairs(entry.events) do
		applyEvent(snapshot, event, fold)
	end

	if segment.textboxPresetId ~= "" then
		snapshot.textboxPresetId = segment.textboxPresetId
	end
end

local function applyTracks(snapshot, tracks, t)
	if not snapshot.portrait then
		return
	end

	local transform = Tracks.samplePortrait(tracks, t)
	if transform then
		snapshot.portrait.transform = transform
	end
end

function SequenceState.compute(sequence, cursor, context)
	local snapshot = emptySnapshot(context)
	cursor = SequenceState.normalizeCursor(sequence, cursor)

	if not cursor then
		snapshot.ended = true
		snapshot._flagChapter = nil
		snapshot._flagScene = nil
		snapshot._replayFlagEvents = nil
		return snapshot
	end

	for segmentIndex, segment in ipairs(sequence.segments) do
		local isCurrent = segmentIndex == cursor.segmentIndex

		if segmentIndex > cursor.segmentIndex then
			break
		end

		if segment.kind == "Timed" then
			local sorted = table.clone(segment.events)
			table.sort(sorted, function(a, b)
				return a.time < b.time
			end)
			local portraitBeforeSegment = snapshot.portrait
			local portraitControlledBySegment = false

			if isCurrent then
				snapshot.localTime = cursor.time
				for _, event in ipairs(sorted) do
					if event.time <= cursor.time + EPSILON then
						if event.type == "PortraitSet" or event.type == "PortraitHide" then
							portraitControlledBySegment = true
						end
						applyEvent(snapshot, event, { current = true, start = event.time })
					end
					if math.abs(event.time - cursor.time) < EPSILON then
						table.insert(snapshot.fired, event)
					end
				end
				applyTracks(snapshot, segment.tracks, cursor.time)
				snapshot.dialogue = nil

				-- Dialogue portraits belong to the line that introduced them. If
				-- the next anchor is a timed segment with no explicit portrait
				-- command, fade that portrait out at the segment boundary instead
				-- of carrying it through the whole timed section.
				local previousSegment = sequence.segments[segmentIndex - 1]
				if previousSegment
					and previousSegment.kind == "Dialogue"
					and portraitBeforeSegment
					and snapshot.portrait == portraitBeforeSegment
					and not portraitControlledBySegment
					and not snapshot.portrait.hiding then
					snapshot.portrait.hiding = true
					snapshot.portrait.start = 0
					snapshot.portrait.duration = 0.25
				end
			else
				for _, event in ipairs(sorted) do
					applyEvent(snapshot, event, { current = false, start = 0 })
				end
				applyTracks(snapshot, segment.tracks, segment.duration)
			end
		else
			local lastEntry = isCurrent and cursor.entryIndex or #segment.entries

			for entryIndex = 1, lastEntry do
				local entry = segment.entries[entryIndex]
				if entry then
					local isAnchor = isCurrent and entryIndex == cursor.entryIndex
					applyEntry(snapshot, entry, segment, { current = isAnchor, start = 0 })

					if isAnchor then
						snapshot.localTime = cursor.entryTime
						applyTracks(snapshot, entry.tracks, cursor.entryTime)
						snapshot.dialogue = {
							character = entry.character,
							text = entry.text,
							skippable = entry.skippable ~= false,
							speaking = entry.speaking ~= false,
							autoAdvanceDelay = entry.autoAdvanceDelay,
							presetId = snapshot.textboxPresetId,
							entryTime = cursor.entryTime,
							entryId = entry.id,
							segmentId = segment.id,
						}
						for _, event in ipairs(entry.events) do
							table.insert(snapshot.fired, event)
						end
					else
						applyTracks(snapshot, entry.tracks, 1e9)
					end
				end
			end
		end
	end

	-- Portrait hide that has fully elapsed on the current anchor is gone.
	if snapshot.portrait and snapshot.portrait.hiding and snapshot.localTime >= snapshot.portrait.start + snapshot.portrait.duration then
		snapshot.portrait = nil
	end

	snapshot._flagChapter = nil
	snapshot._flagScene = nil
	snapshot._replayFlagEvents = nil

	return snapshot
end

return SequenceState
