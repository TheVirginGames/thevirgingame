-- Draws a snapshot on a full screen frame.
--
-- Two background layers allow cross fades, the portrait applies a transform
-- from keyframe tracks, and the dialogue UI is supplied by the Visualui
-- template while textbox presets control its animation. Each line types
-- out from snapshot.dialogue.entryTime, and requestAdvance() plays the out
-- animations before the runner moves on.

local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")
local StarterGui = game:GetService("StarterGui")

local Schema = require(script.Parent.Parent.Core.Schema)
local Easing = require(script.Parent.Parent.Runtime.Easing)

local StageView = {}
StageView.__index = StageView

local PORTRAIT_SIZE = Vector2.new(0.28, 0.72)

-- Per-entry tracks are authored around the original portrait resting point
-- (0.5, 1). The project layout moves that resting point for every portrait
-- without changing any existing animation/keyframe data.
local function portraitPresentation(transform, layout)
	layout = layout or Schema.newPortraitLayout()

	return {
		x = layout.x + (transform.x - 0.5),
		y = layout.y + (transform.y - 1),
		-- Track scale remains a uniform animation multiplier. The preset layout
		-- supplies the independently editable width and height multipliers.
		scaleX = layout.scaleX * transform.scale,
		scaleY = layout.scaleY * transform.scale,
	}
end

local function create(className, properties, children)
	local instance = Instance.new(className)

	for key, value in pairs(properties or {}) do
		if key ~= "Parent" then
			instance[key] = value
		end
	end

	for _, child in ipairs(children or {}) do
		child.Parent = instance
	end

	if properties and properties.Parent then
		instance.Parent = properties.Parent
	end

	return instance
end

function StageView.parseColor(value, fallback)
	local r, g, b = string.match(tostring(value), "(%d+)%s*,%s*(%d+)%s*,%s*(%d+)")

	if r then
		return Color3.fromRGB(
			math.clamp(tonumber(r), 0, 255),
			math.clamp(tonumber(g), 0, 255),
			math.clamp(tonumber(b), 0, 255)
		)
	end

	return fallback or Color3.fromRGB(40, 44, 72)
end

local parseColor = StageView.parseColor

local function requiredChild(parent, name, className)
	local child = parent:FindFirstChild(name)

	assert(
		child and (not className or child:IsA(className)),
		string.format(
			"Visualui is missing %s%s",
			name,
			className and " (" .. className .. ")" or ""
		)
	)

	return child
end

-- Uses the authored StarterGui design as source data, then moves its visible
-- parts under the stage so they share its safe area, shake, and transitions.
local function takeVisualTemplate(parent)
	local playerGui = Players.LocalPlayer and Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
	local visualUi = playerGui and playerGui:FindFirstChild("Visualui")

	if not visualUi then
		local source = StarterGui:FindFirstChild("Visualui")
		assert(source and source:IsA("ScreenGui"), "StarterGui.Visualui must be a ScreenGui")
		visualUi = source:Clone()
	end

	assert(visualUi:IsA("ScreenGui"), "Visualui must be a ScreenGui")

	local bars = requiredChild(visualUi, "Bars", "Frame")
	local rectangle = requiredChild(visualUi, "rectangle", "ImageLabel")

	local contents = requiredChild(rectangle, "Contents", "Frame")
	local dialog = requiredChild(contents, "Dialog", "TextLabel")
	local leftClick = requiredChild(contents, "leftclick", "ImageLabel")
	local skipSound = requiredChild(leftClick, "Skip", "Sound")

	local namePlate = requiredChild(bars, "Name", "ImageLabel")
	local nameLabel = requiredChild(namePlate, "Name", "TextLabel")

	local pinkBar = requiredChild(bars, "Pinkbar", "ImageLabel")
	local speaking = requiredChild(bars, "SPEAKING", "ImageLabel")
	local speakingText = requiredChild(speaking, "Text", "ImageLabel")

	rectangle.ZIndex = 6
	contents.ZIndex = 7
	dialog.ZIndex = 8
	leftClick.ZIndex = 8

	bars.ZIndex = 8
	pinkBar.ZIndex = 8
	speaking.ZIndex = 8
	speakingText.ZIndex = 9

	namePlate.ZIndex = 9
	nameLabel.ZIndex = 10

	bars.Parent = parent
	rectangle.Parent = parent

	visualUi:Destroy()

	return {
		bars = bars,
		rectangle = rectangle,
		contents = contents,
		dialog = dialog,
		leftClick = leftClick,
		skipSound = skipSound,

		namePlate = namePlate,
		nameLabel = nameLabel,

		pinkBar = pinkBar,
		speaking = speaking,
		speakingText = speakingText,
	}
end

local function captureVisualState(root, includeDescendants, excluded)
	local state = {}
	local instances = { root }

	if includeDescendants then
		for _, descendant in ipairs(root:GetDescendants()) do
			table.insert(instances, descendant)
		end
	end

	for _, instance in ipairs(instances) do
		if not (excluded and excluded[instance]) then
			local values = {}

			if instance:IsA("GuiObject") then
				values.BackgroundTransparency = instance.BackgroundTransparency
			end

			if instance:IsA("ImageLabel") or instance:IsA("ImageButton") then
				values.ImageTransparency = instance.ImageTransparency
			elseif instance:IsA("TextLabel")
				or instance:IsA("TextButton")
				or instance:IsA("TextBox") then

				values.TextTransparency = instance.TextTransparency
				values.TextStrokeTransparency = instance.TextStrokeTransparency

			elseif instance:IsA("UIStroke") then
				values.Transparency = instance.Transparency
			end

			if next(values) then
				table.insert(state, {
					instance = instance,
					values = values,
				})
			end
		end
	end

	return state
end

local function visualGoals(values, alpha)
	local goals = {}

	for property, restingValue in pairs(values) do
		goals[property] = restingValue + (1 - restingValue) * alpha
	end

	return goals
end

local function newBackgroundLayer(name, parent, zIndex)
	local frame = create("Frame", {
		Name = name,
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Color3.fromRGB(40, 44, 72),
		BorderSizePixel = 0,
		ZIndex = zIndex,
		Parent = parent,
	})

	local image = create("ImageLabel", {
		Name = "Image",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		ScaleType = Enum.ScaleType.Crop,
		Image = "",
		ZIndex = zIndex,
		Parent = frame,
	})

	return {
		frame = frame,
		image = image,
	}
end

-- Paints one background state onto a layer at the given opacity.
local function paintLayer(layer, state, opacity)
	if not state or opacity <= 0 or state.kind == "Camera3D" then
		layer.frame.BackgroundTransparency = 1
		layer.image.ImageTransparency = 1
		layer.image.Image = ""
		return
	end

	if state.kind == "Image" and state.value ~= "" then
		local imageId = Schema.formatImageId(state.value)

		layer.image.Image = imageId ~= "" and imageId or state.value
		layer.image.ImageTransparency = 1 - opacity

		-- The image itself is the complete visual layer. Giving its parent a
		-- semi-transparent dark fill as well means that, halfway through an
		-- image crossfade, black is composited beneath the new image before the
		-- old one. Keep the frame transparent so opacity blends only old image
		-- into new image, exactly like a scene crossfade.
		layer.frame.BackgroundTransparency = 1
	else
		layer.image.Image = ""
		layer.image.ImageTransparency = 1

		layer.frame.BackgroundColor3 = parseColor(state.value)
		layer.frame.BackgroundTransparency = 1 - opacity
	end
end

function StageView.new(parent)
	local self = setmetatable({}, StageView)

	self.safeBottom = 0
	self.shaking = false

	self.lastPortraitId = nil
	self.portraitFadeUntil = 0
	self.portraitLayout = Schema.newPortraitLayout()

	self.lastEntryId = nil
	self.revealed = false

	self.elementTweens = {}

	self.outUntil = 0
	self.boxHiddenByOut = false
	self.pendingDialogueMerge = nil

	self.frozen = nil

	-- How long the entrance animation takes before typewriter text may begin.
	self.typewriterDelay = 0

	self.root = create("Frame", {
		Name = "Stage",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		ClipsDescendants = true,
		ZIndex = 1,
		Parent = parent,
	})

	self.shakeHolder = create("Frame", {
		Name = "ShakeHolder",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Parent = self.root,
	})

	self.layerFrom = newBackgroundLayer(
		"BackgroundFrom",
		self.shakeHolder,
		1
	)

	self.layerTo = newBackgroundLayer(
		"BackgroundTo",
		self.shakeHolder,
		2
	)

	self.vignette = create("Frame", {
		Name = "Vignette",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Color3.fromRGB(0, 0, 0),
		BorderSizePixel = 0,
		ZIndex = 3,
		Parent = self.shakeHolder,
	}, {
		create("UIGradient", {
			Rotation = 90,
			Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 1),
				NumberSequenceKeypoint.new(0.55, 0.85),
				NumberSequenceKeypoint.new(1, 0.45),
			}),
			Color = ColorSequence.new(Color3.fromRGB(0, 0, 0)),
		}),
	})

	-- Copy of the last background used by CrossFade transitions.
	self.freezeLayer = newBackgroundLayer(
		"Freeze",
		self.shakeHolder,
		4
	)

	paintLayer(self.freezeLayer, nil, 0)

	self.characterLayer = create("Frame", {
		Name = "Characters",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		ZIndex = 5,
		Parent = self.shakeHolder,
	})

	self.portrait = create("ImageLabel", {
		Name = "Portrait",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.fromScale(0.5, 1),
		Size = UDim2.fromScale(
			PORTRAIT_SIZE.X,
			PORTRAIT_SIZE.Y
		),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		-- The transform is defined by this visible portrait rectangle. Fit would
		-- center square/wide assets inside it and leave an unmovable blank strip
		-- at the bottom, so every source fills the same transform bounds.
		ScaleType = Enum.ScaleType.Stretch,
		Image = "",
		ImageTransparency = 0,
		Visible = false,
		ZIndex = 5,
		Parent = self.characterLayer,
	})

	-- Used only while the camera turns from one speaking character to another.
	-- The normal portrait remains the incoming portrait; this layer carries the
	-- previous speaker off-screen without changing normal crossfade behavior.
	self.outgoingPortrait = create("ImageLabel", {
		Name = "OutgoingPortrait",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.fromScale(0.5, 1),
		Size = UDim2.fromScale(PORTRAIT_SIZE.X, PORTRAIT_SIZE.Y),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScaleType = Enum.ScaleType.Stretch,
		Image = "",
		ImageTransparency = 1,
		Visible = false,
		ZIndex = 5,
		Parent = self.characterLayer,
	})
	self.portrait.ZIndex = 6
	self.speakerPortraitTransition = nil
	self.portraitFadeTween = nil

	local visual = takeVisualTemplate(self.shakeHolder)

	self.dialogueBox = visual.rectangle
	self.bars = visual.bars

	self.dialogueContents = visual.contents

	self.namePlate = visual.namePlate
	self.nameLabel = visual.nameLabel

	self.pinkBar = visual.pinkBar
	self.speaking = visual.speaking
	self.speakingText = visual.speakingText

	self.textLabel = visual.dialog
	self.leftClick = visual.leftClick
	self.skipSound = visual.skipSound
	self.leftClickPulse = nil
	self.leftClickFlashTween = nil
	self.leftClickFlashToken = 0
	self.leftClickSkipFlashed = false
	self.leftClick.Visible = false
	self.speakingTextPulse = nil
	self.speakingPulseDelay = math.huge
	self.speakingExitTweens = {}
	self.speakingExitToken = 0
	self.currentSpeaking = false
	self.templateTextColor = self.textLabel.TextColor3
	self.templateTextStrokeColor = self.textLabel.TextStrokeColor3
	self.nonSpeakingTextStrokeColor = Color3.fromRGB(141, 136, 136)
	self.speaking.Visible = false

	self.dialogueBox.Visible = false
	self.bars.Visible = false

	self.flashOverlay = create("Frame", {
		Name = "Flash",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Color3.fromRGB(255, 255, 255),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ZIndex = 20,
		Parent = self.shakeHolder,
	})

	self.debugLabel = create("TextLabel", {
		Name = "StateReadout",
		Position = UDim2.new(0, 16, 0, 58),
		Size = UDim2.new(0, 560, 0, 18),
		BackgroundTransparency = 1,
		Font = Enum.Font.Code,
		TextSize = 12,
		TextColor3 = Color3.fromRGB(150, 154, 175),
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "",
		ZIndex = 8,
		Parent = self.root,
	})

	-- Rest positions and opacity come directly from the authored Visualui
	-- template.
	self.rest = {
		box = {
			templatePosition = self.dialogueBox.Position,
			position = self.dialogueBox.Position,

			-- Dialog itself is excluded because its visibility is handled by
			-- MaxVisibleGraphemes and the typewriter sequence.
			visual = captureVisualState(
				self.dialogueBox,
				true,
				{
					[self.textLabel] = true,
				}
			),
		},

		-- Bars itself acts as the container whose screen position changes when
		-- the editor safe area is active.
		bars = {
			templatePosition = self.bars.Position,
			position = self.bars.Position,
		},

		-- Pinkbar is animated independently from the Name hierarchy.
		pinkBar = {
			templatePosition = self.pinkBar.Position,
			position = self.pinkBar.Position,
			visual = captureVisualState(
				self.pinkBar,
				true
			),
		},

		-- SPEAKING and its nested Text image fade together. Its Text image later
		-- receives a separate gentle pulse once this entrance has settled.
		speaking = {
			templatePosition = self.speaking.Position,
			position = self.speaking.Position,
			visual = captureVisualState(
				self.speaking,
				true
			),
		},

		-- Name and the TextLabel inside Name fade together.
		namePlate = {
			templatePosition = self.namePlate.Position,
			position = self.namePlate.Position,
			visual = captureVisualState(
				self.namePlate,
				true
			),
		},

		body = {
			templatePosition = self.textLabel.Position,
			position = self.textLabel.Position,
			visual = captureVisualState(
				self.textLabel,
				false
			),
		},
	}

	return self
end

-- The docked editor panel covers the bottom of the screen, so while editing
-- the dialogue box and portrait are lifted above it.
function StageView:setSafeAreaBottom(scale)
	self.safeBottom = scale

	self.characterLayer.Size = UDim2.new(
		1,
		0,
		1 - scale,
		0
	)

	local safeOffset = UDim2.new(
		0,
		0,
		-scale,
		0
	)

	self.rest.box.position =
		self.rest.box.templatePosition + safeOffset

	self.rest.bars.position =
		self.rest.bars.templatePosition + safeOffset

	if not self.dialogueBox.Visible then
		self.dialogueBox.Position =
			self.rest.box.position

		self.bars.Position =
			self.rest.bars.position
	end
end

function StageView:setAdvanceHint(text)
	self.advanceHintText = text or ""
end

function StageView:setDebugVisible(visible)
	self.debugLabel.Visible = visible
end

-- The template's leftclick image is a prompt, not a second input system. It
-- becomes visible only after a skippable line has finished typing.
function StageView:_stopLeftClickPulse(hide, preserveFlash)
	local keepFlash = preserveFlash and self.leftClickFlashTween ~= nil
	if self.leftClickPulse then
		self.leftClickPulse:Cancel()
		self.leftClickPulse = nil
	end
	if not keepFlash then
		self.leftClickFlashToken += 1
		if self.leftClickFlashTween then
			self.leftClickFlashTween:Cancel()
			self.leftClickFlashTween = nil
		end
	end

	if hide then
		if not keepFlash then
			self.leftClick.Visible = false
			self.leftClick.ImageTransparency = 1
		end
		self.leftClickSkipFlashed = keepFlash
	end
end

function StageView:_showLeftClickPulse()
	if self.leftClickPulse or self.leftClickFlashTween or self.leftClickSkipFlashed then
		return
	end

	self.leftClick.Visible = true
	self.leftClick.ImageTransparency = 0.1

	local pulse = TweenService:Create(
		self.leftClick,
		TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut, -1, true),
		{ ImageTransparency = 0.5 }
	)
	self.leftClickPulse = pulse
	pulse:Play()
end

-- The SPEAKING badge itself follows Pinkbar's entrance/exit. Only its nested
-- Text image pulses, so both images still fade and move together as one badge.
function StageView:_stopSpeakingTextPulse(resetTransparency)
	if self.speakingTextPulse then
		self.speakingTextPulse:Cancel()
		self.speakingTextPulse = nil
	end

	if resetTransparency and self.speakingText.Parent then
		for _, item in ipairs(self.rest.speaking.visual or {}) do
			if item.instance == self.speakingText then
				self.speakingText.ImageTransparency = item.values.ImageTransparency or 0
				break
			end
		end
	end
end

function StageView:_showSpeakingTextPulse()
	if not self.speaking.Visible or self.speakingTextPulse then
		return
	end

	self.speakingText.ImageTransparency = 0.1
	local pulse = TweenService:Create(
		self.speakingText,
		TweenInfo.new(0.8, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut, -1, true),
		{ ImageTransparency = 0.5 }
	)
	self.speakingTextPulse = pulse
	pulse:Play()
end

function StageView:_updateSpeakingBadge(dialogue)
	if dialogue.speaking == false or not self.speaking.Visible then
		self:_stopSpeakingTextPulse(true)
		return
	end

	if (dialogue.entryTime or 0) >= self.speakingPulseDelay then
		self:_showSpeakingTextPulse()
	end
end

-- Called when the player clicks the visible prompt to skip/advance. The token prevents a
-- delayed completion callback from hiding the prompt belonging to a later line.
function StageView:_flashLeftClickOnSkip()
	if not self.leftClick.Visible then
		return
	end

	self.skipSound:Stop()
	self.skipSound.TimePosition = 0
	self.skipSound:Play()

	if self.leftClickPulse then
		self.leftClickPulse:Cancel()
		self.leftClickPulse = nil
	end
	if self.leftClickFlashTween then
		self.leftClickFlashTween:Cancel()
	end

	self.leftClickFlashToken += 1
	local token = self.leftClickFlashToken
	self.leftClickSkipFlashed = true
	self.leftClick.Visible = true
	self.leftClick.ImageTransparency = 0

	local fade = TweenService:Create(
		self.leftClick,
		TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, 0, false, 0.08),
		{ ImageTransparency = 1 }
	)
	self.leftClickFlashTween = fade
	fade.Completed:Connect(function()
		if token ~= self.leftClickFlashToken then
			return
		end
		self.leftClickFlashTween = nil
		self.leftClick.Visible = false
		self.leftClick.ImageTransparency = 1
		self.leftClickSkipFlashed = false
	end)
	fade:Play()
end

--------------------------------------------------------------------------------
-- Background
--------------------------------------------------------------------------------

function StageView:_renderBackground(background, localTime)
	local progress = Easing.progress(
		localTime,
		background.start,
		background.duration
	)

	if background.from and progress < 1 then
		local eased = Easing.alpha(
			background.easing,
			progress
		)

		paintLayer(
			self.layerFrom,
			background.from,
			1
		)

		paintLayer(
			self.layerTo,
			background,
			eased
		)

		self.vignette.Visible =
			background.kind ~= "Camera3D"
			or background.from.kind ~= "Camera3D"
	else
		paintLayer(
			self.layerFrom,
			nil,
			0
		)

		paintLayer(
			self.layerTo,
			background,
			1
		)

		self.vignette.Visible =
			background.kind ~= "Camera3D"
	end

	self.currentBackground = {
		kind = background.kind,
		value = background.value,
		poseId = background.poseId,
	}
end

function StageView:freeze()
	paintLayer(
		self.freezeLayer,
		self.currentBackground,
		1
	)

	self.frozen = true
end

function StageView:unfreeze(duration, easing)
	if not self.frozen then
		return
	end

	self.frozen = false

	local info = TweenInfo.new(
		math.max(0.01, duration or 0.5),
		Easing.style(easing or "Quad"),
		Enum.EasingDirection.InOut
	)

	TweenService:Create(
		self.freezeLayer.frame,
		info,
		{
			BackgroundTransparency = 1,
		}
	):Play()

	TweenService:Create(
		self.freezeLayer.image,
		info,
		{
			ImageTransparency = 1,
		}
	):Play()
end

--------------------------------------------------------------------------------
-- Portrait
--------------------------------------------------------------------------------

function StageView:_renderPortrait(portrait, localTime)
	if not portrait or portrait.imageId == "" then
		self.speakerPortraitTransition = nil
		self.outgoingPortrait.Visible = false
		self.portrait.Visible = false
		self.portrait.Image = ""
		self.lastPortraitId = nil
		return
	end

	local speakerTransition = self.speakerPortraitTransition
	if speakerTransition then
		if portrait.imageId == speakerTransition.imageId then
			-- Position and opacity are currently driven by the coordinated turn.
			return
		end

		self.speakerPortraitTransition = nil
		self.outgoingPortrait.Visible = false
	end

	local transform = portrait.transform
	local presentation = portraitPresentation(transform, self.portraitLayout)
	local alpha = transform.alpha

	if portrait.hiding then
		alpha *= 1 - Easing.alpha(
			"Quad",
			Easing.progress(
				localTime,
				portrait.start,
				portrait.duration
			)
		)
	elseif portrait.duration > 0 then
		alpha *= Easing.alpha(
			"Quad",
			Easing.progress(
				localTime,
				portrait.start,
				portrait.duration
			)
		)
	end

	self.portrait.Visible = true

	self.portrait.Position = UDim2.fromScale(
		presentation.x,
		presentation.y
	)

	self.portrait.Size = UDim2.fromScale(
		PORTRAIT_SIZE.X * presentation.scaleX,
		PORTRAIT_SIZE.Y * presentation.scaleY
	)

	self.portrait.Rotation =
		transform.rotation

	local target = 1 - alpha

	if portrait.imageId ~= self.lastPortraitId then
		if self.portraitFadeTween then
			self.portraitFadeTween:Cancel()
			self.portraitFadeTween = nil
		end

		self.lastPortraitId =
			portrait.imageId

		self.portrait.Image =
			portrait.imageId

		if portrait.duration <= 0 then
			self.portrait.ImageTransparency = 1
			self.portraitFadeUntil =
				os.clock() + 0.2

			self.portraitFadeTween = TweenService:Create(
				self.portrait,
				TweenInfo.new(
					0.2,
					Enum.EasingStyle.Quad,
					Enum.EasingDirection.Out
				),
				{
					ImageTransparency = target,
				}
			)
			self.portraitFadeTween:Play()

			return
		end
	end

	if os.clock() >= self.portraitFadeUntil then
		self.portrait.ImageTransparency =
			target
	end
end

-- Begins a Danganronpa-style speaker handoff. The Presenter starts the small
-- camera yaw in the same render pass using this exact duration/easing.
function StageView:beginSpeakerPortraitTransition(incomingPortrait, direction, duration)
	if not incomingPortrait or incomingPortrait.imageId == "" then
		return false
	end

	if not self.portrait.Visible or self.portrait.Image == "" then
		return false
	end

	if self.portraitFadeTween then
		self.portraitFadeTween:Cancel()
		self.portraitFadeTween = nil
	end

	direction = direction and direction >= 0 and 1 or -1
	duration = math.max(0.05, duration or 0.32)

	local transform = incomingPortrait.transform
	local presentation = portraitPresentation(transform, self.portraitLayout)
	local incomingX = presentation.x + direction * 1.15
	local targetTransparency = 1 - transform.alpha

	self.outgoingPortrait.Image = self.portrait.Image
	self.outgoingPortrait.Position = self.portrait.Position
	self.outgoingPortrait.Size = self.portrait.Size
	self.outgoingPortrait.Rotation = self.portrait.Rotation
	self.outgoingPortrait.ImageTransparency = self.portrait.ImageTransparency
	self.outgoingPortrait.Visible = true

	self.portrait.Image = incomingPortrait.imageId
	self.portrait.Position = UDim2.fromScale(incomingX, presentation.y)
	self.portrait.Size = UDim2.fromScale(
		PORTRAIT_SIZE.X * presentation.scaleX,
		PORTRAIT_SIZE.Y * presentation.scaleY
	)
	self.portrait.Rotation = transform.rotation
	self.portrait.ImageTransparency = targetTransparency
	self.portrait.Visible = true
	self.lastPortraitId = incomingPortrait.imageId

	local info = TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut)
	local incomingTween = TweenService:Create(self.portrait, info, {
		Position = UDim2.fromScale(presentation.x, presentation.y),
	})
	local outgoingTween = TweenService:Create(self.outgoingPortrait, info, {
		Position = UDim2.new(self.outgoingPortrait.Position.X.Scale, self.outgoingPortrait.Position.X.Offset - direction * 1100, self.outgoingPortrait.Position.Y.Scale, self.outgoingPortrait.Position.Y.Offset),
		ImageTransparency = 1,
	})

	self.speakerPortraitTransition = { imageId = incomingPortrait.imageId }
	incomingTween:Play()
	outgoingTween:Play()

	incomingTween.Completed:Connect(function(playbackState)
		if playbackState == Enum.PlaybackState.Completed and self.speakerPortraitTransition and self.speakerPortraitTransition.imageId == incomingPortrait.imageId then
			self.speakerPortraitTransition = nil
		end
	end)
	outgoingTween.Completed:Connect(function(playbackState)
		if playbackState == Enum.PlaybackState.Completed then
			self.outgoingPortrait.Visible = false
		end
	end)

	return true
end

--------------------------------------------------------------------------------
-- Dialogue box and textbox presets
--------------------------------------------------------------------------------

function StageView:_cancelElementTweens()
	for _, tween in ipairs(self.elementTweens) do
		tween:Cancel()
	end

	table.clear(self.elementTweens)
end

-- A SPEAKING-off line in a same-speaker merge lets the badge finish its
-- reverse movement while the next line starts immediately. Keep those tweens
-- separate from the main element list so a new line cannot accidentally turn
-- its exit into a delay or leave a later badge hidden.
function StageView:_cancelSpeakingExit(resetVisual)
	self.speakingExitToken += 1

	for _, tween in ipairs(self.speakingExitTweens) do
		tween:Cancel()
	end

	table.clear(self.speakingExitTweens)

	if resetVisual and self.speaking.Parent then
		self.speaking.Position = self.rest.speaking.position
		self:_setVisualTransparency(self.rest.speaking, 0)
	end
end

function StageView:_setVisualTransparency(rest, alpha)
	for _, item in ipairs(rest.visual or {}) do
		if item.instance.Parent then
			for property, value in pairs(
				visualGoals(item.values, alpha)
				) do
				item.instance[property] = value
			end
		end
	end
end

function StageView:_tweenVisualTransparency(
	rest,
	info,
	alpha
)
	for _, item in ipairs(rest.visual or {}) do
		if item.instance.Parent then
			local tween = TweenService:Create(
				item.instance,
				info,
				visualGoals(
					item.values,
					alpha
				)
			)

			tween:Play()

			table.insert(
				self.elementTweens,
				tween
			)
		end
	end
end

local function animDuration(anim, fallback)
	local duration = anim and tonumber(anim.duration) or 0

	if duration <= 0 then
		return fallback or 0
	end

	return duration
end

local function animDelay(anim)
	return anim and tonumber(anim.delay) or 0
end

local function animEasing(anim)
	return anim and anim.easing or "Quad"
end

-- Runs one sequential entrance stage.
--
-- startDelay is the time at which this stage begins relative to the start
-- of the complete entrance sequence.
function StageView:_playSequentialIn(
	element,
	rest,
	anim,
	startDelay,
	offset,
	fallbackDuration,
	move
)
	local duration =
		animDuration(
			anim,
			fallbackDuration
		)

	local ownDelay =
		animDelay(anim)

	local actualStart =
		startDelay + ownDelay

	element.Position =
		rest.position

	self:_setVisualTransparency(
		rest,
		1
	)

	if move then
		element.Position =
			rest.position + offset
	end

	local info = TweenInfo.new(
		duration,
		Easing.style(
			animEasing(anim)
		),
		Enum.EasingDirection.Out,
		0,
		false,
		actualStart
	)

	if move then
		local positionTween =
			TweenService:Create(
				element,
				info,
				{
					Position =
					rest.position,
				}
			)

		positionTween:Play()

		table.insert(
			self.elementTweens,
			positionTween
		)
	end

	self:_tweenVisualTransparency(
		rest,
		info,
		0
	)

	return actualStart + duration
end

-- Runs one sequential exit stage.
function StageView:_playSequentialOut(
	element,
	rest,
	anim,
	startDelay,
	offset,
	fallbackDuration,
	move
)
	local duration =
		animDuration(
			anim,
			fallbackDuration
		)

	local ownDelay =
		animDelay(anim)

	local actualStart =
		startDelay + ownDelay

	local info = TweenInfo.new(
		duration,
		Easing.style(
			animEasing(anim)
		),
		Enum.EasingDirection.In,
		0,
		false,
		actualStart
	)

	if move then
		local positionTween =
			TweenService:Create(
				element,
				info,
				{
					Position =
					rest.position + offset,
				}
			)

		positionTween:Play()

		table.insert(
			self.elementTweens,
			positionTween
		)
	end

	self:_tweenVisualTransparency(
		rest,
		info,
		1
	)

	return actualStart + duration
end

function StageView:_playIn(preset)
	self:_cancelElementTweens()
	self:_cancelSpeakingExit(true)
	-- Let the rectangle's existing reverse fade carry the prompt out with it.
	self:_stopLeftClickPulse(false)

	self.boxHiddenByOut = false

	-- Always restore the container to its correct safe-area position.
	self.bars.Position =
		self.rest.bars.position

	----------------------------------------------------------------------
	-- 1. RECTANGLE
	--
	-- Starts to the left and fades/slides into the authored position.
	----------------------------------------------------------------------

	local boxAnim =
		preset.elements.box or {}

	local boxEnd =
		self:_playSequentialIn(
			self.dialogueBox,
			self.rest.box,
			boxAnim,
			0,
			UDim2.new(
				0,
				-64,
				0,
				0
			),
			0.25,
			true
		)

	----------------------------------------------------------------------
	-- 2. PINKBAR
	--
	-- Starts BELOW its authored position, then travels upward while fading
	-- in. This does not start until the rectangle is completely finished.
	----------------------------------------------------------------------

	local nameAnim =
		preset.elements.namePlate or {}
	local speakingAnim =
		preset.elements.speaking or nameAnim

	local pinkBarEnd =
		self:_playSequentialIn(
			self.pinkBar,
			self.rest.pinkBar,
			nameAnim,
			boxEnd,
			UDim2.new(
				0,
				0,
				0,
				40
			),
			0.2,
			true
		)

	-- The SPEAKING badge is a sibling of Pinkbar in Visualui, so it enters at
	-- exactly the same time with the same position/fade treatment. Its nested
	-- Text ImageLabel is included in the captured visual state above.
	local speakingEnd = 0
	if self.speaking.Visible then
		speakingEnd = self:_playSequentialIn(
			self.speaking,
			self.rest.speaking,
			speakingAnim,
			boxEnd,
			UDim2.new(0, 0, 0, 40),
			0.2,
			true
		)
	end
	self.speakingPulseDelay = speakingEnd

	----------------------------------------------------------------------
	-- 3. NAME
	--
	-- Name does not move. It simply fades in after Pinkbar has completely
	-- finished its entrance.
	----------------------------------------------------------------------

	local sequenceEnd =
		math.max(pinkBarEnd, speakingEnd)

	if self.namePlate.Visible then
		sequenceEnd =
			self:_playSequentialIn(
				self.namePlate,
				self.rest.namePlate,
				nameAnim,
				pinkBarEnd,
				UDim2.new(),
				0.2,
				false
			)
	else
		self:_setVisualTransparency(
			self.rest.namePlate,
			0
		)
	end

	----------------------------------------------------------------------
	-- 4. DIALOGUE
	--
	-- Typewriter timing is held at zero until every visual entrance stage
	-- above has completed.
	----------------------------------------------------------------------

	self.typewriterDelay =
		sequenceEnd

	self.textLabel.MaxVisibleGraphemes =
		0
end

-- Replays only the speaker-specific portion of the standard entrance. The
-- rectangle stays fully visible and at its authored resting position.
function StageView:_playMergedSpeakerIn(preset, animateSpeaking)
	self:_cancelElementTweens()
	self:_cancelSpeakingExit(true)
	self.boxHiddenByOut = false
	self.dialogueBox.Visible = true
	self.dialogueBox.Position = self.rest.box.position
	self:_setVisualTransparency(self.rest.box, 0)
	self.bars.Visible = true
	self.bars.Position = self.rest.bars.position
	self.pinkBar.Visible = true

	local nameAnim = table.clone(preset.elements.namePlate or {})
	nameAnim.duration = math.max(0.1, animDuration(nameAnim, 0.2) * 0.65)
	nameAnim.delay = 0
	local speakingAnim = table.clone(preset.elements.speaking or preset.elements.namePlate or {})
	speakingAnim.duration = math.max(0.1, animDuration(speakingAnim, 0.2) * 0.65)
	speakingAnim.delay = 0

	local pinkBarEnd = self:_playSequentialIn(
		self.pinkBar,
		self.rest.pinkBar,
		nameAnim,
		0,
		UDim2.new(0, 0, 0, 40),
		0.13,
		true
	)

	local speakingEnd = 0
	if self.speaking.Visible and animateSpeaking then
		speakingEnd = self:_playSequentialIn(
			self.speaking,
			self.rest.speaking,
			speakingAnim,
			0,
			UDim2.new(0, 0, 0, 40),
			0.13,
			true
		)
	end
	self.speakingPulseDelay = animateSpeaking and speakingEnd or 0

	local sequenceEnd = math.max(pinkBarEnd, speakingEnd)
	if self.namePlate.Visible then
		sequenceEnd = self:_playSequentialIn(
			self.namePlate,
			self.rest.namePlate,
			nameAnim,
			pinkBarEnd,
			UDim2.new(),
			0.13,
			false
		)
	end

	self.typewriterDelay = sequenceEnd
	self.textLabel.MaxVisibleGraphemes = 0
end

-- Used when a same-speaker merge turns the SPEAKING badge on. The normal
-- speaker UI deliberately stays untouched in that merge, while the badge
-- still gets its authored Pinkbar-style entrance.
function StageView:_playMergedSpeakingIn(preset)
	self:_cancelElementTweens()
	self:_cancelSpeakingExit(true)
	self.speaking.Visible = true

	local speakingAnim = table.clone(preset.elements.speaking or preset.elements.namePlate or {})
	speakingAnim.duration = math.max(0.1, animDuration(speakingAnim, 0.2) * 0.65)
	speakingAnim.delay = 0

	self.speakingPulseDelay = self:_playSequentialIn(
		self.speaking,
		self.rest.speaking,
		speakingAnim,
		0,
		UDim2.new(0, 0, 0, 40),
		0.13,
		true
	)
end

-- Same-speaker dialogue keeps Pinkbar and Name in place, but a SPEAKING-off
-- line still dismisses the badge with the same down/fade motion as Pinkbar.
-- This intentionally does not contribute to typewriterDelay.
function StageView:_playMergedSpeakingOut(preset)
	self:_cancelSpeakingExit(true)

	if not self.speaking.Visible then
		return
	end

	local anim = preset.elements.speaking or preset.elements.namePlate or {}
	local duration = animDuration(anim, 0.2)
	local actualStart = animDelay(anim)
	local info = TweenInfo.new(
		duration,
		Easing.style(animEasing(anim)),
		Enum.EasingDirection.In,
		0,
		false,
		actualStart
	)

	local positionTween = TweenService:Create(self.speaking, info, {
		Position = self.rest.speaking.position + UDim2.new(0, 0, 0, 40),
	})
	positionTween:Play()
	table.insert(self.speakingExitTweens, positionTween)

	for _, item in ipairs(self.rest.speaking.visual or {}) do
		if item.instance.Parent then
			local tween = TweenService:Create(item.instance, info, visualGoals(item.values, 1))
			tween:Play()
			table.insert(self.speakingExitTweens, tween)
		end
	end

	local token = self.speakingExitToken
	task.delay(actualStart + duration, function()
		if token == self.speakingExitToken and self.speaking.Parent then
			self.speaking.Visible = false
			table.clear(self.speakingExitTweens)
		end
	end)
end

-- A player can reveal and advance a line while its speaker entrance is still
-- tweening. Cancelling that tween must not leave the next same-speaker line
-- with a half-faded Pinkbar or name plate. Settle those elements at their
-- authored resting state before the merged line takes ownership of the UI.
function StageView:_settleSpeakerElements(settleSpeaking)
	self.bars.Visible = true
	self.bars.Position = self.rest.bars.position

	self.pinkBar.Visible = true
	self.pinkBar.Position = self.rest.pinkBar.position
	self:_setVisualTransparency(self.rest.pinkBar, 0)

	self.namePlate.Position = self.rest.namePlate.position
	if self.namePlate.Visible then
		self:_setVisualTransparency(self.rest.namePlate, 0)
	end

	if settleSpeaking and self.speaking.Visible then
		self.speaking.Position = self.rest.speaking.position
		self:_setVisualTransparency(self.rest.speaking, 0)
	end
end

-- Plays the complete reverse of the entrance:
--
-- 1. Dialogue text disappears instantly.
-- 2. Name fades out.
-- 3. Pinkbar fades and moves downward.
-- 4. Rectangle fades and moves left.
--
-- Returns the total time before the runner should advance.
function StageView:requestAdvance(merge)
	if not self.dialogueBox.Visible
		or not self.currentPreset then

		return 0
	end

	self:_cancelElementTweens()
	self:_cancelSpeakingExit(true)
	self:_stopSpeakingTextPulse(true)
	self.speakingPulseDelay = math.huge
	if self.leftClick.Visible then
		self:_flashLeftClickOnSkip()
	else
		self:_stopLeftClickPulse(merge ~= nil)
	end

	local preset =
		self.currentPreset

	local boxAnim =
		preset.elements.box or {}

	local nameAnim =
		preset.elements.namePlate or {}
	local speakingAnim =
		preset.elements.speaking or nameAnim

	----------------------------------------------------------------------
	-- 1. TEXT
	--
	-- No tween. It simply disappears immediately.
	----------------------------------------------------------------------

	self.revealed = false

	self.textLabel.MaxVisibleGraphemes =
		0
	self.textLabel.Text = ""

	if merge then
		self.pendingDialogueMerge = {
			fromEntryId = self.lastEntryId,
			sameSpeaker = merge.sameSpeaker == true,
			fromSpeaking = self.currentSpeaking == true,
			toSpeaking = merge.toSpeaking == true,
		}
		self.boxHiddenByOut = false
		self.outUntil = 0

		-- The main rectangle and Bars remain. A changed speaker replays only
		-- Pinkbar/Name on the incoming line; for the same speaker everything
		-- except the text is left untouched. If the prior line was interrupted
		-- during its entrance, settle its speaker elements first instead of
		-- preserving a cancelled half-transparent tween state.
		local shouldExitSpeaking = self.pendingDialogueMerge.sameSpeaker
			and self.pendingDialogueMerge.fromSpeaking
			and not self.pendingDialogueMerge.toSpeaking

		if self.pendingDialogueMerge.sameSpeaker then
			self:_settleSpeakerElements(self.speaking.Visible)
		else
			self.pinkBar.Visible = false
			self.namePlate.Visible = false
			self.speaking.Visible = false
		end

		-- A merged line takes over immediately. In particular, a SPEAKING-off
		-- line must never hold the typewriter hostage while an old badge exits.
		-- Changed-speaker merges reset the whole top bar as one group, so the
		-- incoming Pinkbar, name plate, and badge cannot get out of step.
		if shouldExitSpeaking then
			self:_playMergedSpeakingOut(preset)
		elseif not self.pendingDialogueMerge.toSpeaking then
			self.speaking.Visible = false
		end

		return 0
	end
	self.pendingDialogueMerge = nil

	----------------------------------------------------------------------
	-- 2. NAME
	--
	-- Fade out first.
	----------------------------------------------------------------------

	local sequenceEnd = 0

	if self.namePlate.Visible then
		sequenceEnd =
			self:_playSequentialOut(
				self.namePlate,
				self.rest.namePlate,
				nameAnim,
				0,
				UDim2.new(),
				0.2,
				false
			)
	end

	----------------------------------------------------------------------
	-- 3. PINKBAR
	--
	-- Exact reverse of its entrance. It travels downward while fading out.
	----------------------------------------------------------------------

	local pinkBarStart = sequenceEnd
	sequenceEnd =
		self:_playSequentialOut(
			self.pinkBar,
			self.rest.pinkBar,
			nameAnim,
			pinkBarStart,
			UDim2.new(
				0,
				0,
				0,
				40
			),
			0.2,
			true
		)

	if self.speaking.Visible then
		sequenceEnd = math.max(
			sequenceEnd,
			self:_playSequentialOut(
				self.speaking,
				self.rest.speaking,
				speakingAnim,
				pinkBarStart,
				UDim2.new(0, 0, 0, 40),
				0.2,
				true
			)
		)
	end

	----------------------------------------------------------------------
	-- 4. RECTANGLE
	--
	-- Exact reverse of the entrance. It travels left while fading out.
	----------------------------------------------------------------------

	sequenceEnd =
		self:_playSequentialOut(
			self.dialogueBox,
			self.rest.box,
			boxAnim,
			sequenceEnd,
			UDim2.new(
				0,
				-64,
				0,
				0
			),
			0.25,
			true
		)

	self.boxHiddenByOut = true

	self.outUntil =
		os.clock() + sequenceEnd

	return sequenceEnd
end

function StageView:isRevealing()
	local total =
		utf8.len(
			self.textLabel.Text
		)
		or #self.textLabel.Text

	return self.dialogueBox.Visible
		and not self.revealed
		and self.textLabel.MaxVisibleGraphemes >= 0
		and self.textLabel.MaxVisibleGraphemes < total
end

function StageView:revealAll()
	self.revealed = true
	self:_flashLeftClickOnSkip()

	self.textLabel.MaxVisibleGraphemes =
		-1
end

function StageView:_renderDialogue(
	dialogue,
	preset,
	context
)
	if not dialogue then
		self:_stopLeftClickPulse(true)
		self:_stopSpeakingTextPulse(true)
		self:_cancelSpeakingExit(false)
		self.pendingDialogueMerge = nil
		self.dialogueBox.Visible = false
		self.bars.Visible = false
		self.speaking.Visible = false
		self.currentSpeaking = false
		self.textLabel.TextColor3 = self.templateTextColor
		self.textLabel.TextStrokeColor3 = self.templateTextStrokeColor

		self.lastEntryId = nil

		return
	end

	-- Keep the previous line hidden while its complete reverse exit sequence
	-- is still playing.
	if self.boxHiddenByOut
		and dialogue.entryId == self.lastEntryId
		and os.clock() < self.outUntil then

		return
	end

	self.currentPreset =
		preset

	self.dialogueBox.Visible =
		true

	self.bars.Visible =
		true

	local characterName =
		dialogue.character or ""
	local isSpeaking = dialogue.speaking ~= false
	local textColor = isSpeaking and self.templateTextColor or Color3.fromRGB(108, 202, 214)
	local textStrokeColor 
	if textColor == Color3.fromRGB(108, 202, 214) then
		textStrokeColor = Color3.fromRGB(84, 159, 167)
	end
	self.textLabel.TextColor3 = textColor
	self.textLabel.TextStrokeColor3 = isSpeaking and textStrokeColor or self.nonSpeakingTextStrokeColor

	-- Inspector preview updates can change this property without creating a new
	-- entry id. Keep the preview faithful instead of requiring a replay.
	if dialogue.entryId == self.lastEntryId and self.currentSpeaking ~= isSpeaking then
		self:_stopSpeakingTextPulse(true)
		self:_cancelSpeakingExit(true)
		self.currentSpeaking = isSpeaking
		self.speaking.Visible = isSpeaking
		if isSpeaking then
			self:_playMergedSpeakingIn(preset)
		else
			self.speakingPulseDelay = math.huge
		end
	end

	self.namePlate.Visible =
		characterName ~= ""

	self.nameLabel.Text =
		characterName

	self.textLabel.Text =
		dialogue.text or ""

	-- A new entry starts the ordered entrance sequence:
	--
	-- rectangle
	-- pinkbar
	-- name
	-- typewriter
	if dialogue.entryId ~= self.lastEntryId
		or self.boxHiddenByOut then
		local merge = self.pendingDialogueMerge
		local isMerge = merge and merge.fromEntryId == self.lastEntryId
		local preservingSpeakingExit = isMerge
			and merge.sameSpeaker
			and merge.fromSpeaking
			and not merge.toSpeaking
		self.pendingDialogueMerge = nil
		self:_stopLeftClickPulse(true, true)
		self:_stopSpeakingTextPulse(true)
		self.speaking.Visible = isSpeaking or preservingSpeakingExit
		self.currentSpeaking = isSpeaking

		self.lastEntryId =
			dialogue.entryId

		self.revealed =
			false

		if isMerge then
			if merge.sameSpeaker then
				-- Same-character consecutive lines retain every piece of the
				-- existing dialogue UI and immediately start the new typewriter.
				self.boxHiddenByOut = false
				self.typewriterDelay = 0
				self.textLabel.MaxVisibleGraphemes = 0
				if merge.toSpeaking and not merge.fromSpeaking then
					self:_playMergedSpeakingIn(preset)
				elseif merge.toSpeaking then
					self.speakingPulseDelay = 0
				else
					self.speakingPulseDelay = math.huge
				end
			else
				-- A changed character refreshes the entire top bar. The badge is
				-- deliberately included even when the prior line was speaking, so
				-- it cannot be left behind while Pinkbar and Name animate in.
				self:_playMergedSpeakerIn(preset, merge.toSpeaking)
			end
		else
			self:_playIn(preset)
		end
	end

	local playingOrScrubbing =
		context.playing
		or context.scrubbing

	local cps =
		preset.typewriterCps or 0

	if self.revealed
		or cps <= 0
		or not playingOrScrubbing then

		self.textLabel.MaxVisibleGraphemes =
			-1
		if dialogue.skippable ~= false then
			self:_showLeftClickPulse()
		else
			self:_stopLeftClickPulse(true, true)
		end
		self:_updateSpeakingBadge(dialogue)

		return
	end

	local total =
		utf8.len(
			self.textLabel.Text
		)
		or #self.textLabel.Text

	-- The line's normal timeline continues running while the UI animates,
	-- so subtract the complete entrance duration. That causes the typewriter
	-- clock to effectively begin only after Name has finished fading in.
	local typewriterTime =
		math.max(
			0,
			dialogue.entryTime
			- self.typewriterDelay
		)

	local visible =
		math.floor(
			typewriterTime * cps
		)

	self.textLabel.MaxVisibleGraphemes =
		math.clamp(
			visible,
			0,
			total
		)

	if dialogue.skippable ~= false
		and self.textLabel.MaxVisibleGraphemes >= total then
		self:_showLeftClickPulse()
	else
		self:_stopLeftClickPulse(true, true)
	end
	self:_updateSpeakingBadge(dialogue)
end

--------------------------------------------------------------------------------
-- Render
--------------------------------------------------------------------------------

function StageView:setPortraitLayout(layout)
	self.portraitLayout = Schema.normalizePortraitLayout(layout)
end

-- context = { project, scene, playing, scrubbing, editor }
function StageView:render(snapshot, context)
	context = context or {}

	local project =
		context.project

	self:setPortraitLayout(project and project.portraitLayout)

	self:_renderBackground(
		snapshot.background,
		snapshot.localTime or 0
	)

	self:_renderPortrait(
		snapshot.portrait,
		snapshot.localTime or 0
	)

	local preset =
		project
		and Schema.findTextboxPreset(
			project,
			snapshot.textboxPresetId
		)
		or Schema.newTextboxPreset(
			"Default"
		)

	self:_renderDialogue(
		snapshot.dialogue,
		preset,
		context
	)

	if context.editor and not context.playing then
		local poseName =
			snapshot.cameraPoseId ~= ""
			and snapshot.cameraPoseId
			or "none"

		if project then
			local pose =
				Schema.findCameraPose(
					project,
					snapshot.cameraPoseId
				)

			poseName =
				pose and pose.name
				or poseName
		end

		self.debugLabel.Text =
			string.format(
				"camera: %s    music: %s    textbox: %s    t=%.2f",
				poseName,
				snapshot.music
				and snapshot.music.trackId
				or "none",
				preset.name,
				snapshot.localTime or 0
			)
	else
		self.debugLabel.Text = ""
	end
end

--------------------------------------------------------------------------------
-- Transient effects
--------------------------------------------------------------------------------

function StageView:playEvents(events)
	for _, event in ipairs(events or {}) do
		local params =
			event.params or {}

		if event.type == "ScreenShake" then
			self:shake(
				tonumber(
					params.intensity
				) or 8,

				tonumber(
					params.duration
				) or 0.35
			)

		elseif event.type == "ScreenFlash" then
			self:flash(
				parseColor(
					params.color,
					Color3.fromRGB(
						255,
						255,
						255
					)
				),

				tonumber(
					params.duration
				) or 0.3
			)
		end
	end
end

function StageView:shake(
	intensity,
	duration
)
	if self.shaking then
		return
	end

	self.shaking = true

	task.spawn(function()
		local started =
			os.clock()

		while os.clock() - started < duration do
			local decay =
				1
			- (
				(os.clock() - started)
					/ duration
			)

			local offsetX =
				math.random(
					-100,
					100
				)
				/ 100
				* intensity
				* decay

			local offsetY =
				math.random(
					-100,
					100
				)
				/ 100
				* intensity
				* decay

			self.shakeHolder.Position =
				UDim2.new(
					0,
					offsetX,
					0,
					offsetY
				)

			task.wait()
		end

		self.shakeHolder.Position =
			UDim2.new()

		self.shaking = false
	end)
end

function StageView:flash(
	color,
	duration
)
	self.flashOverlay.BackgroundColor3 =
		color

	self.flashOverlay.BackgroundTransparency =
		0.05

	TweenService:Create(
		self.flashOverlay,
		TweenInfo.new(
			duration,
			Enum.EasingStyle.Quad,
			Enum.EasingDirection.Out
		),
		{
			BackgroundTransparency = 1,
		}
	):Play()
end

-- Hide portrait and dialogue but keep the background.
function StageView:clearForeground()
	self:_cancelElementTweens()
	self:_cancelSpeakingExit(false)
	self:_stopLeftClickPulse(true)
	self:_stopSpeakingTextPulse(true)
	self.speaking.Visible = false
	self.speakingPulseDelay = math.huge
	self.currentSpeaking = false
	self.textLabel.TextColor3 = self.templateTextColor
	self.textLabel.TextStrokeColor3 = self.templateTextStrokeColor
	self.speakerPortraitTransition = nil
	self.outgoingPortrait.Visible = false

	self.portrait.Visible =
		false

	self.portrait.Image =
		""

	self.lastPortraitId =
		nil

	self.dialogueBox.Visible =
		false

	self.bars.Visible =
		false

	self.lastEntryId =
		nil

	self.boxHiddenByOut =
		false
	self.pendingDialogueMerge = nil

	self.typewriterDelay =
		0
end

-- Neutral backdrop for when no scene is open.
function StageView:clear()
	self:clearForeground()

	self:_renderBackground(
		{
			kind = "Color",
			value = "20,21,32",
			poseId = "",
			start = 0,
			duration = 0,
			easing = "Quad",
		},
		0
	)

	self.debugLabel.Text =
		""
end

function StageView:setVisible(visible)
	self.root.Visible =
		visible
end

function StageView:destroy()
	self:_cancelElementTweens()
	self.root:Destroy()
end

return StageView
