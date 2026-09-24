-- The hybrid timeline for the open sequence (intro, outro or an interaction).
--
--   timed segments     a ruler in real seconds, where effects sit at a timestamp
--   dialogue segments  a container of click-to-advance entries, where time stops
--
--     [ 0s -- 1s -- 2s ] > [ DIALOGUE 3 ] > [ 0s -- 1s ] > [ DIALOGUE 2 ]
--
-- Clicking a second jumps the preview to that moment. Clicking a dialogue entry
-- jumps the preview to that entry. Neither one starts playback.

local root = script.Parent.Parent
local Schema = require(root.Core.Schema)
local EventRegistry = require(root.Core.EventRegistry)

local Theme = require(script.Parent.Theme)
local Widgets = require(script.Parent.Widgets)

local TimelineView = {}
TimelineView.__index = TimelineView

local BLOCK_HEIGHT = 104
local TICK_STEP = 0.5
local TICK_WIDTH = 34
local RULER_INSET = 12
local DIALOGUE_WIDTH = 214

local function truncate(text, limit)
	if #text <= limit then
		return text
	end

	return string.sub(text, 1, limit - 3) .. "..."
end

function TimelineView.new(parent, app)
	local self = setmetatable({}, TimelineView)

	self.app = app

	self.title = Widgets.sectionTitle("Timeline", parent)

	self.strip = Widgets.scroll({
		Name = "TimelineStrip",
		Position = UDim2.new(0, 0, 0, 20),
		Size = UDim2.new(1, 0, 1, -20),
		Axis = Enum.AutomaticSize.X,
		Parent = parent,
	}, {
		Widgets.hlist(8, Enum.VerticalAlignment.Top),
		Widgets.padding(2, 8, 2, 2),
	})

	return self
end

--------------------------------------------------------------------------------
-- Segment header shared by both block kinds
--------------------------------------------------------------------------------

function TimelineView:_buildHeader(block, index, labelText, labelColor)
	local app = self.app
	local sequence = app:getSequence()

	Widgets.label({
		Text = labelText,
		Position = UDim2.new(0, 10, 0, 6),
		Size = UDim2.new(1, -80, 0, 16),
		Font = Theme.FontBold,
		TextSize = 11,
		TextColor3 = labelColor,
		Parent = block,
	})

	local group = Widgets.create("Frame", {
		Name = "SegmentActions",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -8, 0, 5),
		Size = UDim2.new(0, 0, 0, 18),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundTransparency = 1,
		Parent = block,
	}, { Widgets.hlist(4) })

	local function move(offset)
		local target = index + offset

		if target < 1 or target > #sequence.segments then
			return
		end

		local moved = table.remove(sequence.segments, index)
		table.insert(sequence.segments, target, moved)

		app:jumpTo({ segmentIndex = target, time = 0, entryIndex = 1 }, { kind = "segment", segmentIndex = target })
		app:markDirty()
	end

	Widgets.button({
		Text = "<",
		Size = UDim2.new(0, 18, 1, 0),
		Radius = 4,
		TextSize = 11,
		LayoutOrder = 1,
		OnClick = function()
			move(-1)
		end,
		Parent = group,
	})

	Widgets.button({
		Text = ">",
		Size = UDim2.new(0, 18, 1, 0),
		Radius = 4,
		TextSize = 11,
		LayoutOrder = 2,
		OnClick = function()
			move(1)
		end,
		Parent = group,
	})

	Widgets.button({
		Text = "x",
		Size = UDim2.new(0, 18, 1, 0),
		Radius = 4,
		TextSize = 11,
		Color = Theme.Danger,
		LayoutOrder = 3,
		OnClick = function()
			table.remove(sequence.segments, index)
			local nextIndex = math.min(index, #sequence.segments)
			if nextIndex >= 1 then
				app.selection = { kind = "segment", segmentIndex = nextIndex }
			else
				app.selection = { kind = "none" }
			end
			app.runner:setCursor({ segmentIndex = 1, time = 0, entryIndex = 1 })
			app:markDirty()
		end,
		Parent = group,
	})
end

--------------------------------------------------------------------------------
-- Timed segment
--------------------------------------------------------------------------------

function TimelineView:_buildTimedSegment(segment, index, isCurrent, isSelected)
	local app = self.app
	local cursor = app:getCursor()

	local tickCount = math.floor(segment.duration / TICK_STEP) + 1
	local width = math.max(200, RULER_INSET * 2 + tickCount * TICK_WIDTH)

	local block = Widgets.button({
		Name = "Timed_" .. segment.id,
		Text = "",
		Size = UDim2.new(0, width, 0, BLOCK_HEIGHT),
		Color = isCurrent and Theme.Timed:Lerp(Theme.TimedSoft, 0.6) or Theme.TimedSoft,
		Radius = 8,
		LayoutOrder = index * 10,
		OnClick = function()
			app:jumpTo({ segmentIndex = index, time = 0 }, { kind = "segment", segmentIndex = index })
		end,
		Parent = self.strip,
	})

	Widgets.stroke(isSelected and Theme.Accent or Theme.Timed, isSelected and 2 or 1, isSelected and 0 or 0.5).Parent = block

	self:_buildHeader(block, index, "TIMED SEGMENT " .. index, Theme.Text)

	Widgets.textBox({
		Name = "Duration",
		Position = UDim2.new(0, 10, 0, 24),
		Size = UDim2.new(0, 62, 0, 20),
		Text = string.format("%.2f", segment.duration),
		TextSize = 11,
		Font = Theme.FontMono,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextYAlignment = Enum.TextYAlignment.Center,
		OnCommit = function(text)
			local parsed = tonumber(text)

			if not parsed then
				app:notify("Duration needs to be a number of seconds.", Theme.Danger)
				app:refresh()
				return
			end

			segment.duration = math.clamp(parsed, Schema.MIN_DURATION, Schema.MAX_DURATION)
			app:markDirty()
		end,
		Parent = block,
	})

	Widgets.label({
		Text = "seconds",
		Position = UDim2.new(0, 76, 0, 24),
		Size = UDim2.new(0, 60, 0, 20),
		TextColor3 = Theme.TextFaint,
		TextSize = 10,
		Parent = block,
	})

	if #segment.tracks > 0 then
		Widgets.label({
			Text = "keyframes",
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -10, 0, 26),
			Size = UDim2.new(0, 70, 0, 16),
			TextXAlignment = Enum.TextXAlignment.Right,
			TextColor3 = Theme.Accent,
			TextSize = 10,
			Parent = block,
		})
	end

	-- Event pips sit directly above the second they are anchored to.
	local pipStrip = Widgets.create("Frame", {
		Name = "Events",
		Position = UDim2.new(0, 0, 0, 48),
		Size = UDim2.new(1, 0, 0, 18),
		BackgroundTransparency = 1,
		Parent = block,
	})

	local stackedAtTime = {}

	for _, event in ipairs(segment.events) do
		local eventTime = math.clamp(event.time or 0, 0, segment.duration)
		local key = string.format("%.2f", eventTime)
		local stackIndex = stackedAtTime[key] or 0
		stackedAtTime[key] = stackIndex + 1

		local centerX = RULER_INSET + (eventTime / TICK_STEP) * TICK_WIDTH + TICK_WIDTH / 2
		local pip = Widgets.button({
			Name = "Pip_" .. event.id,
			Text = "",
			Position = UDim2.new(0, centerX - 6 + stackIndex * 5, 0, 3),
			Size = UDim2.new(0, 12, 0, 12),
			Color = EventRegistry.color(event.type),
			Radius = 6,
			OnClick = function()
				app:jumpTo(
					{ segmentIndex = index, time = eventTime },
					{ kind = "event", segmentIndex = index, eventId = event.id }
				)
			end,
			Parent = pipStrip,
		})

		if (event.duration or 0) > 0 then
			local spanWidth = (event.duration / TICK_STEP) * TICK_WIDTH
			Widgets.create("Frame", {
				Position = UDim2.new(0, centerX, 0, 8),
				Size = UDim2.new(0, math.max(2, spanWidth), 0, 2),
				BackgroundColor3 = EventRegistry.color(event.type),
				BackgroundTransparency = 0.4,
				BorderSizePixel = 0,
				ZIndex = 0,
				Parent = pipStrip,
			})
		end

		if app.selection.kind == "event" and app.selection.eventId == event.id then
			Widgets.stroke(Theme.Text, 2, 0).Parent = pip
		end
	end

	local ruler = Widgets.create("Frame", {
		Name = "Ruler",
		Position = UDim2.new(0, 0, 0, 68),
		Size = UDim2.new(1, 0, 0, 32),
		BackgroundTransparency = 1,
		Parent = block,
	})

	Widgets.create("Frame", {
		Name = "Baseline",
		Position = UDim2.new(0, RULER_INSET + TICK_WIDTH / 2, 0, 8),
		Size = UDim2.new(0, math.max(1, (tickCount - 1) * TICK_WIDTH), 0, 2),
		BackgroundColor3 = Theme.Timed,
		BackgroundTransparency = 0.4,
		BorderSizePixel = 0,
		Parent = ruler,
	})

	for tick = 1, tickCount do
		local tickTime = (tick - 1) * TICK_STEP
		local isWholeSecond = math.abs(tickTime % 1) < 0.001
		local isAtCursor = isCurrent and math.abs((cursor.time or 0) - tickTime) < TICK_STEP / 2

		local cell = Widgets.button({
			Name = string.format("Tick_%.2f", tickTime),
			Text = isWholeSecond and string.format("%ds", tickTime) or ".",
			Position = UDim2.new(0, RULER_INSET + (tick - 1) * TICK_WIDTH, 0, 0),
			Size = UDim2.new(0, TICK_WIDTH, 1, 0),
			Color = isAtCursor and Theme.Accent or Theme.TimedSoft,
			Radius = 4,
			Font = isWholeSecond and Theme.FontBold or Theme.Font,
			TextSize = isWholeSecond and 11 or 14,
			TextColor3 = isAtCursor and Theme.Text or (isWholeSecond and Theme.Text or Theme.TextFaint),
			OnClick = function()
				app:jumpTo(
					{ segmentIndex = index, time = tickTime },
					{ kind = "segment", segmentIndex = index }
				)
			end,
			Parent = ruler,
		})

		cell.BackgroundTransparency = isAtCursor and 0 or 0.55
	end

	local lastTick = (tickCount - 1) * TICK_STEP

	if math.abs(lastTick - segment.duration) > 0.001 then
		Widgets.label({
			Text = string.format("end %.2fs", segment.duration),
			Position = UDim2.new(0, RULER_INSET + tickCount * TICK_WIDTH, 0, 8),
			Size = UDim2.new(0, 70, 0, 16),
			TextColor3 = Theme.TextFaint,
			TextSize = 10,
			Parent = ruler,
		})
	end
end

--------------------------------------------------------------------------------
-- Dialogue segment
--------------------------------------------------------------------------------

function TimelineView:_buildDialogueSegment(segment, index, isCurrent, isSelected)
	local app = self.app
	local cursor = app:getCursor()

	local block = Widgets.button({
		Name = "Dialogue_" .. segment.id,
		Text = "",
		Size = UDim2.new(0, DIALOGUE_WIDTH, 0, BLOCK_HEIGHT),
		Color = isCurrent and Theme.Dialogue:Lerp(Theme.DialogueSoft, 0.55) or Theme.DialogueSoft,
		Radius = 8,
		LayoutOrder = index * 10,
		OnClick = function()
			app:jumpTo({ segmentIndex = index, entryIndex = 1, entryTime = 0 }, { kind = "segment", segmentIndex = index })
		end,
		Parent = self.strip,
	})

	Widgets.stroke(isSelected and Theme.Accent or Theme.Dialogue, isSelected and 2 or 1, isSelected and 0 or 0.4).Parent = block

	self:_buildHeader(block, index, string.format("DIALOGUE  %d LINE(S)", #segment.entries), Theme.Text)

	local chips = Widgets.scroll({
		Name = "Chips",
		Position = UDim2.new(0, 8, 0, 26),
		Size = UDim2.new(1, -16, 0, 72),
		ScrollBarThickness = 4,
		Parent = block,
	}, { Widgets.vlist(3) })

	for entryIndex, entry in ipairs(segment.entries) do
		local isEntryAtCursor = isCurrent and (cursor.entryIndex or 1) == entryIndex
		local isEntrySelected = app.selection.kind ~= "segment"
			and app.selection.segmentIndex == index
			and app.selection.entryIndex == entryIndex

		local character = entry.character ~= "" and entry.character or "narration"
		local preview = entry.text ~= "" and entry.text or "(empty)"

		Widgets.button({
			Name = "Chip_" .. entry.id,
			Text = string.format("%d  %s: %s", entryIndex, character, truncate(preview, 30)),
			Size = UDim2.new(1, -4, 0, 20),
			Color = isEntryAtCursor and Theme.Accent or Theme.Row,
			Radius = 4,
			Font = Theme.Font,
			TextSize = 11,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			TextColor3 = isEntrySelected and Theme.Text or Theme.TextDim,
			LayoutOrder = entryIndex,
			OnClick = function()
				app:jumpTo(
					{ segmentIndex = index, entryIndex = entryIndex, entryTime = 0 },
					{ kind = "entry", segmentIndex = index, entryIndex = entryIndex }
				)
			end,
			Parent = chips,
		})
	end
end

--------------------------------------------------------------------------------
-- Render
--------------------------------------------------------------------------------

function TimelineView:render()
	local app = self.app
	local sequence = app.scene and app:getSequence()

	Widgets.clearChildren(self.strip)

	if not sequence then
		return
	end

	self.title.Text = string.upper("Timeline  .  " .. app:getSequenceLabel())

	local cursor = app:getCursor()

	for index, segment in ipairs(sequence.segments) do
		local isCurrent = cursor.segmentIndex == index
		local isSelected = app.selection.segmentIndex == index

		if segment.kind == "Timed" then
			self:_buildTimedSegment(segment, index, isCurrent, isSelected)
		else
			self:_buildDialogueSegment(segment, index, isCurrent, isSelected)
		end

		if index < #sequence.segments then
			Widgets.label({
				Name = "Arrow_" .. index,
				Text = ">",
				Size = UDim2.new(0, 12, 0, BLOCK_HEIGHT),
				TextXAlignment = Enum.TextXAlignment.Center,
				TextColor3 = Theme.TextFaint,
				TextSize = 16,
				LayoutOrder = index * 10 + 5,
				Parent = self.strip,
			})
		end
	end

	local adders = Widgets.create("Frame", {
		Name = "Adders",
		Size = UDim2.new(0, 132, 0, BLOCK_HEIGHT),
		BackgroundTransparency = 1,
		LayoutOrder = 100000,
		Parent = self.strip,
	}, { Widgets.vlist(6) })

	Widgets.button({
		Text = "+ Timed Section",
		Size = UDim2.new(1, 0, 0, 30),
		Color = Theme.Timed,
		LayoutOrder = 1,
		OnClick = function()
			table.insert(sequence.segments, Schema.newTimedSegment(2))
			app:jumpTo({ segmentIndex = #sequence.segments, time = 0 }, { kind = "segment", segmentIndex = #sequence.segments })
			app:markDirty()
		end,
		Parent = adders,
	})

	Widgets.button({
		Text = "+ Dialogue Block",
		Size = UDim2.new(1, 0, 0, 30),
		Color = Theme.Dialogue,
		LayoutOrder = 2,
		OnClick = function()
			table.insert(sequence.segments, Schema.newDialogueSegment())
			app:jumpTo({ segmentIndex = #sequence.segments, entryIndex = 1, entryTime = 0 }, { kind = "segment", segmentIndex = #sequence.segments })
			app:markDirty()
		end,
		Parent = adders,
	})

	Widgets.label({
		Text = #sequence.segments == 0 and "this sequence is empty; add a block" or "click a second or a line to jump the preview",
		Size = UDim2.new(1, 0, 0, 30),
		TextColor3 = Theme.TextFaint,
		TextSize = 10,
		TextWrapped = true,
		TextTruncate = Enum.TextTruncate.None,
		LayoutOrder = 3,
		Parent = adders,
	})
end

return TimelineView
