-- The one object the runtime talks to when it wants something on screen.
--
-- Wraps StageView (2D layers), CameraRig (3D viewpoint), Transitions and
-- WorldBindings (hotspots), plus music and sound playback. The Director and
-- SequenceRunner never touch instances directly.

local Players = game:GetService("Players")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Signal = require(script.Parent.Parent.Core.Signal)
local Schema = require(script.Parent.Parent.Core.Schema)
local Easing = require(script.Parent.Parent.Runtime.Easing)
local StageView = require(script.Parent.StageView)
local CameraRig = require(script.Parent.CameraRig)
local Transitions = require(script.Parent.Transitions)
local WorldBindings = require(script.Parent.WorldBindings)
local CharacterModelLayer = require(script.Parent.CharacterModelLayer)
local AssemblySession = require(script.Parent.AssemblySession)
local AssemblyAppearance = require(script.Parent.AssemblyAppearance)

local Presenter = {}
Presenter.__index = Presenter

local function isRealAsset(id)
	return type(id) == "string" and id ~= "" and id ~= "rbxassetid://0" and id ~= "0"
end

-- Room3D speaker handoffs deliberately use the authored room pose as their
-- common reference point.  This prevents several consecutive turns from
-- accumulating small relative rotations, while still letting a placed 3D
-- character determine a stable, physical shot in the room.
local DEFAULT_SPEAKER_TURN_YAW = math.rad(18)
local SPEAKER_TURN_SIDE_FACTOR = 0.22

local function speakerTurnBasePose(scene, project)
	local subscene = scene and Schema.subsceneIndex(scene, scene.activeSubsceneId)
	local poseId = subscene and Schema.effectivePoseId(scene, subscene) or ""
	return poseId ~= "" and Schema.findCameraPose(project, poseId) or nil
end

local function speakerTurnShot(scene, project, characterModels, characterName, fallbackDirection, current, anchoredBase, sweepSettings)
	sweepSettings = sweepSettings or {}
	local yaw = math.rad(tonumber(sweepSettings.yawDegrees) or 18)
	local sideDistance = tonumber(sweepSettings.sideDistance) or 1.5
	local backwardDistance = tonumber(sweepSettings.backwardDistance) or 0.88
	local basePose = speakerTurnBasePose(scene, project)
	-- A Zoom interaction deliberately establishes a closer framing before the
	-- response starts.  That live framing is the speaker-turn origin for this
	-- dialogue run; the authored Room3D pose is only the fallback.
	local base = anchoredBase or (basePose and Schema.decodeCFrame(basePose.cframe)) or current
	if not base then
		return nil, fallbackDirection
	end
	-- Treat the authored/live camera as a player-horizontal reference.  The
	-- original pose may look slightly up/down (or inherit a tiny roll), but a
	-- speaker handoff must never turn that into a diagonal orbit: its travel is
	-- entirely on the XZ plane and its rotation changes yaw only.
	local flatForward = Vector3.new(base.LookVector.X, 0, base.LookVector.Z)
	if flatForward.Magnitude < 0.001 then
		flatForward = Vector3.new(0, 0, -1)
	else
		flatForward = flatForward.Unit
	end
	local baseYaw = math.atan2(-flatForward.X, -flatForward.Z)
	local basePitch = math.asin(math.clamp(base.LookVector.Y, -1, 1))
	local flatRight = Vector3.new(math.cos(baseYaw), 0, -math.sin(baseYaw))

	-- `side` is physical screen/world direction: -1 = left, +1 = right.
	-- Every handoff deliberately takes the same diagonal side-and-back route;
	-- the camera is never pulled inward to frame a model directly.
	local side = fallbackDirection >= 0 and 1 or -1
	local modelDistanceScale = 1

	if not (scene and scene.stage.kind == "Explore3D") then
		-- Room3D models only choose which side the staged handoff belongs on.
		-- Their placement can make a distant character slightly more pronounced,
		-- but must not replace the authored sweep with a look-at shot.
		local model = characterModels:findByCharacter(characterName, base.Position)
		local _, modelCenter = WorldBindings.geometryOf(model)
		if modelCenter then
			local horizontalOffset = (modelCenter - base.Position):Dot(flatRight)
			if math.abs(horizontalOffset) > 0.08 then
				side = horizontalOffset >= 0 and 1 or -1
			end
			modelDistanceScale = math.clamp(0.8 + math.abs(horizontalOffset) * SPEAKER_TURN_SIDE_FACTOR, 0.8, 1.45)
		end
	end

	sideDistance *= modelDistanceScale
	backwardDistance *= modelDistanceScale
	local position = base.Position
		+ flatRight * side * sideDistance
		- flatForward * backwardDistance
	-- Positive Roblox yaw looks left, so its sign is the inverse of the
	-- physical side offset. Position and rotation now agree: a left sweep goes
	-- left/back while looking left; a right sweep mirrors it exactly.
	local shot = CFrame.new(position)
		* CFrame.Angles(0, baseYaw - yaw * side, 0)
		* CFrame.Angles(basePitch, 0, 0)
	return shot, side
end

function Presenter.new(parentGui, options)
	options = options or {}

	local self = setmetatable({}, Presenter)

	self.gui = parentGui
	self.editorMode = options.editor == true
	self.interactive = not self.editorMode
	self.scene = nil
	self.project = nil
	self.runtimePhase = "Idle"
	self.controlsDisabled = false
	self.lockedHumanoid = nil
	self.savedWalkSpeed = nil
	self.walkSpeedConnection = nil
	self.exploreBaseWalkSpeed = nil
	self.exploreAppliedWalkSpeed = nil
	self.exploreMotionHumanoid = nil
	self.exploreStepDistance = 0
	self.exploreBobPhase = 0
	self.exploreLastAutoFootstep = nil
	self.exploreFootstepToken = 0
	self.exploreFootstepSound = nil
	self.mutedFootstepSounds = {}
	self.exploreMotionBinding = nil
	self.characterChildConnection = nil
	self.characterConnection = nil
	self.mousePolicyBinding = nil
	self.editorMouseCaptured = false
	self.editorFly = false
	self.music = nil
	self.musicId = nil
	self.lastDialogueEntryId = nil
	self.lastDialogueSegmentId = nil
	self.lastDialogueSpeaker = ""
	self.lastDialoguePortraitId = ""
	self.lastDialogueCrossfadeNext = false
	self.speakerTurnDirection = 1
	self.speakerTurnBaseCFrame = nil

	self.stage = StageView.new(parentGui)
	self.stage:setDebugVisible(self.editorMode)

	self.rig = CameraRig.new()
	self.world = WorldBindings.new()
	self.characterModels = CharacterModelLayer.new()
	self.assemblyAppearance = AssemblyAppearance.new()
	self.assemblyAppearanceDefinition = nil
	self.hiddenCharacterModels = {}

	self.overlay = Instance.new("Frame")
	self.overlay.Name = "TransitionOverlay"
	self.overlay.Size = UDim2.fromScale(1, 1)
	self.overlay.BackgroundColor3 = Color3.new(0, 0, 0)
	self.overlay.BackgroundTransparency = 1
	self.overlay.BorderSizePixel = 0
	self.overlay.Visible = false
	self.overlay.ZIndex = 30
	self.overlay.Parent = self.stage.root

	self.roomExitChoices = Instance.new("Frame")
	self.roomExitChoices.Name = "RoomExitChoices"
	self.roomExitChoices.AnchorPoint = Vector2.new(0.5, 1)
	self.roomExitChoices.Position = UDim2.new(0.5, 0, 0.84, 0)
	self.roomExitChoices.Size = UDim2.fromOffset(280, 44)
	self.roomExitChoices.BackgroundTransparency = 1
	self.roomExitChoices.Visible = false
	self.roomExitChoices.ZIndex = 40
	self.roomExitChoices.Parent = self.stage.root
	self.roomExitButtons = {}
	for index, answer in ipairs({ "Yes", "No" }) do
		local button = Instance.new("TextButton")
		button.Name = answer
		button.Text = answer
		button.Font = Enum.Font.GothamBold
		button.TextSize = 18
		button.TextColor3 = Color3.new(1, 1, 1)
		button.BackgroundColor3 = Color3.fromRGB(44, 43, 60)
		button.AnchorPoint = Vector2.new(0, 0)
		button.Position = UDim2.fromOffset((index - 1) * 146, 0)
		button.Size = UDim2.fromOffset(134, 44)
		button.ZIndex = 41
		button.Parent = self.roomExitChoices
		Instance.new("UICorner", button).CornerRadius = UDim.new(0, 7)
		button.Activated:Connect(function()
			if self.roomExitChoices.Visible and self.roomExitCallback then
				self.roomExitCallback(answer == "Yes")
			end
		end)
		self.roomExitButtons[index] = button
	end

	self.InteractionRequested = Signal.new()
	self.HoverChanged = self.world.HoverChanged

	self.world.InteractionRequested:Connect(function(interactionId)
		self.InteractionRequested:Fire(interactionId)
	end)

	local player = Players.LocalPlayer
	if player then
		self.characterConnection = player.CharacterAdded:Connect(function(character)
			self:_watchCharacter(character)
		end)
		self:_watchCharacter(player.Character)
	end

	-- Roblox's default camera controller re-applies its mouse behavior every
	-- render frame. Apply the editor policy just after it so Escape/menu focus
	-- cannot leave the cursor locked after chapter playback stops.
	if self.editorMode then
		self.mousePolicyBinding = "VNSceneEditorMousePolicy_" .. tostring(self)
		RunService:BindToRenderStep(self.mousePolicyBinding, Enum.RenderPriority.Camera.Value + 1, function()
			self:_applyCameraPolicy()
		end)
		self:_applyCameraPolicy()
	end

	-- Apply only after Roblox's standard camera update, so Explore3D gets a
	-- subtle first-person walk bob without taking ownership of the camera.
	self.exploreMotionBinding = "VNSceneEditorExploreMotion_" .. tostring(self)
	RunService:BindToRenderStep(self.exploreMotionBinding, Enum.RenderPriority.Camera.Value + 2, function(dt)
		self:_updateExploreMotion(dt)
	end)

	return self
end

--------------------------------------------------------------------------------
-- Modes
--------------------------------------------------------------------------------

function Presenter:setSafeAreaBottom(scale)
	self.stage:setSafeAreaBottom(scale)
end

-- Editor-only transient controls (such as the panel quick switcher) can hide
-- the cursor without competing with the per-frame camera mouse policy.
function Presenter:setEditorMouseCaptured(captured)
	self.editorMouseCaptured = captured == true
	self:_applyCameraPolicy()
end

function Presenter:setAdvanceHint(text)
	self.stage:setAdvanceHint(text)
end

-- Edge fades are authored as Room Assembly appearance data. They need to be
-- visible in an ordinary Room3D as well as while its temporary assembly
-- copies are animating, so their lifetime is owned by the active room.
function Presenter:setAssemblyAppearance(definition)
	self.assemblyAppearanceDefinition = definition
	self.assemblyAppearance:apply(definition)
end

function Presenter:_syncAssemblyAppearance(scene, project)
	-- Presenter receives Schema.subsceneView(), which already resolves linked
	-- Room3D ownership into these two fields.
	local definition = scene and type(scene.roomDefinitionId) == "string" and scene.roomDefinitionId ~= "" and project
		and Schema.findById(project.roomDefinitions, scene.roomDefinitionId) or nil
	self:setAssemblyAppearance(definition)
end

function Presenter:showRoomExitChoices(callback)
	self.roomExitCallback = callback
	self.roomExitChoices.Visible = callback ~= nil
end

-- While the editor panels are up, world clicks must not fire interactions.
function Presenter:setInteractive(enabled)
	self.interactive = enabled
	self.world:setEnabled(enabled)
	self:_setPlaybackPerspective(enabled)
	self:_syncPlayerState()
	self:_applyCameraPolicy()
	if not enabled and self.scene == nil then
		self:_restoreEditorCameraControl()
	end
end

-- Browsing the editor uses a Scriptable noclip camera. Runtime playtests never
-- do: they clear this flag before the Director enters its first scene.
function Presenter:setEditorFly(enabled)
	if not self.editorMode then return end
	self.editorFly = enabled == true
	self:_syncPlayerState()
	self:_applyCameraPolicy()
end

-- The editor always uses Roblox's first-person camera mode. Only active
-- Explore3D chapter play captures the mouse; Room3D play, preview, and editor
-- views leave the cursor free for normal panels and world selection.
function Presenter:_applyCameraPolicy()
	if not self.editorMode then return end
	local player = Players.LocalPlayer
	if not player then return end

	if player.CameraMode ~= Enum.CameraMode.LockFirstPerson then
		player.CameraMode = Enum.CameraMode.LockFirstPerson
	end

	-- Query the live state instead of trusting InputEnded: Roblox menus and GUI
	-- capture can consume that event and otherwise leave the editor permanently
	-- believing that the right button is held.
	local lockMouseForExplore = self.interactive and self.scene ~= nil
		and self.scene.stage.kind == "Explore3D"
	local previewDragging = not self.interactive
		and UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2)
	local mouseBehavior
	if lockMouseForExplore then
		mouseBehavior = Enum.MouseBehavior.LockCenter
	elseif previewDragging then
		-- Keep one consistent captured mode for the entire drag. This avoids the
		-- rapid-drag snap caused by alternation with MouseBehavior.Default.
		mouseBehavior = Enum.MouseBehavior.LockCurrentPosition
	else
		mouseBehavior = Enum.MouseBehavior.Default
	end
	if UserInputService.MouseBehavior ~= mouseBehavior then
		UserInputService.MouseBehavior = mouseBehavior
	end
	UserInputService.MouseIconEnabled = not self.editorMouseCaptured and not lockMouseForExplore and not previewDragging
end

function Presenter:_setPlaybackPerspective(_playback)
	self:_applyCameraPolicy()
end

local function humanoidOf(character)
	return character and character:FindFirstChildOfClass("Humanoid") or nil
end

local function isFootstepSound(sound)
	if not sound:IsA("Sound") then return false end
	local name = string.lower(sound.Name)
	return name == "running" or string.find(name, "footstep", 1, true) ~= nil
		or string.find(name, "walk", 1, true) ~= nil
end

function Presenter:_restoreDefaultFootsteps()
	for sound, volume in pairs(self.mutedFootstepSounds) do
		if sound.Parent then sound.Volume = volume end
	end
	table.clear(self.mutedFootstepSounds)
end

function Presenter:_muteDefaultFootsteps(character)
	if not character then return end
	for _, descendant in ipairs(character:GetDescendants()) do
		if descendant ~= self.exploreFootstepSound and isFootstepSound(descendant) then
			if self.mutedFootstepSounds[descendant] == nil then
				self.mutedFootstepSounds[descendant] = descendant.Volume
			end
			descendant.Volume = 0
		end
	end
end

function Presenter:_clearExploreMovement()
	local humanoid = self.exploreMotionHumanoid
	if humanoid and humanoid.Parent and self.exploreBaseWalkSpeed ~= nil then
		humanoid.WalkSpeed = self.exploreBaseWalkSpeed
	end
	self.exploreBaseWalkSpeed = nil
	self.exploreAppliedWalkSpeed = nil
	self.exploreMotionHumanoid = nil
	self.exploreStepDistance = 0
	self.exploreBobPhase = 0
	self.exploreLastAutoFootstep = nil
	self.exploreFootstepToken += 1
	if self.exploreFootstepSound then
		self.exploreFootstepSound:Stop()
		self.exploreFootstepSound:Destroy()
		self.exploreFootstepSound = nil
	end
	self:_restoreDefaultFootsteps()
end

function Presenter:_canExploreMove()
	return self.interactive and not self.controlsDisabled and self.scene ~= nil
		and self.scene.stage.kind == "Explore3D" and self.runtimePhase == "Await"
end

function Presenter:_playExploreFootstep(root, settings, delay)
	local token = self.exploreFootstepToken
	local function play()
		if token ~= self.exploreFootstepToken or not root or not root.Parent then return end
		if not self.exploreFootstepSound or self.exploreFootstepSound.Parent ~= root then
			if self.exploreFootstepSound then self.exploreFootstepSound:Destroy() end
			local sound = Instance.new("Sound")
			sound.Name = "VNExploreFootstep"
			sound.RollOffMaxDistance = 28
			sound.Parent = root
			self.exploreFootstepSound = sound
		end
		self.exploreFootstepSound.SoundId = settings.footstepSoundId
		self.exploreFootstepSound.Volume = settings.footstepVolume
		self.exploreFootstepSound.TimePosition = 0
		self.exploreFootstepSound:Play()
	end

	-- Negative timing is handled by detecting the next bob beat early; a
	-- positive value simply schedules playback after that beat.
	delay = tonumber(delay) or 0
	if delay > 0 then
		task.delay(delay, play)
	else
		play()
	end
end

function Presenter:_updateExploreMotion(dt)
	if not self:_canExploreMove() then return end

	local player = Players.LocalPlayer
	local character = player and player.Character
	local humanoid = humanoidOf(character)
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not humanoid or not root then return end

	if self.exploreMotionHumanoid ~= humanoid then
		self:_clearExploreMovement()
		self.exploreMotionHumanoid = humanoid
		self.exploreBaseWalkSpeed = math.max(0, humanoid.WalkSpeed)
		self.exploreAppliedWalkSpeed = humanoid.WalkSpeed
	end

	-- If another game system changes walking speed while this Explore3D is
	-- awaiting input, treat that as the new normal speed before applying sprint.
	if self.exploreAppliedWalkSpeed ~= nil
		and math.abs(humanoid.WalkSpeed - self.exploreAppliedWalkSpeed) > 0.01 then
		self.exploreBaseWalkSpeed = math.max(0, humanoid.WalkSpeed)
	end

	local sprinting = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift)
		or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
	local settings = Schema.normalizeExploreMovementSettings(self.project and self.project.exploreMovement)
	local desiredSpeed = (self.exploreBaseWalkSpeed or 0) * (sprinting and settings.sprintMultiplier or 1)
	if math.abs(humanoid.WalkSpeed - desiredSpeed) > 0.01 then
		humanoid.WalkSpeed = desiredSpeed
	end
	self.exploreAppliedWalkSpeed = desiredSpeed

	self:_muteDefaultFootsteps(character)
	local velocity = root.AssemblyLinearVelocity
	local horizontalSpeed = Vector3.new(velocity.X, 0, velocity.Z).Magnitude
	local moving = humanoid.MoveDirection.Magnitude > 0.05 and horizontalSpeed > 0.35
	if not moving then return end

	self.exploreBobPhase += horizontalSpeed * dt * settings.bobSpeed
	local bobAmount = settings.bobIntensity * (sprinting and 1.35 or 1)
	local camera = Workspace.CurrentCamera
	if camera and camera.CameraType ~= Enum.CameraType.Scriptable then
		camera.CFrame = camera.CFrame * CFrame.new(0, math.sin(self.exploreBobPhase) * bobAmount, 0)
	end

	if settings.footstepAuto then
		-- One beat occurs on every half-cycle of the bob. A negative delay shifts
		-- the detection point earlier by the appropriate amount of phase, which
		-- is the only meaningful way to play before a future visual bob.
		local delay = settings.footstepDelay
		local earlyPhase = math.max(0, -delay) * horizontalSpeed * settings.bobSpeed
		local beat = math.floor((self.exploreBobPhase + earlyPhase) / math.pi)
		if self.exploreLastAutoFootstep == nil then
			self.exploreLastAutoFootstep = beat
		elseif beat > self.exploreLastAutoFootstep then
			self.exploreLastAutoFootstep = beat
			self:_playExploreFootstep(root, settings, delay)
		end
	else
		self.exploreLastAutoFootstep = nil
		self.exploreStepDistance += horizontalSpeed * dt
		local stride = settings.footstepStride * (sprinting and 1.28 or 1)
		if self.exploreStepDistance >= stride then
			self.exploreStepDistance -= stride
			self:_playExploreFootstep(root, settings, 0)
		end
	end
end

-- ESC can end a chapter while Roblox's default camera controller still has
-- mouse capture for the current frame. Restore the surrounding controls, but
-- deliberately retain first-person mode per the editor's camera policy.
function Presenter:_restoreEditorCameraControl()
	if not self.editorMode then return end
	-- A free-flying editor is already the intended camera owner; restoring the
	-- stock Custom camera here would fight its render-step loop after a playtest.
	if self.editorFly then return end
	local player = Players.LocalPlayer
	if not player then return end

	local function restore()
		self:_applyCameraPolicy()
		WorldBindings.setPlayerControls(true)
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		UserInputService.MouseIconEnabled = true
		local camera = Workspace.CurrentCamera
		local humanoid = humanoidOf(player.Character)
		if camera then
			camera.CameraType = Enum.CameraType.Custom
			if humanoid then camera.CameraSubject = humanoid end
		end
	end

	restore()
	-- The stock camera controller may apply one final first-person update during
	-- the same input frame as Escape. Reassert after it has yielded once.
	task.defer(function()
		if self.editorMode and not self.interactive and self.scene == nil then restore() end
	end)
	-- Default PlayerModule camera updates run on the render step, so one later
	-- reassertion prevents an Escape press from leaving it in LockCenter.
	task.delay(0.1, function()
		if self.editorMode and not self.interactive and self.scene == nil then restore() end
	end)
end

function Presenter:_restoreWalkSpeed()
	if self.walkSpeedConnection then
		self.walkSpeedConnection:Disconnect()
		self.walkSpeedConnection = nil
	end

	local humanoid = self.lockedHumanoid
	local walkSpeed = self.savedWalkSpeed
	self.lockedHumanoid = nil
	self.savedWalkSpeed = nil

	if humanoid and humanoid.Parent and walkSpeed ~= nil then
		humanoid.WalkSpeed = walkSpeed
	end
end

function Presenter:_lockHumanoid(humanoid)
	if not humanoid then
		return
	end

	if self.lockedHumanoid ~= humanoid then
		self:_restoreWalkSpeed()
		self.lockedHumanoid = humanoid
		self.savedWalkSpeed = humanoid.WalkSpeed
		humanoid.WalkSpeed = 0

		-- Preserve an updated game-specific movement speed if another system tries
		-- to change it while VN playback owns the movement lock.
		self.walkSpeedConnection = humanoid:GetPropertyChangedSignal("WalkSpeed"):Connect(function()
			if self.controlsDisabled and self.lockedHumanoid == humanoid and humanoid.WalkSpeed ~= 0 then
				self.savedWalkSpeed = humanoid.WalkSpeed
				humanoid.WalkSpeed = 0
			end
		end)
	elseif humanoid.WalkSpeed ~= 0 then
		self.savedWalkSpeed = humanoid.WalkSpeed
		humanoid.WalkSpeed = 0
	end
end

function Presenter:_watchCharacter(character)
	if self.characterChildConnection then
		self.characterChildConnection:Disconnect()
		self.characterChildConnection = nil
	end

	if not character then
		return
	end

	if self.controlsDisabled then
		WorldBindings.setPlayerControls(false)
		self:_lockHumanoid(humanoidOf(character))
	end

	self.characterChildConnection = character.ChildAdded:Connect(function(child)
		if child:IsA("Humanoid") and self.controlsDisabled then
			self:_lockHumanoid(child)
		end
	end)
end

function Presenter:_setControls(enabled)
	if enabled then
		if self.controlsDisabled then
			self.controlsDisabled = false
			self:_restoreWalkSpeed()
			WorldBindings.setPlayerControls(true)
		end
	else
		if not self.controlsDisabled then
			self.controlsDisabled = true
		end
		-- Retry acquisition if PlayerModule was not ready on an earlier call.
		WorldBindings.setPlayerControls(false)

		local player = Players.LocalPlayer
		self:_lockHumanoid(humanoidOf(player and player.Character))
	end
end

function Presenter:_syncPlayerState()
	-- Preview is an editor view, not runtime playback. It must never inherit the
	-- WalkSpeed/control lock used by active sequences.
	if self.editorMode and not self.interactive then
		self:_clearExploreMovement()
		-- The editor's free-flight camera owns W/A/S/D/Q/E. Disable the normal
		-- PlayerModule movement while it is active so the avatar does not walk
		-- below a noclip camera at the same time.
		self:_setControls(not self.editorFly)
		return
	end

	local exploreAwait = self.scene ~= nil
		and self.scene.stage.kind == "Explore3D"
		and self.runtimePhase == "Await"
	local canExploreMove = exploreAwait and self.interactive
	local outsidePlayback = self.scene == nil
		and (self.runtimePhase == "Idle" or self.runtimePhase == "Ended")

	-- Restore the normal walk speed before any non-AWAIT state installs its
	-- zero-WalkSpeed lock. Holding Shift can therefore never punch through a
	-- sequence, dialogue, or transition movement lock.
	if not canExploreMove then
		self:_clearExploreMovement()
	end
	self:_setControls(outsidePlayback or canExploreMove)
	if exploreAwait then
		-- A Zoom exit has just returned the scripted rig to the pre-interaction
		-- Explore camera view. Use the guarded handoff so the stock controller
		-- cannot flash one stale pose before it resumes player control.
		self.rig:releaseToPlayer()
	end
end

-- The Director owns this phase. Movement is available only while an
-- interactive Explore3D subscene is genuinely waiting for player input.
function Presenter:setRuntimePhase(phase)
	self.runtimePhase = phase or "Idle"
	self:_syncPlayerState()
end

local function exploreSpawnPreviewCFrame(subscene)
	local spawn = subscene and Schema.decodeCFrame(subscene.spawnCFrame)
	if not spawn then
		local position = subscene and Schema.decodePosition(subscene.spawnPosition)
		if not position then return nil end
		local camera = Workspace.CurrentCamera
		local rotation = camera and camera.CFrame.Rotation or CFrame.identity
		return CFrame.new(position + Vector3.new(0, 3, 0)) * rotation
	end
	-- Keep the exact spawn facing, but put the editor camera a little above the
	-- character's root point so opening the subscene is immediately readable.
	return CFrame.new(spawn.Position + Vector3.new(0, 3, 0)) * spawn.Rotation
end

-- Apply a scene's stage settings: camera pose, controls, world mode.
function Presenter:enterScene(scene, project)
	self:closeAssembly(false)
	self:showRoomExitChoices(nil)
	self.scene = scene
	self.project = project or self.project
	self.stage:clearForeground()
	self.lastDialogueEntryId = nil
	self.lastDialogueSegmentId = nil
	self.lastDialogueSpeaker = ""
	self.lastDialoguePortraitId = ""
	self.lastDialogueCrossfadeNext = false
	self.speakerTurnDirection = 1
	self.speakerTurnBaseCFrame = nil
	self.world:clear()
	local activeSubscene = Schema.subsceneIndex(scene, scene.activeSubsceneId)
	self.characterModels:setScene(scene, activeSubscene, self.project, self.hiddenCharacterModels)
	self.characterModels:setInteractionBindings(scene.interactions)
	self:_syncAssemblyAppearance(scene, self.project)
	self:_setPlaybackPerspective(self.interactive and scene.stage.kind == "Explore3D")

	local kind = scene.stage.kind
	local editorFly = self.editorMode and self.editorFly and not self.interactive

	if editorFly then
		-- Free flight remains the camera owner in the editor, but entering a
		-- subscene (including through a blue camera-pose marker) is an explicit
		-- navigation request and must still place the camera at that subscene's
		-- authored pose. CameraRig keeps its fly transform in sync with setPose,
		-- so the user can immediately keep flying from there afterward.
		self.rig:startFly()
		if kind == "Explore3D" then
			local spawnCFrame = exploreSpawnPreviewCFrame(activeSubscene)
			if spawnCFrame then self.rig:setCFrame(spawnCFrame) end
		elseif kind == "Room3D" or scene.background.kind == "Camera3D" then
			local poseId = scene.stage.cameraPoseId ~= "" and scene.stage.cameraPoseId or scene.background.poseId
			local pose = Schema.findCameraPose(self.project, poseId)
			if pose then
				self.rig:setPose(pose)
			else
				self.rig:setCFrame(self.rig:getCFrame())
			end
		end
	elseif kind == "Explore3D" then
		-- Switch to the ordinary player camera behind any active screen overlay.
		-- Movement remains phase-locked until this subscene reaches AWAIT.
		self.rig:release()
	else
		local poseId = scene.stage.cameraPoseId ~= "" and scene.stage.cameraPoseId or scene.background.poseId
		local pose = Schema.findCameraPose(self.project, poseId)

		if pose then
			self.rig:setPose(pose)
		elseif kind == "Room3D" or scene.background.kind == "Camera3D" then
			-- No pose yet: hold the camera where it is so the world stays visible.
			self.rig:setCFrame(self.rig:getCFrame())
		end
	end

	self:_syncPlayerState()
end

-- Re-apply stage settings without clearing (editor refresh after edits).
function Presenter:refreshScene(scene, project)
	self.scene = scene
	self.project = project or self.project
	local activeSubscene = Schema.subsceneIndex(scene, scene.activeSubsceneId)
	-- refreshScene is used by Merge, whose source Zoom state must remain intact
	-- until its deferred zoom-out runs.  Ordinary entries use enterScene above,
	-- which deliberately resets that state.
	self.characterModels:setScene(scene, activeSubscene, self.project, self.hiddenCharacterModels, true)
	self.characterModels:setInteractionBindings(scene.interactions)
	self:_syncAssemblyAppearance(scene, self.project)
	self:_setPlaybackPerspective(self.interactive and scene.stage.kind == "Explore3D")
	self:_syncPlayerState()
end

function Presenter:leaveScene()
	self:closeAssembly(true)
	self:setAssemblyAppearance(nil)
	self:showRoomExitChoices(nil)
	self.world:clear()
	self.characterModels:resetFade()
	self.characterModels:setScene(nil, nil, nil, self.hiddenCharacterModels)
	if not (self.editorMode and self.editorFly and not self.interactive) then
		self.rig:release()
	end
	self.stage:clear()
	self.scene = nil
	self:_setPlaybackPerspective(false)
	-- Return to the surrounding game only when the editor is not immediately
	-- resuming its map-browsing fly camera.
	self:_syncPlayerState()
	self:_restoreEditorCameraControl()
	self.lastDialogueEntryId = nil
	self.lastDialogueSegmentId = nil
	self.lastDialogueSpeaker = ""
	self.lastDialoguePortraitId = ""
	self.lastDialogueCrossfadeNext = false
	self.speakerTurnBaseCFrame = nil
	self:stopMusic(0.5)
end

function Presenter:prepareAssembly(definition, destination, options)
	self:closeAssembly(false)
	local session, err = AssemblySession.create(definition, self.rig, destination or self.rig:getCFrame(), options)
	if not session then return nil, err end
	self.assemblySession = session
	self.assemblyCharacterFade = self.characterModels.faded
	if not options or options.hideCharacters ~= false then self.characterModels:setFaded(true) end
	return session
end

function Presenter:closeAssembly(restoreCamera)
	if not self.assemblySession then return end
	self.assemblySession:close(restoreCamera)
	self.assemblySession = nil
	self.characterModels:setFaded(self.assemblyCharacterFade == true)
	self.assemblyCharacterFade = nil
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

function Presenter:getCharacterModels()
	return self.characterModels
end

function Presenter:setHiddenCharacterModels(hidden)
	self.hiddenCharacterModels = type(hidden) == "table" and hidden or {}
	if self.scene then
		local activeSubscene = Schema.subsceneIndex(self.scene, self.scene.activeSubsceneId)
		-- Hiding a placed model during an active Zoom can rebuild the layer; keep
		-- the current fade state rather than flashing every other model back in.
		self.characterModels:setScene(self.scene, activeSubscene, self.project, self.hiddenCharacterModels, true)
		self.characterModels:setInteractionBindings(self.scene.interactions)
	end
end

function Presenter:removeCharacterModel(placementId)
	self.hiddenCharacterModels[placementId] = true
	self.characterModels:remove(placementId)
end

--------------------------------------------------------------------------------
-- Rendering
--------------------------------------------------------------------------------

function Presenter:_renderCamera(snapshot)
	if self.rig.cameraLease then return end
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
			self.speakerTurnBaseCFrame = nil
			self.rig:setBlend(fromPose, toPose, Easing.alpha(tween.easing, progress))
			return
		end
	end

	if self.rig:getCurrentPoseId() ~= toPose.id then
		self.speakerTurnBaseCFrame = nil
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
		self.lastDialogueSegmentId = nil
		self.lastDialogueSpeaker = ""
		self.lastDialoguePortraitId = ""
		self.lastDialogueCrossfadeNext = false
		return false
	end

	if dialogue.entryId == self.lastDialogueEntryId then
		return false
	end

	local scene = self.scene
	-- Explore3D has no authored speaker staging. Start every dialogue block with
	-- a fresh, temporary left/right stage so its invented sides do not leak into
	-- a later block elsewhere in the sequence.
	if scene and scene.stage.kind == "Explore3D"
		and dialogue.segmentId ~= self.lastDialogueSegmentId then
		self.speakerTurnDirection = 1
		self.speakerTurnBaseCFrame = nil
	end

	local previousSpeaker = self.lastDialogueSpeaker
	local previousPortraitId = self.lastDialoguePortraitId
	local previousCrossfadeNext = self.lastDialogueCrossfadeNext == true
	local nextSpeaker = dialogue.character or ""
	local nextPortraitId = snapshot.portrait and snapshot.portrait.imageId or ""
	self.lastDialogueEntryId = dialogue.entryId
	self.lastDialogueSegmentId = dialogue.segmentId
	self.lastDialogueSpeaker = nextSpeaker
	self.lastDialoguePortraitId = nextPortraitId
	self.lastDialogueCrossfadeNext = dialogue.crossfadeNextPortrait == true

	local portrait = snapshot.portrait
	local cameraBacked = scene
		and (scene.stage.kind == "Room3D" or scene.stage.kind == "Explore3D"
			or snapshot.background.kind == "Camera3D" or snapshot.cameraPoseId ~= "")

	if not cameraBacked
		or previousSpeaker == ""
		or nextSpeaker == ""
		or previousSpeaker == nextSpeaker
		or previousCrossfadeNext
		-- The visible portrait is the actual in-room speaker cue.  A line can
		-- intentionally carry a different character label while reusing the same
		-- portrait, and that should not imply a new camera target or a sweep.
		or nextPortraitId == previousPortraitId
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

	local current = self.rig:getCFrame()
	if not self.speakerTurnBaseCFrame then
		-- Capture the actual live view on the first handoff.  In particular this
		-- preserves a Hotspot's Zoom framing instead of jumping back to the full
		-- Room3D camera pose before sweeping to the next speaker.
		self.speakerTurnBaseCFrame = current
	end
	local direction = self.speakerTurnDirection
	local sweepSettings = Schema.normalizeSpeakerSweepSettings(self.project and self.project.speakerSweep)
	local duration = sweepSettings.duration
	local shot, resolvedDirection = speakerTurnShot(
		scene,
		self.project,
		self.characterModels,
		nextSpeaker,
		direction,
		current,
		self.speakerTurnBaseCFrame,
		sweepSettings
	)
	direction = resolvedDirection or direction
	-- Portrait travel follows the camera's screen direction: a rightward pan
	-- brings the new portrait in from the right edge (and vice versa).
	if not self.stage:beginSpeakerPortraitTransition(portrait, direction, duration) then
		return false
	end

	self.speakerTurnDirection = -direction
	local fallbackYaw = math.rad(sweepSettings.yawDegrees or math.deg(DEFAULT_SPEAKER_TURN_YAW))
	self.rig:moveTo(shot or current * CFrame.Angles(0, -fallbackYaw * direction, 0), duration, sweepSettings.easing)
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
	local eventScene = (context and context.scene) or self.scene

	for _, event in ipairs(events or {}) do
		local params = event.params or {}
		if event.type == "ScreenShake" then
			-- A Camera3D background lives in Workspace rather than StageView, so
			-- mirror its background channel onto the scripted camera.
			if eventScene and eventScene.background and eventScene.background.kind == "Camera3D" then
				self.rig:shake(
					tonumber(params.backgroundIntensity or params.intensity) or 11,
					tonumber(params.backgroundDuration or params.duration) or 0.5
				)
			end
		elseif event.type == "PlaySound" and isRealAsset(params.soundId) then
			local sound = Instance.new("Sound")
			sound.SoundId = params.soundId
			sound.Volume = params.volume or 0.5
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

function Presenter:fadePortraitOut(duration)
	return self.stage:fadePortraitOut(duration)
end

function Presenter:hideImageFocus()
	self.stage:hideImageFocus()
end

function Presenter:clearImageFocus(immediate)
	self.stage:clearImageFocus(immediate == true)
end

--------------------------------------------------------------------------------
-- Transitions and world
--------------------------------------------------------------------------------

-- Yields.
function Presenter:runTransition(preset, context)
	context = context or {}
	-- The next dialogue handoff must begin from the camera state established by
	-- a new interaction Zoom, rather than a speaker shot from an earlier run.
	if preset and preset.kind == "Zoom" and context.direction ~= "exit" then
		self.speakerTurnBaseCFrame = nil
	end
	context.stage = self.stage
	context.rig = self.rig
	context.overlay = self.overlay
	context.project = context.project or self.project
	context.characterModels = self.characterModels
	context.apply = context.apply or function() end

	Transitions.run(preset, context)
end

-- The response editor represents the state after an interaction's entrance,
-- so mirror any supported transition without playing time-based animation.
function Presenter:previewInteractionEntrance(interaction)
	if not interaction or not self.project then return false end
	local preset = Schema.findTransition(self.project, interaction.transitionId)
	if not preset then return false end
	return Transitions.preview(preset, {
		rig = self.rig,
		characterModels = self.characterModels,
		interaction = interaction,
		targetId = interaction.targetId,
	})
end

function Presenter:forgetInteractionTransition(interaction)
	Transitions.forgetInteraction(interaction)
end

-- list = { { interaction, available }, ... }
function Presenter:setInteractables(list)
	-- The model advertises its authored Hotspot association even while the
	-- interaction is temporarily unavailable during a playing sequence.
	self.characterModels:setInteractionBindings(self.scene and self.scene.interactions or list)
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
	self:closeAssembly(true)
	self:setAssemblyAppearance(nil)
	self.scene = nil
	self:_clearExploreMovement()
	self:_setPlaybackPerspective(false)
	self:_setControls(true)
	if self.exploreMotionBinding then
		RunService:UnbindFromRenderStep(self.exploreMotionBinding)
		self.exploreMotionBinding = nil
	end
	self:_restoreEditorCameraControl()
	if self.mousePolicyBinding then
		RunService:UnbindFromRenderStep(self.mousePolicyBinding)
		self.mousePolicyBinding = nil
	end
	if self.characterConnection then
		self.characterConnection:Disconnect()
		self.characterConnection = nil
	end
	if self.characterChildConnection then
		self.characterChildConnection:Disconnect()
		self.characterChildConnection = nil
	end
	self:stopMusic(0)
	self.world:destroy()
	self.characterModels:destroy()
	self.assemblyAppearance:destroy()
	self.rig:destroy()
	self.stage:destroy()
	self.InteractionRequested:DisconnectAll()
end

return Presenter
