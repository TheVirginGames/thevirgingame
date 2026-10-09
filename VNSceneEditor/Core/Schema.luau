-- The project data format: factories, catalog helpers and normalizers.
--
-- Every value here is a plain string, number, boolean or table so a project
-- round trips through JSON. Roblox datatypes are never stored: colours travel
-- as "r,g,b" and camera poses as twelve comma separated CFrame components.
--
--   Project = {
--       formatVersion = 21, name, mainCharacter,
--       characters       = { { name, portraits = { imageId, ... }, priorityPortrait?, modelRef? }, ... },
--       cameraPoses      = { { id, name, cframe }, ... },
--       textboxPresets   = { TextboxPreset, ... },
--       transitionPresets= { TransitionPreset, ... },
--       portraitLayout  = { x, y, scaleX, scaleY }, -- shared portrait transform
--       exploreMovement = { sprintMultiplier, bobIntensity, bobSpeed, footstepSoundId, footstepAuto, footstepDelay, footstepStride, footstepVolume },
--       speakerSweep = { yawDegrees, sideDistance, backwardDistance, duration, easing },
--       hotspotZoom = { lookDuration, zoomInDuration, zoomOutDuration, modelFadeOutDuration, modelFadeInDuration, easing },
--       portraitTiming = { crossfadeDuration, fadeInDuration, fadeOutDuration, blackFlashEnabled, blackFlashStrength, blackFlashDuration },
--       chapters         = { Chapter, ... },
--       recycleBin       = { chapters = {}, scenes = {}, portraits = {} },
--   }
--
--   Chapter = { id, name, startSceneId, flags = { { id, kind, default } }, scenes = { Scene } }
--
--   Scene = {
--       id, name, flow = { x, y },
--       subscenes = { Subscene, ... },            -- ordered default progression
--       flags = { { id, kind, default } },           -- local to this scene
--       interactions = { Interaction },
--       characterModels = { { id, character, cframe, scope, subsceneId } },
--       next = { sceneId, transitionId },          -- Novel2D auto advance
--   }
--
--   Subscene = {
--       id, name, role = "intro" | "outro" | "custom",
--       kind = "Novel2D" | "Room3D" | "Explore3D",
--       stage = { kind, cameraPoseId }, background = { kind, value, poseId },
--       sequence = Sequence, nextTransitionId, awaitRoutes, linkPreviousRoom,
--       linkedRoomId, linkLocalInteractions, linkLocalCharacterModels,
--   }
--
--   Interaction = {
--       id, name, kind = "Hotspot", targetId, targetRef, targetCharacterModelId,
--       scope = "Local" | "Shared", subsceneId,
--       enabled = boolean,
--       responses = { { id, name, conditions, repeatPolicy, sequence } }, -- ordered variants
--       sequence = Sequence, -- unconditional fallback response
--       transitionId,                              -- enter transition (e.g. Zoom), reversed on exit
--       onComplete = { Event },
--   }
--
--   Sequence = { segments = { Segment } }
--   Segment  = { id, kind = "Timed", duration, events, tracks }
--            | { id, kind = "Dialogue", textboxPresetId, entries }
--            | { id, kind = "Interaction", interaction = InteractionSegment }
--
--   InteractionSegment = {
--       sourceInteractionId, sourceName, sourceRevision,
--       snapshot = Interaction, -- detached until explicitly refreshed
--   }
--   Entry    = { id, character, text, skippable, speaking, crossfadeNextPortrait, portrait, events, tracks }
--   Event    = { id, type, time, duration, easing, params }
--   Track    = { id, target = "portrait", keys = { { t, x, y, scale, rotation, alpha, easing } } }

local EventRegistry = require(script.Parent.EventRegistry)
local Migrate = require(script.Parent.Migrate)
local RoomAssembly = require(script.Parent.RoomAssembly)

local Schema = {}

Schema.FORMAT_VERSION = 21
Schema.pendingWarnings = {}
Schema.MIN_DURATION = 0.25
Schema.MAX_DURATION = 120
Schema.DEFAULT_DIALOGUE_AUTO_ADVANCE = 2.5
Schema.MIN_DIALOGUE_AUTO_ADVANCE = 0
Schema.MAX_DIALOGUE_AUTO_ADVANCE = 120
Schema.MIN_PORTRAIT_LAYOUT_SCALE = 0.05
Schema.MAX_PORTRAIT_LAYOUT_SCALE = 5

Schema.SCENE_KINDS = { "Novel2D", "Room3D", "Explore3D" }
Schema.BACKGROUND_KINDS = { "Color", "Image", "Camera3D" }
Schema.INTERACTION_KINDS = { "Hotspot" }
Schema.REPEAT_POLICIES = { "once", "always" }
Schema.FLAG_KINDS = { "bool", "int" }
Schema.SCENE_FLAG_PREFIX = "scene:"
Schema.CONDITION_OPS = { "==", "~=", ">", "<", ">=", "<=" }
Schema.EASINGS = { "Linear", "Quad", "Cubic", "Quart", "Sine", "Back", "Bounce", "Elastic" }
Schema.ANIM_KINDS = { "None", "Fade", "SlideUp", "SlideDown", "SlideLeft", "SlideRight", "Scale" }
Schema.TRANSITION_KINDS = { "FadeBlack", "CrossFade", "Zoom", "CameraSweep" }
Schema.TEXTBOX_ELEMENTS = { "box", "namePlate", "speaking", "body", "continueHint" }

Schema.DEFAULT_TEXTBOX = "tb_default"
Schema.DEFAULT_FADE = "tr_fadeblack"
Schema.DEFAULT_CROSSFADE = "tr_crossfade"
-- Keep the old opaque id so existing interaction references remain valid.
Schema.DEFAULT_ZOOM = "tr_npctalk"
Schema.DEFAULT_NPCTALK = Schema.DEFAULT_ZOOM -- compatibility for external code
Schema.DEFAULT_SWEEP = "tr_sweep"
Schema.DEFAULT_ROOM_EXIT = "seq_room_exit"
Schema.DEFAULT_ROOM_BLOCKED = "seq_room_blocked"
Schema.DEFAULT_EXPLORE_FOOTSTEP_SOUND = "rbxassetid://77067455211043"

local idCounter = 0

function Schema.newId(prefix)
	idCounter += 1
	return string.format("%s_%x_%d", prefix, os.time() % 0xFFFFFF, idCounter)
end

function Schema.deepCopy(value)
	if type(value) ~= "table" then
		return value
	end

	local copy = {}
	for key, inner in pairs(value) do
		copy[key] = Schema.deepCopy(inner)
	end

	return copy
end

local function asString(value, default)
	if type(value) == "string" then
		return value
	end

	if type(value) == "number" or type(value) == "boolean" then
		return tostring(value)
	end

	return default
end

local function asNumber(value, default)
	if type(value) == "number" then
		return value
	end

	if type(value) == "string" then
		local parsed = tonumber(value)
		if parsed then
			return parsed
		end
	end

	return default
end

local function asBool(value, default)
	if type(value) == "boolean" then
		return value
	end

	if value == "true" then
		return true
	end

	if value == "false" then
		return false
	end

	return default
end

local function oneOf(value, choices, default)
	local text = asString(value, default)
	return table.find(choices, text) and text or default
end

Schema.asString = asString
Schema.asNumber = asNumber
Schema.asBool = asBool

function Schema.trimName(name)
	return (asString(name, ""):match("^%s*(.-)%s*$")) or ""
end

local function looksLikeImageId(text)
	return text:match("^rbxassetid://") ~= nil
		or text:match("^rbxasset://") ~= nil
		or text:match("^https?://") ~= nil
		or text:match("^%d+$") ~= nil
end

-- Bare numbers become rbxassetid://n. Anything that is not an asset reference
-- becomes "".
function Schema.formatImageId(value)
	local text = Schema.trimName(asString(value, ""))

	if text == "" or not looksLikeImageId(text) then
		return ""
	end

	if text:match("^%d+$") then
		return "rbxassetid://" .. text
	end

	return text
end

--------------------------------------------------------------------------------
-- Camera pose strings
--------------------------------------------------------------------------------

function Schema.encodeCFrame(cframe)
	local components = { cframe:GetComponents() }
	local parts = {}

	for index, component in ipairs(components) do
		parts[index] = string.format("%.4f", component)
	end

	return table.concat(parts, ",")
end

function Schema.decodeCFrame(text)
	if type(text) ~= "string" then
		return nil
	end

	local values = {}

	for token in string.gmatch(text, "[^,]+") do
		local parsed = tonumber(token)
		if not parsed then
			return nil
		end
		table.insert(values, parsed)
	end

	if #values ~= 12 then
		return nil
	end

	return CFrame.new(table.unpack(values))
end

function Schema.encodePosition(position)
	return string.format("%.4f,%.4f,%.4f", position.X, position.Y, position.Z)
end

function Schema.decodePosition(text)
	if type(text) ~= "string" then return nil end
	local x, y, z = text:match("^%s*([%+%-]?[%d%.]+),%s*([%+%-]?[%d%.]+),%s*([%+%-]?[%d%.]+)%s*$")
	x, y, z = tonumber(x), tonumber(y), tonumber(z)
	if not x or not y or not z then return nil end
	return Vector3.new(x, y, z)
end

local function isCFrameString(text)
	return Schema.decodeCFrame(text) ~= nil
end

--------------------------------------------------------------------------------
-- Factories
--------------------------------------------------------------------------------

function Schema.newEvent(eventType, time)
	return {
		id = Schema.newId("evt"),
		type = eventType,
		time = time or 0,
		-- Delay is measured from the event's anchor. It is deliberately separate
		-- from a timed segment's duration, so delayed events never extend it.
		delay = 0,
		duration = 0,
		easing = "Quad",
		params = EventRegistry.defaultParams(eventType),
	}
end

function Schema.newKey(t, target)
	-- Portraits rest on the lower edge, while full-screen image backgrounds
	-- rest at their center. Keeping those neutral poses separate means a new
	-- background track never jumps the image before its first edit.
	return { t = t or 0, x = 0.5, y = target == "background" and 0.5 or 1, scale = 1, rotation = 0, alpha = 1, easing = "Quad" }
end

function Schema.newTrack(target)
	return {
		id = Schema.newId("trk"),
		target = target or "portrait",
		keys = { Schema.newKey(0, target) },
	}
end

function Schema.newDialogueEntry(character, text)
	return {
		id = Schema.newId("line"),
		character = character or "",
		text = text or "",
		-- Existing dialogue remains skippable unless explicitly disabled.
		skippable = true,
		-- A speaking line shows the Visualui SPEAKING badge by default. Set this
		-- false for narration or other non-speaking text.
		speaking = true,
		-- When enabled, the next distinct portrait uses the cinematic crossfade
		-- instead of starting a camera/portrait sweep.
		crossfadeNextPortrait = false,
		autoAdvanceDelay = Schema.DEFAULT_DIALOGUE_AUTO_ADVANCE,
		portrait = "",
		events = {},
		tracks = {},
	}
end

-- The raw factory deliberately has no project dependency so imports and seed
-- data can retain their authored values.  Editor-created lines use the helper
-- below to resolve the project's current defaults.
function Schema.defaultDialogueCharacter(project, previousCharacter)
	local inherited = Schema.trimName(previousCharacter)
	if inherited ~= "" then
		return inherited
	end

	return project and Schema.trimName(project.mainCharacter) or ""
end

function Schema.getCharacterPriorityPortrait(project, name)
	if type(project) ~= "table" then
		return ""
	end
	local record = Schema.findCharacter(project, name)
	if not record or record.priorityPortrait == false then
		return ""
	end

	if type(record.priorityPortrait) == "string" and table.find(record.portraits, record.priorityPortrait) then
		return record.priorityPortrait
	end

	-- Projects made before priority portraits (and records with no explicit
	-- choice) use their first portrait as the natural default.
	return record.portraits[1] or ""
end

function Schema.newProjectDialogueEntry(project, previousCharacter, text, previousPortrait)
	local character = Schema.defaultDialogueCharacter(project, previousCharacter)
	local entry = Schema.newDialogueEntry(character, text)
	entry.portrait = Schema.getCharacterPriorityPortrait(project, character)

	-- A main-character line may deliberately narrate over another character's
	-- portrait.  Carry that borrowed portrait into an added line so the visual
	-- speaker does not unexpectedly snap back to the main character's default.
	local isMainCharacter = type(project) == "table"
		and character ~= ""
		and character == Schema.trimName(project.mainCharacter)
	local isBorrowedPortrait = type(project) == "table"
		and type(previousPortrait) == "string"
		and previousPortrait ~= ""
		and not table.find(Schema.getCharacterPortraits(project, character), previousPortrait)
	if isMainCharacter and isBorrowedPortrait then
		entry.portrait = previousPortrait
	end

	return entry
end

-- Assigning a character from the editor normally applies that character's
-- priority portrait.  The main character is the deliberate exception: an
-- existing portrait is allowed to remain, which supports narration by the
-- protagonist over another character's portrait.
function Schema.assignDialogueCharacter(project, entry, character)
	local trimmed = Schema.trimName(character)
	local preservePortrait = trimmed ~= ""
		and trimmed == Schema.trimName(project and project.mainCharacter)
		and entry.portrait ~= ""

	entry.character = trimmed
	if trimmed == "" then
		entry.portrait = ""
	elseif not preservePortrait then
		entry.portrait = Schema.getCharacterPriorityPortrait(project, trimmed)
	end

	return preservePortrait
end

function Schema.newTimedSegment(duration)
	return {
		id = Schema.newId("timed"),
		kind = "Timed",
		duration = duration or 2,
		events = {},
		tracks = {},
	}
end

function Schema.newDialogueSegment(project, previousEntry)
	local previousCharacter = type(previousEntry) == "table" and previousEntry.character or ""
	return {
		id = Schema.newId("dlg"),
		kind = "Dialogue",
		textboxPresetId = "",
		entries = { Schema.newProjectDialogueEntry(project, previousCharacter, "New line.") },
	}
end

function Schema.newSequence(withDefaults, project)
	local sequence = { segments = {} }

	if withDefaults then
		table.insert(sequence.segments, Schema.newTimedSegment(1))
		table.insert(sequence.segments, Schema.newDialogueSegment(project))
	end

	return sequence
end

function Schema.newInteraction(kind)
	return {
		id = Schema.newId("int"),
		name = "New interaction",
		kind = "Hotspot",
		targetId = "",
		targetRef = nil,
		-- A placed character copy is addressed by its durable placement id rather
		-- than by a temporary clone's Workspace path.
		targetCharacterModelId = "",
		enabled = true,
		scope = "Shared",
		subsceneId = "",
		transitionId = Schema.DEFAULT_ZOOM,
		-- Conditional responses are evaluated in list order. The legacy
		-- `sequence` remains the always-available fallback so every interaction
		-- has a safe response even when no condition matches.
		responses = {},
		sequence = Schema.newSequence(false),
		onComplete = {},
	}
end

-- A timeline Interaction segment is deliberately a detached invocation of an
-- interaction, not a second live binding to it.  The source fields make that
-- relationship inspectable and refreshable; the snapshot is what will play
-- until an author explicitly refreshes it from the source.
function Schema.newInteractionSegment(sourceInteraction)
	local sourceId = type(sourceInteraction) == "table" and asString(sourceInteraction.id, "") or ""
	local sourceName = type(sourceInteraction) == "table" and asString(sourceInteraction.name, "") or ""
	local snapshot = Schema.copyInteractionSnapshot(sourceInteraction)
	Schema.reidentifyInteractionSnapshot(snapshot)

	return {
		id = Schema.newId("intseg"),
		kind = "Interaction",
		interaction = {
			sourceInteractionId = sourceId,
			sourceName = sourceName,
			sourceRevision = sourceId ~= "" and Schema.interactionRevision(sourceInteraction) or "",
			snapshot = snapshot,
		},
	}
end

-- More descriptive alias for integrations that distinguish the segment from
-- the source interaction itself.
Schema.newInteractionTimelineSegment = Schema.newInteractionSegment

function Schema.newSequencePreset(name, dialogueText, project)
	local sequence = Schema.newSequence(false)
	if dialogueText then
		local block = Schema.newDialogueSegment(project)
		block.entries[1].text = dialogueText
		block.entries[1].speaking = false
		table.insert(sequence.segments, block)
	end
	return { id = Schema.newId("seq"), name = name or "Sequence preset", sequence = sequence }
end

function Schema.newInteractionResponse(name)
	return {
		id = Schema.newId("resp"),
		name = name or "Conditional response",
		conditions = {},
		repeatPolicy = "always",
		sequence = Schema.newSequence(false),
	}
end

-- `nil`, "", and "default" all refer to the unconditional fallback kept in
-- interaction.sequence for backwards-compatible project data.
function Schema.getInteractionResponse(interaction, responseId)
	if not interaction or responseId == nil or responseId == "" or responseId == "default" then
		return nil
	end
	return Schema.findById(interaction.responses, responseId)
end

function Schema.getInteractionSequence(interaction, responseId)
	local response = Schema.getInteractionResponse(interaction, responseId)
	return response and response.sequence or (interaction and interaction.sequence) or nil
end

-- A subscene owns its environment and sequence; flags remain on the scene node.
function Schema.newSubscene(name, kind, project)
	kind = kind or "Novel2D"
	return {
		id = Schema.newId("sub"),
		name = name or "Subscene",
		role = "custom",
		kind = kind,
		stage = { kind = kind, cameraPoseId = "" },
		background = { kind = kind == "Novel2D" and "Color" or "Camera3D", value = "40,44,72", poseId = "" },
		-- An Explore3D's normal entry position and facing. Room3D exit return
		-- positions override the position for that particular arrival.
		spawnPosition = "",
		spawnCFrame = "",
		assemblyEnabled = false,
		roomDefinitionId = "",
		sequence = Schema.newSequence(false, project),
		nextTransitionId = Schema.DEFAULT_FADE,
		awaitRoutes = {},
		linkPreviousRoom = false,
		linkedRoomId = "",
		linkLocalInteractions = true,
		linkLocalCharacterModels = true,
		exiting = {
			exitable = true,
			conditions = {},
			conditionResult = true,
			destinationMode = "Auto",
			sceneId = "",
			subsceneId = "",
			returnPosition = "",
			transitionId = Schema.DEFAULT_FADE,
			exitablePresetId = Schema.DEFAULT_ROOM_EXIT,
			blockedPresetId = Schema.DEFAULT_ROOM_BLOCKED,
		},
	}
end

function Schema.subsceneIndex(scene, id)
	return Schema.findById(scene and scene.subscenes, id)
end

function Schema.subsceneView(scene, subscene)
	local view = table.clone(scene)
	view.activeSubsceneId = subscene.id
	view.stage = table.clone(subscene.stage)
	view.background = table.clone(subscene.background)
	local assemblyOwner = Schema.assemblyOwner(scene, subscene)
	view.assemblyEnabled = subscene.kind == "Room3D" and assemblyOwner.assemblyEnabled == true
	view.roomDefinitionId = assemblyOwner.roomDefinitionId or ""
	if subscene.linkPreviousRoom and Schema.isValidRoomLink(scene, subscene) then
		local previous = Schema.previousSubscene(scene, subscene.id)
		view.background = Schema.subsceneView(scene, previous).background
		local poseId = Schema.effectivePoseId(scene, subscene)
		view.stage.cameraPoseId = poseId
		view.background.poseId = poseId
	end
	return view
end

function Schema.assemblyOwner(scene, subscene)
	local current = subscene
	while current.linkPreviousRoom and Schema.isValidRoomLink(scene, current) do
		current = Schema.previousSubscene(scene, current.id)
	end
	return current
end

function Schema.previousSubscene(scene, subsceneId)
	local _, index = Schema.subsceneIndex(scene, subsceneId)
	return index and scene.subscenes[index - 1] or nil
end

function Schema.isValidRoomLink(scene, subscene)
	local previous = Schema.previousSubscene(scene, subscene.id)
	return subscene.kind == "Room3D" and previous ~= nil and previous.kind == "Room3D"
		and subscene.linkedRoomId == previous.id
end

-- Local character copies use the same linked-Room3D inheritance direction as
-- local Hotspots, but are independently configurable. This lets a linked room
-- retain its view without necessarily retaining its inhabitants.
function Schema.characterModelInSubscene(scene, subscene, placement)
	if not scene or not subscene or not placement then return false end
	if placement.scope ~= "Local" then return true end
	if placement.subsceneId == "" then return false end
	local current = subscene
	while current do
		if placement.subsceneId == current.id then return true end
		if not current.linkPreviousRoom or current.linkLocalCharacterModels ~= true
			or not Schema.isValidRoomLink(scene, current) then break end
		current = Schema.previousSubscene(scene, current.id)
	end
	return false
end

function Schema.newCharacterModelPlacement(characterName, cframeText, scope, subsceneId)
	return {
		id = Schema.newId("charModel"),
		character = Schema.trimName(characterName),
		cframe = cframeText or Schema.encodeCFrame(CFrame.new()),
		scope = oneOf(scope, { "Local", "Shared" }, "Local"),
		subsceneId = asString(subsceneId, ""),
	}
end

function Schema.findCharacterModel(scene, placementId)
	return scene and Schema.findById(scene.characterModels, placementId) or nil
end

function Schema.characterModelForInteraction(scene, interaction)
	return interaction and Schema.findCharacterModel(scene, interaction.targetCharacterModelId) or nil
end

-- Merge is a property of a concrete source → destination transition. The
-- destination must be the immediately following Room3D and be permanently
-- linked back to that exact source; merely having two Room3Ds in a scene is
-- never enough.
function Schema.isValidMergeBetween(scene, source, destination)
	if type(source) == "string" then source = Schema.subsceneIndex(scene, source) end
	if type(destination) == "string" then destination = Schema.subsceneIndex(scene, destination) end
	if not source or not destination or source.kind ~= "Room3D" or destination.kind ~= "Room3D" then
		return false
	end
	local previous = Schema.previousSubscene(scene, destination.id)
	return destination.linkPreviousRoom == true
		and destination.linkedRoomId == source.id
		and previous ~= nil and previous.id == source.id
end

function Schema.isValidMerge(scene, subscene)
	local _, index = Schema.subsceneIndex(scene, subscene and subscene.id)
	return index ~= nil and Schema.isValidMergeBetween(scene, subscene, scene.subscenes[index + 1])
end

function Schema.defaultSubsceneTransition(scene, source, destinationId)
	return Schema.isValidMergeBetween(scene, source, destinationId) and "Merge" or Schema.DEFAULT_FADE
end

-- Enter is intentionally not a project-wide transition preset. It only makes
-- sense for a Go To event authored inside a Hotspot's sequence, where the
-- runtime has a concrete world target to move toward. Interaction completion
-- events are outside that sequence and therefore do not qualify.
function Schema.canUseEnterTransition(interaction, anchorKind)
	return interaction ~= nil and interaction.kind == "Hotspot"
		and (anchorKind == "Timed" or anchorKind == "Dialogue")
end

function Schema.defaultGotoSceneTransition(interaction, anchorKind)
	return Schema.canUseEnterTransition(interaction, anchorKind) and "Enter" or Schema.DEFAULT_FADE
end

function Schema.defaultGotoSubsceneTransition(scene, source, destinationId, interaction, anchorKind)
	if Schema.canUseEnterTransition(interaction, anchorKind) then
		return "Enter"
	end
	return Schema.defaultSubsceneTransition(scene, source, destinationId)
end

-- Empty linear sequences do not create a visible or interactive state, so
-- automatic Novel2D progression skips them. A 3D subscene remains meaningful
-- even with an empty sequence because it can enter AWAIT with its environment,
-- routes, and interactions active.
function Schema.nextAutomaticSubscene(scene, source)
	if type(source) == "string" then source = Schema.subsceneIndex(scene, source) end
	local _, index = Schema.subsceneIndex(scene, source and source.id)
	if not index then return nil end
	for candidateIndex = index + 1, #(scene.subscenes or {}) do
		local candidate = scene.subscenes[candidateIndex]
		if candidate.kind ~= "Novel2D" or #candidate.sequence.segments > 0 then
			return candidate, candidateIndex
		end
	end
	return nil
end

function Schema.effectivePoseId(scene, subscene)
	-- Explore3D camera ownership belongs to the player. Its spawn transform is
	-- the sole entry location, never a reusable fixed camera-pose preset.
	if subscene and subscene.kind == "Explore3D" then
		return ""
	end
	local previous = Schema.previousSubscene(scene, subscene.id)
	if subscene.linkPreviousRoom and previous and Schema.isValidRoomLink(scene, subscene) then
		return Schema.effectivePoseId(scene, previous)
	end
	return subscene.stage.cameraPoseId ~= "" and subscene.stage.cameraPoseId or subscene.background.poseId
end

function Schema.interactionInSubscene(scene, subscene, interaction)
	if interaction.scope ~= "Local" then return true end
	if interaction.subsceneId == "" then return false end
	local current = subscene
	while current do
		if interaction.subsceneId == current.id then return true end
		if not current.linkPreviousRoom or current.linkLocalInteractions ~= true
			or not Schema.isValidRoomLink(scene, current) then break end
		current = Schema.previousSubscene(scene, current.id)
	end
	return false
end

-- Repair structural edits in one place so saved data never keeps a broken
-- contextual transition or dangling subscene reference.
function Schema.reconcileSubscenes(scene)
	local warnings = {}
	for _, subscene in ipairs(scene.subscenes or {}) do
		if subscene.linkPreviousRoom and not Schema.isValidRoomLink(scene, subscene) then
			subscene.linkPreviousRoom = false
			subscene.linkedRoomId = ""
			table.insert(warnings, subscene.name .. " lost its Room3D link after the sequence order or kind changed.")
		end
	end
	for _, subscene in ipairs(scene.subscenes or {}) do
		local exiting = subscene.exiting
		if exiting and exiting.destinationMode == "Manual"
			and (exiting.sceneId == "" or exiting.sceneId == scene.id)
			and exiting.subsceneId ~= "" and not Schema.subsceneIndex(scene, exiting.subsceneId) then
			exiting.subsceneId = ""
			exiting.returnPosition = ""
			table.insert(warnings, subscene.name .. " had a missing Room3D exit destination; destination cleared.")
		end
		for _, route in ipairs(subscene.awaitRoutes or {}) do
			if route.toSubsceneId ~= "" and (route.toSubsceneId == subscene.id
				or not Schema.subsceneIndex(scene, route.toSubsceneId)) then
				route.toSubsceneId = ""
				table.insert(warnings, subscene.name .. " had an invalid conditional route; destination cleared.")
			end
			if route.transitionId == "Merge" and not Schema.isValidMergeBetween(scene, subscene, route.toSubsceneId) then
				route.transitionId = Schema.DEFAULT_FADE
				table.insert(warnings, subscene.name .. " had an incompatible Merge route; changed to Fade to Black.")
			elseif route.transitionExplicit ~= true
				and Schema.isValidMergeBetween(scene, subscene, route.toSubsceneId) then
				route.transitionId = "Merge"
			end
		end
		if subscene.nextTransitionId == "Merge" and not Schema.isValidMerge(scene, subscene) then
			subscene.nextTransitionId = Schema.DEFAULT_FADE
			table.insert(warnings, subscene.name .. " used an incompatible Merge; changed to Fade to Black.")
		end
	end
	for _, interaction in ipairs(scene.interactions or {}) do
		if interaction.scope == "Local" and interaction.subsceneId ~= "" and not Schema.subsceneIndex(scene, interaction.subsceneId) then
			interaction.subsceneId = ""
			table.insert(warnings, interaction.name .. " referred to a missing subscene and is disabled until reassigned.")
		end
	end
	local removedCharacterModels = {}
	for index = #(scene.characterModels or {}), 1, -1 do
		local placement = scene.characterModels[index]
		if placement.scope == "Local" and (placement.subsceneId == "" or not Schema.subsceneIndex(scene, placement.subsceneId)) then
			removedCharacterModels[placement.id] = true
			table.remove(scene.characterModels, index)
			table.insert(warnings, "A local 3D character model lost its owning subscene and was removed.")
		end
	end
	if next(removedCharacterModels) then
		for _, interaction in ipairs(scene.interactions or {}) do
			if removedCharacterModels[interaction.targetCharacterModelId] then
				interaction.targetCharacterModelId = ""
			end
		end
	end
	Schema.forEachEventList(scene, function(events, owner, anchor)
		local source = nil
		local interaction = nil
		if owner.owner == "subscene" then
			source = Schema.subsceneIndex(scene, owner.subsceneId)
		elseif owner.owner == "interaction" then
			interaction = Schema.findInteraction(scene, owner.interactionId)
			if interaction and interaction.scope == "Local" then
				source = Schema.subsceneIndex(scene, interaction.subsceneId)
			end
		elseif owner.owner == "timelineInteraction" then
			-- The block runs in its host subscene, but uses its detached snapshot
			-- for Hotspot-only transition validation (not the possibly changed or
			-- deleted source interaction).
			interaction = owner.interaction
			source = Schema.subsceneIndex(scene, owner.subsceneId)
		end
		for _, event in ipairs(events) do
			if event.type == "FlowGotoSubscene" and event.params.subsceneId ~= ""
				and not Schema.subsceneIndex(scene, event.params.subsceneId) then
				event.params.subsceneId = ""
				table.insert(warnings, "A Go to Subscene event had a missing destination; destination cleared.")
			end
			local isGotoEvent = event.type == "FlowGotoSubscene" or event.type == "FlowGoto"
			local canEnter = isGotoEvent
				and Schema.canUseEnterTransition(interaction, anchor and anchor.kind)
			if isGotoEvent and event.params.transitionId == "Enter" and not canEnter then
				event.params.transitionId = Schema.DEFAULT_FADE
				table.insert(warnings, "A Go To event used Enter outside a Hotspot sequence; changed to Fade to Black.")
			elseif event.type == "FlowGotoSubscene" and event.params.transitionId == "Merge"
				and not Schema.isValidMergeBetween(scene, source, event.params.subsceneId) then
				event.params.transitionId = Schema.DEFAULT_FADE
				table.insert(warnings, "A Go to Subscene event had an incompatible Merge; changed to Fade to Black.")
			elseif event.type == "FlowGotoSubscene" and event.transitionExplicit ~= true then
				local defaultTransition = Schema.defaultGotoSubsceneTransition(
					scene,
					source,
					event.params.subsceneId,
					interaction,
					anchor and anchor.kind
				)
				local currentTransition = event.params.transitionId
				if currentTransition == "" or currentTransition == Schema.DEFAULT_FADE
					or currentTransition == "Merge" or currentTransition == "Enter" then
					event.params.transitionId = defaultTransition
				else
					-- Older projects predate transitionExplicit. Preserve a custom
					-- preset as an intentional choice instead of replacing it.
					event.transitionExplicit = true
				end
			elseif event.type == "FlowGoto" and event.transitionExplicit ~= true then
				local currentTransition = event.params.transitionId
				if currentTransition == "" or currentTransition == Schema.DEFAULT_FADE or currentTransition == "Enter" then
					event.params.transitionId = Schema.defaultGotoSceneTransition(interaction, anchor and anchor.kind)
				else
					event.transitionExplicit = true
				end
			end
		end
	end)
	if #warnings > 0 then
		local pending = Schema.pendingWarnings[scene.id] or {}
		for _, warning in ipairs(warnings) do table.insert(pending, warning) end
		Schema.pendingWarnings[scene.id] = pending
	end
	return warnings
end

function Schema.takeWarnings(sceneId)
	local warnings = Schema.pendingWarnings[sceneId] or {}
	Schema.pendingWarnings[sceneId] = nil
	return warnings
end

function Schema.ensureSubscenes(scene)
	if type(scene.subscenes) == "table" and #scene.subscenes > 0 then
		return scene.subscenes
	end
	local intro = Schema.newSubscene("Intro", scene.stage.kind)
	intro.role = "intro"
	intro.stage = Schema.deepCopy(scene.stage)
	intro.background = Schema.deepCopy(scene.background)
	intro.sequence = scene.intro
	intro.nextTransitionId = "" -- Existing Intro → Outro playback had no transition.
	local outro = Schema.newSubscene("Outro", scene.stage.kind)
	outro.role = "outro"
	outro.stage = Schema.deepCopy(scene.stage)
	outro.background = Schema.deepCopy(scene.background)
	outro.sequence = scene.outro
	scene.subscenes = { intro, outro }
	return scene.subscenes
end

function Schema.newFlag(id, kind)
	return { id = id or "flag", kind = kind or "bool", default = kind == "int" and 0 or false }
end

function Schema.newScene(name, kind, project)
	kind = kind or "Novel2D"

	return {
		id = Schema.newId("scene"),
		name = name or "New Scene",
		flow = { x = 80, y = 80 },
		stage = { kind = kind, cameraPoseId = "" },
		background = {
			kind = kind == "Novel2D" and "Color" or "Camera3D",
			value = "40,44,72",
			poseId = "",
		},
		intro = Schema.newSequence(kind == "Novel2D", project),
		outro = Schema.newSequence(false),
		flags = {},
		interactions = {},
		characterModels = {},
		next = { sceneId = "", transitionId = Schema.DEFAULT_FADE },
	}
end

function Schema.newChapter(name, project)
	local scene = Schema.newScene("Opening", "Novel2D", project)

	return {
		id = Schema.newId("chapter"),
		name = name or "New Chapter",
		startSceneId = scene.id,
		flags = {},
		scenes = { scene },
	}
end

function Schema.newCameraPose(name, cframeText)
	return {
		id = Schema.newId("pose"),
		name = name or "Camera pose",
		cframe = cframeText or Schema.encodeCFrame(CFrame.new(0, 10, 20)),
	}
end

function Schema.newAnim(inKind, outKind, duration)
	return {
		inKind = inKind or "Fade",
		outKind = outKind or "Fade",
		duration = duration or 0.25,
		easing = "Quad",
		delay = 0,
	}
end

function Schema.newTextboxPreset(name)
	return {
		id = Schema.newId("tb"),
		name = name or "Textbox style",
		typewriterCps = 40,
		typeSoundId = "",
		elements = {
			box = Schema.newAnim("SlideUp", "Fade", 0.3),
			namePlate = Schema.newAnim("SlideLeft", "Fade", 0.25),
			-- The SPEAKING badge shares the top-bar entrance by default, while
			-- remaining independently configurable in the Textbox Styles editor.
			speaking = Schema.newAnim("SlideLeft", "Fade", 0.25),
			body = Schema.newAnim("Fade", "Fade", 0.2),
			continueHint = Schema.newAnim("Fade", "None", 0.4),
		},
	}
end

local function isLegacyZoomName(name)
	return type(name) == "string" and name:lower():gsub("[%s_%-]", "") == "npctalk"
end

function Schema.newTransitionPreset(name, kind)
	kind = kind or "FadeBlack"
	if kind == "NpcTalk" then
		kind = "Zoom"
		if isLegacyZoomName(name) then name = "Zoom" end
	end

	local params = {}

	if kind == "FadeBlack" then
		params = { fadeOut = 0.5, hold = 0.2, fadeIn = 0.5 }
	elseif kind == "CrossFade" then
		params = { duration = 0.8 }
	elseif kind == "Zoom" then
		params = { duration = 0.6, easing = "Sine" }
	elseif kind == "CameraSweep" then
		params = { duration = 1.2 }
	end

	return {
		id = Schema.newId("tr"),
		name = name or kind,
		kind = kind,
		params = params,
	}
end

function Schema.emptyRecycleBin()
	return { chapters = {}, scenes = {}, portraits = {} }
end

-- Portrait tracks are still authored per line. This is the shared resting
-- placement applied underneath those track offsets, so every portrait can be
-- repositioned and resized without rewriting scene data.
function Schema.newPortraitLayout()
	return {
		x = 0.5,
		y = 1,
		scaleX = 1,
		scaleY = 1,
	}
end

function Schema.normalizePortraitLayout(raw)
	raw = type(raw) == "table" and raw or {}

	return {
		x = math.clamp(asNumber(raw.x, 0.5), -1, 2),
		y = math.clamp(asNumber(raw.y, 1), -1, 2),
		scaleX = math.clamp(
			asNumber(raw.scaleX, asNumber(raw.scale, 1)),
			Schema.MIN_PORTRAIT_LAYOUT_SCALE,
			Schema.MAX_PORTRAIT_LAYOUT_SCALE
		),
		scaleY = math.clamp(
			asNumber(raw.scaleY, asNumber(raw.scale, 1)),
			Schema.MIN_PORTRAIT_LAYOUT_SCALE,
			Schema.MAX_PORTRAIT_LAYOUT_SCALE
		),
	}
end

-- Project-wide Explore3D feel. These are intentionally a compact set of
-- author-facing controls rather than a physics replacement: sprint pace,
-- first-person bob, and the cadence/volume/asset of the single footstep SFX.
function Schema.newExploreMovementSettings()
	return {
		sprintMultiplier = 1.65,
		bobIntensity = 0.085,
		bobSpeed = 0.72,
		footstepSoundId = Schema.DEFAULT_EXPLORE_FOOTSTEP_SOUND,
		-- Auto cadence follows the camera's bob half-cycles. Manual spacing stays
		-- available for projects that prefer a fixed distance cadence.
		footstepAuto = true,
		footstepDelay = 0,
		footstepStride = 3.2,
		footstepVolume = 0.45,
	}
end

function Schema.normalizeExploreMovementSettings(raw)
	raw = type(raw) == "table" and raw or {}
	local defaults = Schema.newExploreMovementSettings()
	local soundId = Schema.formatImageId(asString(raw.footstepSoundId, defaults.footstepSoundId))
	return {
		sprintMultiplier = math.clamp(asNumber(raw.sprintMultiplier, defaults.sprintMultiplier), 1, 4),
		bobIntensity = math.clamp(asNumber(raw.bobIntensity, defaults.bobIntensity), 0, 0.35),
		bobSpeed = math.clamp(asNumber(raw.bobSpeed, defaults.bobSpeed), 0.1, 3),
		footstepSoundId = soundId ~= "" and soundId or defaults.footstepSoundId,
		footstepAuto = asBool(raw.footstepAuto, defaults.footstepAuto),
		footstepDelay = math.clamp(asNumber(raw.footstepDelay, defaults.footstepDelay), -1, 2),
		footstepStride = math.clamp(asNumber(raw.footstepStride, defaults.footstepStride), 0.5, 12),
		footstepVolume = math.clamp(asNumber(raw.footstepVolume, defaults.footstepVolume), 0, 2),
	}
end

-- Camera-backed dialogue uses this shared, authored feel in both Room3D and
-- Explore3D.  Explore3D still invents its speaker sides; these values only
-- control how far and how sharply each resulting handoff moves.
function Schema.newSpeakerSweepSettings()
	return {
		yawDegrees = 18,
		sideDistance = 1.5,
		backwardDistance = 0.88,
		duration = 0.38,
		easing = "Quad",
	}
end

function Schema.normalizeSpeakerSweepSettings(raw)
	raw = type(raw) == "table" and raw or {}
	local defaults = Schema.newSpeakerSweepSettings()
	-- `movementScale` was the short-lived first version of this setting. Keep
	-- existing projects visually close while promoting them to direct distances.
	local legacyScale = math.clamp(asNumber(raw.movementScale, 1.25), 0.25, 3)
	local easing = asString(raw.easing, defaults.easing)
	if not table.find(Schema.EASINGS, easing) then easing = defaults.easing end
	return {
		yawDegrees = math.clamp(asNumber(raw.yawDegrees, defaults.yawDegrees), 0, 90),
		sideDistance = math.clamp(asNumber(raw.sideDistance, 1.2 * legacyScale), 0, 20),
		backwardDistance = math.clamp(asNumber(raw.backwardDistance, 0.7 * legacyScale), 0, 20),
		duration = math.clamp(asNumber(raw.duration, defaults.duration), 0.05, 2.5),
		easing = easing,
	}
end

-- Hotspot Zoom is deliberately project-wide: an interaction transition should
-- feel identical no matter which response or scene happens to invoke it.
function Schema.newHotspotZoomSettings()
	return {
		lookDuration = 0.2,
		zoomInDuration = 0.6,
		zoomOutDuration = 0.6,
		modelFadeOutDuration = 0.6,
		modelFadeInDuration = 0.6,
		easing = "Sine",
	}
end

function Schema.normalizeHotspotZoomSettings(raw)
	raw = type(raw) == "table" and raw or {}
	local defaults = Schema.newHotspotZoomSettings()
	local easing = asString(raw.easing, defaults.easing)
	if not table.find(Schema.EASINGS, easing) then easing = defaults.easing end
	return {
		lookDuration = math.clamp(asNumber(raw.lookDuration, defaults.lookDuration), 0, 3),
		zoomInDuration = math.clamp(asNumber(raw.zoomInDuration, defaults.zoomInDuration), 0.05, 5),
		zoomOutDuration = math.clamp(asNumber(raw.zoomOutDuration, defaults.zoomOutDuration), 0.05, 5),
		modelFadeOutDuration = math.clamp(asNumber(raw.modelFadeOutDuration, defaults.modelFadeOutDuration), 0, 5),
		modelFadeInDuration = math.clamp(asNumber(raw.modelFadeInDuration, defaults.modelFadeInDuration), 0, 5),
		easing = easing,
	}
end

-- Portrait changes can be authored independently from textbox animations, so
-- keep their shared visual rhythm in the same System preset category.
function Schema.newPortraitTimingSettings()
	return {
		crossfadeDuration = 0.2,
		fadeInDuration = 0.2,
		fadeOutDuration = 0.2,
		-- This is used only by a dialogue line that explicitly requests a
		-- portrait crossfade. The incoming portrait begins dark, then regains
		-- its authored colour while the two portraits overlap.
		blackFlashEnabled = true,
		blackFlashStrength = 1,
		blackFlashDuration = 0.28,
	}
end

function Schema.normalizePortraitTimingSettings(raw)
	raw = type(raw) == "table" and raw or {}
	local defaults = Schema.newPortraitTimingSettings()
	return {
		crossfadeDuration = math.clamp(asNumber(raw.crossfadeDuration, defaults.crossfadeDuration), 0.05, 3),
		fadeInDuration = math.clamp(asNumber(raw.fadeInDuration, defaults.fadeInDuration), 0.05, 3),
		fadeOutDuration = math.clamp(asNumber(raw.fadeOutDuration, defaults.fadeOutDuration), 0.05, 3),
		blackFlashEnabled = raw.blackFlashEnabled ~= false,
		blackFlashStrength = math.clamp(asNumber(raw.blackFlashStrength, defaults.blackFlashStrength), 0, 1),
		blackFlashDuration = math.clamp(asNumber(raw.blackFlashDuration, defaults.blackFlashDuration), 0.05, 3),
	}
end

function Schema.newProject(name)
	local project = {
		formatVersion = Schema.FORMAT_VERSION,
		name = name or "VN Project",
		mainCharacter = "",
		characters = {},
		cameraPoses = {},
		textboxPresets = {},
		transitionPresets = {},
		sequencePresets = {},
		roomDefinitions = {},
		assemblyPresets = {},
		portraitLayout = Schema.newPortraitLayout(),
		exploreMovement = Schema.newExploreMovementSettings(),
		speakerSweep = Schema.newSpeakerSweepSettings(),
		hotspotZoom = Schema.newHotspotZoomSettings(),
		portraitTiming = Schema.newPortraitTimingSettings(),
		chapters = {},
		recycleBin = Schema.emptyRecycleBin(),
	}

	Schema.ensureDefaults(project)
	return project
end

-- Default presets referenced by factories. Idempotent.
function Schema.ensureDefaults(project)
	project.textboxPresets = project.textboxPresets or {}
	project.transitionPresets = project.transitionPresets or {}
	project.sequencePresets = project.sequencePresets or {}
	project.roomDefinitions = project.roomDefinitions or {}
	project.assemblyPresets = project.assemblyPresets or {}
	project.cameraPoses = project.cameraPoses or {}
	project.characters = project.characters or {}
	for _, record in ipairs(project.characters) do
		record.name = Schema.trimName(record.name)
		record.portraits = type(record.portraits) == "table" and record.portraits or {}
		-- A source-model reference is optional. Do not resolve it here: templates
		-- can legitimately be unavailable outside a Studio play session.
		if record.modelRef ~= nil and type(record.modelRef) ~= "table" then record.modelRef = nil end
		if record.priorityPortrait ~= false and (
			type(record.priorityPortrait) ~= "string" or not table.find(record.portraits, record.priorityPortrait)
		) then
			-- nil means automatic first-portrait priority.  It also safely repairs
			-- a priority image that was removed by an older project version.
			record.priorityPortrait = nil
		end
	end
	project.mainCharacter = Schema.trimName(project.mainCharacter)
	if project.mainCharacter ~= "" and not Schema.findCharacter(project, project.mainCharacter) then
		project.mainCharacter = ""
	end
	project.portraitLayout = Schema.normalizePortraitLayout(project.portraitLayout)
	project.exploreMovement = Schema.normalizeExploreMovementSettings(project.exploreMovement)
	project.speakerSweep = Schema.normalizeSpeakerSweepSettings(project.speakerSweep)
	project.hotspotZoom = Schema.normalizeHotspotZoomSettings(project.hotspotZoom)
	project.portraitTiming = Schema.normalizePortraitTimingSettings(project.portraitTiming)
	project.chapters = project.chapters or {}
	project.recycleBin = project.recycleBin or Schema.emptyRecycleBin()
	-- Projects already resident in memory do not pass through normalizeProject.
	-- Reconcile retired enum values here too, including scenes restored from the
	-- recycle bin later in the session.
	local function reconcileLegacyScene(scene)
		for _, interaction in ipairs(scene.interactions or {}) do
			if interaction.kind == "Exit" then
				local destination = interaction.exit or {}
				if destination.sceneId and destination.sceneId ~= "" then
					local goto = Schema.newEvent("FlowGoto", 0)
					goto.params.sceneId = destination.sceneId
					goto.params.transitionId = destination.transitionId or Schema.DEFAULT_FADE
					interaction.onComplete = interaction.onComplete or {}
					table.insert(interaction.onComplete, goto)
				end
				interaction.exit = nil
			end
			if not table.find(Schema.INTERACTION_KINDS, interaction.kind) then
				interaction.kind = "Hotspot"
			end
			interaction.targetCharacterModelId = asString(interaction.targetCharacterModelId, "")
			interaction.enabled = asBool(interaction.enabled, true)
			-- A placed copy is recreated per active subscene, so it must never
			-- compete with a regular Workspace target left over from older data.
			if interaction.targetCharacterModelId ~= "" then
				interaction.targetId = ""
				interaction.targetRef = nil
			end
			interaction.responses = type(interaction.responses) == "table" and interaction.responses or {}
			interaction.sequence = type(interaction.sequence) == "table" and interaction.sequence or Schema.newSequence(false)
			for index = #interaction.responses, 1, -1 do
				local response = interaction.responses[index]
				if type(response) ~= "table" or type(response.sequence) ~= "table"
					or type(response.conditions) ~= "table" or #response.conditions == 0 then
					table.remove(interaction.responses, index)
				else
					response.id = asString(response.id, Schema.newId("resp"))
					local name = Schema.trimName(asString(response.name, ""))
					response.name = name ~= "" and name or "Conditional response"
					response.repeatPolicy = oneOf(response.repeatPolicy, Schema.REPEAT_POLICIES, "always")
				end
			end
		end
		Schema.ensureSubscenes(scene)
		scene.characterModels = type(scene.characterModels) == "table" and scene.characterModels or {}
		for _, subscene in ipairs(scene.subscenes) do
			if type(subscene.exiting) ~= "table" then subscene.exiting = Schema.newSubscene("", subscene.kind).exiting end
			if not Schema.decodePosition(subscene.spawnPosition) then subscene.spawnPosition = "" end
			if not Schema.decodeCFrame(subscene.spawnCFrame) then subscene.spawnCFrame = "" end
			if subscene.kind == "Explore3D" then
				subscene.stage.cameraPoseId = ""
				subscene.background.poseId = ""
			end
			subscene.linkLocalCharacterModels = asBool(subscene.linkLocalCharacterModels, true)
		end
		Schema.reconcileSubscenes(scene)
	end
	for _, chapter in ipairs(project.chapters) do
		for _, scene in ipairs(chapter.scenes or {}) do
			reconcileLegacyScene(scene)
		end
	end
	for _, item in ipairs(project.recycleBin.chapters or {}) do
		for _, scene in ipairs(item.chapter and item.chapter.scenes or {}) do reconcileLegacyScene(scene) end
	end
	for _, item in ipairs(project.recycleBin.scenes or {}) do
		if item.scene then reconcileLegacyScene(item.scene) end
	end

	for _, preset in ipairs(project.transitionPresets) do
		local legacyKind = preset.kind == "NpcTalk"
		if legacyKind then preset.kind = "Zoom" end
		if (preset.id == Schema.DEFAULT_ZOOM or legacyKind) and isLegacyZoomName(preset.name) then
			preset.name = "Zoom"
		end
		if preset.kind == "Zoom" then
			preset.params = type(preset.params) == "table" and preset.params or {}
			preset.params.duration = math.max(0, asNumber(preset.params.duration, 0.6))
			preset.params.easing = oneOf(preset.params.easing, Schema.EASINGS, "Sine")
			preset.params.portraitFade = nil
		end
	end
	if not Schema.findById(project.sequencePresets, Schema.DEFAULT_ROOM_EXIT) then
		local preset = Schema.newSequencePreset("Exitable Room Exit", "Leave the room?")
		preset.id = Schema.DEFAULT_ROOM_EXIT
		table.insert(project.sequencePresets, 1, preset)
	end
	if not Schema.findById(project.sequencePresets, Schema.DEFAULT_ROOM_BLOCKED) then
		local preset = Schema.newSequencePreset("Non-Exitable Room Exit", "I should probably check everything out first...")
		preset.id = Schema.DEFAULT_ROOM_BLOCKED
		table.insert(project.sequencePresets, 2, preset)
	end

	if not Schema.findById(project.textboxPresets, Schema.DEFAULT_TEXTBOX) then
		local preset = Schema.newTextboxPreset("Default")
		preset.id = Schema.DEFAULT_TEXTBOX
		table.insert(project.textboxPresets, 1, preset)
	end

	local defaults = {
		{ Schema.DEFAULT_FADE, "Fade to black", "FadeBlack" },
		{ Schema.DEFAULT_CROSSFADE, "Cross fade", "CrossFade" },
		{ Schema.DEFAULT_ZOOM, "Zoom", "Zoom" },
		{ Schema.DEFAULT_SWEEP, "Camera sweep", "CameraSweep" },
	}

	for _, entry in ipairs(defaults) do
		if not Schema.findById(project.transitionPresets, entry[1]) then
			local preset = Schema.newTransitionPreset(entry[2], entry[3])
			preset.id = entry[1]
			table.insert(project.transitionPresets, preset)
		end
	end
end

--------------------------------------------------------------------------------
-- Lookups
--------------------------------------------------------------------------------

function Schema.findById(list, id)
	if type(list) ~= "table" or id == nil or id == "" then
		return nil
	end

	for index, item in ipairs(list) do
		if item.id == id then
			return item, index
		end
	end

	return nil
end

function Schema.findChapter(project, chapterId)
	return Schema.findById(project.chapters, chapterId)
end

function Schema.findScene(chapter, sceneId)
	-- Keep both values returned by findById: callers that edit the scene list
	-- need the matching array index as well as the scene itself.  Using `and` /
	-- `or` here collapses the multiple return values, leaving that index nil.
	if not chapter then
		return nil
	end

	return Schema.findById(chapter.scenes, sceneId)
end

function Schema.findFlag(chapter, flagId)
	if not chapter then
		return nil
	end

	for _, flag in ipairs(chapter.flags or {}) do
		if flag.id == flagId then
			return flag
		end
	end

	return nil
end

function Schema.findSceneFlag(scene, flagId)
	if not scene then
		return nil
	end

	return Schema.findById(scene.flags or {}, flagId)
end

function Schema.sceneFlagRef(flagId)
	return Schema.SCENE_FLAG_PREFIX .. tostring(flagId or "")
end

function Schema.isSceneFlagRef(flagRef)
	return type(flagRef) == "string" and flagRef:sub(1, #Schema.SCENE_FLAG_PREFIX) == Schema.SCENE_FLAG_PREFIX
end

function Schema.flagIdFromRef(flagRef)
	if Schema.isSceneFlagRef(flagRef) then
		return flagRef:sub(#Schema.SCENE_FLAG_PREFIX + 1)
	end
	return flagRef
end

-- Existing unqualified references remain chapter flags for backwards
-- compatibility. Scene-local references are explicitly namespaced so a scene
-- flag may safely share a human-readable name with a chapter flag.
function Schema.resolveFlag(chapter, scene, flagRef)
	-- Exact chapter ids win so a legacy project that happened to use the now
	-- reserved prefix keeps its original meaning.
	local chapterFlag = Schema.findFlag(chapter, flagRef)
	if chapterFlag then
		return chapterFlag, "chapter", flagRef
	end

	if Schema.isSceneFlagRef(flagRef) then
		local flagId = Schema.flagIdFromRef(flagRef)
		return Schema.findSceneFlag(scene, flagId), "scene", flagId
	end

	return nil, "chapter", flagRef
end

function Schema.displayFlagRef(flagRef)
	if Schema.isSceneFlagRef(flagRef) then
		return "scene." .. tostring(Schema.flagIdFromRef(flagRef))
	end
	return tostring(flagRef or "")
end

function Schema.findCameraPose(project, poseId)
	return Schema.findById(project.cameraPoses, poseId)
end

function Schema.findTextboxPreset(project, presetId)
	return Schema.findById(project.textboxPresets, presetId) or Schema.findById(project.textboxPresets, Schema.DEFAULT_TEXTBOX)
end

function Schema.findTransition(project, transitionId)
	return Schema.findById(project.transitionPresets, transitionId)
end

function Schema.findSequencePreset(project, presetId)
	return project and Schema.findById(project.sequencePresets, presetId) or nil
end

function Schema.findInteraction(scene, interactionId)
	return scene and Schema.findById(scene.interactions, interactionId) or nil
end

function Schema.defaultFlags(chapter)
	return Schema.normalizeFlagState(chapter, nil)
end

function Schema.defaultSceneFlags(scene)
	local state = {}
	for _, flag in ipairs(scene and scene.flags or {}) do
		state[Schema.sceneFlagRef(flag.id)] = Schema.coerceFlagValue(flag, flag.default)
	end
	return state
end

-- Coerce every runtime value through its flag definition. This prevents a
-- boolean flag from becoming the string "false", fills newly-added flags from
-- their defaults, and drops stale values for definitions that were removed.
function Schema.coerceFlagValue(flag, value)
	if not flag then
		return nil
	end

	if flag.kind == "int" then
		return asNumber(value, asNumber(flag.default, 0))
	end

	if type(value) == "string" then
		local lowered = Schema.trimName(value):lower()
		if lowered == "true" or lowered == "1" then
			return true
		elseif lowered == "false" or lowered == "0" then
			return false
		end
	elseif type(value) == "number" then
		return value ~= 0
	end

	return asBool(value, flag.default == true)
end

function Schema.normalizeFlagState(chapter, values)
	local state = {}
	values = type(values) == "table" and values or {}

	for _, flag in ipairs(chapter and chapter.flags or {}) do
		local value = values[flag.id]
		if value == nil then
			value = flag.default
		end
		state[flag.id] = Schema.coerceFlagValue(flag, value)
	end

	return state
end

-- Builds the complete flag view for one active scene. Chapter values are kept
-- across scene transitions; scene values are separately supplied so ordinary
-- scene entry can reset them while saved-game restore can rehydrate them.
function Schema.normalizeRuntimeFlagState(chapter, scene, chapterValues, sceneValues)
	local state = Schema.normalizeFlagState(chapter, chapterValues)
	sceneValues = type(sceneValues) == "table" and sceneValues or {}

	for _, flag in ipairs(scene and scene.flags or {}) do
		local flagRef = Schema.sceneFlagRef(flag.id)
		-- A legacy chapter flag may already own this exact reserved key. Preserve
		-- it rather than silently changing the meaning of existing project data.
		if state[flagRef] == nil then
			local value = sceneValues[flagRef]
			if value == nil then
				value = flag.default
			end
			state[flagRef] = Schema.coerceFlagValue(flag, value)
		end
	end

	return state
end

--------------------------------------------------------------------------------
-- Character portrait catalog
--------------------------------------------------------------------------------

function Schema.findCharacter(project, name)
	local trimmed = Schema.trimName(name)

	if trimmed == "" then
		return nil
	end

	for _, record in ipairs(project.characters or {}) do
		if record.name == trimmed then
			return record
		end
	end

	return nil
end

function Schema.getCharacterPortraits(project, name)
	local record = Schema.findCharacter(project, name)
	return record and record.portraits or {}
end

function Schema.addCharacterPortrait(project, name, imageId)
	local trimmed = Schema.trimName(name)
	local formatted = Schema.formatImageId(imageId)

	if trimmed == "" or formatted == "" then
		return false, formatted
	end

	project.characters = project.characters or {}
	local record = Schema.findCharacter(project, trimmed)

	if not record then
		record = { name = trimmed, portraits = {} }
		table.insert(project.characters, record)
	end

	if table.find(record.portraits, formatted) then
		return false, formatted
	end

	table.insert(record.portraits, formatted)
	return true, formatted
end

function Schema.removeCharacterPortrait(project, name, imageId)
	local record = Schema.findCharacter(project, name)
	if not record then
		return false
	end

	local index = table.find(record.portraits, imageId)
	if not index then
		return false
	end

	table.remove(record.portraits, index)
	if record.priorityPortrait == imageId then
		record.priorityPortrait = nil
	end
	return true
end

function Schema.setCharacterPriorityPortrait(project, name, imageId)
	local record = Schema.findCharacter(project, name)
	if not record then
		return false
	end

	if imageId == false then
		record.priorityPortrait = false
		return true
	end

	if type(imageId) ~= "string" or not table.find(record.portraits, imageId) then
		return false
	end

	record.priorityPortrait = imageId
	return true
end

function Schema.setCharacterModelReference(project, name, reference)
	local record = Schema.findCharacter(project, name)
	if not record then return false end
	record.modelRef = reference and Schema.deepCopy(reference) or nil
	return true
end

function Schema.getCharacterModelReference(project, name)
	local record = Schema.findCharacter(project, name)
	return record and record.modelRef or nil
end

--------------------------------------------------------------------------------
-- Walking
--------------------------------------------------------------------------------

-- Every sequence a scene owns, with a label for the sequence selector.
function Schema.sequencesOf(scene)
	local list = {}
	for _, subscene in ipairs(Schema.ensureSubscenes(scene)) do
		local roleLabel = subscene.role == "intro" and subscene.name ~= "Intro" and " [Intro]"
			or subscene.role == "outro" and subscene.name ~= "Outro" and " [Outro]" or ""
		table.insert(list, {
			owner = "subscene", subsceneId = subscene.id,
			label = subscene.name .. roleLabel .. " · " .. subscene.kind,
			sequence = subscene.sequence,
		})
	end
	for _, interaction in ipairs(scene.interactions or {}) do
		for _, response in ipairs(interaction.responses or {}) do
			table.insert(list, {
				owner = "interaction",
				interactionId = interaction.id,
				subsceneId = interaction.subsceneId,
				responseId = response.id,
				label = "Interaction: " .. interaction.name .. " · " .. response.name,
				sequence = response.sequence,
			})
		end
		table.insert(list, {
			owner = "interaction",
			interactionId = interaction.id,
			subsceneId = interaction.subsceneId,
			responseId = "default",
			label = "Interaction: " .. interaction.name .. " · Default response",
			sequence = interaction.sequence,
		})
	end

	return list
end

function Schema.getSequence(scene, owner, interactionId, responseId)
	if owner == "subscene" then
		local subscene = Schema.subsceneIndex(scene, interactionId)
		return subscene and subscene.sequence or nil
	end

	if owner == "interaction" then
		local interaction = Schema.findInteraction(scene, interactionId)
		return Schema.getInteractionSequence(interaction, responseId)
	end

	if owner == "outro" then return scene.outro end
	return scene.intro
end

function Schema.forEachEntry(scene, callback)
	local function visitSequence(sequence, owner, depth)
		if type(sequence) ~= "table" or depth > 16 then return end

		for _, segment in ipairs(sequence.segments or {}) do
			if segment.kind == "Dialogue" then
				for _, entry in ipairs(segment.entries or {}) do
					callback(entry, segment, owner)
				end
			elseif segment.kind == "Interaction" then
				local snapshot = Schema.getInteractionSegmentSnapshot(segment)
				if snapshot then
					local data = segment.interaction
					local nestedOwner = {
						owner = "timelineInteraction",
						interactionId = data.sourceInteractionId,
						subsceneId = owner.subsceneId,
						segmentId = segment.id,
						interaction = snapshot,
						label = "Timeline interaction: " .. (snapshot.name or "Interaction"),
					}
					for _, response in ipairs(snapshot.responses or {}) do
						local responseOwner = table.clone(nestedOwner)
						responseOwner.responseId = response.id
						visitSequence(response.sequence, responseOwner, depth + 1)
					end
					local fallbackOwner = table.clone(nestedOwner)
					fallbackOwner.responseId = "default"
					visitSequence(snapshot.sequence, fallbackOwner, depth + 1)
				end
			end
		end
	end

	for _, item in ipairs(Schema.sequencesOf(scene)) do
		visitSequence(item.sequence, item, 0)
	end
end

function Schema.forEachEventList(scene, callback)
	local function hostSubsceneId(owner)
		if owner and owner.subsceneId and owner.subsceneId ~= "" then
			return owner.subsceneId
		end
		if owner and owner.owner == "interaction" then
			local interaction = Schema.findInteraction(scene, owner.interactionId)
			if interaction and interaction.scope == "Local" then
				return interaction.subsceneId
			end
		end
		return ""
	end

	local visitSequence
	local function visitInteractionSegment(segment, parentOwner, depth)
		if depth > 16 then return end
		local snapshot = Schema.getInteractionSegmentSnapshot(segment)
		if not snapshot then return end

		local data = segment.interaction
		local owner = {
			owner = "timelineInteraction",
			interactionId = data.sourceInteractionId,
			subsceneId = hostSubsceneId(parentOwner),
			segmentId = segment.id,
			interaction = snapshot,
			label = "Timeline interaction: " .. (snapshot.name or "Interaction"),
		}

		for _, response in ipairs(snapshot.responses or {}) do
			local responseOwner = table.clone(owner)
			responseOwner.responseId = response.id
			visitSequence(response.sequence, responseOwner, depth + 1)
		end
		local fallbackOwner = table.clone(owner)
		fallbackOwner.responseId = "default"
		visitSequence(snapshot.sequence, fallbackOwner, depth + 1)
		callback(snapshot.onComplete or {}, owner, {
			kind = "Complete",
			timelineSegmentId = segment.id,
		})
	end

	visitSequence = function(sequence, owner, depth)
		if type(sequence) ~= "table" or depth > 16 then return end

		for segmentIndex, segment in ipairs(sequence.segments or {}) do
			if segment.kind == "Timed" then
				callback(segment.events or {}, owner, {
					kind = "Timed",
					segmentIndex = segmentIndex,
				})
			elseif segment.kind == "Dialogue" then
				for entryIndex, entry in ipairs(segment.entries or {}) do
					callback(entry.events or {}, owner, {
						kind = "Dialogue",
						segmentIndex = segmentIndex,
						entryIndex = entryIndex,
					})
				end
			elseif segment.kind == "Interaction" then
				visitInteractionSegment(segment, owner, depth + 1)
			end
		end
	end

	for _, item in ipairs(Schema.sequencesOf(scene)) do
		visitSequence(item.sequence, item, 0)
	end

	for _, interaction in ipairs(scene.interactions or {}) do
		callback(interaction.onComplete or {}, {
			owner = "interaction",
			interactionId = interaction.id,
			subsceneId = interaction.subsceneId,
			label = interaction.name,
		}, {
			kind = "Complete",
		})
	end
end

function Schema.forEachSceneInProject(project, callback)
	for _, chapter in ipairs(project.chapters or {}) do
		for _, scene in ipairs(chapter.scenes) do
			callback(scene, chapter)
		end
	end
end

function Schema.clearPortraitUses(project, characterName, imageId, extraScenes)
	local trimmed = Schema.trimName(characterName)

	local function clearScene(scene)
		Schema.forEachEntry(scene, function(entry)
			if entry.character == trimmed and entry.portrait == imageId then
				entry.portrait = ""
			end
		end)
	end

	Schema.forEachSceneInProject(project, clearScene)

	for _, scene in ipairs(extraScenes or {}) do
		clearScene(scene)
	end
end

-- Flow sources are derived from the scene data. The flow view draws a wire only
-- when a source has a destination; unassigned Go To Scene sources are
-- retained so authors can still see and edit the real underlying record. No
-- graph edges are stored separately.
function Schema.sceneLinks(scene)
	local links = {}

	local subscenes = Schema.ensureSubscenes(scene)
	local last = subscenes[#subscenes]
	if last and last.kind == "Novel2D" and scene.next and scene.next.sceneId ~= "" then
		table.insert(links, {
			id = "next",
			kind = "next",
			toSceneId = scene.next.sceneId,
			transitionId = scene.next.transitionId,
			label = "Next",
		})
	end
	for _, subscene in ipairs(subscenes) do
		local exiting = subscene.exiting
		if subscene.kind == "Room3D" and exiting and exiting.destinationMode == "Manual"
			and exiting.sceneId ~= "" and exiting.sceneId ~= scene.id and exiting.subsceneId ~= "" then
			table.insert(links, {
				id = "roomexit_" .. subscene.id,
				kind = "roomExit",
				subsceneId = subscene.id,
				toSceneId = exiting.sceneId,
				transitionId = exiting.transitionId,
				label = "R EXIT · " .. subscene.name,
				conditional = #(exiting.conditions or {}) > 0,
			})
		end
	end

	Schema.forEachEventList(scene, function(events, owner, anchor)
		for _, event in ipairs(events) do
			if event.type == "FlowGoto" then
				table.insert(links, {
					id = event.id,
					kind = "goto",
					eventId = event.id,
					owner = owner.owner,
					interactionId = owner.interactionId,
					responseId = owner.responseId,
					subsceneId = owner.subsceneId,
					timelineSegmentId = owner.segmentId,
					anchor = anchor,
					eventTime = event.time,
					toSceneId = event.params.sceneId,
					transitionId = event.params.transitionId,
					label = "Go To Scene",
				})
			end
		end
	end)

	return links
end

-- Terminal flow effects have no destination node, but are still meaningful in
-- the graph and need to remain reachable from it.
function Schema.sceneFlowMarkers(scene)
	local markers = {}

	Schema.forEachEventList(scene, function(events, owner, anchor)
		for _, event in ipairs(events) do
			if event.type == "FlowEndChapter" then
				table.insert(markers, {
					id = event.id,
					kind = "end",
					eventId = event.id,
					owner = owner.owner,
					interactionId = owner.interactionId,
					responseId = owner.responseId,
					subsceneId = owner.subsceneId,
					timelineSegmentId = owner.segmentId,
					anchor = anchor,
					eventTime = event.time,
					label = "End Chapter",
				})
			end
		end
	end)

	return markers
end

function Schema.clearSubsceneDestinations(scene, subsceneId)
	-- Local character placements cannot outlive their owning subscene. Clear
	-- their Hotspot bindings as well, leaving the interaction itself editable.
	local removedPlacementIds = {}
	for index = #(scene.characterModels or {}), 1, -1 do
		local placement = scene.characterModels[index]
		if placement.scope == "Local" and placement.subsceneId == subsceneId then
			removedPlacementIds[placement.id] = true
			table.remove(scene.characterModels, index)
		end
	end
	if next(removedPlacementIds) then
		for _, interaction in ipairs(scene.interactions or {}) do
			if removedPlacementIds[interaction.targetCharacterModelId] then
				interaction.targetCharacterModelId = ""
			end
		end
	end
	for _, subscene in ipairs(scene.subscenes or {}) do
		if subscene.exiting and subscene.exiting.subsceneId == subsceneId
			and (subscene.exiting.sceneId == "" or subscene.exiting.sceneId == scene.id) then
			subscene.exiting.subsceneId = ""
			subscene.exiting.returnPosition = ""
		end
		for _, route in ipairs(subscene.awaitRoutes or {}) do
			if route.toSubsceneId == subsceneId then route.toSubsceneId = "" end
		end
	end
	Schema.forEachEventList(scene, function(events)
		for _, event in ipairs(events) do
			if event.type == "FlowGotoSubscene" and event.params.subsceneId == subsceneId then
				event.params.subsceneId = ""
			end
		end
	end)
	for index = #(scene.interactions or {}), 1, -1 do
		local interaction = scene.interactions[index]
		if interaction.scope == "Local" and interaction.subsceneId == subsceneId then
			table.remove(scene.interactions, index)
		end
	end
end

-- Clear only destinations that point at a deleted scene. The transition and
-- timeline effect itself remain intact, so an author can retarget it later.
function Schema.clearSceneDestinations(chapter, sceneId)
	if not chapter then
		return
	end

	for _, scene in ipairs(chapter.scenes or {}) do
		if scene.next and scene.next.sceneId == sceneId then
			scene.next.sceneId = ""
		end

		for _, subscene in ipairs(scene.subscenes or {}) do
			if subscene.exiting and subscene.exiting.sceneId == sceneId then
				subscene.exiting.sceneId = ""
				subscene.exiting.subsceneId = ""
				subscene.exiting.returnPosition = ""
			end
		end

		Schema.forEachEventList(scene, function(events)
			for _, event in ipairs(events) do
				if event.type == "FlowGoto" and event.params.sceneId == sceneId then
					event.params.sceneId = ""
				end
			end
		end)
	end
end

function Schema.countLines(scene)
	local total = 0
	Schema.forEachEntry(scene, function()
		total += 1
	end)
	return total
end

function Schema.countEvents(scene)
	local total = 0
	Schema.forEachEventList(scene, function(events)
		total += #events
	end)
	return total
end

function Schema.countSegments(scene)
	local total = 0
	local function countSequence(sequence, depth)
		if type(sequence) ~= "table" or depth > 16 then return end
		for _, segment in ipairs(sequence.segments or {}) do
			total += 1
			if segment.kind == "Interaction" then
				local snapshot = Schema.getInteractionSegmentSnapshot(segment)
				if snapshot then
					for _, response in ipairs(snapshot.responses or {}) do
						countSequence(response.sequence, depth + 1)
					end
					countSequence(snapshot.sequence, depth + 1)
				end
			end
		end
	end
	for _, item in ipairs(Schema.sequencesOf(scene)) do
		countSequence(item.sequence, 0)
	end
	return total
end

-- Fresh ids throughout a copied scene so two scenes never share entry ids.
function Schema.reidentifyScene(scene)
	local previousSceneId = scene.id
	scene.id = Schema.newId("scene")
	local subsceneIds = {}
	for _, subscene in ipairs(Schema.ensureSubscenes(scene)) do
		local oldId = subscene.id
		subscene.id = Schema.newId("sub")
		subsceneIds[oldId] = subscene.id
	end

	-- Placed character copies are scene-owned records, so duplicated scenes must
	-- get new placement identities just like their subscenes and interactions.
	-- Keep this map before reidentifying sequences: interaction snapshots may
	-- point at one of these placements as well.
	local characterModelIds = {}
	for _, placement in ipairs(scene.characterModels or {}) do
		local oldId = placement.id
		placement.id = Schema.newId("charModel")
		characterModelIds[oldId] = placement.id
		if placement.scope == "Local" then
			placement.subsceneId = subsceneIds[placement.subsceneId] or ""
		end
	end

	-- Allocate source interaction identities before copying any sequence so a
	-- timeline block can preserve its source link inside the duplicated scene.
	local interactionIds = {}
	local oldInteractionRevisions = {}
	for _, interaction in ipairs(scene.interactions or {}) do
		local oldId = interaction.id
		oldInteractionRevisions[oldId] = Schema.interactionRevision(interaction)
		interaction.id = Schema.newId("int")
		interactionIds[oldId] = interaction.id
	end

	-- Records whether a block was current before identifiers changed.  We only
	-- refresh its stored revision after the copy when it really was current; an
	-- intentionally stale, locally edited snapshot must remain stale.
	local blockWasCurrent = {}
	local reidSequence
	local reidSnapshot

	local function reidEvents(events)
		for _, event in ipairs(events or {}) do
			event.id = Schema.newId("evt")
		end
	end

	local function reidTracks(tracks)
		for _, track in ipairs(tracks or {}) do
			track.id = Schema.newId("trk")
		end
	end

	reidSequence = function(sequence, depth)
		if type(sequence) ~= "table" or (depth or 0) > 16 then return end

		for _, segment in ipairs(sequence.segments or {}) do
			if segment.kind == "Timed" then
				segment.id = Schema.newId("timed")
				reidEvents(segment.events)
				reidTracks(segment.tracks)
			elseif segment.kind == "Dialogue" then
				segment.id = Schema.newId("dlg")
				for _, entry in ipairs(segment.entries or {}) do
					entry.id = Schema.newId("line")
					reidEvents(entry.events)
					reidTracks(entry.tracks)
				end
			elseif segment.kind == "Interaction" then
				segment.id = Schema.newId("intseg")
				local data = type(segment.interaction) == "table" and segment.interaction or nil
				if data then
					local oldSourceId = data.sourceInteractionId
					blockWasCurrent[data] = oldInteractionRevisions[oldSourceId] ~= nil
						and data.sourceRevision == oldInteractionRevisions[oldSourceId]
					data.sourceInteractionId = interactionIds[oldSourceId] or oldSourceId or ""
					if type(data.snapshot) == "table" then
						reidSnapshot(data.snapshot, (depth or 0) + 1)
					end
				end
			else
				-- Keep a unique segment id even for a future/unknown segment type.
				segment.id = Schema.newId("seg")
			end
		end
	end

	reidSnapshot = function(snapshot, depth)
		if type(snapshot) ~= "table" or depth > 16 then return end
		snapshot.id = Schema.newId("intcopy")
		snapshot.subsceneId = subsceneIds[snapshot.subsceneId] or ""
		snapshot.targetCharacterModelId = characterModelIds[snapshot.targetCharacterModelId] or ""
		reidSequence(snapshot.sequence, depth)
		for _, response in ipairs(snapshot.responses or {}) do
			response.id = Schema.newId("resp")
			reidSequence(response.sequence, depth)
		end
		reidEvents(snapshot.onComplete)
	end

	for _, subscene in ipairs(scene.subscenes) do
		subscene.linkedRoomId = subsceneIds[subscene.linkedRoomId] or ""
		if subscene.exiting then
			if subscene.exiting.sceneId == previousSceneId then
				subscene.exiting.sceneId = scene.id
				subscene.exiting.subsceneId = subsceneIds[subscene.exiting.subsceneId] or ""
			elseif subscene.exiting.sceneId == "" then
				subscene.exiting.subsceneId = subsceneIds[subscene.exiting.subsceneId] or ""
			end
		end
		reidSequence(subscene.sequence, 0)
		for _, route in ipairs(subscene.awaitRoutes or {}) do
			route.id = Schema.newId("route")
			route.toSubsceneId = subsceneIds[route.toSubsceneId] or ""
		end
	end

	for _, interaction in ipairs(scene.interactions or {}) do
		interaction.subsceneId = subsceneIds[interaction.subsceneId] or ""
		interaction.targetCharacterModelId = characterModelIds[interaction.targetCharacterModelId] or ""
		reidSequence(interaction.sequence, 0)
		for _, response in ipairs(interaction.responses or {}) do
			response.id = Schema.newId("resp")
			reidSequence(response.sequence, 0)
		end
		reidEvents(interaction.onComplete)
	end

	local function refreshCurrentBlockRevisions(sequence, depth)
		if type(sequence) ~= "table" or depth > 16 then return end
		for _, segment in ipairs(sequence.segments or {}) do
			if segment.kind == "Interaction" and type(segment.interaction) == "table" then
				local data = segment.interaction
				local source = Schema.findInteraction(scene, data.sourceInteractionId)
				if blockWasCurrent[data] and source then
					data.sourceRevision = Schema.interactionRevision(source)
				end
				if type(data.snapshot) == "table" then
					refreshCurrentBlockRevisions(data.snapshot.sequence, depth + 1)
					for _, response in ipairs(data.snapshot.responses or {}) do
						refreshCurrentBlockRevisions(response.sequence, depth + 1)
					end
				end
			end
		end
	end

	for _, subscene in ipairs(scene.subscenes or {}) do
		refreshCurrentBlockRevisions(subscene.sequence, 0)
	end
	for _, interaction in ipairs(scene.interactions or {}) do
		refreshCurrentBlockRevisions(interaction.sequence, 0)
		for _, response in ipairs(interaction.responses or {}) do
			refreshCurrentBlockRevisions(response.sequence, 0)
		end
	end
	Schema.forEachEventList(scene, function(events)
		for _, event in ipairs(events) do
			if event.type == "FlowGotoSubscene" then
				event.params.subsceneId = subsceneIds[event.params.subsceneId] or ""
			end
		end
	end)

	return scene
end

--------------------------------------------------------------------------------
-- Normalizers
--
-- Imported JSON is untrusted, so everything gets rebuilt field by field. Bad
-- values are replaced with defaults and unsalvageable records are dropped.
--------------------------------------------------------------------------------

function Schema.normalizeEvent(raw)
	if type(raw) ~= "table" then
		return nil
	end

	local eventType = EventRegistry.resolveType(asString(raw.type, ""))
	if not eventType then
		return nil
	end

	local params = EventRegistry.defaultParams(eventType)
	local rawParams = type(raw.params) == "table" and raw.params or {}

	for _, field in ipairs(EventRegistry.fields(eventType)) do
		local value = rawParams[field.key]

		if field.kind == "number" then
			params[field.key] = asNumber(value, field.default)
		elseif field.kind == "boolean" then
			params[field.key] = asBool(value, field.default)
		elseif field.kind == "choice" then
			params[field.key] = oneOf(value, field.choices, field.default)
		else
			params[field.key] = asString(value, field.default)
		end
	end

	-- ScreenShake used one shared pair before portrait/background channels were
	-- introduced. Preserve authored projects by using that pair for both layers.
	if eventType == "ScreenShake" then
		local legacyIntensity = rawParams.intensity
		local legacyDuration = rawParams.duration
		if rawParams.portraitIntensity == nil and legacyIntensity ~= nil then
			params.portraitIntensity = math.max(0, asNumber(legacyIntensity, 8))
		end
		if rawParams.backgroundIntensity == nil and legacyIntensity ~= nil then
			params.backgroundIntensity = math.max(0, asNumber(legacyIntensity, 11))
		end
		if rawParams.portraitDuration == nil and legacyDuration ~= nil then
			params.portraitDuration = math.max(0, asNumber(legacyDuration, 0.35))
		end
		if rawParams.backgroundDuration == nil and legacyDuration ~= nil then
			params.backgroundDuration = math.max(0, asNumber(legacyDuration, 0.5))
		end
	end

	-- ScreenFlash originally used `duration` as its only fade length. Preserve
	-- that appearance while promoting new events to a hold Duration plus a
	-- separate Fade time.
	if eventType == "ScreenFlash" then
		local legacyDuration = rawParams.duration
		if rawParams.fade == nil and legacyDuration ~= nil then
			params.duration = 0
			params.fade = math.max(0, asNumber(legacyDuration, 0.3))
		end
	end

	-- v1 CameraMove carried a "target" name rather than a pose id.
	if eventType == "CameraMoveTo" and params.poseId == "" and type(rawParams.target) == "string" then
		params.poseId = ""
	end

	-- Go To Explore arrivals store only a plain world position. Keep malformed
	-- imported values from becoming a silent, permanent pseudo-destination; the
	-- runtime then deliberately falls back to the Explore3D spawn.
	if (eventType == "FlowGoto" or eventType == "FlowGotoSubscene")
		and not Schema.decodePosition(params.exploreReturnPosition) then
		params.exploreReturnPosition = ""
	end

	return {
		id = asString(raw.id, Schema.newId("evt")),
		type = eventType,
		time = math.max(0, asNumber(raw.time, 0)),
		delay = math.max(0, asNumber(raw.delay, 0)),
		duration = math.max(0, asNumber(raw.duration, 0)),
		easing = oneOf(raw.easing, Schema.EASINGS, "Quad"),
		params = params,
		transitionExplicit = raw.transitionExplicit == true,
	}
end

local function normalizeEventList(raw)
	local events = {}

	if type(raw) == "table" then
		for _, rawEvent in ipairs(raw) do
			local event = Schema.normalizeEvent(rawEvent)
			if event then
				table.insert(events, event)
			end
		end
	end

	return events
end

function Schema.normalizeKey(raw, target)
	if type(raw) ~= "table" then
		return nil
	end

	return {
		t = math.max(0, asNumber(raw.t, 0)),
		x = asNumber(raw.x, 0.5),
		y = asNumber(raw.y, target == "background" and 0.5 or 1),
		scale = math.max(0.05, asNumber(raw.scale, 1)),
		rotation = asNumber(raw.rotation, 0),
		alpha = math.clamp(asNumber(raw.alpha, 1), 0, 1),
		easing = oneOf(raw.easing, Schema.EASINGS, "Quad"),
	}
end

function Schema.normalizeTrack(raw)
	if type(raw) ~= "table" then
		return nil
	end

	local target = raw.target == "background" and "background" or "portrait"
	local keys = {}

	if type(raw.keys) == "table" then
		for _, rawKey in ipairs(raw.keys) do
			local key = Schema.normalizeKey(rawKey, target)
			if key then
				table.insert(keys, key)
			end
		end
	end

	if #keys == 0 then
		table.insert(keys, Schema.newKey(0, target))
	end

	table.sort(keys, function(a, b)
		return a.t < b.t
	end)

	return {
		id = asString(raw.id, Schema.newId("trk")),
		target = target,
		keys = keys,
	}
end

local function normalizeTrackList(raw)
	local tracks = {}

	if type(raw) == "table" then
		for _, rawTrack in ipairs(raw) do
			local track = Schema.normalizeTrack(rawTrack)
			if track then
				table.insert(tracks, track)
			end
		end
	end

	return tracks
end

function Schema.normalizeEntry(raw)
	if type(raw) ~= "table" then
		return nil
	end

	return {
		id = asString(raw.id, Schema.newId("line")),
		character = Schema.trimName(asString(raw.character or raw.speaker, "")),
		text = asString(raw.text, ""),
		skippable = raw.skippable ~= false,
		speaking = raw.speaking ~= false,
		crossfadeNextPortrait = raw.crossfadeNextPortrait == true,
		autoAdvanceDelay = math.clamp(
			asNumber(raw.autoAdvanceDelay, Schema.DEFAULT_DIALOGUE_AUTO_ADVANCE),
			Schema.MIN_DIALOGUE_AUTO_ADVANCE,
			Schema.MAX_DIALOGUE_AUTO_ADVANCE
		),
		portrait = Schema.formatImageId(raw.portrait),
		events = normalizeEventList(raw.events),
		tracks = normalizeTrackList(raw.tracks),
	}
end

function Schema.normalizeSegment(raw)
	if type(raw) ~= "table" then
		return nil
	end

	local kind = asString(raw.kind, "Timed")

	if kind == "Dialogue" then
		local entries = {}

		if type(raw.entries) == "table" then
			for _, rawEntry in ipairs(raw.entries) do
				local entry = Schema.normalizeEntry(rawEntry)
				if entry then
					table.insert(entries, entry)
				end
			end
		end

		if #entries == 0 then
			table.insert(entries, Schema.newDialogueEntry("", ""))
		end

		return {
			id = asString(raw.id, Schema.newId("dlg")),
			kind = "Dialogue",
			textboxPresetId = asString(raw.textboxPresetId, ""),
			entries = entries,
		}
	end

	-- `InteractionBlock` was the short-lived working name while timeline
	-- hotspots were being introduced.  Normalize it to the persisted
	-- `Interaction` spelling instead of silently treating it as a Timed segment.
	if kind == "Interaction" or kind == "InteractionBlock" then
		return Schema.normalizeInteractionSegment(raw)
	end

	return {
		id = asString(raw.id, Schema.newId("timed")),
		kind = "Timed",
		duration = math.clamp(asNumber(raw.duration, 2), Schema.MIN_DURATION, Schema.MAX_DURATION),
		events = normalizeEventList(raw.events),
		tracks = normalizeTrackList(raw.tracks),
	}
end

function Schema.normalizeSequence(raw)
	local sequence = { segments = {} }

	local rawSegments = nil
	if type(raw) == "table" then
		rawSegments = raw.segments
		if rawSegments == nil and raw[1] ~= nil then
			rawSegments = raw
		end
	end

	if type(rawSegments) == "table" then
		for _, rawSegment in ipairs(rawSegments) do
			local segment = Schema.normalizeSegment(rawSegment)
			if segment then
				table.insert(sequence.segments, segment)
			end
		end
	end

	return sequence
end

function Schema.normalizeCondition(raw)
	if type(raw) ~= "table" then
		return nil
	end

	local flag = asString(raw.flag, "")
	if flag == "" then
		return nil
	end

	return {
		flag = flag,
		op = oneOf(raw.op, Schema.CONDITION_OPS, "=="),
		value = asString(raw.value, "true"),
	}
end

-- Target references are serializable Workspace paths. They deliberately avoid
-- Roblox instances, which cannot cross the project database or survive a
-- playtest reset.
local function normalizeTargetReference(raw)
	if type(raw) ~= "table" or type(raw.path) ~= "table" or #raw.path == 0 then
		return nil
	end
	local path = {}
	for _, rawSegment in ipairs(raw.path) do
		if type(rawSegment) ~= "table" then return nil end
		local name = asString(rawSegment.name, "")
		if name == "" then return nil end
		table.insert(path, {
			name = name,
			className = asString(rawSegment.className, ""),
			ordinal = math.max(1, math.floor(asNumber(rawSegment.ordinal, 1))),
			worldPosition = asString(rawSegment.worldPosition, ""),
		})
		if #path >= 64 then break end
	end
	return #path > 0 and { path = path } or nil
end

function Schema.normalizeInteraction(raw)
	if type(raw) ~= "table" then
		return nil
	end

	-- Older Trigger and Exit records become Hotspots. Legacy Exit destinations
	-- become completion events so authored projects keep their graph branch.
	local kind = "Hotspot"
	-- Interaction-level availability conditions are intentionally retired. They
	-- are omitted rather than retained as invisible runtime gates.
	local legacyRepeatPolicy = oneOf(raw.repeatPolicy, Schema.REPEAT_POLICIES, "always")

	local rawGoto = type(raw.exit) == "table" and raw.exit or {}
	local onComplete = normalizeEventList(raw.onComplete)
	if raw.kind == "Exit" and asString(rawGoto.sceneId, "") ~= "" then
		local goto = Schema.newEvent("FlowGoto", 0)
		goto.params.sceneId = asString(rawGoto.sceneId, "")
		goto.params.transitionId = asString(rawGoto.transitionId, Schema.DEFAULT_FADE)
		table.insert(onComplete, goto)
	end
	local responses = {}
	for _, rawResponse in ipairs(type(raw.responses) == "table" and raw.responses or {}) do
		if type(rawResponse) == "table" then
			local responseConditions = {}
			for _, rawCondition in ipairs(type(rawResponse.conditions) == "table" and rawResponse.conditions or {}) do
				local condition = Schema.normalizeCondition(rawCondition)
				if condition then table.insert(responseConditions, condition) end
			end
			-- A conditionless variant would permanently shadow every later
			-- response, so omit malformed entries and retain the interaction's
			-- dedicated fallback sequence instead.
			if #responseConditions > 0 then
				table.insert(responses, {
					id = asString(rawResponse.id, Schema.newId("resp")),
					name = Schema.trimName(asString(rawResponse.name, "")) ~= "" and Schema.trimName(asString(rawResponse.name, "")) or "Conditional response",
					conditions = responseConditions,
					repeatPolicy = oneOf(rawResponse.repeatPolicy, Schema.REPEAT_POLICIES, legacyRepeatPolicy),
					sequence = Schema.normalizeSequence(rawResponse.sequence),
				})
			end
		end
	end

	local targetCharacterModelId = asString(raw.targetCharacterModelId, "")
	local targetRef = nil
	if targetCharacterModelId == "" then
		targetRef = normalizeTargetReference(raw.targetRef)
	end
	return {
		id = asString(raw.id, Schema.newId("int")),
		name = asString(raw.name, kind),
		kind = kind,
		-- Character placements are recreated per scene entry, so their stable
		-- project id is authoritative. Ordinary world-object targets retain the
		-- durable Workspace reference path.
		targetId = targetCharacterModelId ~= "" and "" or asString(raw.targetId, ""),
		targetRef = targetRef,
		targetCharacterModelId = targetCharacterModelId,
		enabled = asBool(raw.enabled, true),
		scope = oneOf(raw.scope, { "Local", "Shared" }, "Shared"),
		subsceneId = asString(raw.subsceneId, ""),
		transitionId = asString(raw.transitionId, Schema.DEFAULT_ZOOM),
		responses = responses,
		sequence = Schema.normalizeSequence(raw.sequence),
		onComplete = onComplete,
	}
end

--------------------------------------------------------------------------------
-- Timeline interaction snapshots
--
-- A source interaction is edited through a private scene checkout, so a mutable
-- integer revision would be easy to forget to increment.  Instead, a block
-- records a deterministic content fingerprint of the source it was copied
-- from.  This makes stale detection reliable for every normal edit path while
-- keeping the source model free of persistence-only bookkeeping.
--------------------------------------------------------------------------------

local REVISION_IGNORED_KEYS = {
	id = true,
	sourceName = true,
	sourceRevision = true,
}

local function appendCanonicalValue(parts, value, visiting)
	local valueType = type(value)

	if valueType == "nil" then
		table.insert(parts, "n")
		return
	end

	if valueType == "boolean" then
		table.insert(parts, value and "b1" or "b0")
		return
	end

	if valueType == "number" then
		table.insert(parts, "#" .. tostring(value) .. ";")
		return
	end

	if valueType == "string" then
		table.insert(parts, "s" .. tostring(#value) .. ":" .. value)
		return
	end

	if valueType ~= "table" then
		-- Normalized project data never contains Instances or functions.  Keep a
		-- stable sentinel rather than allowing an unusual live value to break a
		-- stale check in the editor.
		table.insert(parts, "<" .. valueType .. ">")
		return
	end

	if visiting[value] then
		table.insert(parts, "<cycle>")
		return
	end
	visiting[value] = true

	local keys = {}
	for key in pairs(value) do
		if not (type(key) == "string" and REVISION_IGNORED_KEYS[key]) then
			table.insert(keys, key)
		end
	end
	table.sort(keys, function(left, right)
		local leftType, rightType = type(left), type(right)
		if leftType ~= rightType then
			return leftType < rightType
		end
		return tostring(left) < tostring(right)
	end)

	table.insert(parts, "{")
	for _, key in ipairs(keys) do
		appendCanonicalValue(parts, key, visiting)
		table.insert(parts, "=")
		appendCanonicalValue(parts, value[key], visiting)
		table.insert(parts, ";")
	end
	table.insert(parts, "}")

	visiting[value] = nil
end

local function fingerprint(text)
	-- A small deterministic rolling hash is enough for stale detection.  The
	-- modulus keeps every intermediate safely within Luau's precise integer
	-- range, unlike a raw multiplication-based 32-bit hash.
	local hash = 5381
	local modulus = 2147483647
	for index = 1, #text do
		hash = (hash * 65599 + string.byte(text, index)) % modulus
	end
	return string.format("r%08x", math.floor(hash))
end

function Schema.interactionRevision(interaction)
	if type(interaction) ~= "table" then
		return ""
	end

	local normalized = Schema.normalizeInteraction(interaction)
	if not normalized then
		return ""
	end

	local parts = {}
	appendCanonicalValue(parts, normalized, {})
	return fingerprint(table.concat(parts))
end

-- Copies the normalized content of an interaction while giving the snapshot a
-- separate identity.  Runtime repeat bookkeeping must never conflate a
-- timeline invocation with the physical interaction that originally inspired
-- it.
function Schema.copyInteractionSnapshot(sourceInteraction, snapshotId)
	local snapshot = Schema.normalizeInteraction(sourceInteraction)
	if not snapshot then
		snapshot = Schema.newInteraction("Hotspot")
	end

	snapshot.id = asString(snapshotId, "")
	if snapshot.id == "" then
		snapshot.id = Schema.newId("intcopy")
	end

	return snapshot
end

-- Snapshot content is authored independently after it is placed on a timeline.
-- Give every nested segment, line, response, event and track a private id so a
-- copied Go To Scene event cannot collide with the same event in its source
-- interaction (for example in the flow graph).  The outer id can be supplied
-- when refreshing an existing block to preserve that block's own identity.
function Schema.reidentifyInteractionSnapshot(snapshot, snapshotId)
	if type(snapshot) ~= "table" then
		return nil
	end

	local reidSequence
	local reidSnapshot

	local function reidEvents(events)
		for _, event in ipairs(events or {}) do
			event.id = Schema.newId("evt")
		end
	end

	local function reidTracks(tracks)
		for _, track in ipairs(tracks or {}) do
			track.id = Schema.newId("trk")
		end
	end

	reidSequence = function(sequence, depth)
		if type(sequence) ~= "table" or depth > 16 then return end
		for _, segment in ipairs(sequence.segments or {}) do
			if segment.kind == "Timed" then
				segment.id = Schema.newId("timed")
				reidEvents(segment.events)
				reidTracks(segment.tracks)
			elseif segment.kind == "Dialogue" then
				segment.id = Schema.newId("dlg")
				for _, entry in ipairs(segment.entries or {}) do
					entry.id = Schema.newId("line")
					reidEvents(entry.events)
					reidTracks(entry.tracks)
				end
			elseif segment.kind == "Interaction" then
				segment.id = Schema.newId("intseg")
				local data = type(segment.interaction) == "table" and segment.interaction or nil
				if data and type(data.snapshot) == "table" then
					reidSnapshot(data.snapshot, nil, depth + 1)
				end
			end
		end
	end

	reidSnapshot = function(value, id, depth)
		if type(value) ~= "table" or depth > 16 then return end
		value.id = asString(id, "")
		if value.id == "" then value.id = Schema.newId("intcopy") end
		reidSequence(value.sequence, depth)
		for _, response in ipairs(value.responses or {}) do
			response.id = Schema.newId("resp")
			reidSequence(response.sequence, depth)
		end
		reidEvents(value.onComplete)
	end

	reidSnapshot(snapshot, snapshotId or snapshot.id, 0)
	return snapshot
end

function Schema.isInteractionSegment(segment)
	return type(segment) == "table" and segment.kind == "Interaction"
		and type(segment.interaction) == "table"
		and type(segment.interaction.snapshot) == "table"
end

function Schema.getInteractionSegmentSnapshot(segment)
	return Schema.isInteractionSegment(segment) and segment.interaction.snapshot or nil
end

function Schema.findInteractionSegmentSource(scene, segment)
	if not Schema.isInteractionSegment(segment) then
		return nil
	end
	return Schema.findInteraction(scene, segment.interaction.sourceInteractionId)
end

-- Imported Interaction blocks accept a few short-lived aliases so projects
-- saved while this feature was being introduced remain readable.  Everything
-- is written back in the canonical `segment.interaction` form.
function Schema.normalizeInteractionSegment(raw)
	if type(raw) ~= "table" then
		return nil
	end

	local rawData = type(raw.interaction) == "table" and raw.interaction or {}
	local rawParams = type(raw.params) == "table" and raw.params or {}
	local rawSnapshot = rawData.snapshot
	if type(rawSnapshot) ~= "table" then rawSnapshot = raw.snapshot end
	if type(rawSnapshot) ~= "table" then rawSnapshot = rawParams.snapshot end
	-- One early in-memory shape stored the copied interaction directly in
	-- `segment.interaction`, before the source metadata wrapper was added.
	-- Preserve it on import just as the runtime compatibility decoder does.
	if type(rawSnapshot) ~= "table"
		and (type(rawData.sequence) == "table" or type(rawData.responses) == "table" or rawData.kind ~= nil) then
		rawSnapshot = rawData
	end

	local snapshotId = type(rawSnapshot) == "table" and asString(rawSnapshot.id, "") or ""
	local snapshot = Schema.copyInteractionSnapshot(rawSnapshot, snapshotId)
	local sourceId = asString(rawData.sourceInteractionId,
		asString(raw.sourceInteractionId, asString(rawParams.sourceInteractionId, "")))
	local sourceName = asString(rawData.sourceName,
		asString(raw.sourceName, asString(rawParams.sourceName, snapshot.name)))
	local sourceRevision = asString(rawData.sourceRevision,
		asString(raw.sourceRevision, asString(rawParams.sourceRevision, "")))

	-- A pre-revision block can safely start as current with respect to its own
	-- snapshot.  The next edit to its source will then make it stale normally.
	if sourceRevision == "" and sourceId ~= "" then
		sourceRevision = Schema.interactionRevision(snapshot)
	end

	return {
		id = asString(raw.id, Schema.newId("intseg")),
		kind = "Interaction",
		interaction = {
			sourceInteractionId = sourceId,
			sourceName = sourceName,
			sourceRevision = sourceRevision,
			snapshot = snapshot,
		},
	}
end

function Schema.isInteractionSegmentStale(segment, sourceInteraction)
	if not Schema.isInteractionSegment(segment) or type(sourceInteraction) ~= "table" then
		return false
	end
	return segment.interaction.sourceRevision ~= Schema.interactionRevision(sourceInteraction)
end

function Schema.refreshInteractionSegment(segment, sourceInteraction)
	if not Schema.isInteractionSegment(segment) or type(sourceInteraction) ~= "table" then
		return false
	end

	local data = segment.interaction
	local previousSnapshot = data.snapshot
	data.sourceInteractionId = asString(sourceInteraction.id, "")
	data.sourceName = asString(sourceInteraction.name, "")
	data.sourceRevision = Schema.interactionRevision(sourceInteraction)
	data.snapshot = Schema.copyInteractionSnapshot(sourceInteraction, previousSnapshot and previousSnapshot.id)
	Schema.reidentifyInteractionSnapshot(data.snapshot, previousSnapshot and previousSnapshot.id)
	return true
end

Schema.isInteractionTimelineBlockStale = Schema.isInteractionSegmentStale
Schema.refreshInteractionTimelineBlock = Schema.refreshInteractionSegment

local function normalizeSubscene(raw)
	if type(raw) ~= "table" then return nil end
	local stage = type(raw.stage) == "table" and raw.stage or {}
	local kind = oneOf(raw.kind or stage.kind, Schema.SCENE_KINDS, "Novel2D")
	local background = type(raw.background) == "table" and raw.background or {}
	local rawExiting = type(raw.exiting) == "table" and raw.exiting or {}
	local exitConditions = {}
	for _, rawCondition in ipairs(type(rawExiting.conditions) == "table" and rawExiting.conditions or {}) do
		local condition = Schema.normalizeCondition(rawCondition)
		if condition then table.insert(exitConditions, condition) end
	end
	local routes = {}
	for _, rawRoute in ipairs(type(raw.awaitRoutes) == "table" and raw.awaitRoutes or {}) do
		if type(rawRoute) == "table" then
			local conditions = {}
			for _, rawCondition in ipairs(type(rawRoute.conditions) == "table" and rawRoute.conditions or {}) do
				local condition = Schema.normalizeCondition(rawCondition)
				if condition then table.insert(conditions, condition) end
			end
			table.insert(routes, {
				id = asString(rawRoute.id, Schema.newId("route")),
				conditions = conditions,
				toSubsceneId = asString(rawRoute.toSubsceneId, ""),
				transitionId = asString(rawRoute.transitionId, Schema.DEFAULT_FADE),
				transitionExplicit = rawRoute.transitionExplicit == true,
			})
		end
	end
	local spawnCFrame = Schema.decodeCFrame(raw.spawnCFrame) and raw.spawnCFrame or ""
	local spawnPosition = Schema.decodePosition(raw.spawnPosition) and raw.spawnPosition or ""
	-- Older Explore3D spawns were authored from a selected part's CFrame. Keep
	-- their facing but promote their stored location to the now-canonical
	-- position field so every spawn is a direct world position going forward.
	if spawnPosition == "" and spawnCFrame ~= "" then
		local cframe = Schema.decodeCFrame(spawnCFrame)
		if cframe then spawnPosition = Schema.encodePosition(cframe.Position) end
	end
	return {
		id = asString(raw.id, Schema.newId("sub")),
		name = asString(raw.name, "Subscene"),
		role = oneOf(raw.role, { "intro", "outro", "custom" }, "custom"),
		kind = kind,
		stage = { kind = kind, cameraPoseId = asString(stage.cameraPoseId, "") },
		background = {
			kind = oneOf(background.kind, Schema.BACKGROUND_KINDS, kind == "Novel2D" and "Color" or "Camera3D"),
			value = asString(background.value, "40,44,72"),
			poseId = asString(background.poseId, ""),
		},
		spawnPosition = spawnPosition,
		spawnCFrame = spawnCFrame,
		assemblyEnabled = raw.assemblyEnabled == true,
		roomDefinitionId = asString(raw.roomDefinitionId, ""),
		sequence = Schema.normalizeSequence(raw.sequence),
		nextTransitionId = asString(raw.nextTransitionId, Schema.DEFAULT_FADE),
		awaitRoutes = routes,
		linkPreviousRoom = raw.linkPreviousRoom == true,
		linkedRoomId = asString(raw.linkedRoomId, ""),
		-- Links made before local inheritance was separately configurable retain
		-- their original behavior.
		linkLocalInteractions = asBool(raw.linkLocalInteractions, true),
		linkLocalCharacterModels = asBool(raw.linkLocalCharacterModels, true),
		exiting = {
			exitable = asBool(rawExiting.exitable, true),
			conditions = exitConditions,
			conditionResult = asBool(rawExiting.conditionResult, true),
			destinationMode = oneOf(rawExiting.destinationMode, { "Auto", "Manual" }, "Auto"),
			sceneId = asString(rawExiting.sceneId, ""),
			subsceneId = asString(rawExiting.subsceneId, ""),
			returnPosition = Schema.decodePosition(rawExiting.returnPosition) and rawExiting.returnPosition or "",
			transitionId = asString(rawExiting.transitionId, Schema.DEFAULT_FADE),
			exitablePresetId = asString(rawExiting.exitablePresetId, Schema.DEFAULT_ROOM_EXIT),
			blockedPresetId = asString(rawExiting.blockedPresetId, Schema.DEFAULT_ROOM_BLOCKED),
		},
	}
end

local function normalizeCharacterModelPlacement(raw)
	if type(raw) ~= "table" then return nil end
	local character = Schema.trimName(asString(raw.character, ""))
	local cframe = asString(raw.cframe, "")
	if character == "" or not isCFrameString(cframe) then return nil end
	return {
		id = asString(raw.id, Schema.newId("charModel")),
		character = character,
		cframe = cframe,
		scope = oneOf(raw.scope, { "Local", "Shared" }, "Local"),
		subsceneId = asString(raw.subsceneId, ""),
	}
end

function Schema.normalizeScene(raw)
	if type(raw) ~= "table" then
		return nil
	end

	local rawStage = type(raw.stage) == "table" and raw.stage or {}
	local kind = oneOf(rawStage.kind, Schema.SCENE_KINDS, "Novel2D")

	local rawBackground = type(raw.background) == "table" and raw.background or {}
	local backgroundKind = oneOf(rawBackground.kind, Schema.BACKGROUND_KINDS, "Color")

	local rawFlow = type(raw.flow) == "table" and raw.flow or {}
	local rawNext = type(raw.next) == "table" and raw.next or {}

	local interactions = {}
	if type(raw.interactions) == "table" then
		for _, rawInteraction in ipairs(raw.interactions) do
			local interaction = Schema.normalizeInteraction(rawInteraction)
			if interaction then
				table.insert(interactions, interaction)
			end
		end
	end

	local flags = {}
	local seenFlags = {}
	if type(raw.flags) == "table" then
		for _, rawFlag in ipairs(raw.flags) do
			local flag = Schema.normalizeFlag(rawFlag)
			if flag and not seenFlags[flag.id] then
				seenFlags[flag.id] = true
				table.insert(flags, flag)
			end
		end
	end

	-- v1 scenes stored segments directly on the scene.
	local rawIntro = raw.intro
	if rawIntro == nil and raw.segments ~= nil then
		rawIntro = { segments = raw.segments }
	end

	local characterModels = {}
	local seenCharacterModelIds = {}
	for _, rawPlacement in ipairs(type(raw.characterModels) == "table" and raw.characterModels or {}) do
		local placement = normalizeCharacterModelPlacement(rawPlacement)
		if placement then
			if seenCharacterModelIds[placement.id] then placement.id = Schema.newId("charModel") end
			seenCharacterModelIds[placement.id] = true
			table.insert(characterModels, placement)
		end
	end

	local scene = {
		id = asString(raw.id, Schema.newId("scene")),
		name = asString(raw.name, "Untitled Scene"),
		flow = { x = asNumber(rawFlow.x, 80), y = asNumber(rawFlow.y, 80) },
		stage = { kind = kind, cameraPoseId = asString(rawStage.cameraPoseId, "") },
		background = {
			kind = backgroundKind,
			value = asString(rawBackground.value, "40,44,72"),
			poseId = asString(rawBackground.poseId, ""),
		},
		intro = Schema.normalizeSequence(rawIntro),
		outro = Schema.normalizeSequence(raw.outro),
		flags = flags,
		interactions = interactions,
		characterModels = characterModels,
		next = {
			sceneId = asString(rawNext.sceneId, ""),
			transitionId = asString(rawNext.transitionId, Schema.DEFAULT_FADE),
		},
	}
	if type(raw.subscenes) == "table" then
		scene.subscenes = {}
		local seenIds = {}
		for _, rawSubscene in ipairs(raw.subscenes) do
			local subscene = normalizeSubscene(rawSubscene)
			if subscene then
				if seenIds[subscene.id] then subscene.id = Schema.newId("sub") end
				seenIds[subscene.id] = true
				table.insert(scene.subscenes, subscene)
			end
		end
	end
	Schema.ensureSubscenes(scene)
	for _, placement in ipairs(scene.characterModels) do
		if placement.scope == "Local" and not Schema.subsceneIndex(scene, placement.subsceneId) then
			placement.subsceneId = scene.subscenes[1] and scene.subscenes[1].id or ""
		end
	end
	local characterModelTargetOwners = {}
	for _, interaction in ipairs(scene.interactions) do
		if interaction.targetCharacterModelId ~= "" and not Schema.findCharacterModel(scene, interaction.targetCharacterModelId) then
			interaction.targetCharacterModelId = ""
		elseif interaction.targetCharacterModelId ~= "" then
			if characterModelTargetOwners[interaction.targetCharacterModelId] then
				-- A model supports one physical Hotspot owner. Keep the first authored
				-- interaction deterministically and leave later records unbound.
				interaction.targetCharacterModelId = ""
			else
				characterModelTargetOwners[interaction.targetCharacterModelId] = interaction.id
			end
		end
	end
	Schema.reconcileSubscenes(scene)
	return scene
end

function Schema.normalizeFlag(raw)
	if type(raw) ~= "table" then
		return nil
	end

	local id = Schema.trimName(asString(raw.id, ""))
	if id == "" then
		return nil
	end

	local kind = oneOf(raw.kind, Schema.FLAG_KINDS, "bool")

	return {
		id = id,
		kind = kind,
		default = kind == "int" and asNumber(raw.default, 0) or asBool(raw.default, false),
	}
end

function Schema.normalizeChapter(raw)
	if type(raw) ~= "table" then
		return nil
	end

	local scenes = {}
	if type(raw.scenes) == "table" then
		for _, rawScene in ipairs(raw.scenes) do
			local scene = Schema.normalizeScene(rawScene)
			if scene then
				table.insert(scenes, scene)
			end
		end
	end

	if #scenes == 0 then
		table.insert(scenes, Schema.newScene("Opening", "Novel2D"))
	end

	local flags = {}
	local seen = {}
	if type(raw.flags) == "table" then
		for _, rawFlag in ipairs(raw.flags) do
			local flag = Schema.normalizeFlag(rawFlag)
			if flag and not seen[flag.id] then
				seen[flag.id] = true
				table.insert(flags, flag)
			end
		end
	end

	local startSceneId = asString(raw.startSceneId, "")
	if not Schema.findById(scenes, startSceneId) then
		startSceneId = scenes[1].id
	end

	return {
		id = asString(raw.id, Schema.newId("chapter")),
		name = asString(raw.name, "Untitled Chapter"),
		startSceneId = startSceneId,
		flags = flags,
		scenes = scenes,
	}
end

local function normalizeCharacters(raw)
	local characters = {}
	local seenNames = {}

	if type(raw) ~= "table" then
		return characters
	end

	for _, rawRecord in ipairs(raw) do
		if type(rawRecord) == "table" then
			local name = Schema.trimName(asString(rawRecord.name, ""))

			if name ~= "" and not seenNames[name] then
				seenNames[name] = true

				local portraits = {}
				local seenIds = {}

				if type(rawRecord.portraits) == "table" then
					for _, rawId in ipairs(rawRecord.portraits) do
						local imageId = Schema.formatImageId(rawId)
						if imageId ~= "" and not seenIds[imageId] then
							seenIds[imageId] = true
							table.insert(portraits, imageId)
						end
					end
				end

				local record = { name = name, portraits = portraits }
				local modelRef = normalizeTargetReference(rawRecord.modelRef)
				if modelRef then
					record.modelRef = modelRef
				end
				if rawRecord.priorityPortrait == false then
					record.priorityPortrait = false
				elseif type(rawRecord.priorityPortrait) == "string" then
					local priorityPortrait = Schema.formatImageId(rawRecord.priorityPortrait)
					if priorityPortrait ~= "" and table.find(portraits, priorityPortrait) then
						record.priorityPortrait = priorityPortrait
					end
				end

				table.insert(characters, record)
			end
		end
	end

	return characters
end

local function normalizeCameraPoses(raw)
	local poses = {}

	if type(raw) ~= "table" then
		return poses
	end

	for _, rawPose in ipairs(raw) do
		if type(rawPose) == "table" then
			local cframeText = asString(rawPose.cframe, "")
			if isCFrameString(cframeText) then
				table.insert(poses, {
					id = asString(rawPose.id, Schema.newId("pose")),
					name = asString(rawPose.name, "Camera pose"),
					cframe = cframeText,
				})
			end
		end
	end

	return poses
end

local function normalizeAnim(raw, fallback)
	if type(raw) ~= "table" then
		raw = {}
	end

	return {
		inKind = oneOf(raw.inKind, Schema.ANIM_KINDS, fallback.inKind),
		outKind = oneOf(raw.outKind, Schema.ANIM_KINDS, fallback.outKind),
		duration = math.max(0, asNumber(raw.duration, fallback.duration)),
		easing = oneOf(raw.easing, Schema.EASINGS, fallback.easing),
		delay = math.max(0, asNumber(raw.delay, fallback.delay)),
	}
end

local function normalizeTextboxPresets(raw)
	local presets = {}

	if type(raw) ~= "table" then
		return presets
	end

	for _, rawPreset in ipairs(raw) do
		if type(rawPreset) == "table" then
			local template = Schema.newTextboxPreset()
			local rawElements = type(rawPreset.elements) == "table" and rawPreset.elements or {}
			local elements = {}

			for _, elementName in ipairs(Schema.TEXTBOX_ELEMENTS) do
				elements[elementName] = normalizeAnim(rawElements[elementName], template.elements[elementName])
			end

			table.insert(presets, {
				id = asString(rawPreset.id, Schema.newId("tb")),
				name = asString(rawPreset.name, "Textbox style"),
				typewriterCps = math.max(0, asNumber(rawPreset.typewriterCps, 40)),
				typeSoundId = asString(rawPreset.typeSoundId, ""),
				elements = elements,
			})
		end
	end

	return presets
end

local function normalizeTransitionPresets(raw)
	local presets = {}

	if type(raw) ~= "table" then
		return presets
	end

	for _, rawPreset in ipairs(raw) do
		if type(rawPreset) == "table" then
			local legacyKind = rawPreset.kind == "NpcTalk"
			local rawKind = legacyKind and "Zoom" or rawPreset.kind
			local kind = oneOf(rawKind, Schema.TRANSITION_KINDS, "FadeBlack")
			local template = Schema.newTransitionPreset(nil, kind)
			local rawParams = type(rawPreset.params) == "table" and rawPreset.params or {}
			local params = {}

			for key, default in pairs(template.params) do
				if key == "easing" then
					params[key] = oneOf(rawParams[key], Schema.EASINGS, default)
				else
					params[key] = math.max(0, asNumber(rawParams[key], default))
				end
			end

			local name = asString(rawPreset.name, kind)
			if (asString(rawPreset.id, "") == Schema.DEFAULT_ZOOM or legacyKind) and isLegacyZoomName(name) then
				name = "Zoom"
			end
			table.insert(presets, {
				id = asString(rawPreset.id, Schema.newId("tr")),
				name = name,
				kind = kind,
				params = params,
			})
		end
	end

	return presets
end

local function normalizeSequencePresets(raw)
	local presets = {}
	local seen = {}
	for _, item in ipairs(type(raw) == "table" and raw or {}) do
		if type(item) == "table" then
			local id = asString(item.id, Schema.newId("seq"))
			if not seen[id] then
				seen[id] = true
				table.insert(presets, {
					id = id,
					name = asString(item.name, "Sequence preset"),
					sequence = Schema.normalizeSequence(item.sequence),
				})
			end
		end
	end
	return presets
end

local function normalizeRecycleBin(raw)
	local bin = Schema.emptyRecycleBin()

	if type(raw) ~= "table" then
		return bin
	end

	if type(raw.chapters) == "table" then
		for _, rawItem in ipairs(raw.chapters) do
			if type(rawItem) == "table" then
				local chapter = Schema.normalizeChapter(rawItem.chapter)
				if chapter then
					table.insert(bin.chapters, {
						id = asString(rawItem.id, Schema.newId("binc")),
						deletedAt = asNumber(rawItem.deletedAt, os.time()),
						chapter = chapter,
					})
				end
			end
		end
	end

	if type(raw.scenes) == "table" then
		for _, rawItem in ipairs(raw.scenes) do
			if type(rawItem) == "table" then
				local scene = Schema.normalizeScene(rawItem.scene or rawItem)
				if scene then
					table.insert(bin.scenes, {
						id = asString(rawItem.id, Schema.newId("bins")),
						deletedAt = asNumber(rawItem.deletedAt, os.time()),
						chapterId = asString(rawItem.chapterId, ""),
						scene = scene,
					})
				end
			end
		end
	end

	if type(raw.portraits) == "table" then
		for _, rawItem in ipairs(raw.portraits) do
			if type(rawItem) == "table" then
				local character = Schema.trimName(asString(rawItem.character, ""))
				local imageId = Schema.formatImageId(rawItem.imageId)

				if character ~= "" and imageId ~= "" then
					table.insert(bin.portraits, {
						id = asString(rawItem.id, Schema.newId("binp")),
						character = character,
						imageId = imageId,
						deletedAt = asNumber(rawItem.deletedAt, os.time()),
					})
				end
			end
		end
	end

	return bin
end

-- Accepts a v2 project, a v1 project, a bare v1 scene, or a bare v2 chapter.
-- Returns project, errorMessage, skippedCount.
function Schema.normalizeProject(raw, allowEmpty)
	if type(raw) ~= "table" then
		return nil, "Top level value is not a JSON object."
	end

	raw = Migrate.upgrade(raw)

	local rawChapters = raw.chapters

	-- A bare chapter export.
	if rawChapters == nil and raw.scenes ~= nil and raw.startSceneId ~= nil then
		rawChapters = { raw }
	end

	if type(rawChapters) ~= "table" then
		return nil, "No chapters found in the pasted JSON."
	end

	local project = {
		formatVersion = Schema.FORMAT_VERSION,
		name = asString(raw.name, "VN Project"),
		mainCharacter = Schema.trimName(asString(raw.mainCharacter, "")),
		characters = normalizeCharacters(raw.characters),
		cameraPoses = normalizeCameraPoses(raw.cameraPoses),
		textboxPresets = normalizeTextboxPresets(raw.textboxPresets),
		transitionPresets = normalizeTransitionPresets(raw.transitionPresets),
		sequencePresets = normalizeSequencePresets(raw.sequencePresets),
		roomDefinitions = RoomAssembly.normalizeList(raw.roomDefinitions),
		assemblyPresets = RoomAssembly.normalizePresets(raw.assemblyPresets),
		portraitLayout = Schema.normalizePortraitLayout(raw.portraitLayout),
		exploreMovement = Schema.normalizeExploreMovementSettings(raw.exploreMovement),
		speakerSweep = Schema.normalizeSpeakerSweepSettings(raw.speakerSweep),
		hotspotZoom = Schema.normalizeHotspotZoomSettings(raw.hotspotZoom),
		portraitTiming = Schema.normalizePortraitTimingSettings(raw.portraitTiming),
		chapters = {},
		recycleBin = normalizeRecycleBin(raw.recycleBin),
	}

	local skipped = 0

	for _, rawChapter in ipairs(rawChapters) do
		local chapter = Schema.normalizeChapter(rawChapter)
		if chapter then
			table.insert(project.chapters, chapter)
		else
			skipped += 1
		end
	end

	if #project.chapters == 0 and not allowEmpty then
		return nil, "The pasted JSON contained no readable chapters."
	end
	-- A placement without a character preset cannot be rendered or selected.
	-- Drop it during import and clear any interaction binding that named it.
	for _, chapter in ipairs(project.chapters) do
		for _, scene in ipairs(chapter.scenes) do
			local validPlacementIds = {}
			for index = #(scene.characterModels or {}), 1, -1 do
				local placement = scene.characterModels[index]
				if not Schema.findCharacter(project, placement.character) then
					table.remove(scene.characterModels, index)
				else
					validPlacementIds[placement.id] = true
				end
			end
			for _, interaction in ipairs(scene.interactions or {}) do
				if interaction.targetCharacterModelId ~= "" and not validPlacementIds[interaction.targetCharacterModelId] then
					interaction.targetCharacterModelId = ""
				end
			end
		end
	end

	Schema.ensureDefaults(project)

	return project, nil, skipped
end

return Schema
