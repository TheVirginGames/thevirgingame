-- Turns the in-memory project into JSON text and back again.
--
-- The exported JSON describes content only, never editor scripts or UI, so the
-- same text is what the game runtime and the database hold.

local HttpService = game:GetService("HttpService")

local Schema = require(script.Parent.Schema)

local JSONCodec = {}

-- HttpService only emits compact JSON. Re-indent for the export box.
local function prettyPrint(compact)
	local out = {}
	local indent = 0
	local inString = false
	local escaped = false

	local function newline()
		table.insert(out, "\n" .. string.rep("  ", indent))
	end

	for index = 1, #compact do
		local character = string.sub(compact, index, index)

		if escaped then
			table.insert(out, character)
			escaped = false
		elseif character == "\\" then
			table.insert(out, character)
			escaped = true
		elseif character == '"' then
			inString = not inString
			table.insert(out, character)
		elseif inString then
			table.insert(out, character)
		elseif character == "{" or character == "[" then
			indent += 1
			table.insert(out, character)
			newline()
		elseif character == "}" or character == "]" then
			indent -= 1
			newline()
			table.insert(out, character)
		elseif character == "," then
			table.insert(out, character)
			newline()
		elseif character == ":" then
			table.insert(out, ": ")
		else
			table.insert(out, character)
		end
	end

	return table.concat(out)
end

local function encode(value, pretty)
	local ok, result = pcall(function()
		return HttpService:JSONEncode(value)
	end)

	if not ok then
		return nil, "Could not encode this data as JSON: " .. tostring(result)
	end

	if pretty == false then
		return result
	end

	return prettyPrint(result)
end

local function stripLegacyScene(scene)
	Schema.ensureSubscenes(scene)
	-- These legacy fields are only an import path. The ordered subscenes
	-- are the single persisted source for environment and sequence data.
	scene.intro = nil
	scene.outro = nil
	scene.stage = nil
	scene.background = nil
end

local function serializableChapter(chapter)
	local copy = Schema.deepCopy(chapter)
	for _, scene in ipairs(copy.scenes or {}) do
		stripLegacyScene(scene)
	end
	return copy
end

local function projectEnvelope(project)
	local chapters = {}
	for _, chapter in ipairs(project.chapters or {}) do
		table.insert(chapters, serializableChapter(chapter))
	end
	local recycleBin = Schema.deepCopy(project.recycleBin or Schema.emptyRecycleBin())
	for _, item in ipairs(recycleBin.chapters or {}) do
		for _, scene in ipairs(item.chapter and item.chapter.scenes or {}) do stripLegacyScene(scene) end
	end
	for _, item in ipairs(recycleBin.scenes or {}) do
		if item.scene then stripLegacyScene(item.scene) end
	end
	return {
		formatVersion = Schema.FORMAT_VERSION,
		name = project.name,
		characters = project.characters or {},
		cameraPoses = project.cameraPoses or {},
		textboxPresets = project.textboxPresets or {},
		transitionPresets = project.transitionPresets or {},
		portraitLayout = Schema.normalizePortraitLayout(project.portraitLayout),
		chapters = chapters,
		recycleBin = recycleBin,
	}
end

function JSONCodec.encodeProject(project, pretty)
	return encode(projectEnvelope(project), pretty)
end

-- A chapter is wrapped in a project envelope carrying the presets it needs, so
-- importing it takes the same path as importing a whole project.
function JSONCodec.encodeChapter(project, chapter, pretty)
	local envelope = projectEnvelope(project)
	envelope.name = chapter.name
	envelope.chapters = { serializableChapter(chapter) }
	envelope.recycleBin = Schema.emptyRecycleBin()
	return encode(envelope, pretty)
end

-- Returns project, errorMessage, skippedCount.
function JSONCodec.decodeProject(text, allowEmpty)
	if type(text) ~= "string" or text:match("^%s*$") then
		return nil, "Nothing was pasted into the box."
	end

	local ok, decoded = pcall(function()
		return HttpService:JSONDecode(text)
	end)

	if not ok then
		return nil, "That is not valid JSON. Check for a missing brace or comma."
	end

	return Schema.normalizeProject(decoded, allowEmpty)
end

return JSONCodec
