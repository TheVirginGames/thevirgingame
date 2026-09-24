-- The in-memory project, plus the hooks that write it to the database.
--
-- Editing a scene uses a checkout / commit pair: the editor works on a deep
-- copy so the preview can react to every keystroke while the stored version
-- stays untouched until Save. Everything else (chapters, presets, recycle bin)
-- edits the stored project directly and schedules a debounced database write.

local Signal = require(script.Parent.Signal)
local Schema = require(script.Parent.Schema)
local Persistence = require(script.Parent.Persistence)
local SeedProject = require(script.Parent.SeedProject)

local ProjectStore = {}

ProjectStore.Changed = Signal.new()
ProjectStore.PersistStatus = Signal.new() -- (status: "saving" | "saved" | "error" | "offline", message)

local project = SeedProject.build()
local persistEnabled = false
local persistGeneration = 0
local lastStatus = { status = "offline", message = "Not connected to the database yet." }

local function fireChanged()
	ProjectStore.Changed:Fire(project)
	ProjectStore.schedulePersist()
end

--------------------------------------------------------------------------------
-- Project
--------------------------------------------------------------------------------

function ProjectStore.getProject()
	return project
end

function ProjectStore.replaceProject(newProject, skipPersist)
	project = newProject
	Schema.ensureDefaults(project)
	ProjectStore.Changed:Fire(project)

	if not skipPersist then
		ProjectStore.schedulePersist()
	end
end

function ProjectStore.mergeProject(incoming)
	for _, record in ipairs(incoming.characters or {}) do
		for _, imageId in ipairs(record.portraits) do
			Schema.addCharacterPortrait(project, record.name, imageId)
		end
	end

	for _, listName in ipairs({ "cameraPoses", "textboxPresets", "transitionPresets" }) do
		for _, item in ipairs(incoming[listName] or {}) do
			if not Schema.findById(project[listName], item.id) then
				table.insert(project[listName], Schema.deepCopy(item))
			end
		end
	end

	for _, chapter in ipairs(incoming.chapters or {}) do
		local copy = Schema.deepCopy(chapter)
		if Schema.findChapter(project, copy.id) then
			copy.id = Schema.newId("chapter")
			copy.name = copy.name .. " (imported)"
		end
		table.insert(project.chapters, copy)
	end

	fireChanged()
end

function ProjectStore.markChanged()
	fireChanged()
end

--------------------------------------------------------------------------------
-- Chapters
--------------------------------------------------------------------------------

function ProjectStore.listChapters()
	return project.chapters
end

function ProjectStore.getChapter(chapterId)
	return Schema.findChapter(project, chapterId)
end

function ProjectStore.createChapter(name)
	local chapter = Schema.newChapter(name)
	table.insert(project.chapters, chapter)
	fireChanged()
	return chapter
end

function ProjectStore.renameChapter(chapterId, name)
	local chapter = Schema.findChapter(project, chapterId)
	if not chapter then
		return
	end

	local trimmed = Schema.trimName(name)
	chapter.name = trimmed ~= "" and trimmed or "Untitled Chapter"
	fireChanged()
end

function ProjectStore.duplicateChapter(chapterId)
	local chapter, index = Schema.findChapter(project, chapterId)
	if not chapter then
		return nil
	end

	local copy = Schema.deepCopy(chapter)
	copy.id = Schema.newId("chapter")
	copy.name = copy.name .. " (copy)"

	local idMap = {}
	for _, scene in ipairs(copy.scenes) do
		local oldId = scene.id
		Schema.reidentifyScene(scene)
		idMap[oldId] = scene.id
	end

	-- Re-point links inside the copy at the copied scenes.
	for _, scene in ipairs(copy.scenes) do
		if idMap[scene.next.sceneId] then
			scene.next.sceneId = idMap[scene.next.sceneId]
		end
		for _, interaction in ipairs(scene.interactions) do
			if idMap[interaction.exit.sceneId] then
				interaction.exit.sceneId = idMap[interaction.exit.sceneId]
			end
		end
		Schema.forEachEventList(scene, function(events)
			for _, event in ipairs(events) do
				if event.type == "FlowGoto" and idMap[event.params.sceneId] then
					event.params.sceneId = idMap[event.params.sceneId]
				end
			end
		end)
	end

	copy.startSceneId = idMap[copy.startSceneId] or (copy.scenes[1] and copy.scenes[1].id or "")

	table.insert(project.chapters, index + 1, copy)
	fireChanged()
	return copy
end

function ProjectStore.deleteChapter(chapterId)
	local chapter, index = Schema.findChapter(project, chapterId)
	if not chapter then
		return
	end

	table.remove(project.chapters, index)

	table.insert(project.recycleBin.chapters, 1, {
		id = Schema.newId("binc"),
		deletedAt = os.time(),
		chapter = chapter,
	})

	fireChanged()
end

function ProjectStore.moveChapter(chapterId, offset)
	local _, index = Schema.findChapter(project, chapterId)
	if not index then
		return
	end

	local target = index + offset
	if target < 1 or target > #project.chapters then
		return
	end

	local moved = table.remove(project.chapters, index)
	table.insert(project.chapters, target, moved)
	fireChanged()
end

--------------------------------------------------------------------------------
-- Flags
--------------------------------------------------------------------------------

function ProjectStore.addFlag(chapterId, flagId, kind)
	local chapter = Schema.findChapter(project, chapterId)
	local trimmed = Schema.trimName(flagId)

	if not chapter or trimmed == "" or Schema.isSceneFlagRef(trimmed) or Schema.findFlag(chapter, trimmed) then
		return false
	end

	table.insert(chapter.flags, Schema.newFlag(trimmed, kind))
	fireChanged()
	return true
end

function ProjectStore.removeFlag(chapterId, flagId)
	local chapter = Schema.findChapter(project, chapterId)
	if not chapter then
		return
	end

	for index, flag in ipairs(chapter.flags) do
		if flag.id == flagId then
			table.remove(chapter.flags, index)
			break
		end
	end

	fireChanged()
end

function ProjectStore.updateFlag(chapterId, flagId, patch)
	local chapter = Schema.findChapter(project, chapterId)
	local flag = chapter and Schema.findFlag(chapter, flagId)
	if not flag then
		return
	end

	if patch.kind then
		flag.kind = patch.kind
		flag.default = patch.kind == "int" and 0 or false
	end

	if patch.default ~= nil then
		flag.default = patch.default
	end

	fireChanged()
end

--------------------------------------------------------------------------------
-- Scenes
--------------------------------------------------------------------------------

function ProjectStore.getScene(chapterId, sceneId)
	local chapter = Schema.findChapter(project, chapterId)
	return Schema.findScene(chapter, sceneId), chapter
end

function ProjectStore.createScene(chapterId, name, kind, position)
	local chapter = Schema.findChapter(project, chapterId)
	if not chapter then
		return nil
	end

	local scene = Schema.newScene(name, kind)
	if position then
		scene.flow = { x = position.x, y = position.y }
	else
		local maxX = 0
		for _, existing in ipairs(chapter.scenes) do
			maxX = math.max(maxX, existing.flow.x)
		end
		scene.flow = { x = maxX + 260, y = 120 }
	end

	table.insert(chapter.scenes, scene)

	if not Schema.findScene(chapter, chapter.startSceneId) then
		chapter.startSceneId = scene.id
	end

	fireChanged()
	return scene
end

function ProjectStore.duplicateScene(chapterId, sceneId)
	local chapter = Schema.findChapter(project, chapterId)
	local scene, index = Schema.findScene(chapter, sceneId)
	if not scene then
		return nil
	end

	local copy = Schema.reidentifyScene(Schema.deepCopy(scene))
	copy.name = copy.name .. " (copy)"
	copy.flow = { x = scene.flow.x + 40, y = scene.flow.y + 60 }

	table.insert(chapter.scenes, index + 1, copy)
	fireChanged()
	return copy
end

local function isSceneDestination(chapter, sourceSceneId, destinationSceneId)
	if destinationSceneId == "" then
		return true
	end

	return destinationSceneId ~= sourceSceneId and Schema.findScene(chapter, destinationSceneId) ~= nil
end

-- Flow graph actions deliberately update the same fields used by the scene
-- inspector and runtime. There is no graph-only connection data.
function ProjectStore.setSceneNext(chapterId, sceneId, destinationSceneId)
	local chapter = Schema.findChapter(project, chapterId)
	local scene = Schema.findScene(chapter, sceneId)

	if not scene or scene.stage.kind ~= "Novel2D" or not isSceneDestination(chapter, sceneId, destinationSceneId) then
		return false
	end

	scene.next.sceneId = destinationSceneId
	fireChanged()
	return true
end

function ProjectStore.setSceneNextTransition(chapterId, sceneId, transitionId)
	local chapter = Schema.findChapter(project, chapterId)
	local scene = Schema.findScene(chapter, sceneId)

	if not scene or scene.stage.kind ~= "Novel2D" then
		return false
	end

	scene.next.transitionId = transitionId or ""
	fireChanged()
	return true
end

function ProjectStore.setExitDestination(chapterId, sceneId, interactionId, destinationSceneId)
	local chapter = Schema.findChapter(project, chapterId)
	local scene = Schema.findScene(chapter, sceneId)
	local interaction = Schema.findInteraction(scene, interactionId)

	if not interaction or interaction.kind ~= "Exit" or not isSceneDestination(chapter, sceneId, destinationSceneId) then
		return false
	end

	interaction.exit.sceneId = destinationSceneId
	fireChanged()
	return true
end

function ProjectStore.setExitTransition(chapterId, sceneId, interactionId, transitionId)
	local chapter = Schema.findChapter(project, chapterId)
	local scene = Schema.findScene(chapter, sceneId)
	local interaction = Schema.findInteraction(scene, interactionId)

	if not interaction or interaction.kind ~= "Exit" then
		return false
	end

	interaction.exit.transitionId = transitionId or ""
	fireChanged()
	return true
end

local function findFlowEvent(scene, eventId)
	local foundEvents, foundIndex, foundEvent

	Schema.forEachEventList(scene, function(events)
		if foundEvent then
			return
		end

		for index, event in ipairs(events) do
			if event.id == eventId then
				foundEvents = events
				foundIndex = index
				foundEvent = event
				break
			end
		end
	end)

	return foundEvents, foundIndex, foundEvent
end

function ProjectStore.setFlowGotoTransition(chapterId, sceneId, eventId, transitionId)
	local chapter = Schema.findChapter(project, chapterId)
	local scene = Schema.findScene(chapter, sceneId)
	if not scene then
		return false
	end

	local _, _, event = findFlowEvent(scene, eventId)

	if not event or event.type ~= "FlowGoto" then
		return false
	end

	event.params.transitionId = transitionId or ""
	fireChanged()
	return true
end

function ProjectStore.deleteFlowEvent(chapterId, sceneId, eventId)
	local chapter = Schema.findChapter(project, chapterId)
	local scene = Schema.findScene(chapter, sceneId)
	if not scene then
		return false
	end

	local events, index, event = findFlowEvent(scene, eventId)

	if not event or (event.type ~= "FlowGoto" and event.type ~= "FlowEndChapter") then
		return false
	end

	table.remove(events, index)
	fireChanged()
	return true
end

function ProjectStore.deleteScene(chapterId, sceneId)
	local chapter = Schema.findChapter(project, chapterId)
	local scene, index = Schema.findScene(chapter, sceneId)
	if not scene then
		return
	end

	table.remove(chapter.scenes, index)
	Schema.clearSceneDestinations(chapter, sceneId)

	table.insert(project.recycleBin.scenes, 1, {
		id = Schema.newId("bins"),
		deletedAt = os.time(),
		chapterId = chapterId,
		scene = scene,
	})

	if chapter.startSceneId == sceneId then
		chapter.startSceneId = chapter.scenes[1] and chapter.scenes[1].id or ""
	end

	fireChanged()
end

function ProjectStore.setStartScene(chapterId, sceneId)
	local chapter = Schema.findChapter(project, chapterId)
	if chapter and Schema.findScene(chapter, sceneId) then
		chapter.startSceneId = sceneId
		fireChanged()
	end
end

function ProjectStore.setScenePosition(chapterId, sceneId, x, y)
	local scene = ProjectStore.getScene(chapterId, sceneId)
	if scene then
		scene.flow.x = math.round(x)
		scene.flow.y = math.round(y)
		fireChanged()
	end
end

-- Hand the editor a private copy to work on.
function ProjectStore.checkout(chapterId, sceneId)
	local scene = ProjectStore.getScene(chapterId, sceneId)
	return scene and Schema.deepCopy(scene) or nil
end

-- Write an edited copy back over the stored scene.
function ProjectStore.commit(chapterId, scene)
	local chapter = Schema.findChapter(project, chapterId)
	if not chapter then
		return false
	end

	local _, index = Schema.findScene(chapter, scene.id)
	local stored = Schema.deepCopy(scene)

	if index then
		chapter.scenes[index] = stored
	else
		table.insert(chapter.scenes, stored)
	end

	fireChanged()
	return true
end

--------------------------------------------------------------------------------
-- Presets
--------------------------------------------------------------------------------

function ProjectStore.addPortrait(characterName, imageId)
	local added, formatted = Schema.addCharacterPortrait(project, characterName, imageId)
	if added then
		fireChanged()
	end
	return added, formatted
end

function ProjectStore.recyclePortrait(characterName, imageId, extraScenes)
	local trimmed = Schema.trimName(characterName)

	if not Schema.removeCharacterPortrait(project, trimmed, imageId) then
		return false
	end

	Schema.clearPortraitUses(project, trimmed, imageId, extraScenes)

	table.insert(project.recycleBin.portraits, 1, {
		id = Schema.newId("binp"),
		character = trimmed,
		imageId = imageId,
		deletedAt = os.time(),
	})

	fireChanged()
	return true
end

function ProjectStore.addCharacter(name)
	local trimmed = Schema.trimName(name)
	if trimmed == "" or Schema.findCharacter(project, trimmed) then
		return false
	end

	table.insert(project.characters, { name = trimmed, portraits = {} })
	fireChanged()
	return true
end

function ProjectStore.removeCharacter(name)
	local record = Schema.findCharacter(project, name)
	if not record then
		return
	end

	for _, imageId in ipairs(table.clone(record.portraits)) do
		ProjectStore.recyclePortrait(name, imageId)
	end

	for index, existing in ipairs(project.characters) do
		if existing == record then
			table.remove(project.characters, index)
			break
		end
	end

	fireChanged()
end

function ProjectStore.addCameraPose(name, cframeText)
	local pose = Schema.newCameraPose(name, cframeText)
	table.insert(project.cameraPoses, pose)
	fireChanged()
	return pose
end

function ProjectStore.updateCameraPose(poseId, patch)
	local pose = Schema.findCameraPose(project, poseId)
	if not pose then
		return
	end

	if patch.name then
		pose.name = patch.name
	end
	if patch.cframe then
		pose.cframe = patch.cframe
	end

	fireChanged()
end

function ProjectStore.removeCameraPose(poseId)
	local _, index = Schema.findById(project.cameraPoses, poseId)
	if index then
		table.remove(project.cameraPoses, index)
		fireChanged()
	end
end

function ProjectStore.addTextboxPreset(name)
	local preset = Schema.newTextboxPreset(name)
	table.insert(project.textboxPresets, preset)
	fireChanged()
	return preset
end

function ProjectStore.removeTextboxPreset(presetId)
	if presetId == Schema.DEFAULT_TEXTBOX then
		return false
	end

	local _, index = Schema.findById(project.textboxPresets, presetId)
	if index then
		table.remove(project.textboxPresets, index)
		fireChanged()
		return true
	end

	return false
end

function ProjectStore.addTransitionPreset(name, kind)
	local preset = Schema.newTransitionPreset(name, kind)
	table.insert(project.transitionPresets, preset)
	fireChanged()
	return preset
end

function ProjectStore.removeTransitionPreset(presetId)
	local _, index = Schema.findById(project.transitionPresets, presetId)
	if index then
		table.remove(project.transitionPresets, index)
		fireChanged()
		return true
	end

	return false
end

--------------------------------------------------------------------------------
-- Recycle bin
--------------------------------------------------------------------------------

function ProjectStore.getRecycleBin()
	project.recycleBin = project.recycleBin or Schema.emptyRecycleBin()
	return project.recycleBin
end

local function removeBinItem(list, binId)
	for index, item in ipairs(list) do
		if item.id == binId then
			return table.remove(list, index)
		end
	end

	return nil
end

function ProjectStore.restoreChapter(binId)
	local item = removeBinItem(ProjectStore.getRecycleBin().chapters, binId)
	if not item then
		return nil
	end

	if Schema.findChapter(project, item.chapter.id) then
		item.chapter.id = Schema.newId("chapter")
	end

	table.insert(project.chapters, item.chapter)
	fireChanged()
	return item.chapter
end

function ProjectStore.restoreScene(binId)
	local item = removeBinItem(ProjectStore.getRecycleBin().scenes, binId)
	if not item then
		return nil
	end

	local chapter = Schema.findChapter(project, item.chapterId) or project.chapters[1]
	if not chapter then
		chapter = ProjectStore.createChapter("Restored")
	end

	if Schema.findScene(chapter, item.scene.id) then
		Schema.reidentifyScene(item.scene)
	end

	table.insert(chapter.scenes, item.scene)
	fireChanged()
	return item.scene
end

function ProjectStore.restorePortrait(binId)
	local item = removeBinItem(ProjectStore.getRecycleBin().portraits, binId)
	if not item then
		return false
	end

	Schema.addCharacterPortrait(project, item.character, item.imageId)
	fireChanged()
	return true
end

function ProjectStore.purgeBinItem(kind, binId)
	local bin = ProjectStore.getRecycleBin()
	local list = bin[kind]
	if list and removeBinItem(list, binId) then
		fireChanged()
		return true
	end
	return false
end

function ProjectStore.emptyRecycleBin()
	project.recycleBin = Schema.emptyRecycleBin()
	fireChanged()
end

--------------------------------------------------------------------------------
-- Database
--------------------------------------------------------------------------------

local function setStatus(status, message)
	lastStatus = { status = status, message = message }
	ProjectStore.PersistStatus:Fire(status, message)
end

function ProjectStore.getPersistStatus()
	return lastStatus.status, lastStatus.message
end

function ProjectStore.setPersistEnabled(enabled, reason)
	persistEnabled = enabled and true or false

	if persistEnabled then
		setStatus("saved", reason or "Connected to the database. Changes save automatically.")
	else
		setStatus("offline", reason or "Database saving is off.")
	end
end

function ProjectStore.isPersistEnabled()
	return persistEnabled
end

function ProjectStore.schedulePersist()
	if not persistEnabled then
		return
	end

	persistGeneration += 1
	local generation = persistGeneration

	task.delay(1.2, function()
		if generation ~= persistGeneration then
			return
		end

		ProjectStore.flush()
	end)
end

function ProjectStore.flush()
	if not persistEnabled then
		return false, lastStatus.message
	end

	persistGeneration += 1
	setStatus("saving", "Saving to database...")

	local ok, err = Persistence.saveProject(project)

	if ok then
		setStatus("saved", "Saved to your database.")
	else
		setStatus("error", err or "Database save failed.")
	end

	return ok, err
end

function ProjectStore.publishChapter(chapterId)
	local chapter = Schema.findChapter(project, chapterId)
	if not chapter then
		return false, "Chapter not found."
	end

	return Persistence.publishChapter(project, chapter)
end

return ProjectStore
