-- Upgrades raw (not yet normalized) project tables from older format versions.
--
-- Works on plain tables only and produces a plain table, which then goes
-- through Schema.normalizeProject like any other import.

local Migrate = {}

local function isV1(raw)
	if type(raw) ~= "table" then
		return false
	end

	if raw.chapters ~= nil then
		return false
	end

	-- A bare v2 chapter export has scenes plus a startSceneId.
	if raw.startSceneId ~= nil then
		return false
	end

	return raw.scenes ~= nil or raw.segments ~= nil
end

local function migrateV1Scene(rawScene, index)
	local scene = {
		id = rawScene.id or ("scene_v1_" .. index),
		name = rawScene.name or ("Scene " .. index),
		flow = { x = 60 + (index - 1) * 240, y = 120 },
		stage = { kind = "Novel2D", cameraPoseId = "" },
		background = rawScene.background or { kind = "Color", value = "40,44,72" },
		intro = { segments = rawScene.segments or {} },
		outro = { segments = {} },
		interactions = {},
		next = { sceneId = "", transitionId = "tr_fadeblack" },
	}

	-- v1 dialogue lines used "speaker"; the normalizer accepts both, but the
	-- v1 portrait field held mood labels that are not image ids, so drop them.
	for _, segment in ipairs(scene.intro.segments) do
		if type(segment) == "table" and segment.kind == "Dialogue" and type(segment.entries) == "table" then
			for _, entry in ipairs(segment.entries) do
				if type(entry) == "table" and type(entry.portrait) == "string" and not entry.portrait:match("^rbxassetid://") and not entry.portrait:match("^%d+$") then
					entry.portrait = ""
				end
			end
		end
	end

	return scene
end

function Migrate.upgrade(raw)
	if not isV1(raw) then
		return raw
	end

	local rawScenes = raw.scenes
	if rawScenes == nil and raw.segments ~= nil then
		rawScenes = { raw }
	end

	local scenes = {}
	for index, rawScene in ipairs(rawScenes or {}) do
		if type(rawScene) == "table" then
			table.insert(scenes, migrateV1Scene(rawScene, index))
		end
	end

	for index, scene in ipairs(scenes) do
		local following = scenes[index + 1]
		scene.next.sceneId = following and following.id or ""
	end

	return {
		formatVersion = 2,
		name = raw.name or "VN Project",
		characters = raw.characters or {},
		cameraPoses = {},
		textboxPresets = {},
		transitionPresets = {},
		chapters = {
			{
				id = "chapter_v1",
				name = "Chapter 1",
				startSceneId = scenes[1] and scenes[1].id or "",
				flags = {},
				scenes = scenes,
			},
		},
		recycleBin = raw.recycleBin,
	}
end

return Migrate
