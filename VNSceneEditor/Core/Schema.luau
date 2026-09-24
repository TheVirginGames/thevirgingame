-- The project data format: factories, catalog helpers and normalizers.
--
-- Every value here is a plain string, number, boolean or table so a project
-- round trips through JSON. Roblox datatypes are never stored: colours travel
-- as "r,g,b" and camera poses as twelve comma separated CFrame components.
--
--   Project = {
--       formatVersion = 3, name,
--       characters       = { { name, portraits = { imageId, ... } }, ... },
--       cameraPoses      = { { id, name, cframe }, ... },
--       textboxPresets   = { TextboxPreset, ... },
--       transitionPresets= { TransitionPreset, ... },
--       portraitLayout  = { x, y, scaleX, scaleY }, -- shared portrait transform
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
--       next = { sceneId, transitionId },          -- Novel2D auto advance
--   }
--
--   Subscene = {
--       id, name, role = "intro" | "outro" | "custom",
--       kind = "Novel2D" | "Room3D" | "Explore3D",
--       stage = { kind, cameraPoseId }, background = { kind, value, poseId },
--       sequence = Sequence, nextTransitionId, awaitRoutes, linkPreviousRoom,
--       linkedRoomId,
--   }
--
--   Interaction = {
--       id, name, kind = "Hotspot" | "Trigger" | "Exit", targetId,
--       scope = "Local" | "Shared", subsceneId,
--       conditions = { { flag, op, value } }, repeatPolicy = "once" | "always",
--       transitionId,                              -- enter transition (e.g. NpcTalk), reversed on exit
--       sequence = Sequence, onComplete = { Event },
--       exit = { sceneId, transitionId },          -- used when kind == "Exit"
--   }
--
--   Sequence = { segments = { Segment } }
--   Segment  = { id, kind = "Timed", duration, events, tracks }
--            | { id, kind = "Dialogue", textboxPresetId, entries }
--   Entry    = { id, character, text, skippable, speaking, portrait, events, tracks }
--   Event    = { id, type, time, duration, easing, params }
--   Track    = { id, target = "portrait", keys = { { t, x, y, scale, rotation, alpha, easing } } }

local EventRegistry = require(script.Parent.EventRegistry)
local Migrate = require(script.Parent.Migrate)

local Schema = {}

Schema.FORMAT_VERSION = 3
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
Schema.INTERACTION_KINDS = { "Hotspot", "Trigger", "Exit" }
Schema.REPEAT_POLICIES = { "once", "always" }
Schema.FLAG_KINDS = { "bool", "int" }
Schema.SCENE_FLAG_PREFIX = "scene:"
Schema.CONDITION_OPS = { "==", "~=", ">", "<", ">=", "<=" }
Schema.EASINGS = { "Linear", "Quad", "Cubic", "Quart", "Sine", "Back", "Bounce", "Elastic" }
Schema.ANIM_KINDS = { "None", "Fade", "SlideUp", "SlideDown", "SlideLeft", "SlideRight", "Scale" }
Schema.TRANSITION_KINDS = { "FadeBlack", "CrossFade", "NpcTalk", "CameraSweep" }
Schema.TEXTBOX_ELEMENTS = { "box", "namePlate", "speaking", "body", "continueHint" }

Schema.DEFAULT_TEXTBOX = "tb_default"
Schema.DEFAULT_FADE = "tr_fadeblack"
Schema.DEFAULT_CROSSFADE = "tr_crossfade"
Schema.DEFAULT_NPCTALK = "tr_npctalk"
Schema.DEFAULT_SWEEP = "tr_sweep"

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
		duration = 0,
		easing = "Quad",
		params = EventRegistry.defaultParams(eventType),
	}
end

function Schema.newKey(t)
	return { t = t or 0, x = 0.5, y = 1, scale = 1, rotation = 0, alpha = 1, easing = "Quad" }
end

function Schema.newTrack(target)
	return {
		id = Schema.newId("trk"),
		target = target or "portrait",
		keys = { Schema.newKey(0) },
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
		autoAdvanceDelay = Schema.DEFAULT_DIALOGUE_AUTO_ADVANCE,
		portrait = "",
		events = {},
		tracks = {},
	}
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

function Schema.newDialogueSegment()
	return {
		id = Schema.newId("dlg"),
		kind = "Dialogue",
		textboxPresetId = "",
		entries = { Schema.newDialogueEntry("", "New line.") },
	}
end

function Schema.newSequence(withDefaults)
	local sequence = { segments = {} }

	if withDefaults then
		table.insert(sequence.segments, Schema.newTimedSegment(1))
		table.insert(sequence.segments, Schema.newDialogueSegment())
	end

	return sequence
end

function Schema.newInteraction(kind)
	return {
		id = Schema.newId("int"),
		name = kind == "Exit" and "Exit" or "New interaction",
		kind = kind or "Hotspot",
		targetId = "",
		conditions = {},
		repeatPolicy = kind == "Exit" and "always" or "once",
		scope = "Shared",
		subsceneId = "",
		transitionId = "",
		sequence = Schema.newSequence(false),
		onComplete = {},
		exit = { sceneId = "", transitionId = Schema.DEFAULT_FADE },
	}
end

-- A subscene owns its environment and sequence; flags remain on the scene node.
function Schema.newSubscene(name, kind)
	kind = kind or "Novel2D"
	return {
		id = Schema.newId("sub"),
		name = name or "Subscene",
		role = "custom",
		kind = kind,
		stage = { kind = kind, cameraPoseId = "" },
		background = { kind = kind == "Novel2D" and "Color" or "Camera3D", value = "40,44,72", poseId = "" },
		sequence = Schema.newSequence(false),
		nextTransitionId = Schema.DEFAULT_FADE,
		awaitRoutes = {},
		linkPreviousRoom = false,
		linkedRoomId = "",
	}
end

function Schema.subsceneIndex(scene, id)
	return Schema.findById(scene and scene.subscenes, id)
end

function Schema.subsceneView(scene, subscene)
	local view = table.clone(scene)
	view.stage = table.clone(subscene.stage)
	view.background = table.clone(subscene.background)
	if subscene.linkPreviousRoom and Schema.isValidRoomLink(scene, subscene) then
		local previous = Schema.previousSubscene(scene, subscene.id)
		view.background = Schema.subsceneView(scene, previous).background
		local poseId = Schema.effectivePoseId(scene, subscene)
		view.stage.cameraPoseId = poseId
		view.background.poseId = poseId
	end
	return view
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
		if not current.linkPreviousRoom or not Schema.isValidRoomLink(scene, current) then break end
		current = Schema.previousSubscene(scene, current.id)
	end
	return false
end

-- Repair structural edits in one place so saved data never keeps a broken Merge.
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
	Schema.forEachEventList(scene, function(events, owner)
		local source = nil
		if owner.owner == "subscene" then
			source = Schema.subsceneIndex(scene, owner.subsceneId)
		elseif owner.owner == "interaction" then
			local interaction = Schema.findInteraction(scene, owner.interactionId)
			if interaction and interaction.scope == "Local" then
				source = Schema.subsceneIndex(scene, interaction.subsceneId)
			end
		end
		for _, event in ipairs(events) do
			if event.type == "FlowGotoSubscene" and event.params.subsceneId ~= ""
				and not Schema.subsceneIndex(scene, event.params.subsceneId) then
				event.params.subsceneId = ""
				table.insert(warnings, "A Go to Subscene event had a missing destination; destination cleared.")
			end
			if event.type == "FlowGotoSubscene" and event.params.transitionId == "Merge"
				and not Schema.isValidMergeBetween(scene, source, event.params.subsceneId) then
				event.params.transitionId = Schema.DEFAULT_FADE
				table.insert(warnings, "A Go to Subscene event had an incompatible Merge; changed to Fade to Black.")
			elseif event.type == "FlowGotoSubscene" and event.transitionExplicit ~= true
				and Schema.isValidMergeBetween(scene, source, event.params.subsceneId) then
				event.params.transitionId = "Merge"
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

function Schema.newScene(name, kind)
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
		intro = Schema.newSequence(kind == "Novel2D"),
		outro = Schema.newSequence(false),
		flags = {},
		interactions = {},
		next = { sceneId = "", transitionId = Schema.DEFAULT_FADE },
	}
end

function Schema.newChapter(name)
	local scene = Schema.newScene("Opening", "Novel2D")

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

function Schema.newTransitionPreset(name, kind)
	kind = kind or "FadeBlack"

	local params = {}

	if kind == "FadeBlack" then
		params = { fadeOut = 0.5, hold = 0.2, fadeIn = 0.5 }
	elseif kind == "CrossFade" then
		params = { duration = 0.8 }
	elseif kind == "NpcTalk" then
		params = { duration = 0.6, portraitFade = 0.3 }
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

function Schema.newProject(name)
	local project = {
		formatVersion = Schema.FORMAT_VERSION,
		name = name or "VN Project",
		characters = {},
		cameraPoses = {},
		textboxPresets = {},
		transitionPresets = {},
		portraitLayout = Schema.newPortraitLayout(),
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
	project.cameraPoses = project.cameraPoses or {}
	project.characters = project.characters or {}
	project.portraitLayout = Schema.normalizePortraitLayout(project.portraitLayout)
	project.chapters = project.chapters or {}
	project.recycleBin = project.recycleBin or Schema.emptyRecycleBin()
	for _, chapter in ipairs(project.chapters) do
		for _, scene in ipairs(chapter.scenes or {}) do
			Schema.ensureSubscenes(scene)
			Schema.reconcileSubscenes(scene)
		end
	end

	if not Schema.findById(project.textboxPresets, Schema.DEFAULT_TEXTBOX) then
		local preset = Schema.newTextboxPreset("Default")
		preset.id = Schema.DEFAULT_TEXTBOX
		table.insert(project.textboxPresets, 1, preset)
	end

	local defaults = {
		{ Schema.DEFAULT_FADE, "Fade to black", "FadeBlack" },
		{ Schema.DEFAULT_CROSSFADE, "Cross fade", "CrossFade" },
		{ Schema.DEFAULT_NPCTALK, "NPC talk", "NpcTalk" },
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
	return true
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
		table.insert(list, {
			owner = "interaction",
			interactionId = interaction.id,
			label = "Interaction: " .. interaction.name,
			sequence = interaction.sequence,
		})
	end

	return list
end

function Schema.getSequence(scene, owner, interactionId)
	if owner == "subscene" then
		local subscene = Schema.subsceneIndex(scene, interactionId)
		return subscene and subscene.sequence or nil
	end

	if owner == "interaction" then
		local interaction = Schema.findInteraction(scene, interactionId)
		return interaction and interaction.sequence or nil
	end

	if owner == "outro" then return scene.outro end
	return scene.intro
end

function Schema.forEachEntry(scene, callback)
	for _, item in ipairs(Schema.sequencesOf(scene)) do
		for _, segment in ipairs(item.sequence.segments) do
			if segment.kind == "Dialogue" then
				for _, entry in ipairs(segment.entries) do
					callback(entry, segment, item)
				end
			end
		end
	end
end

function Schema.forEachEventList(scene, callback)
	for _, item in ipairs(Schema.sequencesOf(scene)) do
		for segmentIndex, segment in ipairs(item.sequence.segments) do
			if segment.kind == "Timed" then
				callback(segment.events, item, {
					kind = "Timed",
					segmentIndex = segmentIndex,
				})
			else
				for entryIndex, entry in ipairs(segment.entries) do
					callback(entry.events, item, {
						kind = "Dialogue",
						segmentIndex = segmentIndex,
						entryIndex = entryIndex,
					})
				end
			end
		end
	end

	for _, interaction in ipairs(scene.interactions or {}) do
		callback(interaction.onComplete, { owner = "interaction", interactionId = interaction.id, label = interaction.name }, {
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
-- when a source has a destination; unassigned Exit and Go To Scene sources are
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

	for _, interaction in ipairs(scene.interactions or {}) do
		if interaction.kind == "Exit" then
			table.insert(links, {
				id = interaction.id,
				kind = "exit",
				interactionId = interaction.id,
				toSceneId = interaction.exit.sceneId,
				transitionId = interaction.exit.transitionId,
				label = "Exit: " .. interaction.name,
				conditional = #interaction.conditions > 0,
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
					subsceneId = owner.subsceneId,
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
					subsceneId = owner.subsceneId,
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
	for _, subscene in ipairs(scene.subscenes or {}) do
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

		for _, interaction in ipairs(scene.interactions or {}) do
			if interaction.exit and interaction.exit.sceneId == sceneId then
				interaction.exit.sceneId = ""
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
	for _, item in ipairs(Schema.sequencesOf(scene)) do
		total += #item.sequence.segments
	end
	return total
end

-- Fresh ids throughout a copied scene so two scenes never share entry ids.
function Schema.reidentifyScene(scene)
	scene.id = Schema.newId("scene")
	local subsceneIds = {}
	for _, subscene in ipairs(Schema.ensureSubscenes(scene)) do
		local oldId = subscene.id
		subscene.id = Schema.newId("sub")
		subsceneIds[oldId] = subscene.id
	end

	local function reidSequence(sequence)
		for _, segment in ipairs(sequence.segments) do
			segment.id = Schema.newId(segment.kind == "Timed" and "timed" or "dlg")

			if segment.kind == "Timed" then
				for _, event in ipairs(segment.events) do
					event.id = Schema.newId("evt")
				end
				for _, track in ipairs(segment.tracks) do
					track.id = Schema.newId("trk")
				end
			else
				for _, entry in ipairs(segment.entries) do
					entry.id = Schema.newId("line")
					for _, event in ipairs(entry.events) do
						event.id = Schema.newId("evt")
					end
					for _, track in ipairs(entry.tracks) do
						track.id = Schema.newId("trk")
					end
				end
			end
		end
	end

	for _, subscene in ipairs(scene.subscenes) do
		subscene.linkedRoomId = subsceneIds[subscene.linkedRoomId] or ""
		reidSequence(subscene.sequence)
		for _, route in ipairs(subscene.awaitRoutes or {}) do
			route.id = Schema.newId("route")
			route.toSubsceneId = subsceneIds[route.toSubsceneId] or ""
		end
	end

	for _, interaction in ipairs(scene.interactions) do
		interaction.id = Schema.newId("int")
		interaction.subsceneId = subsceneIds[interaction.subsceneId] or ""
		reidSequence(interaction.sequence)
		for _, event in ipairs(interaction.onComplete) do
			event.id = Schema.newId("evt")
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

	-- v1 CameraMove carried a "target" name rather than a pose id.
	if eventType == "CameraMoveTo" and params.poseId == "" and type(rawParams.target) == "string" then
		params.poseId = ""
	end

	return {
		id = asString(raw.id, Schema.newId("evt")),
		type = eventType,
		time = math.max(0, asNumber(raw.time, 0)),
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

function Schema.normalizeKey(raw)
	if type(raw) ~= "table" then
		return nil
	end

	return {
		t = math.max(0, asNumber(raw.t, 0)),
		x = asNumber(raw.x, 0.5),
		y = asNumber(raw.y, 1),
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

	local keys = {}

	if type(raw.keys) == "table" then
		for _, rawKey in ipairs(raw.keys) do
			local key = Schema.normalizeKey(rawKey)
			if key then
				table.insert(keys, key)
			end
		end
	end

	if #keys == 0 then
		table.insert(keys, Schema.newKey(0))
	end

	table.sort(keys, function(a, b)
		return a.t < b.t
	end)

	return {
		id = asString(raw.id, Schema.newId("trk")),
		target = "portrait",
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

function Schema.normalizeInteraction(raw)
	if type(raw) ~= "table" then
		return nil
	end

	local kind = oneOf(raw.kind, Schema.INTERACTION_KINDS, "Hotspot")
	local conditions = {}

	if type(raw.conditions) == "table" then
		for _, rawCondition in ipairs(raw.conditions) do
			local condition = Schema.normalizeCondition(rawCondition)
			if condition then
				table.insert(conditions, condition)
			end
		end
	end

	local rawGoto = type(raw.exit) == "table" and raw.exit or {}

	return {
		id = asString(raw.id, Schema.newId("int")),
		name = asString(raw.name, kind),
		kind = kind,
		targetId = asString(raw.targetId, ""),
		conditions = conditions,
		repeatPolicy = oneOf(raw.repeatPolicy, Schema.REPEAT_POLICIES, "once"),
		scope = oneOf(raw.scope, { "Local", "Shared" }, "Shared"),
		subsceneId = asString(raw.subsceneId, ""),
		transitionId = asString(raw.transitionId, ""),
		sequence = Schema.normalizeSequence(raw.sequence),
		onComplete = normalizeEventList(raw.onComplete),
		exit = {
			sceneId = asString(rawGoto.sceneId, ""),
			transitionId = asString(rawGoto.transitionId, Schema.DEFAULT_FADE),
		},
	}
end

local function normalizeSubscene(raw)
	if type(raw) ~= "table" then return nil end
	local stage = type(raw.stage) == "table" and raw.stage or {}
	local kind = oneOf(raw.kind or stage.kind, Schema.SCENE_KINDS, "Novel2D")
	local background = type(raw.background) == "table" and raw.background or {}
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
		sequence = Schema.normalizeSequence(raw.sequence),
		nextTransitionId = asString(raw.nextTransitionId, Schema.DEFAULT_FADE),
		awaitRoutes = routes,
		linkPreviousRoom = raw.linkPreviousRoom == true,
		linkedRoomId = asString(raw.linkedRoomId, ""),
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

				table.insert(characters, { name = name, portraits = portraits })
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
			local kind = oneOf(rawPreset.kind, Schema.TRANSITION_KINDS, "FadeBlack")
			local template = Schema.newTransitionPreset(nil, kind)
			local rawParams = type(rawPreset.params) == "table" and rawPreset.params or {}
			local params = {}

			for key, default in pairs(template.params) do
				params[key] = math.max(0, asNumber(rawParams[key], default))
			end

			table.insert(presets, {
				id = asString(rawPreset.id, Schema.newId("tr")),
				name = asString(rawPreset.name, kind),
				kind = kind,
				params = params,
			})
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
		characters = normalizeCharacters(raw.characters),
		cameraPoses = normalizeCameraPoses(raw.cameraPoses),
		textboxPresets = normalizeTextboxPresets(raw.textboxPresets),
		transitionPresets = normalizeTransitionPresets(raw.transitionPresets),
		portraitLayout = Schema.normalizePortraitLayout(raw.portraitLayout),
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

	Schema.ensureDefaults(project)

	return project, nil, skipped
end

return Schema
