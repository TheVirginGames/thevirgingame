-- The event attachment layer.
--
-- Whatever is selected supplies an anchor: a second inside a timed segment, a
-- dialogue entry, or an interaction's onComplete list. This panel lists the
-- events on that anchor and adds new ones from EventRegistry, grouped by
-- category. Editing an event's parameters happens in the inspector.

local root = script.Parent.Parent
local Schema = require(root.Core.Schema)
local EventRegistry = require(root.Core.EventRegistry)

local Theme = require(script.Parent.Theme)
local Widgets = require(script.Parent.Widgets)

local EventLayerView = {}
EventLayerView.__index = EventLayerView

function EventLayerView.new(parent, app)
	local self = setmetatable({}, EventLayerView)

	self.app = app
	self.addOpen = false
	self.addingSceneFlag = false
	self.mode = "events"

	self.panel = Widgets.panel({
		Name = "EventPanel",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Theme.Panel,
		BackgroundTransparency = 0.08,
		Parent = parent,
	}, { Widgets.padding(10, 12, 10, 12) })

	self.title = Widgets.sectionTitle("Events", self.panel)

	self.anchorLabel = Widgets.label({
		Position = UDim2.new(0, 0, 0, 18),
		Size = UDim2.new(1, 0, 0, 14),
		TextSize = 11,
		TextColor3 = Theme.TextFaint,
		Parent = self.panel,
	})

	self.list = Widgets.scroll({
		Name = "EventList",
		Position = UDim2.new(0, 0, 0, 36),
		Size = UDim2.new(1, 0, 1, -72),
		Parent = self.panel,
	}, { Widgets.vlist(4) })

	self.addButton = Widgets.button({
		Text = "+ Event",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 0, 1, 0),
		Size = UDim2.new(1, 0, 0, 30),
		Color = Theme.Button,
		OnClick = function()
			if self.mode == "sceneFlags" then
				self.addingSceneFlag = not self.addingSceneFlag
			else
				self.addOpen = not self.addOpen
			end
			self:render()
		end,
		Parent = self.panel,
	})

	return self
end

function EventLayerView:_renderSceneFlags()
	local app = self.app
	local scene = app.scene
	self.mode = "sceneFlags"
	self.addOpen = false
	self.title.Text = "SCENE FLAGS"
	self.anchorLabel.Text = "local to " .. scene.name
	self.addButton.Visible = true
	self.addButton.Text = self.addingSceneFlag and "Cancel" or "+ Scene Flag"

	if #scene.flags == 0 and not self.addingSceneFlag then
		Widgets.hint(
			"Scene flags are reset from these defaults whenever this scene is entered. They can be used by this scene's interactions and events.",
			self.list,
			70
		)
	end

	for index, flag in ipairs(scene.flags) do
		local row = Widgets.create("Frame", {
			Size = UDim2.new(1, -6, 0, 48),
			BackgroundColor3 = Theme.Row,
			BorderSizePixel = 0,
			LayoutOrder = index,
			Parent = self.list,
		}, { Widgets.corner(4), Widgets.padding(6, 8, 6, 8) })

		Widgets.label({
			Text = flag.id,
			Size = UDim2.new(1, -30, 0, 16),
			Font = Theme.FontBold,
			TextSize = 12,
			Parent = row,
		})

		Widgets.button({
			Text = "x",
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, 0, 0, 0),
			Size = UDim2.new(0, 20, 0, 18),
			Color = Theme.Danger,
			TextSize = 10,
			OnClick = function()
				table.remove(scene.flags, index)
				app:markDirty()
			end,
			Parent = row,
		})

		Widgets.segmented({
			Options = { { id = "bool", label = "bool" }, { id = "int", label = "int" } },
			Value = flag.kind,
			Position = UDim2.new(0, 0, 0, 20),
			Size = UDim2.new(0, 110, 0, 18),
			OnPick = function(kind)
				flag.kind = kind
				flag.default = kind == "int" and 0 or false
				app:markDirty()
			end,
			Parent = row,
		})

		if flag.kind == "bool" then
			Widgets.toggle({
				AnchorPoint = Vector2.new(1, 0),
				Position = UDim2.new(1, 0, 0, 20),
				Size = UDim2.new(0, 44, 0, 18),
				Value = flag.default == true,
				OnToggle = function(nextValue)
					flag.default = nextValue
					app:markDirty()
				end,
				Parent = row,
			})
		else
			Widgets.textBox({
				AnchorPoint = Vector2.new(1, 0),
				Position = UDim2.new(1, 0, 0, 19),
				Size = UDim2.new(0, 60, 0, 20),
				Text = tostring(flag.default),
				TextYAlignment = Enum.TextYAlignment.Center,
				TextXAlignment = Enum.TextXAlignment.Right,
				TextSize = 11,
				Font = Theme.FontMono,
				Flat = true,
				OnCommit = function(text)
					flag.default = tonumber(text) or 0
					app:markDirty()
				end,
				Parent = row,
			})
		end
	end

	if self.addingSceneFlag then
		local box
		box = Widgets.textBox({
			PlaceholderText = "flagName (letters, no spaces)",
			Size = UDim2.new(1, -6, 0, 28),
			TextYAlignment = Enum.TextYAlignment.Center,
			LayoutOrder = #scene.flags + 1,
			OnCommit = function(text, enterPressed)
				self.addingSceneFlag = false
				if enterPressed then
					local flagId = Schema.trimName(text):gsub("%s+", "_")
					local conflictsWithLegacyChapterId = Schema.findFlag(app:getChapter(), Schema.sceneFlagRef(flagId)) ~= nil
					if flagId == "" or Schema.findSceneFlag(scene, flagId) or conflictsWithLegacyChapterId then
						app:notify("Scene flag names must be unique and not empty.", Theme.Danger)
					else
						table.insert(scene.flags, Schema.newFlag(flagId, "bool"))
						app:markDirty()
						return
					end
				end
				self:render()
			end,
			Parent = self.list,
		})

		task.defer(function()
			if box.Parent then
				box:CaptureFocus()
			end
		end)
	end
end

function EventLayerView:_renderAddMenu(anchorKind, events)
	local app = self.app
	local order = 0
	local lastCategory = nil

	for _, eventType in ipairs(EventRegistry.listTypes(anchorKind)) do
		local category = EventRegistry.category(eventType)

		if category ~= lastCategory then
			lastCategory = category
			order += 1
			Widgets.label({
				Text = string.upper(category),
				Size = UDim2.new(1, -6, 0, 16),
				TextSize = 10,
				Font = Theme.FontBold,
				TextColor3 = Theme.TextFaint,
				LayoutOrder = order,
				Parent = self.list,
			})
		end

		order += 1
		local row = Widgets.button({
			Text = "    " .. EventRegistry.displayName(eventType),
			Size = UDim2.new(1, -6, 0, 24),
			Color = Theme.Row,
			Radius = 4,
			Font = Theme.Font,
			TextXAlignment = Enum.TextXAlignment.Left,
			LayoutOrder = order,
			OnClick = function()
				local time = 0

				if anchorKind == "Timed" then
					local segment = app:getSelectedSegment()
					local cursor = app:getCursor()

					if segment and cursor.segmentIndex == app.selection.segmentIndex then
						time = math.clamp(cursor.time or 0, 0, segment.duration)
					end
				end

				local event = Schema.newEvent(eventType, time)
				table.insert(events, event)

				self.addOpen = false
				local selection = table.clone(app.selection)
				selection.kind = "event"
				selection.eventId = event.id
				app.selection = selection

				app:markDirty()
			end,
			Parent = self.list,
		})

		Widgets.create("Frame", {
			Name = "Swatch",
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.new(0, 6, 0.5, 0),
			Size = UDim2.new(0, 8, 0, 8),
			BackgroundColor3 = EventRegistry.color(eventType),
			BorderSizePixel = 0,
			Parent = row,
		}, { Widgets.corner(4) })
	end
end

function EventLayerView:render()
	local app = self.app

	Widgets.clearChildren(self.list)

	if not app.scene then
		self.anchorLabel.Text = ""
		self.addButton.Visible = false
		return
	end

	if app:isSceneFlagsInspectorActive() then
		self:_renderSceneFlags()
		return
	end

	self.mode = "events"
	self.addingSceneFlag = false

	local events, anchorKind, anchorName = app:getAnchor()

	if not events then
		self.title.Text = "EVENTS"
		self.anchorLabel.Text = "no anchor selected"
		self.addButton.Visible = false
		self.addOpen = false

		Widgets.hint(
			"Events attach to an anchor. Pick a second inside a timed section, a line inside a dialogue block, or an interaction (for its completion events), then add effects to it.",
			self.list,
			70
		)

		return
	end

	self.title.Text = "EVENTS"
	self.addButton.Visible = true
	self.addButton.Text = self.addOpen and "Cancel" or "+ Event"

	if anchorKind == "Timed" then
		local cursor = app:getCursor()
		local atSegment = cursor.segmentIndex == app.selection.segmentIndex

		self.anchorLabel.Text = atSegment
			and string.format("on %s, new events land at %.2fs", anchorName, cursor.time or 0)
			or string.format("on %s", anchorName)
	elseif anchorKind == "Complete" then
		self.anchorLabel.Text = string.format("%s: runs when the interaction finishes", anchorName)
	else
		self.anchorLabel.Text = string.format("on %s, fires when the line shows", anchorName)
	end

	if self.addOpen then
		self:_renderAddMenu(anchorKind, events)
		return
	end

	if #events == 0 then
		Widgets.label({
			Text = "Nothing attached here yet.",
			Size = UDim2.new(1, -6, 0, 24),
			TextSize = 11,
			TextColor3 = Theme.TextFaint,
			Parent = self.list,
		})

		return
	end

	local resolver = function(picker, id)
		return app:resolvePicker(picker, id)
	end

	for index, event in ipairs(events) do
		local isSelected = app.selection.kind == "event" and app.selection.eventId == event.id

		local row = Widgets.button({
			Name = "Event_" .. event.id,
			Text = "",
			Size = UDim2.new(1, -6, 0, 30),
			Color = isSelected and Theme.RowHover or Theme.Row,
			Radius = 5,
			LayoutOrder = index,
			OnClick = function()
				local selection = table.clone(app.selection)
				selection.kind = "event"
				selection.eventId = event.id
				app:setSelection(selection)
			end,
			Parent = self.list,
		})

		if isSelected then
			Widgets.stroke(Theme.Accent, 2, 0).Parent = row
		end

		Widgets.create("Frame", {
			Name = "Swatch",
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.new(0, 8, 0.5, 0),
			Size = UDim2.new(0, 8, 0, 8),
			BackgroundColor3 = EventRegistry.color(event.type),
			BorderSizePixel = 0,
			Parent = row,
		}, { Widgets.corner(4) })

		local timeWidth = anchorKind == "Timed" and 48 or 0

		Widgets.label({
			Text = EventRegistry.summarize(event, resolver),
			Position = UDim2.new(0, 22, 0, 0),
			Size = UDim2.new(1, -(56 + timeWidth), 1, 0),
			TextSize = 11,
			TextColor3 = isSelected and Theme.Text or Theme.TextDim,
			Parent = row,
		})

		if anchorKind == "Timed" then
			Widgets.label({
				Text = string.format("%.2fs", event.time or 0),
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.new(1, -32, 0.5, 0),
				Size = UDim2.new(0, 46, 0, 14),
				TextXAlignment = Enum.TextXAlignment.Right,
				Font = Theme.FontMono,
				TextSize = 10,
				TextColor3 = Theme.TextFaint,
				Parent = row,
			})
		end

		Widgets.button({
			Text = "x",
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -6, 0.5, 0),
			Size = UDim2.new(0, 20, 0, 20),
			Radius = 4,
			TextSize = 11,
			Color = Theme.Danger,
			OnClick = function()
				table.remove(events, index)

				local selection = table.clone(app.selection)
				selection.eventId = nil
				if anchorKind == "Complete" then
					selection.kind = "interaction"
				elseif selection.entryIndex then
					selection.kind = "entry"
				else
					selection.kind = "segment"
				end
				app.selection = selection

				app:markDirty()
			end,
			Parent = row,
		})
	end
end

return EventLayerView
