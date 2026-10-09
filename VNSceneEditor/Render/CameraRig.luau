-- Owns the local camera while a scene needs a fixed viewpoint.
--
-- Poses are stored as twelve component CFrame strings (see Schema.encodeCFrame).
-- Fly mode is how the editor captures new poses: WASD + Q/E to move, hold the
-- right mouse button to look, Shift to speed up.

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Schema = require(script.Parent.Parent.Core.Schema)
local Easing = require(script.Parent.Parent.Runtime.Easing)

local CameraRig = {}
CameraRig.__index = CameraRig

function CameraRig.new()
	local self = setmetatable({}, CameraRig)

	self.owned = false
	self.savedType = nil
	self.savedSubject = nil
	self.currentPoseId = nil
	self.tween = nil
	self.shakeConnection = nil
	self.shakeToken = 0
	self.flying = false
	self.flyConnections = {}
	self.flyPosition = nil
	self.flyYaw = 0
	self.flyPitch = 0
	self.flyTweening = false
	-- When a scripted interaction returns to Explore3D, Roblox's Custom camera
	-- can otherwise apply one stale controller frame immediately after release.
	-- Keep a short, post-camera handoff guard so it adopts the returned view
	-- instead of visibly snapping before normal player control resumes.
	self.playerHandoffBinding = "VNSceneCameraHandoff_" .. tostring(self)
	self.playerHandoffActive = false
	self.playerHandoffToken = 0

	return self
end

local function camera()
	return Workspace.CurrentCamera
end

function CameraRig:_cancelPlayerHandoff()
	self.playerHandoffToken += 1
	if self.playerHandoffActive then
		RunService:UnbindFromRenderStep(self.playerHandoffBinding)
		self.playerHandoffActive = false
	end
end

function CameraRig:_own()
	self:_cancelPlayerHandoff()
	local cam = camera()
	if not cam then
		return
	end

	if not self.owned then
		self.owned = true
		self.savedType = cam.CameraType
		self.savedSubject = cam.CameraSubject
	end

	cam.CameraType = Enum.CameraType.Scriptable
end

function CameraRig:_cancelTween()
	if self.tween then
		self.tween:Cancel()
		self.tween = nil
	end
	self.flyTweening = false
end

function CameraRig:_stopShake()
	self.shakeToken += 1
	if self.shakeConnection then
		self.shakeConnection:Disconnect()
		self.shakeConnection = nil
	end
end

function CameraRig:isOwned()
	return self.owned
end

function CameraRig:acquireLease()
	if self.cameraLease then return nil, "Camera already reserved" end
	local cam = camera()
	if not cam then return nil, "Camera unavailable" end
	local token = { cframe = cam.CFrame, fov = cam.FieldOfView, flying = self.flying }
	self:stopFly()
	self:_cancelTween()
	self:_stopShake()
	self:_own()
	self.cameraLease = token
	return token
end

function CameraRig:releaseLease(token, restore)
	if self.cameraLease ~= token then return end
	self.cameraLease = nil
	local cam = camera()
	if cam then
		cam.FieldOfView = token.fov
		if restore then self:setCFrame(token.cframe) end
	end
	if token.flying then self:startFly(restore and token.cframe or self:getCFrame()) end
end

function CameraRig:getCFrame()
	local cam = camera()
	return cam and cam.CFrame or CFrame.new()
end

function CameraRig:setCFrame(cframe, owner)
	if self.cameraLease and self.cameraLease ~= owner then return end
	self:_own()
	self:_cancelTween()
	self:_stopShake()
	local cam = camera()
	if cam then
		cam.CFrame = cframe
	end
	if self.flying then
		self:_setFlyCFrame(cframe)
	end
end

-- Snap to a pose. poseId is remembered so renders can skip redundant sets.
function CameraRig:setPose(pose)
	if self.cameraLease then return end
	if not pose then
		return
	end

	local cframe = Schema.decodeCFrame(pose.cframe)
	if not cframe then
		return
	end

	self.currentPoseId = pose.id
	self:setCFrame(cframe)
end

function CameraRig:getCurrentPoseId()
	return self.currentPoseId
end

-- Non yielding tween to a CFrame.
function CameraRig:moveTo(cframe, duration, easing)
	if self.cameraLease then return nil end
	self:_own()
	self:_cancelTween()
	self:_stopShake()

	local cam = camera()
	if not cam then
		return nil
	end

	if not duration or duration <= 0 then
		cam.CFrame = cframe
		return nil
	end

	self.tween = TweenService:Create(cam, TweenInfo.new(duration, Easing.style(easing or "Quad"), Enum.EasingDirection.InOut), {
		CFrame = cframe,
	})
	if self.flying then
		-- The free-fly loop normally owns the camera every render step. Let a
		-- deliberate cinematic/editor tween own it temporarily, then fold its
		-- final pose back into free-fly so it cannot snap to the old view.
		self.flyTweening = true
		local tween = self.tween
		tween.Completed:Connect(function(state)
			if self.tween == tween and self.flying then
				if state == Enum.PlaybackState.Completed then
					self:_setFlyCFrame(cam.CFrame)
				end
				self.flyTweening = false
			end
		end)
	end
	self.tween:Play()
	return self.tween
end

function CameraRig:moveToPose(pose, duration, easing)
	if not pose then
		return
	end

	local cframe = Schema.decodeCFrame(pose.cframe)
	if not cframe then
		return
	end

	self.currentPoseId = pose.id
	self:moveTo(cframe, duration, easing)
end

-- Yields until the move completes.
function CameraRig:moveToAsync(cframe, duration, easing)
	local tween = self:moveTo(cframe, duration, easing)
	if tween then
		tween.Completed:Wait()
	end
end

-- Place the camera mid-way through a tween between two poses. Used when the
-- editor scrubs into a Camera.MoveTo with a duration.
function CameraRig:setBlend(fromPose, toPose, alpha)
	local fromCFrame = fromPose and Schema.decodeCFrame(fromPose.cframe)
	local toCFrame = toPose and Schema.decodeCFrame(toPose.cframe)

	if not toCFrame then
		return
	end

	if not fromCFrame or alpha >= 1 then
		self.currentPoseId = toPose.id
		self:setCFrame(toCFrame)
		return
	end

	self.currentPoseId = nil
	self:setCFrame(fromCFrame:Lerp(toCFrame, alpha))
end

-- Camera3D backgrounds are not GUI layers, so their background shake is
-- applied directly to the scripted camera. The shake is transient and never
-- changes the authored pose.
function CameraRig:shake(intensity, duration)
	if self.cameraLease then return end
	if not self.owned then return end
	intensity = math.max(0, tonumber(intensity) or 0)
	duration = math.max(0, tonumber(duration) or 0)
	if intensity <= 0 or duration <= 0 then return end

	self:_stopShake()
	local cam = camera()
	if not cam then return end
	local base = cam.CFrame
	local token = self.shakeToken
	local started = os.clock()
	self.shakeConnection = RunService.RenderStepped:Connect(function()
		if token ~= self.shakeToken then return end
		local elapsed = os.clock() - started
		if elapsed >= duration then
			cam.CFrame = base
			self:_stopShake()
			return
		end
		local decay = 1 - (elapsed / duration)
		local x = math.random(-100, 100) / 100 * intensity * decay
		local y = math.random(-100, 100) / 100 * intensity * decay
		cam.CFrame = base
			* CFrame.new(x * 0.012, y * 0.012, 0)
			* CFrame.Angles(y * 0.002, x * 0.002, 0)
	end)
end

-- Give the camera back to the default scripts.
function CameraRig:release()
	if self.cameraLease then return end
	self:_cancelPlayerHandoff()
	self:stopFly()
	self:_cancelTween()
	self:_stopShake()

	local cam = camera()
	if cam and self.owned then
		cam.CameraType = self.savedType or Enum.CameraType.Custom
		local subject = self.savedSubject
		if not subject or subject.Parent == nil then
			local player = Players.LocalPlayer
			subject = player and player.Character and player.Character:FindFirstChildOfClass("Humanoid") or nil
		end
		if subject then
			cam.CameraSubject = subject
		end
	end

	self.owned = false
	self.currentPoseId = nil
end

-- Hand camera ownership back to Roblox without a one-frame reset. This is
-- intentionally only used when an Explore3D interaction has just returned to
-- AWAIT: ordinary scene/editor releases should remain completely immediate.
function CameraRig:releaseToPlayer()
	if self.cameraLease then return end
	if not self.owned then
		return
	end

	local finalCFrame = self:getCFrame()
	self:release()

	local cam = camera()
	if not cam then
		return
	end
	local token = self.playerHandoffToken
	local framesRemaining = 2
	self.playerHandoffActive = true
	RunService:BindToRenderStep(self.playerHandoffBinding, Enum.RenderPriority.Camera.Value + 1, function()
		if token ~= self.playerHandoffToken or self.owned then
			RunService:UnbindFromRenderStep(self.playerHandoffBinding)
			self.playerHandoffActive = false
			return
		end

		-- The Custom controller has updated by this point. Reassert the exact
		-- final Zoom-return CFrame briefly, then leave all subsequent frames to
		-- the normal player camera.
		if cam == camera() and cam.CameraType ~= Enum.CameraType.Scriptable then
			cam.CFrame = finalCFrame
		end
		framesRemaining -= 1
		if framesRemaining <= 0 then
			RunService:UnbindFromRenderStep(self.playerHandoffBinding)
			self.playerHandoffActive = false
		end
	end)
end

--------------------------------------------------------------------------------
-- Fly mode
--------------------------------------------------------------------------------

function CameraRig:isFlying()
	return self.flying
end

-- Keep the fly loop's own position/orientation in sync with programmatic
-- camera moves (for example the editor's "Go" button). Without this, the
-- next render step restores the old local flight state and makes the camera
-- appear stuck or snap back.
function CameraRig:_setFlyCFrame(cframe)
	if not cframe then return end
	self.flyPosition = cframe.Position
	local look = cframe.LookVector
	self.flyYaw = math.atan2(-look.X, -look.Z)
	self.flyPitch = math.asin(math.clamp(look.Y, -1, 1))
end

function CameraRig:startFly(startCFrame)
	if self.cameraLease then return end
	if self.flying then
		return
	end

	self:_own()
	self:_cancelTween()
	self.flying = true

	local cam = camera()
	local cframe = startCFrame or (cam and cam.CFrame) or CFrame.new(0, 10, 20)
	if cam then
		cam.CFrame = cframe
	end

	self:_setFlyCFrame(cframe)
	local looking = false

	table.insert(self.flyConnections, UserInputService.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton2 then
			looking = true
			UserInputService.MouseBehavior = Enum.MouseBehavior.LockCurrentPosition
		end
	end))

	table.insert(self.flyConnections, UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton2 then
			looking = false
			UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		end
	end))

	table.insert(self.flyConnections, UserInputService.InputChanged:Connect(function(input)
		if looking and input.UserInputType == Enum.UserInputType.MouseMovement then
			self.flyYaw -= input.Delta.X * 0.004
			self.flyPitch = math.clamp(self.flyPitch - input.Delta.Y * 0.004, -1.5, 1.5)
		end
	end))

	table.insert(self.flyConnections, RunService.RenderStepped:Connect(function(dt)
		local cam2 = camera()
		if not cam2 then
			return
		end
		if self.flyTweening then
			return
		end

		local rotation = CFrame.fromEulerAnglesYXZ(self.flyPitch, self.flyYaw, 0)
		local speed = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) and 60 or 18
		local move = Vector3.zero

		if UserInputService:GetFocusedTextBox() == nil then
			if UserInputService:IsKeyDown(Enum.KeyCode.W) then
				move += rotation.LookVector
			end
			if UserInputService:IsKeyDown(Enum.KeyCode.S) then
				move -= rotation.LookVector
			end
			if UserInputService:IsKeyDown(Enum.KeyCode.D) then
				move += rotation.RightVector
			end
			if UserInputService:IsKeyDown(Enum.KeyCode.A) then
				move -= rotation.RightVector
			end
			if UserInputService:IsKeyDown(Enum.KeyCode.E) then
				move += Vector3.yAxis
			end
			if UserInputService:IsKeyDown(Enum.KeyCode.Q) then
				move -= Vector3.yAxis
			end
		end

		if move.Magnitude > 0 then
			self.flyPosition += move.Unit * speed * dt
		end

		cam2.CameraType = Enum.CameraType.Scriptable
		cam2.CFrame = CFrame.new(self.flyPosition) * rotation
	end))
end

-- Returns the final CFrame.
function CameraRig:stopFly()
	if not self.flying then
		return self:getCFrame()
	end

	self.flying = false
	self.flyPosition = nil
	self.flyTweening = false

	for _, connection in ipairs(self.flyConnections) do
		connection:Disconnect()
	end
	table.clear(self.flyConnections)

	UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	return self:getCFrame()
end

function CameraRig:capture()
	return Schema.encodeCFrame(self:getCFrame())
end

function CameraRig:destroy()
	self:release()
end

return CameraRig
