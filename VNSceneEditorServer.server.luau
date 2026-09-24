--------------------------------------------------------------------------------
-- VN Scene Editor: server side database.
--
-- PLACE THIS SCRIPT IN ServerScriptService. It will not run anywhere under
-- StarterPlayer, and the editor will report "Database offline" if it is missing.
--
-- In Studio also turn on: Game Settings > Security > Enable Studio Access to
-- API Services, otherwise DataStore calls fail.
--
-- Keys:
--   u_<userId>        the editing user's whole project (JSON text)
--   pub_<chapterId>   a published chapter (JSON text, project envelope)
--   pub_index         { [chapterId] = { name, publishedAt } }
--------------------------------------------------------------------------------

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local STORE_NAME = "VNSceneEditor_v2"
local FOLDER_NAME = "VNSceneEditorRemotes"
local REMOTE_NAME = "Invoke"
local MAX_JSON_CHARS = 3900000

local store = DataStoreService:GetDataStore(STORE_NAME)

local folder = ReplicatedStorage:FindFirstChild(FOLDER_NAME)
if not folder then
	folder = Instance.new("Folder")
	folder.Name = FOLDER_NAME
	folder.Parent = ReplicatedStorage
end

local invoke = folder:FindFirstChild(REMOTE_NAME)
if not invoke then
	invoke = Instance.new("RemoteFunction")
	invoke.Name = REMOTE_NAME
	invoke.Parent = folder
end

local function fail(message)
	return { ok = false, err = message }
end

local function succeed(data)
	return { ok = true, data = data }
end

local function readText(key)
	local ok, result = pcall(function()
		return store:GetAsync(key)
	end)

	if not ok then
		return nil, tostring(result)
	end

	if result == nil then
		return "", nil
	end

	if type(result) == "string" then
		return result, nil
	end

	local encodedOk, encoded = pcall(function()
		return HttpService:JSONEncode(result)
	end)

	if not encodedOk then
		return nil, "Saved data is not readable."
	end

	return encoded, nil
end

local function validateJson(text)
	if type(text) ~= "string" then
		return false, "Payload must be JSON text."
	end

	if #text > MAX_JSON_CHARS then
		return false, string.format("Project is too large to save (%d characters, limit %d).", #text, MAX_JSON_CHARS)
	end

	local decodedOk = pcall(function()
		HttpService:JSONDecode(text)
	end)

	if not decodedOk then
		return false, "Payload is not valid JSON."
	end

	return true
end

local function writeText(key, text)
	local ok, err = pcall(function()
		store:SetAsync(key, text)
	end)

	if not ok then
		return false, tostring(err)
	end

	return true
end

local function updateIndex(chapterId, name)
	local ok, err = pcall(function()
		store:UpdateAsync("pub_index", function(current)
			current = type(current) == "table" and current or {}
			current[chapterId] = { name = name, publishedAt = os.time() }
			return current
		end)
	end)

	return ok, err
end

local actions = {}

function actions.Load(player)
	local text, err = readText("u_" .. player.UserId)
	if err then
		return fail(err)
	end
	return succeed(text)
end

function actions.Save(player, payload)
	local valid, err = validateJson(payload)
	if not valid then
		return fail(err)
	end

	local written, writeErr = writeText("u_" .. player.UserId, payload)
	if not written then
		return fail(writeErr)
	end

	return succeed(nil)
end

function actions.Publish(_, payload)
	if type(payload) ~= "table" or type(payload.chapterId) ~= "string" or payload.chapterId == "" then
		return fail("Publish needs a chapterId.")
	end

	local valid, err = validateJson(payload.text)
	if not valid then
		return fail(err)
	end

	local written, writeErr = writeText("pub_" .. payload.chapterId, payload.text)
	if not written then
		return fail(writeErr)
	end

	local indexed, indexErr = updateIndex(payload.chapterId, tostring(payload.name or payload.chapterId))
	if not indexed then
		return fail("Chapter saved but the index failed: " .. tostring(indexErr))
	end

	return succeed(nil)
end

function actions.LoadPublished(_, chapterId)
	if type(chapterId) ~= "string" or chapterId == "" then
		return fail("LoadPublished needs a chapterId.")
	end

	local text, err = readText("pub_" .. chapterId)
	if err then
		return fail(err)
	end

	return succeed(text)
end

function actions.ListPublished()
	local ok, result = pcall(function()
		return store:GetAsync("pub_index")
	end)

	if not ok then
		return fail(tostring(result))
	end

	local list = {}
	if type(result) == "table" then
		for chapterId, info in pairs(result) do
			table.insert(list, {
				chapterId = chapterId,
				name = type(info) == "table" and info.name or chapterId,
				publishedAt = type(info) == "table" and info.publishedAt or 0,
			})
		end
	end

	table.sort(list, function(a, b)
		return a.name < b.name
	end)

	return succeed(list)
end

invoke.OnServerInvoke = function(player, action, payload)
	local handler = actions[action]

	if not handler then
		return fail("Unknown database action: " .. tostring(action))
	end

	local ok, result = pcall(handler, player, payload)
	if not ok then
		return fail("Server error: " .. tostring(result))
	end

	return result
end

print("[VNSceneEditor] Database server ready.")
