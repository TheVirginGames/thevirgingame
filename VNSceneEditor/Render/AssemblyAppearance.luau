-- Materializes editor-authored Room Assembly appearance overlays. These are
-- temporary SurfaceGuis backed by saved data, never permanent map edits.
-- A black UIGradient is deliberately asset-free, so authors do not need a
-- decal image just to let sparse Room3D geometry disappear into darkness.
local Workspace = game:GetService("Workspace")

local Bindings = require(script.Parent.WorldBindings)

local Appearance = {}
Appearance.__index = Appearance

local function partsOf(instance)
	local parts = {}
	if instance:IsA("BasePart") then table.insert(parts, instance) end
	for _, descendant in ipairs(instance:GetDescendants()) do
		if descendant:IsA("BasePart") then table.insert(parts, descendant) end
	end
	return parts
end

local function surfaceDimensions(part, face)
	if face == "Top" or face == "Bottom" then return part.Size.X, part.Size.Z end
	if face == "Left" or face == "Right" then return part.Size.Z, part.Size.Y end
	return part.Size.X, part.Size.Y
end

local function edgeFrame(part, fade)
	local horizontal, vertical = surfaceDimensions(part, fade.face)
	local fraction = math.clamp(fade.width / math.max(0.001, (fade.edge == "Left" or fade.edge == "Right") and horizontal or vertical), 0.001, 1)
	if fade.edge == "Left" then
		return UDim2.fromScale(fraction, 1), UDim2.fromScale(0, 0), 0
	elseif fade.edge == "Right" then
		return UDim2.fromScale(fraction, 1), UDim2.fromScale(1 - fraction, 0), 180
	elseif fade.edge == "Top" then
		return UDim2.fromScale(1, fraction), UDim2.fromScale(0, 0), 90
	end
	return UDim2.fromScale(1, fraction), UDim2.fromScale(0, 1 - fraction), -90
end

local function makeFade(part, fade)
	local gui = Instance.new("SurfaceGui")
	gui.Name = "VNAssemblyEdgeFade_" .. fade.id
	gui:SetAttribute("VNAssemblyEdgeFade", true)
	gui.Adornee = part
	gui.Face = Enum.NormalId[fade.face]
	gui.AlwaysOnTop = false
	gui.LightInfluence = 0
	gui.ZOffset = 0.01
	gui.ResetOnSpawn = false
	gui.Parent = part

	local size, position, rotation = edgeFrame(part, fade)
	local frame = Instance.new("Frame")
	frame.Name = "Fade"
	frame.BorderSizePixel = 0
	frame.BackgroundColor3 = Color3.new(0, 0, 0)
	frame.BackgroundTransparency = 1 - fade.opacity
	frame.Size = size
	frame.Position = position
	frame.Parent = gui

	local gradient = Instance.new("UIGradient")
	gradient.Name = "BlackToClear"
	gradient.Rotation = rotation
	gradient.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(1, 1),
	})
	gradient.Parent = frame
	return gui
end

function Appearance.new()
	return setmetatable({ created = {} }, Appearance)
end

function Appearance:clear()
	for _, gui in ipairs(self.created) do
		if gui and gui.Parent then gui:Destroy() end
	end
	table.clear(self.created)
end

function Appearance:apply(definition)
	self:clear()
	if type(definition) ~= "table" then return end
	for _, group in ipairs(definition.groups or {}) do
		if group.reference and type(group.edgeFades) == "table" and #group.edgeFades > 0 then
			local source = Bindings.resolveStrict(group.reference)
			if source and source:IsDescendantOf(Workspace) then
				for _, part in ipairs(partsOf(source)) do
					for _, fade in ipairs(group.edgeFades) do
						local gui = makeFade(part, fade)
						table.insert(self.created, gui)
					end
				end
			end
		end
	end
end

function Appearance:destroy()
	self:clear()
end

return Appearance
