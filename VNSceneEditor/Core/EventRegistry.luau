-- Catalog of every effect that can be attached to a timeline second, a dialogue
-- entry, or an interaction's onComplete list.
--
-- Adding an effect means one entry here plus one branch in
-- Runtime/SequenceState.applyEvent (for state) or Render/Presenter.playEvents
-- (for transient effects). The inspector, event panel and normalizers all read
-- this table, so no UI code changes.
--
-- Field kinds:
--   string | number | boolean | choice (choices = {...})
--   picker  (picker = "scene" | "flag" | "pose" | "transition" | "textbox" | "character")
--
-- anchors: Timed (a second inside a timed segment), Dialogue (a dialogue entry),
-- Complete (an interaction's onComplete list).

local EventRegistry = {}

local ALL = { Timed = true, Dialogue = true, Complete = true }
local SEQ = { Timed = true, Dialogue = true }

local definitions = {
	BackgroundChange = {
		displayName = "Background",
		category = "Background",
		color = Color3.fromRGB(104, 202, 152),
		anchors = SEQ,
		durational = true,
		fields = {
			{ key = "kind", label = "Kind", kind = "choice", choices = { "Color", "Image", "Camera3D" }, default = "Color" },
			{ key = "value", label = "Colour (r,g,b) or image id", kind = "string", default = "40,44,72" },
			{ key = "poseId", label = "Camera pose", kind = "picker", picker = "pose", default = "" },
		},
	},
	CameraMoveTo = {
		displayName = "Camera Move To",
		category = "Camera",
		color = Color3.fromRGB(255, 196, 84),
		anchors = SEQ,
		durational = true,
		fields = {
			{ key = "poseId", label = "Camera pose", kind = "picker", picker = "pose", default = "" },
		},
	},
	PortraitSet = {
		displayName = "Show Portrait",
		category = "Portrait",
		color = Color3.fromRGB(88, 178, 255),
		anchors = SEQ,
		durational = true,
		fields = {
			{ key = "character", label = "Character", kind = "picker", picker = "character", default = "" },
			{ key = "imageId", label = "Portrait image id", kind = "string", default = "" },
		},
	},
	PortraitHide = {
		displayName = "Hide Portrait",
		category = "Portrait",
		color = Color3.fromRGB(126, 138, 168),
		anchors = SEQ,
		durational = true,
		fields = {},
	},
	TextboxSetPreset = {
		displayName = "Textbox Style",
		category = "Textbox",
		color = Color3.fromRGB(230, 140, 200),
		anchors = SEQ,
		fields = {
			{ key = "presetId", label = "Textbox preset", kind = "picker", picker = "textbox", default = "" },
		},
	},
	PlaySound = {
		displayName = "Sound Effect",
		category = "Audio",
		color = Color3.fromRGB(196, 152, 255),
		anchors = ALL,
		fields = {
			{ key = "soundId", label = "Sound Id", kind = "string", default = "rbxassetid://0" },
			{ key = "volume", label = "Volume", kind = "number", default = 0.5 },
		},
	},
	PlayMusic = {
		displayName = "Music",
		category = "Audio",
		color = Color3.fromRGB(152, 138, 255),
		anchors = ALL,
		fields = {
			{ key = "trackId", label = "Track Id", kind = "string", default = "rbxassetid://0" },
			{ key = "volume", label = "Volume", kind = "number", default = 0.4 },
			{ key = "speed", label = "Playback speed", kind = "number", default = 1 },
			{ key = "fade", label = "Fade", kind = "number", default = 1 },
		},
	},
	StopMusic = {
		displayName = "Stop Music",
		category = "Audio",
		color = Color3.fromRGB(120, 110, 190),
		anchors = ALL,
		fields = {
			{ key = "fade", label = "Fade", kind = "number", default = 1 },
		},
	},
	ScreenShake = {
		displayName = "Screen Shake",
		category = "Effects",
		color = Color3.fromRGB(255, 118, 92),
		anchors = SEQ,
		fields = {
			{ key = "intensity", label = "Intensity", kind = "number", default = 8 },
			{ key = "duration", label = "Duration", kind = "number", default = 0.35 },
		},
	},
	ScreenFlash = {
		displayName = "Screen Flash",
		category = "Effects",
		color = Color3.fromRGB(255, 236, 140),
		anchors = SEQ,
		fields = {
			{ key = "color", label = "Colour", kind = "string", default = "255,255,255" },
			{ key = "duration", label = "Duration", kind = "number", default = 0.3 },
		},
	},
	FlowSetFlag = {
		displayName = "Set Flag",
		category = "Flow",
		color = Color3.fromRGB(96, 214, 200),
		anchors = ALL,
		fields = {
			{ key = "flag", label = "Flag", kind = "picker", picker = "flag", default = "" },
			{ key = "value", label = "Value (true/false or number)", kind = "string", default = "true" },
		},
	},
	FlowIncrement = {
		displayName = "Increment Flag",
		category = "Flow",
		color = Color3.fromRGB(80, 190, 180),
		anchors = ALL,
		fields = {
			{ key = "flag", label = "Flag", kind = "picker", picker = "flag", default = "" },
			{ key = "amount", label = "Amount", kind = "number", default = 1 },
		},
	},
	FlowGoto = {
		displayName = "Go To Scene",
		category = "Flow",
		color = Color3.fromRGB(255, 160, 90),
		anchors = ALL,
		fields = {
			{ key = "sceneId", label = "Scene", kind = "picker", picker = "scene", default = "" },
			{ key = "transitionId", label = "Transition", kind = "picker", picker = "transition", default = "" },
		},
	},
	FlowEndChapter = {
		displayName = "End Chapter",
		category = "Flow",
		color = Color3.fromRGB(230, 90, 120),
		anchors = ALL,
		fields = {},
	},
}

local order = {
	"BackgroundChange",
	"CameraMoveTo",
	"PortraitSet",
	"PortraitHide",
	"TextboxSetPreset",
	"PlaySound",
	"PlayMusic",
	"StopMusic",
	"ScreenShake",
	"ScreenFlash",
	"FlowSetFlag",
	"FlowIncrement",
	"FlowGoto",
	"FlowEndChapter",
}

-- Old names from format version 1 projects.
local aliases = {
	CameraMove = "CameraMoveTo",
}

function EventRegistry.resolveType(eventType)
	if definitions[eventType] then
		return eventType
	end

	return aliases[eventType]
end

function EventRegistry.get(eventType)
	return definitions[eventType]
end

function EventRegistry.exists(eventType)
	return definitions[eventType] ~= nil
end

function EventRegistry.listTypes(anchorKind)
	local result = {}

	for _, eventType in ipairs(order) do
		local definition = definitions[eventType]
		if not anchorKind or definition.anchors[anchorKind] then
			table.insert(result, eventType)
		end
	end

	return result
end

function EventRegistry.defaultParams(eventType)
	local definition = definitions[eventType]
	local params = {}

	if definition then
		for _, field in ipairs(definition.fields) do
			params[field.key] = field.default
		end
	end

	return params
end

function EventRegistry.fields(eventType)
	local definition = definitions[eventType]
	return definition and definition.fields or {}
end

function EventRegistry.displayName(eventType)
	local definition = definitions[eventType]
	return definition and definition.displayName or tostring(eventType)
end

function EventRegistry.category(eventType)
	local definition = definitions[eventType]
	return definition and definition.category or "Other"
end

function EventRegistry.color(eventType)
	local definition = definitions[eventType]
	return definition and definition.color or Color3.fromRGB(150, 150, 165)
end

function EventRegistry.isDurational(eventType)
	local definition = definitions[eventType]
	return definition ~= nil and definition.durational == true
end

function EventRegistry.isFlow(eventType)
	return EventRegistry.category(eventType) == "Flow"
end

-- Short one line description used in list rows. Picker values are ids, so the
-- caller can pass a resolver to turn them into names.
function EventRegistry.summarize(event, resolve)
	local definition = definitions[event.type]
	if not definition then
		return tostring(event.type)
	end

	local parts = {}
	for _, field in ipairs(definition.fields) do
		local value = event.params and event.params[field.key]
		if value ~= nil and value ~= "" then
			if field.kind == "picker" and resolve then
				value = resolve(field.picker, value) or value
			end
			table.insert(parts, tostring(value))
		end
	end

	local text = definition.displayName
	if #parts > 0 then
		text = text .. "  " .. table.concat(parts, " / ")
	end

	if definition.durational and (event.duration or 0) > 0 then
		text = text .. string.format("  (%.2fs)", event.duration)
	end

	return text
end

return EventRegistry
