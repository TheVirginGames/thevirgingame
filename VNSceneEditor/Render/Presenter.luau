-- The one object the runtime talks to when it wants something on screen.
--
-- Wraps StageView (2D layers), CameraRig (3D viewpoint), Transitions and
-- WorldBindings (hotspots), plus music and sound playback. The Director and
-- SequenceRunner never touch instances directly.

local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

local Signal = require(script.Parent.Parent.Core.Signal)
local Schema = require(script.Parent.Parent.Core.Schema)
local Easing = require(script.Parent.Parent.Runtime.Easing)
local StageView = require(script.Parent.StageView)
local CameraRig = require(script.Parent.CameraRig)
local Transitions = require(script.Parent.Transitions)
local WorldBindings = require(script.Parent.WorldBindings)

local Presenter = {}
Presenter.__index = Presenter

local function isRealAsset(id)
	return type(id) == "string" and id ~= "" and id ~= "rbxassetid://0" and id ~= "0"
end

function Presenter.new(parentGui, options)
	options = options or {}

	local self = setmetatable({}, Presenter)

	self.gui = parentGui
	self.editorMode = options.editor == true
	self.interactive = not self.editorMode
	self.scene = nil
	self.project = nil
	self.controlsDisabled = false
	self.music = nil
	self.musicId = nil
	self.lastDialogueEntryId = nil
	self.lastDialogueSpeaker = ""
	self.speakerTurnDirection = 1

	self.stage = StageView.new(parentGui)
	self.stage:setDebugVisible(self.editorMode)

	self.rig = CameraRig.new()
	self.world = WorldBindings.new()

	self.overlay = Instance.new("Frame")
	self.overlay.Name = "TransitionOverlay"
	self.overlay.Size = UDim2.fromScale(1, 1)
	self.overlay.BackgroundColor3 = Color3.new(0, 0, 0)
	self.overlay.BackgroundTransparency = 1
	self.overlay.BorderSizePixel = 0
	self.overlay.Visible = false
	self.overlay.ZIndex = 30
	self.overlay.Parent = self.stage.root

	self.InteractionRequested = Signal.new()
	self.HoverChanged = self.world.HoverChanged

	self.world.InteractionRequested:Connect(function(interactionId)
		self.InteractionRequested:Fire(interactionId)
	end)

	return self
end

--------------------------------------------------------------------------------
-- Modes
--------------------------------------------------------------------------------

function Presenter:setSafeAreaBottom(scale)
	self.stage:setSafeAreaBottom(scale)
end

function Presenter:setAdvanceHint(text)
	self.stage:setAdvanceHint(text)
end

-- While the editor panels are up, world clicks must not fire interactions.
function Presenter:setInteractive(enabled)
	self.interactive = enabled
	self.world:setEnabled(enabled)
end

function Presenter:_setControls(enabled)
	if enabled and self.controlsDisabled then
		WorldBindings.setPlayerControls(true)
		self.controlsDisabled = false
	elseif not enabled and not self.controlsDisabled then
		WorldBindings.setPlayerControls(false)
		self.controlsDisabled = true
	end
end

-- Apply a scene's stage settings: camera pose, controls, world mode.
function Presenter:enterScene(scene, project)
	self.scene = scene
	self.project = project or self.project
	self.stage:clearForeground()
	self.lastDialogueEntryId = nil
	self.lastDialogueSpeaker = ""
	self.speakerTurnDirection = 1
	self.world:clear()

	local kind = scene.stage.kind

	if kind == "Explore3D" then
		self.rig:release()
		self:_setControls(true)
	else
		self:_setControls(false)
		local poseId = scene.stage.cameraPoseId ~= "" and scene.stage.cameraPoseId or scene.background.poseId
		local pose = Schema.findCameraPose(self.project, poseId)

		if pose then
			self.rig:setPose(pose)
		elseif kind == "Room3D" or scene.background.kind == "Camera3D" then
			-- No pose yet: hold the camera where it is so the world stays visible.
			self.rig:setCFrame(self.rig:getCFrame())
		end
	end
end

-- Re-apply stage settings without clearing (editor refresh after edits).
function Presenter:refreshScene(scene, project)
	self.scene = scene
	self.project = project or self.project
end

function Presenter:leaveScene()
	self.world:clear()
	self.rig:release()
	self:_setControls(true)
	self.stage:clear()
	self.scene = nil
	self.lastDialogueEntryId = nil
	self.lastDialogueSpeaker = ""
	self:stopMusic(0.5)
end

function Presenter:clearStage()
	self.stage:clearForeground()
end

function Presenter:getStage()
	return self.stage
end

function Presenter:getRig()
	return self.rig
end

function Presenter:getWorld()
	return self.world
end

--------------------------------------------------------------------------------
-- Rendering
--------------------------------------------------------------------------------

function Presenter:_renderCamera(snapshot)
	if not self.scene or self.scene.stage.kind == "Explore3D" or self.rig:isFlying() then
		return
	end

	local project = self.project
	if not project or snapshot.cameraPoseId == "" then
		return
	end

	local toPose = Schema.findCameraPose(project, snapshot.cameraPoseId)
	if not toPose then
		return
	end

	local tween = snapshot.cameraTween
	if tween and tween.duration > 0 then
		local progress = Easing.progress(snapshot.localTime or 0, tween.start, tween.duration)
		if progress < 1 then
			local fromPose = Schema.findCameraPose(project, tween.fromPoseId)
			self.rig:setBlend(fromPose, toPose, Easing.alpha(tween.easing, progress))
			return
		end
	end

	if self.rig:getCurrentPoseId() ~= toPose.id then
		self.rig:setPose(toPose)
	end
end

-- Returns true only for a camera-backed scene where the renderer currently
-- has a portrait to hand off. This preserves normal portrait behavior for
-- same-speaker expression changes and all flat-background scenes.
function Presenter:_beginSpeakerTurn(snapshot)
	local dialogue = snapshot.dialogue
	if not dialogue then
		self.lastDialogueEntryId = nil
		self.lastDialogueSpeaker = ""
		return false
	end

	if dialogue.entryId == self.lastDialogueEntryId then
		return false
	end

	local previousSpeaker = self.lastDialogueSpeaker
	local nextSpeaker = dialogue.character or ""
	self.lastDialogueEntryId = dialogue.entryId
	self.lastDialogueSpeaker = nextSpeaker

	local scene = self.scene
	local portrait = snapshot.portrait
	local cameraBacked = scene
		and scene.stage.kind ~= "Explore3D"
		and (scene.stage.kind == "Room3D" or snapshot.background.kind == "Camera3D" or snapshot.cameraPoseId ~= "")

	if not cameraBacked
		or previousSpeaker == ""
		or nextSpeaker == ""
		or previousSpeaker == nextSpeaker
		or not portrait
		or portrait.imageId == ""
		or portrait.name ~= nextSpeaker
		or snapshot.cameraTween then
		return false
	end

	-- Do not override a real camera-pose change that is still being applied.
	if snapshot.cameraPoseId ~= "" and self.rig:getCurrentPoseId() ~= snapshot.cameraPoseId then
		return false
	end

	local direction = self.speakerTurnDirection
	local duration = 0.32
	if not self.stage:beginSpeakerPortraitTransition(portrait, direction, duration) then
		return false
	end

	self.speakerTurnDirection = -direction
	local current = self.rig:getCFrame()
	local yaw = math.rad(7) * direction
	self.rig:moveTo(current * CFrame.Angles(0, yaw, 0), duration, "Quad")
	return true
end

function Presenter:_renderMusic(snapshot, context)
	-- The paused editor still folds persistent events into its visual snapshot.
	-- Music is audible state, not preview artwork, so do not start it merely by
	-- selecting or scrubbing past a Music event. It is enabled while a sequence
	-- or chapter is actually playing.
	if self.editorMode and not (context and context.playing) then
		if self.music then
			self:stopMusic(0)
		end
		return
	end

	local music = snapshot.music
	local wanted = music and isRealAsset(music.trackId) and music.trackId or nil
	local speed = math.clamp(tonumber(music and music.speed) or 1, 0.05, 4)

	if wanted == self.musicId then
		if self.music then
			self.music.PlaybackSpeed = speed
		end
		return
	end

	self:stopMusic(music and music.fade or 0.5)
	self.musicId = wanted

	if wanted then
		local sound = Instance.new("Sound")
		sound.Name = "VNMusic"
		sound.SoundId = wanted
		sound.Looped = true
		sound.Volume = 0
		sound.PlaybackSpeed = speed
		sound.Parent = SoundService
		sound:Play()
		TweenService:Create(sound, TweenInfo.new(music.fade or 0.5), { Volume = music.volume or 0.4 }):Play()
		self.music = sound
	end
end

function Presenter:stopMusic(fade)
	local sound = self.music
	self.music = nil
	self.musicId = nil

	if sound then
		local tween = TweenService:Create(sound, TweenInfo.new(fade or 0.5), { Volume = 0 })
		tween:Play()
		tween.Completed:Connect(function()
			sound:Destroy()
		end)
	end
end

-- context = { project, scene, playing, scrubbing, editor }
function Presenter:render(snapshot, context)
	context = context or {}
	context.project = context.project or self.project
	context.editor = self.editorMode

	if context.project then
		self.project = context.project
	end

	-- Speaker handoffs can start before StageView:render, so give that
	-- coordinated portrait tween the current shared placement first.
	self.stage:setPortraitLayout(context.project and context.project.portraitLayout)
	local speakerTurn = self:_beginSpeakerTurn(snapshot)
	self.stage:render(snapshot, context)
	if not speakerTurn then
		self:_renderCamera(snapshot)
	end
	self:_renderMusic(snapshot, context)
end

function Presenter:playEvents(events, context)
	self.stage:playEvents(events)

	for _, event in ipairs(events or {}) do
		if event.type == "PlaySound" and isRealAsset(event.params.soundId) then
			local sound = Instance.new("Sound")
			sound.SoundId = event.params.soundId
			sound.Volume = event.params.volume or 0.5
			sound.Parent = SoundService
			sound:Play()
			sound.Ended:Connect(function()
				sound:Destroy()
			end)
			task.delay(30, function()
				if sound.Parent then
					sound:Destroy()
				end
			end)
		end
	end
end

--------------------------------------------------------------------------------
-- Dialogue pacing
--------------------------------------------------------------------------------

function Presenter:isRevealing()
	return self.stage:isRevealing()
end

function Presenter:revealAll()
	self.stage:revealAll()
end

function Presenter:requestAdvance(merge)
	return self.stage:requestAdvance(merge)
end

--------------------------------------------------------------------------------
-- Transitions and world
--------------------------------------------------------------------------------

-- Yields.
function Presenter:runTransition(preset, context)
	context = context or {}
	context.stage = self.stage
	context.rig = self.rig
	context.overlay = self.overlay
	context.project = context.project or self.project
	context.apply = context.apply or function() end

	Transitions.run(preset, context)
end

-- list = { { interaction, available }, ... }
function Presenter:setInteractables(list)
	if not self.scene or #list == 0 then
		self.world:clear()
		return
	end

	if self.scene.stage.kind == "Explore3D" then
		self.world:setExploreMode(list)
	else
		self.world:setRoomMode(list)
	end

	self.world:setEnabled(self.interactive)
end

function Presenter:destroy()
	self:stopMusic(0)
	self.world:destroy()
	self.rig:destroy()
	self.stage:destroy()
	self.InteractionRequested:DisconnectAll()
end

return Presenter
