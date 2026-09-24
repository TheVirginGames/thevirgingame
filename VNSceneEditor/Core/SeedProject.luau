-- Starter content so the editor has something to show the first time it opens
-- with an empty database. Delete or replace freely.

local Schema = require(script.Parent.Schema)

local SeedProject = {}

local function event(eventType, time, params, duration)
	local built = Schema.newEvent(eventType, time)

	for key, value in pairs(params or {}) do
		built.params[key] = value
	end

	built.duration = duration or 0
	return built
end

local function timed(duration, events)
	local segment = Schema.newTimedSegment(duration)
	segment.events = events or {}
	return segment
end

local function line(character, text, events)
	local entry = Schema.newDialogueEntry(character, text)
	entry.events = events or {}
	return entry
end

local function dialogue(entries)
	local segment = Schema.newDialogueSegment()
	segment.entries = entries
	return segment
end

local function novel(name, backgroundValue, segments, x)
	local scene = Schema.newScene(name, "Novel2D")
	scene.background = { kind = "Color", value = backgroundValue, poseId = "" }
	scene.intro = { segments = segments }
	scene.flow = { x = x, y = 120 }
	return scene
end

function SeedProject.build()
	local project = Schema.newProject("Killing Game")
	local chapter = Schema.newChapter("Chapter 1")
	chapter.scenes = {}

	local prologue = novel("Prologue", "22,24,40", {
		timed(3, {
			event("BackgroundChange", 0, { kind = "Color", value = "22,24,40" }),
			event("PlayMusic", 0.25, { trackId = "rbxassetid://0", volume = 0.35 }),
		}),
		dialogue({
			line("", "The doors sealed behind us with a sound like a coffin lid."),
			line("Monokuma", "Upupupu! Welcome to your brand new school life!", {
				event("PlaySound", 0, { soundId = "rbxassetid://0", volume = 0.6 }),
			}),
			line("Makoto", "This has to be some kind of joke."),
		}),
		timed(1.5, {
			event("ScreenFlash", 0, { color = "255,255,255", duration = 0.4 }),
		}),
	}, 60)

	local morning = novel("Morning", "52,58,92", {
		timed(2, {
			event("BackgroundChange", 0, { kind = "Color", value = "52,58,92" }, 0.8),
		}),
		dialogue({
			line("Makoto", "Something feels wrong."),
			line("Kyoko", "You noticed it too?", {
				event("PlaySound", 0, { soundId = "rbxassetid://0", volume = 0.5 }),
			}),
			line("Makoto", "Yeah.", {
				event("ScreenShake", 0, { intensity = 10, duration = 0.4 }),
			}),
		}),
	}, 320)

	local classroom = Schema.newScene("Classroom", "Room3D")
	classroom.flow = { x = 580, y = 120 }
	classroom.intro = {
		segments = {
			dialogue({
				line("", "The classroom. Someone has been here recently."),
			}),
		},
	}

	local hotspot = Schema.newInteraction("Hotspot")
	hotspot.name = "Podium"
	hotspot.sequence = {
		segments = {
			dialogue({
				line("Makoto", "A chair scraped somewhere behind the podium."),
				line("Kyoko", "We are not alone in here."),
			}),
		},
	}
	table.insert(hotspot.onComplete, event("FlowSetFlag", 0, { flag = "checkedPodium", value = "true" }))
	table.insert(classroom.interactions, hotspot)

	local exit = Schema.newInteraction("Exit")
	exit.name = "Door to hallway"
	exit.conditions = { { flag = "checkedPodium", op = "==", value = "true" } }
	exit.exit = { sceneId = "", transitionId = Schema.DEFAULT_FADE }
	table.insert(classroom.interactions, exit)

	local investigation = novel("Investigation", "30,34,46", {
		timed(2, {
			event("BackgroundChange", 0, { kind = "Color", value = "30,34,46" }, 0.6),
			event("ScreenFlash", 0.1, { color = "255,120,120", duration = 0.5 }),
		}),
		dialogue({
			line("", "Truth Bullet acquired: the broken window latch."),
			line("Makoto", "The latch was forced from the inside."),
			line("Kyoko", "Then whoever did it never left.", {
				event("ScreenShake", 0, { intensity = 6, duration = 0.3 }),
			}),
		}),
	}, 840)

	table.insert(investigation.intro.segments, timed(1, {
		event("FlowEndChapter", 0.5, {}),
	}))

	prologue.next.sceneId = morning.id
	morning.next.sceneId = classroom.id
	exit.exit.sceneId = investigation.id

	chapter.flags = {
		Schema.newFlag("checkedPodium", "bool"),
	}

	chapter.scenes = { prologue, morning, classroom, investigation }
	chapter.startSceneId = prologue.id

	table.insert(project.chapters, chapter)

	return project
end

return SeedProject
