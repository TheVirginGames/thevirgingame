-- Plays a chapter in the finished game, with no editor UI.
--
-- Usage from a LocalScript:
--
--   local ChapterRuntime = require(path.to.VNSceneEditor.ChapterRuntime)
--   local session = ChapterRuntime.playPublished("chapter_v1")      -- from the database
--   -- or
--   local session = ChapterRuntime.playProject(projectTable, chapterId)
--
--   session.director.Finished:Connect(function() session:destroy() end)
--   session:save()  -> table you can store; session:restore(saved)
--
-- Depends only on Core, Runtime and Render, never on UI.

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local Persistence = require(script.Parent.Core.Persistence)
local Schema = require(script.Parent.Core.Schema)
local Director = require(script.Parent.Runtime.Director)
local Presenter = require(script.Parent.Render.Presenter)

local ChapterRuntime = {}

local Session = {}
Session.__index = Session

local function newSession(project, chapter, parentGui)
	local self = setmetatable({}, Session)

	local player = Players.LocalPlayer
	parentGui = parentGui or Instance.new("ScreenGui")

	if not parentGui.Parent then
		parentGui.Name = "VNChapter"
		parentGui.ResetOnSpawn = false
		parentGui.IgnoreGuiInset = true
		parentGui.DisplayOrder = 50
		parentGui.Parent = player:WaitForChild("PlayerGui")
		self.ownsGui = true
	end

	self.gui = parentGui
	self.project = project
	self.chapter = chapter
	self.presenter = Presenter.new(parentGui, { editor = false })
	self.presenter:setAdvanceHint("click to continue")
	self.director = Director.new(self.presenter, project)
	self.director:setChapter(chapter)

	self.inputConnection = UserInputService.InputBegan:Connect(function(input, processed)
		if processed then
			return
		end

		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch
			or input.KeyCode == Enum.KeyCode.Space
			or input.KeyCode == Enum.KeyCode.Return then
			self.director:advance()
		end
	end)

	return self
end

function Session:start(sceneId)
	-- Starting a stopped session is a new playthrough. Saved flag state is only
	-- restored through Session:restore; ordinary starts always use definitions.
	self.director:setChapter(self.chapter)
	return self.director:start(sceneId)
end

function Session:save()
	return self.director:serialize()
end

function Session:restore(state)
	return self.director:restore(state)
end

function Session:stop()
	self.director:stop()
end

function Session:destroy()
	self.inputConnection:Disconnect()
	self.director:destroy()
	self.presenter:destroy()
	if self.ownsGui then
		self.gui:Destroy()
	end
end

-- project: a normalized project table (e.g. from JSONCodec.decodeProject).
function ChapterRuntime.playProject(project, chapterId, parentGui, sceneId)
	local chapter = Schema.findChapter(project, chapterId) or project.chapters[1]
	if not chapter then
		return nil, "Project has no chapters."
	end

	local session = newSession(project, chapter, parentGui)
	session:start(sceneId)
	return session
end

-- Loads the chapter published from the editor (Publish button) and plays it.
function ChapterRuntime.playPublished(chapterId, parentGui, sceneId)
	local project, err = Persistence.loadPublishedChapter(chapterId)
	if not project then
		return nil, err
	end

	return ChapterRuntime.playProject(project, chapterId, parentGui, sceneId)
end

-- { { chapterId, name, publishedAt }, ... }
function ChapterRuntime.listPublished()
	return Persistence.listPublished()
end

-- Load without starting, for menus that resume a save.
function ChapterRuntime.loadPublished(chapterId, parentGui)
	local project, err = Persistence.loadPublishedChapter(chapterId)
	if not project then
		return nil, err
	end

	local chapter = Schema.findChapter(project, chapterId) or project.chapters[1]
	return newSession(project, chapter, parentGui)
end

return ChapterRuntime
