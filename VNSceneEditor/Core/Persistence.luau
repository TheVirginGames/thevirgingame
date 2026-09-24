-- Client side of the project database.
--
-- The DataStore itself lives in VNSceneEditorServer.server.luau, which must be
-- placed in ServerScriptService. This module only talks to the RemoteFunction
-- that script creates. Every call returns a single table { ok, data | err } so
-- nothing depends on multiple return values crossing the network.
--
-- If the server script is missing the editor keeps working in memory and the
-- UI shows why saving is off.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local JSONCodec = require(script.Parent.JSONCodec)

local Persistence = {}

Persistence.FOLDER_NAME = "VNSceneEditorRemotes"
Persistence.REMOTE_NAME = "Invoke"

local WAIT_SECONDS = 5
local remote = nil
local unavailableReason = nil

local function findRemote()
	if remote and remote.Parent then
		return remote
	end

	local folder = ReplicatedStorage:FindFirstChild(Persistence.FOLDER_NAME)
		or ReplicatedStorage:WaitForChild(Persistence.FOLDER_NAME, WAIT_SECONDS)

	if not folder then
		unavailableReason = "Database offline: put VNSceneEditorServer in ServerScriptService and enable Studio access to API services."
		return nil
	end

	remote = folder:FindFirstChild(Persistence.REMOTE_NAME) or folder:WaitForChild(Persistence.REMOTE_NAME, 2)

	if not remote then
		unavailableReason = "Database offline: the server script did not create its RemoteFunction."
	end

	return remote
end

local function call(action, payload)
	local invoke = findRemote()

	if not invoke then
		return { ok = false, err = unavailableReason or "Database offline." }
	end

	local ok, result = pcall(function()
		return invoke:InvokeServer(action, payload)
	end)

	if not ok then
		return { ok = false, err = "Database call failed: " .. tostring(result) }
	end

	if type(result) ~= "table" then
		return { ok = false, err = "Database returned an unexpected response." }
	end

	return result
end

function Persistence.isAvailable()
	return findRemote() ~= nil
end

function Persistence.unavailableReason()
	return unavailableReason
end

-- Returns project, errorMessage. Both nil means nothing has been saved yet.
function Persistence.loadProject()
	local result = call("Load")

	if not result.ok then
		return nil, result.err
	end

	if type(result.data) ~= "string" or result.data == "" then
		return nil, nil
	end

	local project, err = JSONCodec.decodeProject(result.data, true)

	if not project then
		return nil, err or "Saved data could not be read."
	end

	return project, nil
end

function Persistence.saveProject(project)
	local text, err = JSONCodec.encodeProject(project, false)

	if not text then
		return false, err
	end

	local result = call("Save", text)
	return result.ok, result.err
end

function Persistence.publishChapter(project, chapter)
	local text, err = JSONCodec.encodeChapter(project, chapter, false)

	if not text then
		return false, err
	end

	local result = call("Publish", { chapterId = chapter.id, name = chapter.name, text = text })
	return result.ok, result.err
end

-- Returns a project envelope holding exactly one chapter, or nil, err.
function Persistence.loadPublishedChapter(chapterId)
	local result = call("LoadPublished", chapterId)

	if not result.ok then
		return nil, result.err
	end

	if type(result.data) ~= "string" or result.data == "" then
		return nil, "That chapter has not been published."
	end

	return JSONCodec.decodeProject(result.data, false)
end

-- Returns { { chapterId, name, publishedAt }, ... }
function Persistence.listPublished()
	local result = call("ListPublished")

	if not result.ok then
		return {}, result.err
	end

	return result.data or {}, nil
end

return Persistence
