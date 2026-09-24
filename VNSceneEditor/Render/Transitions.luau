-- Scene to scene (and interaction enter / exit) transitions. Every run call
-- yields until the transition has finished.
--
-- context = {
--   stage, rig, overlay, project, fromScene, toScene, apply,
--   targetId, interaction, direction = "enter" | "exit"   (interaction transitions)
-- }
-- apply() switches to the new content; each kind calls it at the right moment.

local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Schema = require(script.Parent.Parent.Core.Schema)
local WorldBindings = require(script.Parent.WorldBindings)

local Transitions = {}

-- Per interaction memory for NpcTalk so the exit can undo the enter.
local npcStates = {}

local function tweenAsync(instance, duration, goals, style)
	if duration <= 0 then
		for key, value in pairs(goals) do
			instance[key] = value
		end
		return
	end

	local tween = TweenService:Create(instance, TweenInfo.new(duration, style or Enum.EasingStyle.Quad, Enum.EasingDirection.InOut), goals)
	tween:Play()
	tween.Completed:Wait()
end

local function scenePose(project, scene)
	if not scene then
		return nil
	end

	local poseId = scene.stage.cameraPoseId ~= "" and scene.stage.cameraPoseId or scene.background.poseId
	return Schema.findCameraPose(project, poseId)
end

local kinds = {}

function kinds.FadeBlack(preset, context)
	local params = preset.params
	local overlay = context.overlay

	overlay.BackgroundColor3 = Color3.new(0, 0, 0)
	overlay.Visible = true
	tweenAsync(overlay, params.fadeOut or 0.5, { BackgroundTransparency = 0 })

	context.apply()

	if (params.hold or 0) > 0 then
		task.wait(params.hold)
	end

	tweenAsync(overlay, params.fadeIn or 0.5, { BackgroundTransparency = 1 })
	overlay.Visible = false
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

	context.apply()
end

-- Danganronpa style NPC talk: camera closes in on the target while the model
-- fades out, then the 2D portrait and dialogue take over. Exit reverses it.
function kinds.NpcTalk(preset, context)
	local params = preset.params
	local duration = params.duration or 0.6
	local key = context.interaction and context.interaction.id or "scene"

	if context.direction == "exit" then
		local state = npcStates[key]
		context.apply()

		if state then
			npcStates[key] = nil

			for part, transparency in pairs(state.parts) do
				if part.Parent then
					TweenService:Create(part, TweenInfo.new(duration), { Transparency = transparency }):Play()
				end
			end

			for decal, transparency in pairs(state.decals) do
				if decal.Parent then
					TweenService:Create(decal, TweenInfo.new(duration), { Transparency = transparency }):Play()
				end
			end

			context.rig:moveToAsync(state.cameraCFrame, duration, "Sine")
		end

		return
	end

	local target = WorldBindings.resolve(context.targetId)
	local state = { parts = {}, decals = {}, cameraCFrame = context.rig:getCFrame() }
	npcStates[key] = state

	if target then
		local center = WorldBindings.centerOf(target)

		for _, descendant in ipairs(target:GetDescendants()) do
			if descendant:IsA("BasePart") then
				state.parts[descendant] = descendant.Transparency
				TweenService:Create(descendant, TweenInfo.new(duration), { Transparency = 1 }):Play()
			elseif descendant:IsA("Decal") or descendant:IsA("Texture") then
				state.decals[descendant] = descendant.Transparency
				TweenService:Create(descendant, TweenInfo.new(duration), { Transparency = 1 }):Play()
			end
		end

		if target:IsA("BasePart") then
			state.parts[target] = target.Transparency
			TweenService:Create(target, TweenInfo.new(duration), { Transparency = 1 }):Play()
		end

		if center then
			local camera = Workspace.CurrentCamera
			local from = camera and camera.CFrame.Position or state.cameraCFrame.Position
			local toward = (center - from)
			local distance = toward.Magnitude
			local destination = from + toward.Unit * math.max(0, distance - math.max(4, distance * 0.35))
			context.rig:moveToAsync(CFrame.lookAt(destination, center), duration, "Sine")
		else
			task.wait(duration)
		end
	else
		task.wait(duration)
	end

	context.apply()
end

function Transitions.run(preset, context)
	local handler = preset and kinds[preset.kind]

	if not handler then
		context.apply()
		return
	end

	local ok, err = pcall(handler, preset, context)
	if not ok then
		warn("[VNSceneEditor] transition failed: " .. tostring(err))
		context.overlay.Visible = false
		context.apply()
	end
end

function Transitions.describe(preset)
	if not preset then
		return "cut"
	end
	return preset.name
end

return Transitions
