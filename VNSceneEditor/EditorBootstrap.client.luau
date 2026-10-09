-- VN Chapter Editor -- entry point (LocalScript under StarterPlayerScripts).
--
-- Loads your saved project from the database (VNSceneEditorServer.server.luau
-- in ServerScriptService), falls back to the seed project when nothing is
-- saved yet, and opens the editor. Press F4 to toggle the editor.

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local root = script.Parent
local ProjectStore = require(root.Core.ProjectStore)
local Persistence = require(root.Core.Persistence)
local EditorApp = require(root.UI.EditorApp)

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local app = EditorApp.new(playerGui)

local loadMessage, loadColor

if Persistence.isAvailable() then
	local project, err = Persistence.loadProject()

	if project then
		ProjectStore.replaceProject(project, true)
		loadMessage = string.format("Loaded %d chapter(s) from your database.", #project.chapters)
		loadColor = Color3.fromRGB(58, 176, 118)
	elseif err then
		loadMessage = "Could not load saved chapters: " .. err .. " (using the starter project)"
		loadColor = Color3.fromRGB(206, 66, 74)
	else
		loadMessage = "No saved chapters yet. Starter project loaded; changes save automatically."
		loadColor = Color3.fromRGB(154, 158, 180)
	end

	ProjectStore.setPersistEnabled(true)
else
	ProjectStore.setPersistEnabled(false, Persistence.unavailableReason())
	loadMessage = Persistence.unavailableReason() or "Database offline."
	loadColor = Color3.fromRGB(206, 66, 74)
end

app:open()
app:notify(loadMessage, loadColor)

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then
		return
	end

	if input.KeyCode == Enum.KeyCode.F4 then
		app:toggle()
	end
end)
