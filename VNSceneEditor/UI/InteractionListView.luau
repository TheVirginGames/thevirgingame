-- Hotspot interactions of a Room3D / Explore3D scene.
-- Shown in the left column in place of the dialogue list when the scene
-- overview is selected.

local root = script.Parent.Parent
local Schema = require(root.Core.Schema)

local Theme = require(script.Parent.Theme)
local Widgets = require(script.Parent.Widgets)

local InteractionListView = {}
InteractionListView.__index = InteractionListView

local ROW_HEIGHT = 58

local KIND_COLORS = {
	Hotspot = Color3.fromRGB(255, 196, 84),
}

function InteractionListView.new(parent, app)
	local self = setmetatable({}, InteractionListView)

	self.app = app
	self.hideOtherSubsceneInteractions = false
	self.hideDisabledInteractions = false

	self.panel = Widgets.panel({
		Name = "InteractionPanel",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Theme.Panel,
		BackgroundTransparency = 0.08,
		Visible = false,
		Parent = parent,
	}, { Widgets.padding(10, 12, 10, 12) })

	self.title = Widgets.sectionTitle("Interactions", self.panel)
	self.filterButton = Widgets.button({
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 0, 0, -2),
		Size = UDim2.new(0, 96, 0, 20),
		Text = "Hide others",
		TextSize = 10,
		Radius = 4,
		Color = Theme.Button,
		Parent = self.panel,
		OnClick = function()
			self.hideOtherSubsceneInteractions = not self.hideOtherSubsceneInteractions
			self:render()
		end,
	})
	self.disabledFilterButton = Widgets.button({
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -102, 0, -2),
		Size = UDim2.new(0, 100, 0, 20),
		Text = "Hide disabled",
		TextSize = 10,
		Radius = 4,
		Color = Theme.Button,
		Parent = self.panel,
		OnClick = function()
			self.hideDisabledInteractions = not self.hideDisabledInteractions
			self:render()
		end,
	})

	self.list = Widgets.scroll({
		Name = "Interactions",
		Position = UDim2.new(0, 0, 0, 20),
		Size = UDim2.new(1, 0, 1, -56),
		Parent = self.panel,
	}, { Widgets.vlist(4) })

	self.adders = Widgets.create("Frame", {
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 0, 1, 0),
		Size = UDim2.new(1, 0, 0, 30),
		BackgroundTransparency = 1,
		Parent = self.panel,
	}, { Widgets.hlist(6) })

	for index, kind in ipairs(Schema.INTERACTION_KINDS) do
		Widgets.button({
			Text = "+ " .. kind,
			Size = UDim2.new(1 / #Schema.INTERACTION_KINDS, -3, 1, 0),
			Color = KIND_COLORS[kind]:Lerp(Theme.Button, 0.55),
			TextSize = 11,
			LayoutOrder = index,
			OnClick = function()
				self:_add(kind)
			end,
			Parent = self.adders,
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

-- A timeline invocation is an intentionally detached snapshot.  It always
-- lands on the active standalone subscene's main timeline, even if the user
-- is currently editing this interaction's own response sequence.
function InteractionListView:_addToTimeline(interaction)
	local app = self.app
	local subscene = app:getActiveSubscene()
	if not subscene then
		app:notify("Open a subscene before adding an interaction to its timeline.", Theme.Danger)
		return
	end

	local segment
	if Schema.newInteractionSegment then
		segment = Schema.newInteractionSegment(interaction)
	else
		-- Kept as a small compatibility fallback while older editor sessions hot
		-- reload UI before the schema module. New saved projects use the factory.
		segment = {
			id = Schema.newId("intseg"),
			kind = "Interaction",
			interaction = {
				sourceInteractionId = interaction.id,
				sourceRevision = Schema.interactionRevision and Schema.interactionRevision(interaction) or "",
				snapshot = Schema.deepCopy(interaction),
			},
		}
	end

	table.insert(subscene.sequence.segments, segment)
	local segmentIndex = #subscene.sequence.segments

	-- Force the real subscene timeline open first. This prevents accidentally
	-- nesting an Interaction block inside an interaction response.
	app:openSequenceOwner("subscene", subscene.id)
	app:jumpTo(
		{ segmentIndex = segmentIndex, time = 0, entryIndex = 1 },
		{
			kind = "timelineInteraction",
			segmentIndex = segmentIndex,
			timelineSubsceneId = subscene.id,
			timelineSegmentId = segment.id,
		}
	)
	app:markDirty()
end

-- Duplicate the complete interaction while preserving its target, scope and
-- authored behavior. Nested IDs need fresh identities so the copy can own its
-- own events/tracks without colliding with the source in the flow graph.
function InteractionListView:_duplicate(interaction, index)
	local app = self.app
	local duplicate = Schema.copyInteractionSnapshot(interaction)
	duplicate.id = Schema.newId("int")
	Schema.reidentifyInteractionSnapshot(duplicate, duplicate.id)
	duplicate.name = interaction.name .. " copy"

	table.insert(app.scene.interactions, index + 1, duplicate)
	app:setSelection({ kind = "interaction", interactionId = duplicate.id })
	app:markDirty()
end

function InteractionListView:render()
	local app = self.app
	local scene = app.scene
	local applyingDefaultResponse = app:isApplyingDefaultResponse()

	Widgets.clearChildren(self.list)
	-- Batch selection must be able to reach every interaction and must not let
	-- authors create a new one in the middle of the operation.
	if applyingDefaultResponse then
		self.hideOtherSubsceneInteractions = false
	end
	self.adders.Visible = not applyingDefaultResponse
	self.filterButton.Text = self.hideOtherSubsceneInteractions and "Show all" or "Hide others"
	self.filterButton.BackgroundColor3 = self.hideOtherSubsceneInteractions and Theme.Accent or Theme.Button
	self.disabledFilterButton.Text = self.hideDisabledInteractions and "Show disabled" or "Hide disabled"
	self.disabledFilterButton.BackgroundColor3 = self.hideDisabledInteractions and Theme.Timed or Theme.Button

	if not scene then
		return
	end

	self.title.Text = string.format("INTERACTIONS  .  %d", #scene.interactions)

	if #scene.interactions == 0 then
		Widgets.hint(
			"Nothing to interact with yet. Add a hotspot for clickable objects.",
			self.list,
			70
		)
		return
	end

	local shown = 0
	for index, interaction in ipairs(scene.interactions) do
		local isSource = applyingDefaultResponse and app.defaultResponseApply
			and app.defaultResponseApply.sourceInteractionId == interaction.id
		local isMarked = applyingDefaultResponse and app:isDefaultResponseTarget(interaction.id)
		local isSelected = not applyingDefaultResponse
			and app.selection.kind == "interaction" and app.selection.interactionId == interaction.id
		local isOpen = app.openSequence.owner == "interaction" and app.openSequence.interactionId == interaction.id
		local inScope = Schema.interactionInSubscene(scene, app:getActiveSubscene(), interaction)
		if self.hideOtherSubsceneInteractions and not inScope then
			continue
		end
		if self.hideDisabledInteractions and interaction.enabled == false then
			continue
		end
		shown += 1
		local isDisabled = interaction.enabled == false
		local rowColor = isDisabled and Theme.PanelAlt or Theme.Row
		if isMarked or isSelected then rowColor = Theme.RowHover end

		local row = Widgets.button({
			Name = "Interaction_" .. interaction.id,
			Text = "",
			Size = UDim2.new(1, -6, 0, ROW_HEIGHT),
			Color = rowColor,
			Radius = 6,
			LayoutOrder = shown,
			OnClick = function()
				if applyingDefaultResponse then
					app:toggleDefaultResponseTarget(interaction.id)
				else
					app:setSelection({ kind = "interaction", interactionId = interaction.id })
				end
			end,
			Parent = self.list,
		})

		if isMarked or isSelected or isOpen or isSource then
			Widgets.stroke(isMarked and Theme.Good or (isOpen and KIND_COLORS[interaction.kind] or Theme.Accent), 2, 0).Parent = row
		end

		Widgets.create("Frame", {
			Position = UDim2.new(0, 0, 0, 0),
			Size = UDim2.new(0, 4, 1, 0),
			BackgroundColor3 = isDisabled and Theme.TextFaint or KIND_COLORS[interaction.kind],
			BorderSizePixel = 0,
			Parent = row,
		}, { Widgets.corner(2) })

		Widgets.label({
			Text = interaction.name .. (isMarked and "  ✓" or (isSource and "  (source)" or "")),
			Position = UDim2.new(0, 12, 0, 5),
			Size = UDim2.new(1, -140, 0, 16),
			Font = Theme.FontBold,
			TextSize = 12,
			TextColor3 = isDisabled and Theme.TextDim or Theme.Text,
			Parent = row,
		})

		Widgets.label({
			Text = string.upper(interaction.kind) .. (interaction.scope == "Local" and " · local" or " · shared"),
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -8, 0, 6),
			Size = UDim2.new(0, 96, 0, 14),
			TextXAlignment = Enum.TextXAlignment.Right,
			TextSize = 10,
			TextColor3 = isDisabled and Theme.TextFaint or KIND_COLORS[interaction.kind],
			Parent = row,
		})

		local characterPlacement = Schema.characterModelForInteraction(scene, interaction)
		local hasWorldTarget = type(interaction.targetId) == "string" and interaction.targetId ~= ""
		local target = characterPlacement and ("character model · " .. characterPlacement.character)
			or (hasWorldTarget and ("target " .. interaction.targetId) or "no target")
		Widgets.label({
			Text = target,
			Position = UDim2.new(0, 12, 0, 22),
			Size = UDim2.new(1, -20, 0, 14),
			TextSize = 10,
			TextColor3 = isDisabled and Theme.TextFaint or ((characterPlacement or hasWorldTarget) and Theme.TextDim or Theme.Danger),
			Parent = row,
		})

		Widgets.label({
			Text = isDisabled and "DISABLED · default response only"
				or (#(interaction.responses or {}) > 0 and string.format("%d conditional response(s)", #interaction.responses) or "default response only")
					.. (inScope and "" or "   (other subscene)"),
			Position = UDim2.new(0, 12, 0, 37),
			Size = UDim2.new(1, -140, 0, 14),
			TextSize = 10,
			TextColor3 = Theme.TextFaint,
			Parent = row,
		})

		-- The action buttons would conflict with a row click during a batch
		-- selection, so present the rows as plain selectable targets instead.
		if not applyingDefaultResponse then
		local actionColor = isDisabled and Theme.Row or nil
		local group = Widgets.create("Frame", {
			AnchorPoint = Vector2.new(1, 1),
			Position = UDim2.new(1, -6, 1, -5),
			Size = UDim2.new(0, 0, 0, 18),
			AutomaticSize = Enum.AutomaticSize.X,
			BackgroundTransparency = 1,
			Parent = row,
		}, { Widgets.hlist(4) })

		Widgets.button({
			Text = #((interaction.responses) or {}) > 0
				and string.format("Responses (%d)", #interaction.responses + 1)
				or string.format("Sequence (%d)", #interaction.sequence.segments),
			Size = UDim2.new(0, 84, 1, 0),
			Radius = 4,
			TextSize = 10,
			Color = actionColor or (isOpen and Theme.Accent or Theme.Button),
			LayoutOrder = 1,
			OnClick = function()
				app:openSequenceOwner("interaction", interaction.id)
			end,
			Parent = group,
		})

		Widgets.button({
			Text = "↑",
			Size = UDim2.new(0, 20, 1, 0),
			Radius = 4,
			TextSize = 13,
			Color = actionColor or KIND_COLORS[interaction.kind]:Lerp(Theme.Button, 0.45),
			LayoutOrder = 2,
			OnClick = function()
				self:_addToTimeline(interaction)
			end,
			Parent = group,
		})

		Widgets.button({
			Text = "↓",
			Size = UDim2.new(0, 20, 1, 0),
			Radius = 4,
			TextSize = 13,
			Color = actionColor or Theme.Timed,
			LayoutOrder = 3,
			OnClick = function()
				self:_duplicate(interaction, index)
			end,
			Parent = group,
		})

		Widgets.button({
			Text = "x",
			Size = UDim2.new(0, 18, 1, 0),
			Radius = 4,
			TextSize = 11,
			Color = actionColor or Theme.Danger,
			LayoutOrder = 4,
			OnClick = function()
				app:showConfirm("Delete interaction?", "Its sequence and events are removed from this scene.", function()
					local wasOpen = app.openSequence.owner == "interaction" and app.openSequence.interactionId == interaction.id
					local openTimelineCopy = nil
					if app.openSequence.owner == "timelineInteraction" then
						local copied = app:getTimelineInteractionSegment(
							app.openSequence.subsceneId,
							app.openSequence.segmentId
						)
						if copied and copied.interaction and copied.interaction.sourceInteractionId == interaction.id then
							openTimelineCopy = {
								timelineSubsceneId = app.openSequence.subsceneId,
								timelineSegmentId = app.openSequence.segmentId,
							}
						end
					end
					local returnSubsceneId = app:getActiveSubscene().id
					table.remove(scene.interactions, index)
					if wasOpen then
						app:openSequenceOwner("subscene", returnSubsceneId)
					elseif openTimelineCopy then
						-- A timeline block owns a detached snapshot, so deleting its
						-- source must not throw the author out of the copied response
						-- they are currently editing.
						app:setSelection({
							kind = "timelineInteraction",
							timelineSubsceneId = openTimelineCopy.timelineSubsceneId,
							timelineSegmentId = openTimelineCopy.timelineSegmentId,
						})
					else
						app:setSelection({ kind = "scene" })
					end
					app:markDirty()
				end)
			end,
			Parent = group,
		})
		end
	end

	if shown == 0 then
		Widgets.hint("No interactions match the active filters. Adjust Hide others or Hide disabled.", self.list, 42)
	end
end

return InteractionListView
