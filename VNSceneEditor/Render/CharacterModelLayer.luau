-- Renders the authored 3D-character placements for one active subscene.
-- Source character models remain ordinary Workspace templates; this layer owns
-- short-lived, anchored clones so editor/runtime state never mutates them.

local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Schema = require(script.Parent.Parent.Core.Schema)
local WorldBindings = require(script.Parent.WorldBindings)

local CharacterModelLayer = {}
CharacterModelLayer.__index = CharacterModelLayer

CharacterModelLayer.FOLDER_NAME = "VNPlacedCharacters"
CharacterModelLayer.PLACEMENT_ATTRIBUTE = "VNCharacterPlacementId"
CharacterModelLayer.CHARACTER_ATTRIBUTE = "VNCharacterName"
CharacterModelLayer.INTERACTION_ATTRIBUTE = "VNHotspotInteractionId"

local function isTemplate(model)
	return model and model:IsA("Model")
		and model:FindFirstChildOfClass("Humanoid") ~= nil
		and model:FindFirstChild("HumanoidRootPart") ~= nil
		and model.HumanoidRootPart:IsA("BasePart")
end

local function targetIdFor(placementId)
	return "character_model_" .. placementId
end

function CharacterModelLayer.new()
	local self = setmetatable({}, CharacterModelLayer)
	self.folder = Instance.new("Folder")
	self.folder.Name = CharacterModelLayer.FOLDER_NAME
	self.folder.Parent = Workspace
	self.instances = {} -- placement id -> clone
	self.baseTransparency = {} -- clone -> part -> authored transparency
	-- Every visual descendent shares one fade alpha.  Tweening each BasePart on
	-- its own left decals, textures and effects visually out of sync (and made
	-- rapid Zoom in/out transitions leave competing tweens behind).
	self.visualTransparency = {} -- clone -> instance -> authored visual state
	self.fadeAlpha = 0 -- 0 = authored visibility, 1 = completely hidden
	self.fadeDriver = Instance.new("NumberValue")
	self.fadeDriver.Name = "VNCharacterFadeDriver"
	self.fadeDriver.Value = 0
	self.fadeTween = nil
	self.fadeDriverConnection = self.fadeDriver:GetPropertyChangedSignal("Value"):Connect(function()
		self.fadeAlpha = self.fadeDriver.Value
		self:_applyFadeAlpha(self.fadeAlpha)
	end)
	self.hidden = {}
	-- Zoom may cross a linked Room3D boundary through Merge. Keep this state at
	-- the layer level so recreating the destination's clones cannot flash them
	-- back in before Zoom's eventual exit transition restores them.
	self.faded = false
	self.scene = nil
	self.subscene = nil
	self.project = nil
	return self
end

function CharacterModelLayer.isCharacterModel(instance)
	local current = instance
	while current and current ~= Workspace do
		if current:GetAttribute(CharacterModelLayer.PLACEMENT_ATTRIBUTE) then
			return current
		end
		current = current.Parent
	end
	return nil
end

function CharacterModelLayer.placementIdOf(instance)
	local owner = CharacterModelLayer.isCharacterModel(instance)
	return owner and owner:GetAttribute(CharacterModelLayer.PLACEMENT_ATTRIBUTE) or nil
end

function CharacterModelLayer.templateFor(project, characterName)
	local record = Schema.findCharacter(project, characterName)
	local template = record and WorldBindings.resolveReference(record.modelRef)
	return isTemplate(template) and template or nil
end

function CharacterModelLayer:_clearInstances()
	for _, instance in pairs(self.instances) do
		if instance and instance.Parent then instance:Destroy() end
	end
	table.clear(self.instances)
	table.clear(self.baseTransparency)
	table.clear(self.visualTransparency)
	self.folder:ClearAllChildren()
end

function CharacterModelLayer:setHidden(hidden)
	self.hidden = type(hidden) == "table" and hidden or {}
end

function CharacterModelLayer:getInstance(placementId)
	return self.instances[placementId]
end

function CharacterModelLayer:resolveTarget(placementId)
	return self.instances[placementId]
end

-- A character may have more than one authored placement.  Speaker turns use
-- the nearest active one, so their camera direction stays predictable without
-- accidentally targeting a copy in another part of the room.
function CharacterModelLayer:findByCharacter(characterName, nearPosition)
	if type(characterName) ~= "string" or characterName == "" then return nil end

	local wanted = string.lower(characterName)
	local closest = nil
	local closestDistance = math.huge
	for _, instance in pairs(self.instances) do
		local placedCharacter = instance:GetAttribute(CharacterModelLayer.CHARACTER_ATTRIBUTE)
		if instance.Parent and type(placedCharacter) == "string" and string.lower(placedCharacter) == wanted then
			local center = WorldBindings.centerOf(instance)
			local distance = center and nearPosition and (center - nearPosition).Magnitude or 0
			if not closest or distance < closestDistance then
				closest = instance
				closestDistance = distance
			end
		end
	end

	return closest
end

local function sequenceAtAlpha(sequence, alpha)
	local keys = {}
	for _, keypoint in ipairs(sequence.Keypoints) do
		local value = keypoint.Value + (1 - keypoint.Value) * alpha
		table.insert(keys, NumberSequenceKeypoint.new(keypoint.Time, value, keypoint.Envelope))
	end
	return NumberSequence.new(keys)
end

function CharacterModelLayer:_applyFadeAlpha(alpha)
	alpha = math.clamp(tonumber(alpha) or 0, 0, 1)
	for clone, visuals in pairs(self.visualTransparency) do
		if clone.Parent then
			for instance, state in pairs(visuals) do
				if instance.Parent then
					if state.kind == "number" then
						instance[state.property] = state.value + (1 - state.value) * alpha
					elseif state.kind == "sequence" then
						instance[state.property] = sequenceAtAlpha(state.value, alpha)
					elseif state.kind == "highlight" then
						instance.FillTransparency = state.fill + (1 - state.fill) * alpha
						instance.OutlineTransparency = state.outline + (1 - state.outline) * alpha
					end
				end
			end
		end
	end
end

local function captureVisualTransparency(clone)
	local visuals = {}
	for _, descendant in ipairs(clone:GetDescendants()) do
		if descendant:IsA("BasePart") then
			visuals[descendant] = { kind = "number", property = "Transparency", value = descendant.Transparency }
		elseif descendant:IsA("Decal") or descendant:IsA("Texture") then
			visuals[descendant] = { kind = "number", property = "Transparency", value = descendant.Transparency }
		elseif descendant:IsA("ParticleEmitter") or descendant:IsA("Trail") or descendant:IsA("Beam") then
			visuals[descendant] = { kind = "sequence", property = "Transparency", value = descendant.Transparency }
		elseif descendant:IsA("Highlight") then
			visuals[descendant] = {
				kind = "highlight",
				fill = descendant.FillTransparency,
				outline = descendant.OutlineTransparency,
			}
		end
	end
	return visuals
end

function CharacterModelLayer:_clonePlacement(placement)
	if self.hidden[placement.id] then return nil end
	local template = CharacterModelLayer.templateFor(self.project, placement.character)
	if not template then return nil end

	local ok, clone = pcall(function()
		return template:Clone()
	end)
	if not ok or not clone then return nil end

	clone.Name = "VNCharacter_" .. placement.character
	for _, descendant in ipairs(clone:GetDescendants()) do
		if descendant:IsA("Script") or descendant:IsA("LocalScript") then
			descendant:Destroy()
		elseif descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanTouch = false
			descendant.CanQuery = true
		end
	end

	clone:PivotTo(Schema.decodeCFrame(placement.cframe) or CFrame.new())
	clone:SetAttribute(CharacterModelLayer.PLACEMENT_ATTRIBUTE, placement.id)
	clone:SetAttribute(CharacterModelLayer.CHARACTER_ATTRIBUTE, placement.character)
	WorldBindings.assignId(clone, targetIdFor(placement.id))
	clone.Parent = self.folder

	local transparency = {}
	for _, descendant in ipairs(clone:GetDescendants()) do
		if descendant:IsA("BasePart") then
			transparency[descendant] = descendant.Transparency
		end
	end
	self.baseTransparency[clone] = transparency
	self.visualTransparency[clone] = captureVisualTransparency(clone)
	self.instances[placement.id] = clone
	self:_applyFadeAlpha(self.fadeAlpha)
	return clone
end

function CharacterModelLayer:setScene(scene, subscene, project, hidden, preserveFade)
	self.scene = scene
	self.subscene = subscene
	self.project = project
	self:setHidden(hidden)
	-- A Zoom can intentionally carry its hidden-model state across a linked
	-- Room3D Merge.  Every other scene/subscene entry is a fresh visual context
	-- and must reveal its authored models again.
	if not preserveFade then
		self:setFaded(false)
	end
	self:_clearInstances()
	if not scene or not subscene or subscene.kind == "Novel2D" then return end

	for _, placement in ipairs(scene.characterModels or {}) do
		if Schema.characterModelInSubscene(scene, subscene, placement) then
			self:_clonePlacement(placement)
		end
	end
end

function CharacterModelLayer:remove(placementId)
	self.hidden[placementId] = true
	local clone = self.instances[placementId]
	if clone then
		self.instances[placementId] = nil
		self.baseTransparency[clone] = nil
		self.visualTransparency[clone] = nil
		clone:Destroy()
	end
end

function CharacterModelLayer:setInteractionBindings(interactions)
	for placementId, clone in pairs(self.instances) do
		clone:SetAttribute(CharacterModelLayer.INTERACTION_ATTRIBUTE, nil)
		for _, item in ipairs(interactions or {}) do
			local interaction = item.interaction or item
			if interaction.targetCharacterModelId == placementId then
				clone:SetAttribute(CharacterModelLayer.INTERACTION_ATTRIBUTE, interaction.id)
				break
			end
		end
	end
end

function CharacterModelLayer:_fade(toHidden, duration)
	if self.fadeTween then
		self.fadeTween:Cancel()
		self.fadeTween = nil
	end
	local target = toHidden and 1 or 0
	local fadeDuration = math.max(0, tonumber(duration) or 0.25)
	if fadeDuration <= 0 then
		self.fadeDriver.Value = target
		return
	end
	self.fadeTween = TweenService:Create(self.fadeDriver, TweenInfo.new(
		fadeDuration,
		Enum.EasingStyle.Sine,
		Enum.EasingDirection.InOut
	), { Value = target })
	self.fadeTween:Play()
end

function CharacterModelLayer:fadeOut(duration)
	self.faded = true
	self:_fade(true, duration)
end

function CharacterModelLayer:fadeIn(duration)
	self.faded = false
	self:_fade(false, duration)
end

-- Editor preview needs to reconstruct an interaction's post-transition state
-- without waiting for an animation. Apply the same visual state immediately.
function CharacterModelLayer:setFaded(faded)
	self.faded = faded == true
	if self.fadeTween then
		self.fadeTween:Cancel()
		self.fadeTween = nil
	end
	self.fadeDriver.Value = self.faded and 1 or 0
end

function CharacterModelLayer:resetFade()
	self.faded = false
	self:setFaded(false)
end

function CharacterModelLayer:destroy()
	if self.fadeTween then self.fadeTween:Cancel() end
	if self.fadeDriverConnection then self.fadeDriverConnection:Disconnect() end
	if self.fadeDriver then self.fadeDriver:Destroy() end
	self:_clearInstances()
	if self.folder then self.folder:Destroy() end
	self.folder = nil
end

return CharacterModelLayer
