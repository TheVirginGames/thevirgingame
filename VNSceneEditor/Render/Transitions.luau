-- Scene to scene (and interaction enter / exit) transitions. Every run call
-- yields until the transition has finished.
--
-- context = {
--   stage, rig, overlay, project, fromScene, toScene, apply,
--   targetId, interaction, direction = "enter" | "exit"   (interaction transitions)
-- }
-- apply() switches to the new content; each kind calls it at the right moment.

local TweenService = game:GetService("TweenService")
local SoundService = game:GetService("SoundService")
local RunService = game:GetService("RunService")

local Schema = require(script.Parent.Parent.Core.Schema)
local WorldBindings = require(script.Parent.WorldBindings)

local Transitions = {}

-- Per-interaction camera memory lets Zoom return to the exact player view it
-- started from. The target itself is never hidden or modified.
local zoomStates = {}

-- Interaction transitions should frame a target clearly without putting the
-- camera uncomfortably close to (or inside) its geometry.
local ZOOM_STANDOFF = 7
local CHARACTER_MODEL_ZOOM_STANDOFF = 12
local ENTER_STAGING_STANDOFF = 7
local ENTER_PUSH_STANDOFF = 5
local ENTER_STAGING_DURATION = 0.55
local ENTER_PRE_FADE_DELAY = 0.05
local ENTER_PUSH_FADE_DURATION = 1.1

local function tweenAsync(instance, duration, goals, style, cancelled)
	if cancelled and cancelled() then
		return false
	end
	if duration <= 0 then
		for key, value in pairs(goals) do
			instance[key] = value
		end
		return true
	end

	local tween = TweenService:Create(instance, TweenInfo.new(duration, style or Enum.EasingStyle.Quad, Enum.EasingDirection.InOut), goals)
	local finished = false
	local connection = tween.Completed:Connect(function()
		finished = true
	end)
	tween:Play()
	while not finished do
		if cancelled and cancelled() then
			connection:Disconnect()
			tween:Cancel()
			return false
		end
		RunService.Heartbeat:Wait()
	end
	connection:Disconnect()
	return not cancelled or not cancelled()
end

local function waitCancelable(duration, cancelled)
	local deadline = os.clock() + math.max(0, duration)
	while os.clock() < deadline do
		if cancelled and cancelled() then return false end
		RunService.Heartbeat:Wait()
	end
	return not cancelled or not cancelled()
end

local function waitForTween(tween, cancelled)
	if not tween then return not cancelled or not cancelled() end
	local finished = false
	local connection = tween.Completed:Connect(function()
		finished = true
	end)
	while not finished do
		if cancelled and cancelled() then
			connection:Disconnect()
			tween:Cancel()
			return false
		end
		RunService.Heartbeat:Wait()
	end
	connection:Disconnect()
	return not cancelled or not cancelled()
end

local function hideOverlay(overlay)
	if overlay and overlay.Parent then
		overlay.BackgroundTransparency = 1
		overlay.Visible = false
	end
end

local function scenePose(project, scene)
	if not scene then
		return nil
	end

	local poseId = scene.stage.cameraPoseId ~= "" and scene.stage.cameraPoseId or scene.background.poseId
	return Schema.findCameraPose(project, poseId)
end

local function transitionTarget(context)
	local interaction = context.interaction
	if interaction and type(interaction.targetCharacterModelId) == "string"
		and interaction.targetCharacterModelId ~= "" and context.characterModels then
		return context.characterModels:resolveTarget(interaction.targetCharacterModelId)
	end
	return WorldBindings.resolve(context.targetId, interaction and interaction.targetRef)
end

local function zoomStandOff(context)
	local interaction = context.interaction
	if interaction and type(interaction.targetCharacterModelId) == "string"
		and interaction.targetCharacterModelId ~= "" then
		return CHARACTER_MODEL_ZOOM_STANDOFF
	end
	return ZOOM_STANDOFF
end

local function zoomFocusPoint(context, target)
	local center = WorldBindings.centerOf(target)
	if not center then return nil end

	local interaction = context.interaction
	if interaction and type(interaction.targetCharacterModelId) == "string"
		and interaction.targetCharacterModelId ~= "" and target and target:IsA("Model") then
		local root = target:FindFirstChild("HumanoidRootPart", true)
		if root and root:IsA("BasePart") then
			-- A character-targeted Zoom reads better from a modestly raised eye-line
			-- than from the model's bounding-box centre.
			local raisedRoot = root.Position + root.CFrame.UpVector * math.max(0.8, root.Size.Y * 0.65)
			return center:Lerp(raisedRoot, 0.6)
		end
	end

	return center
end

local function zoomDestination(context, target, fromPosition)
	local focus = zoomFocusPoint(context, target)
	if not focus then return nil end

	local from = fromPosition or context.rig:getCFrame().Position
	local toward = focus - from
	local distance = toward.Magnitude
	if distance <= 0.001 then return nil end

	local destination = focus - toward.Unit * math.min(distance, zoomStandOff(context))
	return CFrame.lookAt(destination, focus)
end

local kinds = {}

local function fadeBlackFallback(context)
	kinds.FadeBlack({
		kind = "FadeBlack",
		params = { fadeOut = 0.5, hold = 0.1, fadeIn = 0.5 },
	}, context)
end

local function playTransitionSound(name, soundId)
	local sound = Instance.new("Sound")
	sound.Name = name
	sound.SoundId = "rbxassetid://" .. soundId
	sound.Volume = 1
	sound.Parent = SoundService
	sound.Ended:Connect(function()
		if sound.Parent then sound:Destroy() end
	end)
	sound:Play()
	task.delay(20, function()
		if sound.Parent then sound:Destroy() end
	end)
	return sound
end

-- Enter uses one natural one-shot during its inward movement. It deliberately
-- has no transition-owned fade or cutoff; the sound plays to completion.
local function playEnterFollowup()
	return playTransitionSound("VNEnterFollowup", "82104982606471")
end

function kinds.FadeBlack(preset, context)
	local params = preset.params
	local overlay = context.overlay

	overlay.BackgroundColor3 = Color3.new(0, 0, 0)
	overlay.Visible = true
	if not tweenAsync(overlay, params.fadeOut or 0.5, { BackgroundTransparency = 0 }, nil, context.cancelled) then
		hideOverlay(overlay)
		return
	end

	context.apply()
	if context.cancelled and context.cancelled() then
		hideOverlay(overlay)
		return
	end

	if (params.hold or 0) > 0 and not waitCancelable(params.hold, context.cancelled) then
		hideOverlay(overlay)
		return
	end

	tweenAsync(overlay, params.fadeIn or 0.5, { BackgroundTransparency = 1 }, nil, context.cancelled)
	hideOverlay(overlay)
end

function kinds.CrossFade(preset, context)
	local stage = context.stage
	stage:freeze()
	context.apply()
	stage:unfreeze(preset.params.duration or 0.8)
	task.wait(preset.params.duration or 0.8)
end

function kinds.CameraSweep(preset, context)
	local pose = scenePose(context.project, context.toScene)
	local duration = preset.params.duration or 1.2

	if pose then
		local cframe = Schema.decodeCFrame(pose.cframe)
		if cframe then
			context.rig:moveToAsync(cframe, duration, "Sine")
		end
	end

	if context.cancelled and context.cancelled() then return end
	context.apply()
end

-- Zoom closes in on the interaction target while leaving the target completely
-- visible. Exit returns to the exact camera CFrame captured on entry.
function kinds.Zoom(preset, context)
	local settings = Schema.normalizeHotspotZoomSettings(context.project and context.project.hotspotZoom)
	local zoomInDuration = settings.zoomInDuration
	local zoomOutDuration = settings.zoomOutDuration
	local easing = settings.easing
	local key = context.interaction and context.interaction.id or "scene"

	if context.direction == "exit" then
		local state = zoomStates[key]

		if state then
			zoomStates[key] = nil
			if context.characterModels then context.characterModels:fadeIn(settings.modelFadeInDuration) end
			local tween = context.rig:moveTo(state.cameraCFrame, zoomOutDuration, easing)
			-- The stage's final line is already running its own outro by the time
			-- this begins. Start the visual return before clearing foreground so
			-- that outro, camera pull-back, and model fade-in share the same beat.
			context.apply()
			waitForTween(tween, context.cancelled)
		else
			context.apply()
		end

		return
	end

	local target = transitionTarget(context)
	local state = { cameraCFrame = context.rig:getCFrame() }
	zoomStates[key] = state
	if target then
		local originalCamera = state.cameraCFrame
		local focus = zoomFocusPoint(context, target)
		if focus then
			-- Establish the player's attention on the object before any forward
			-- movement. This is a turn in place, not the Zoom itself.
			local lookAtTarget = CFrame.lookAt(originalCamera.Position, focus)
			context.rig:moveToAsync(lookAtTarget, settings.lookDuration, easing)
		end

		local destination = zoomDestination(context, target, originalCamera.Position)
		if context.characterModels then context.characterModels:fadeOut(settings.modelFadeOutDuration) end
		if destination then
			-- Placed character models use a wider cinematic framing than ordinary
			-- object Hotspots. Never finish closer than the selected stand-off,
			-- even when the interaction starts very near its target.
			local tween = context.rig:moveTo(destination, zoomInDuration, easing)
			if context.onZoomPushStarted then context.onZoomPushStarted() end
			waitForTween(tween, context.cancelled)
		else
			if context.onZoomPushStarted then context.onZoomPushStarted() end
			waitCancelable(zoomInDuration, context.cancelled)
		end
	else
		if context.characterModels then context.characterModels:fadeOut(settings.modelFadeOutDuration) end
		if context.onZoomPushStarted then context.onZoomPushStarted() end
		waitCancelable(zoomInDuration, context.cancelled)
	end

	context.apply()
end

-- Reconstruct the post-enter state while authoring an interaction response.
-- This is intentionally instant: the editor is showing the point after its
-- entrance transition, not replaying that transition every time a line is
-- selected or scrubbed.
function Transitions.preview(preset, context)
	if not preset or (preset.kind ~= "Zoom" and preset.kind ~= "NpcTalk") or (context.direction == "exit") then
		return false
	end
	local target = transitionTarget(context)
	local destination = zoomDestination(context, target)
	if destination then
		context.rig:setCFrame(destination)
	end
	if context.characterModels then
		context.characterModels:setFaded(true)
	end
	return destination ~= nil
end

-- Defensive compatibility for an in-memory project that has not passed
-- through Schema normalization yet.
kinds.NpcTalk = kinds.Zoom

-- Hotspot-only Go To transition. It first establishes a deliberate
-- front-facing shot, then pushes toward the object while the destination is
-- hidden behind a black overlay.
function kinds.Enter(_preset, context)
	if context.interaction then
		-- A direct Go to Subscene bypasses the normal Zoom exit path.
		zoomStates[context.interaction.id] = nil
	end

	local target = transitionTarget(context)
	local facingCFrame, center, size = WorldBindings.geometryOf(target)
	if not facingCFrame or not center or not size then
		fadeBlackFallback(context)
		return
	end

	local facing = facingCFrame.LookVector
	local up = facingCFrame.UpVector
	local halfDepth = math.max(0.25, size.Z * 0.5)
	-- Enter still has a small forward movement under the black fade, but both
	-- its initial framing and its closest point remain comfortably away from the
	-- target rather than pressing the camera into the geometry.
	local stagingDistance = halfDepth + ENTER_STAGING_STANDOFF
	local pushDistance = halfDepth + ENTER_PUSH_STANDOFF
	local stagingPosition = center + facing * stagingDistance
	local pushPosition = center + facing * pushDistance
	local stagingCFrame = CFrame.lookAt(stagingPosition, center, up)
	local pushCFrame = CFrame.lookAt(pushPosition, center, up)

	context.rig:moveToAsync(stagingCFrame, ENTER_STAGING_DURATION, "Sine")
	if context.cancelled and context.cancelled() then return end
	-- Give the push only a tiny beat after staging, then play its one-shot
	-- naturally while the camera and black fade begin together.
	if not waitCancelable(ENTER_PRE_FADE_DELAY, context.cancelled) then return end
	playEnterFollowup()

	local overlay = context.overlay
	overlay.BackgroundColor3 = Color3.new(0, 0, 0)
	overlay.BackgroundTransparency = 1
	overlay.Visible = true
	context.rig:moveTo(pushCFrame, ENTER_PUSH_FADE_DURATION, "Sine")
	if not tweenAsync(overlay, ENTER_PUSH_FADE_DURATION, { BackgroundTransparency = 0 }, Enum.EasingStyle.Sine, context.cancelled) then
		hideOverlay(overlay)
		return
	end

	context.apply()
	if not waitCancelable(0.08, context.cancelled) then
		hideOverlay(overlay)
		return
	end
	tweenAsync(overlay, 0.5, { BackgroundTransparency = 1 }, Enum.EasingStyle.Sine, context.cancelled)
	hideOverlay(overlay)
end

function Transitions.run(preset, context)
	local handler = preset and kinds[preset.kind]

	if not handler then
		context.apply()
		return
	end

	-- A failing transition must not apply its destination twice if the failure
	-- occurred after the swap point.
	local originalApply = context.apply
	local applied = false
	context.apply = function()
		if applied then return end
		applied = true
		originalApply()
	end

	local ok, err = pcall(handler, preset, context)
	if not ok then
		warn("[VNSceneEditor] transition failed: " .. tostring(err))
		hideOverlay(context.overlay)
		if not context.cancelled or not context.cancelled() then
			context.apply()
		end
	end
end

function Transitions.describe(preset)
	if not preset then
		return "cut"
	end
	return preset.name
end

function Transitions.forgetInteraction(interaction)
	local interactionId = type(interaction) == "table" and interaction.id or interaction
	if interactionId then zoomStates[interactionId] = nil end
end

return Transitions
