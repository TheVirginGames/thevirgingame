-- Interactions of a Room3D / Explore3D scene: hotspots, triggers and exits.
-- Shown in the left column in place of the dialogue list when the scene
-- overview is selected.

local root = script.Parent.Parent
local Schema = require(root.Core.Schema)
local Conditions = require(root.Runtime.Conditions)

local Theme = require(script.Parent.Theme)
local Widgets = require(script.Parent.Widgets)

local InteractionListView = {}
InteractionListView.__index = InteractionListView

local ROW_HEIGHT = 58

local KIND_COLORS = {
	Hotspot = Color3.fromRGB(255, 196, 84),
	Trigger = Color3.fromRGB(96, 214, 200),
	Exit = Color3.fromRGB(255, 120, 120),
}

function InteractionListView.new(parent, app)
	local self = setmetatable({}, InteractionListView)

	self.app = app

	self.panel = Widgets.panel({
		Name = "InteractionPanel",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Theme.Panel,
		BackgroundTransparency = 0.08,
		Visible = false,
		Parent = parent,
	}, { Widgets.padding(10, 12, 10, 12) })

	self.title = Widgets.sectionTitle("Interactions", self.panel)

	self.list = Widgets.scroll({
		Name = "Interactions",
		Position = UDim2.new(0, 0, 0, 20),
		Size = UDim2.new(1, 0, 1, -56),
		Parent = self.panel,
	}, { Widgets.vlist(4) })

	local adders = Widgets.create("Frame", {
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 0, 1, 0),
		Size = UDim2.new(1, 0, 0, 30),
		BackgroundTransparency = 1,
		Parent = self.panel,
	}, { Widgets.hlist(6) })

	for index, kind in ipairs(Schema.INTERACTION_KINDS) do
		Widgets.button({
			Text = "+ " .. kind,
			Size = UDim2.new(1 / 3, -4, 1, 0),
			Color = KIND_COLORS[kind]:Lerp(Theme.Button, 0.55),
			TextSize = 11,
			LayoutOrder = index,
			OnClick = function()
				self:_add(kind)
			end,
			Parent = adders,
		})
	end

	return self
end

function InteractionListView:setVisible(visible)
	self.panel.Visible = visible
end

function InteractionListView:_add(kind)
	local app = self.app
	local interaction = Schema.newInteraction(kind)
	interaction.scope = "Local"
	interaction.subsceneId = app:getActiveSubscene().id
	table.insert(app.scene.interactions, interaction)
	app:setSelection({ kind = "interaction", interactionId = interaction.id })
	app:markDirty()
end

function InteractionListView:render()
	local app = self.app
	local scene = app.scene

	Widgets.clearChildren(self.list)

	if not scene then
		return
	end

	self.title.Text = string.format("INTERACTIONS  .  %d", #scene.interactions)

	if #scene.interactions == 0 then
		Widgets.hint(
			"Nothing to interact with yet. Add a hotspot for clickable objects, a trigger for touch zones, or an exit that leads to another scene.",
			self.list,
			70
		)
		return
	end

	local flags = app:getPreviewFlags()
	local chapter = app:getChapter()

	for index, interaction in ipairs(scene.interactions) do
		local isSelected = app.selection.kind == "interaction" and app.selection.interactionId == interaction.id
		local isOpen = app.openSequence.owner == "interaction" and app.openSequence.interactionId == interaction.id
		local inScope = Schema.interactionInSubscene(scene, app:getActiveSubscene(), interaction)
		local available = inScope and Conditions.evaluate(interaction.conditions, flags, chapter, scene)

		local row = Widgets.button({
			Name = "Interaction_" .. interaction.id,
			Text = "",
			Size = UDim2.new(1, -6, 0, ROW_HEIGHT),
			Color = isSelected and Theme.RowHover or Theme.Row,
			Radius = 6,
			LayoutOrder = index,
			OnClick = function()
				app:setSelection({ kind = "interaction", interactionId = interaction.id })
			end,
			Parent = self.list,
		})

		if isSelected or isOpen then
			Widgets.stroke(isOpen and KIND_COLORS[interaction.kind] or Theme.Accent, 2, 0).Parent = row
		end

		Widgets.create("Frame", {
			Position = UDim2.new(0, 0, 0, 0),
			Size = UDim2.new(0, 4, 1, 0),
			BackgroundColor3 = KIND_COLORS[interaction.kind],
			BorderSizePixel = 0,
			Parent = row,
		}, { Widgets.corner(2) })

		Widgets.label({
			Text = interaction.name,
			Position = UDim2.new(0, 12, 0, 5),
			Size = UDim2.new(1, -110, 0, 16),
			Font = Theme.FontBold,
			TextSize = 12,
			TextColor3 = Theme.Text,
			Parent = row,
		})

		Widgets.label({
			Text = string.upper(interaction.kind) .. (interaction.scope == "Local" and " · local" or " · shared"),
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -8, 0, 6),
			Size = UDim2.new(0, 96, 0, 14),
			TextXAlignment = Enum.TextXAlignment.Right,
			TextSize = 10,
			TextColor3 = KIND_COLORS[interaction.kind],
			Parent = row,
		})

		local target = interaction.targetId ~= "" and ("target " .. interaction.targetId) or "no target"
		local extra = ""
		if interaction.kind == "Exit" then
			local destination = app:resolvePicker("scene", interaction.exit.sceneId)
			extra = "  ->  " .. (destination or "end of chapter")
		end

		Widgets.label({
			Text = target .. extra,
			Position = UDim2.new(0, 12, 0, 22),
			Size = UDim2.new(1, -20, 0, 14),
			TextSize = 10,
			TextColor3 = interaction.targetId ~= "" and Theme.TextDim or Theme.Danger,
			Parent = row,
		})

		Widgets.label({
			Text = "if " .. Conditions.describeAll(interaction.conditions)
				.. (inScope and (available and "" or "   (blocked by preview flags)") or "   (other subscene)"),
			Position = UDim2.new(0, 12, 0, 37),
			Size = UDim2.new(1, -110, 0, 14),
			TextSize = 10,
			TextColor3 = available and Theme.TextFaint or Theme.Danger,
			Parent = row,
		})

		local group = Widgets.create("Frame", {
			AnchorPoint = Vector2.new(1, 1),
			Position = UDim2.new(1, -6, 1, -5),
			Size = UDim2.new(0, 0, 0, 18),
			AutomaticSize = Enum.AutomaticSize.X,
			BackgroundTransparency = 1,
			Parent = row,
		}, { Widgets.hlist(4) })

		Widgets.button({
			Text = string.format("Sequence (%d)", #interaction.sequence.segments),
			Size = UDim2.new(0, 84, 1, 0),
			Radius = 4,
			TextSize = 10,
			Color = isOpen and Theme.Accent or Theme.Button,
			LayoutOrder = 1,
			OnClick = function()
				app:openSequenceOwner("interaction", interaction.id)
			end,
			Parent = group,
		})

		Widgets.button({
			Text = "x",
			Size = UDim2.new(0, 18, 1, 0),
			Radius = 4,
			TextSize = 11,
			Color = Theme.Danger,
			LayoutOrder = 2,
			OnClick = function()
				app:showConfirm("Delete interaction?", "Its sequence and events are removed from this scene.", function()
					local wasOpen = app.openSequence.owner == "interaction" and app.openSequence.interactionId == interaction.id
					local returnSubsceneId = app:getActiveSubscene().id
					table.remove(scene.interactions, index)
					if wasOpen then app:openSequenceOwner("subscene", returnSubsceneId) end
					app:setSelection({ kind = "scene" })
					app:markDirty()
				end)
			end,
			Parent = group,
		})
	end
end

return InteractionListView
