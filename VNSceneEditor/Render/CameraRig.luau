-- Owns the local camera while a scene needs a fixed viewpoint.
--
-- Poses are stored as twelve component CFrame strings (see Schema.encodeCFrame).
-- Fly mode is how the editor captures new poses: WASD + Q/E to move, hold the
-- right mouse button to look, Shift to speed up.

local RunService = game:GetService("RunService")
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
	self.flying = false
	self.flyConnections = {}

	return self
end

local function camera()
	return Workspace.CurrentCamera
end

function CameraRig:_own()
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
end

function CameraRig:isOwned()
	return self.owned
end

function CameraRig:getCFrame()
	local cam = camera()
	return cam and cam.CFrame or CFrame.new()
end

function CameraRig:setCFrame(cframe)
	self:_own()
	self:_cancelTween()
	local cam = camera()
	if cam then
		cam.CFrame = cframe
	end
end

-- Snap to a pose. poseId is remembered so renders can skip redundant sets.
function CameraRig:setPose(pose)
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
	self:_own()
	self:_cancelTween()

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

-- Give the camera back to the default scripts.
function CameraRig:release()
	self:stopFly()
	self:_cancelTween()

	local cam = camera()
	if cam and self.owned then
		cam.CameraType = self.savedType or Enum.CameraType.Custom
		if self.savedSubject then
			cam.CameraSubject = self.savedSubject
		end
	end

	self.owned = false
	self.currentPoseId = nil
end

--------------------------------------------------------------------------------
-- Fly mode
--------------------------------------------------------------------------------

function CameraRig:isFlying()
	return self.flying
end

function CameraRig:startFly(startCFrame)
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

	local yaw, pitch = 0, 0
	do
		local look = cframe.LookVector
		yaw = math.atan2(-look.X, -look.Z)
		pitch = math.asin(math.clamp(look.Y, -1, 1))
	end

	local position = cframe.Position
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
			yaw -= input.Delta.X * 0.004
			pitch = math.clamp(pitch - input.Delta.Y * 0.004, -1.5, 1.5)
		end
	end))

	table.insert(self.flyConnections, RunService.RenderStepped:Connect(function(dt)
		local cam2 = camera()
		if not cam2 then
			return
		end

		local rotation = CFrame.fromEulerAnglesYXZ(pitch, yaw, 0)
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
			position += move.Unit * speed * dt
		end

		cam2.CameraType = Enum.CameraType.Scriptable
		cam2.CFrame = CFrame.new(position) * rotation
	end))
end

-- Returns the final CFrame.
function CameraRig:stopFly()
	if not self.flying then
		return self:getCFrame()
	end

	self.flying = false

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
