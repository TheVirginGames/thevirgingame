-- Capture overlay for camera poses. Puts the CameraRig in fly mode and shows
-- Capture / Cancel.

local UserInputService = game:GetService("UserInputService")

local Theme = require(script.Parent.Theme)
local Widgets = require(script.Parent.Widgets)

local FlyCam = {}
FlyCam.__index = FlyCam

function FlyCam.new(parent, app)
	local self = setmetatable({}, FlyCam)

	self.app = app
	self.active = false
	self.callback = nil
	self.connection = nil

	self.overlay = Widgets.panel({
		Name = "FlyCam",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 20),
		Size = UDim2.new(0, 560, 0, 70),
		BackgroundColor3 = Theme.Panel,
		BackgroundTransparency = 0.05,
		ZIndex = 60,
		Visible = false,
		Parent = parent,
	}, { Widgets.stroke(Theme.Accent, 2, 0), Widgets.padding(10, 14, 10, 14) })

	Widgets.label({
		Text = "Fly: W A S D move, Q / E down / up, hold right mouse to look, Shift for speed.\nFrame the shot, then press Capture (or Enter).",
		Size = UDim2.new(1, -230, 1, 0),
		TextWrapped = true,
		TextTruncate = Enum.TextTruncate.None,
		TextSize = 12,
		ZIndex = 61,
		Parent = self.overlay,
	})

	Widgets.button({
		Text = "Capture  (Enter)",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -110, 0.5, 0),
		Size = UDim2.new(0, 120, 0, 30),
		Color = Theme.Good,
		TextSize = 11,
		ZIndex = 61,
		OnClick = function()
			self:capture()
		end,
		Parent = self.overlay,
	})

	Widgets.button({
		Text = "Cancel  (Esc)",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, 0, 0.5, 0),
		Size = UDim2.new(0, 100, 0, 30),
		Color = Theme.Danger,
		TextSize = 11,
		ZIndex = 61,
		OnClick = function()
			self:stop()
		end,
		Parent = self.overlay,
	})

	return self
end

function FlyCam:isActive()
	return self.active
end

function FlyCam:start(callback, startCFrame)
	self:stop()

	self.active = true
	self.callback = callback
	self.overlay.Visible = true

	self.app.presenter:getRig():startFly(startCFrame)

	self.connection = UserInputService.InputBegan:Connect(function(input, processed)
		if processed and input.KeyCode ~= Enum.KeyCode.Escape then
			return
		end

		if input.KeyCode == Enum.KeyCode.Escape then
			self:stop()
		elseif input.KeyCode == Enum.KeyCode.Return then
			self:capture()
		end
	end)
end

function FlyCam:capture()
	if not self.active then
		return
	end

	local rig = self.app.presenter:getRig()
	local text = rig:capture()
	local callback = self.callback

	self:stop()

	if callback then
		callback(text)
	end
end

function FlyCam:stop()
	if self.connection then
		self.connection:Disconnect()
		self.connection = nil
	end

	local wasActive = self.active
	self.active = false
	self.callback = nil
	self.overlay.Visible = false

	if wasActive then
		self.app.presenter:getRig():stopFly()
		self.app:onCameraCaptureEnded()
	end
end

function FlyCam:destroy()
	self:stop()
	self.overlay:Destroy()
end

return FlyCam
