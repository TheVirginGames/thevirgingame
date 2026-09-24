-- The expanded view of whichever dialogue block is selected in the timeline.
--
-- Each row is one click-to-advance line, in the order the player will see them.
-- A row is also the anchor that events get attached to, which is why the row
-- shows how many events it carries.

local root = script.Parent.Parent
local Schema = require(root.Core.Schema)

local Theme = require(script.Parent.Theme)
local Widgets = require(script.Parent.Widgets)

local DialogueListView = {}
DialogueListView.__index = DialogueListView

local ROW_HEIGHT = 46

function DialogueListView.new(parent, app)
	local self = setmetatable({}, DialogueListView)

	self.app = app
	self.renderedSegmentId = nil
	self.scrollRestoreGeneration = 0

	self.panel = Widgets.panel({
		Name = "DialoguePanel",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Theme.Panel,
		BackgroundTransparency = 0.08,
		Parent = parent,
	}, { Widgets.padding(10, 12, 10, 12) })

	self.title = Widgets.sectionTitle("Dialogue Entries", self.panel)

	self.list = Widgets.scroll({
		Name = "Entries",
		Position = UDim2.new(0, 0, 0, 20),
		Size = UDim2.new(1, 0, 1, -56),
		Parent = self.panel,
	}, { Widgets.vlist(4) })

	self.addButton = Widgets.button({
		Text = "+ Add Line",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 0, 1, 0),
		Size = UDim2.new(1, 0, 0, 30),
		Color = Theme.Dialogue,
		OnClick = function()
			self:_addEntry()
		end,
		Parent = self.panel,
	})

	return self
end

function DialogueListView:setVisible(visible)
	self.panel.Visible = visible
end

function DialogueListView:_addEntry()
	local app = self.app
	local segment = app:getSelectedSegment()

	if not segment or segment.kind ~= "Dialogue" then
		return
	end

	local insertAt = #segment.entries + 1

	if app.selection.entryIndex then
		insertAt = app.selection.entryIndex + 1
	end

	-- New lines inherit the previous line's character for faster writing.
	local previous = segment.entries[insertAt - 1]
	local entry = Schema.newDialogueEntry(previous and previous.character or "", "New line.")
	table.insert(segment.entries, insertAt, entry)

	app:jumpTo(
		{ segmentIndex = app.selection.segmentIndex, entryIndex = insertAt, entryTime = 0 },
		{ kind = "entry", segmentIndex = app.selection.segmentIndex, entryIndex = insertAt }
	)
	app:markDirty()
end

function DialogueListView:_showHint(text)
	self.addButton.Visible = false
	Widgets.hint(text, self.list, 80)
end

function DialogueListView:render()
	local app = self.app
	local previousScroll = self.list.CanvasPosition
	local previousSegmentId = self.renderedSegmentId
	self.scrollRestoreGeneration += 1
	local renderGeneration = self.scrollRestoreGeneration

	Widgets.clearChildren(self.list)

	if not app.scene then
		self.renderedSegmentId = nil
		return
	end

	local segment = app:getSelectedSegment()

	if not segment then
		self.renderedSegmentId = nil
		self.title.Text = "DIALOGUE ENTRIES"
		self:_showHint("Select a block in the timeline above.")
		return
	end

	if segment.kind ~= "Dialogue" then
		self.renderedSegmentId = nil
		self.title.Text = "DIALOGUE ENTRIES"
		self:_showHint(
			"A timed section is selected. Timed sections run on a clock and hold events at specific seconds. "
				.. "Select a dialogue block to edit its lines."
		)
		return
	end

	self.title.Text = string.format("DIALOGUE ENTRIES  .  BLOCK %d", app.selection.segmentIndex)
	self.addButton.Visible = true
	self.renderedSegmentId = segment.id
	local preserveScroll = previousSegmentId == segment.id

	local segmentIndex = app.selection.segmentIndex
	local cursor = app:getCursor()

	for entryIndex, entry in ipairs(segment.entries) do
		local isSelected = app.selection.entryIndex == entryIndex
		local isAtCursor = cursor.segmentIndex == segmentIndex and (cursor.entryIndex or 1) == entryIndex

		local row = Widgets.button({
			Name = "Entry_" .. entry.id,
			Text = "",
			Size = UDim2.new(1, -6, 0, ROW_HEIGHT),
			Color = isSelected and Theme.RowHover or Theme.Row,
			Radius = 6,
			LayoutOrder = entryIndex,
			OnClick = function()
				app:jumpTo(
					{ segmentIndex = segmentIndex, entryIndex = entryIndex, entryTime = 0 },
					{ kind = "entry", segmentIndex = segmentIndex, entryIndex = entryIndex }
				)
			end,
			Parent = self.list,
		})

		if isAtCursor then
			Widgets.stroke(Theme.Accent, 2, 0).Parent = row
		end

		Widgets.label({
			Text = tostring(entryIndex),
			Position = UDim2.new(0, 8, 0, 6),
			Size = UDim2.new(0, 20, 0, 16),
			Font = Theme.FontBold,
			TextSize = 12,
			TextColor3 = isAtCursor and Theme.Accent or Theme.TextFaint,
			Parent = row,
		})

		Widgets.label({
			Text = entry.character ~= "" and entry.character or "(narration)",
			Position = UDim2.new(0, 28, 0, 5),
			Size = UDim2.new(1, -184, 0, 16),
			Font = Theme.FontBold,
			TextSize = 12,
			TextColor3 = entry.character ~= "" and Theme.Text or Theme.TextDim,
			Parent = row,
		})

		Widgets.label({
			Text = entry.text ~= "" and entry.text or "(no text yet)",
			Position = UDim2.new(0, 28, 0, 23),
			Size = UDim2.new(1, -184, 0, 16),
			TextSize = 11,
			TextColor3 = Theme.TextDim,
			Parent = row,
		})

		local badges = {}
		if #entry.events > 0 then
			table.insert(badges, #entry.events == 1 and "1 event" or (#entry.events .. " events"))
		end
		if #entry.tracks > 0 then
			table.insert(badges, "keys")
		end
		if entry.portrait ~= "" then
			table.insert(badges, "portrait")
		end

		Widgets.label({
			Text = table.concat(badges, " . "),
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -80, 0, 6),
			Size = UDim2.new(0, 120, 0, 14),
			TextXAlignment = Enum.TextXAlignment.Right,
			TextSize = 10,
			TextColor3 = #badges > 0 and Theme.Accent or Theme.TextFaint,
			Parent = row,
		})

		local group = Widgets.create("Frame", {
			Name = "EntryActions",
			AnchorPoint = Vector2.new(1, 1),
			Position = UDim2.new(1, -6, 1, -5),
			Size = UDim2.new(0, 0, 0, 18),
			AutomaticSize = Enum.AutomaticSize.X,
			BackgroundTransparency = 1,
			Parent = row,
		}, { Widgets.hlist(4) })

		local function move(offset)
			local target = entryIndex + offset

			if target < 1 or target > #segment.entries then
				return
			end

			local moved = table.remove(segment.entries, entryIndex)
			table.insert(segment.entries, target, moved)

			app:jumpTo(
				{ segmentIndex = segmentIndex, entryIndex = target, entryTime = 0 },
				{ kind = "entry", segmentIndex = segmentIndex, entryIndex = target }
			)
			app:markDirty()
		end

		Widgets.button({
			Text = "^",
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
			Text = "v",
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
				if #segment.entries <= 1 then
					app:notify("A dialogue block needs at least one line.", Theme.Danger)
					return
				end

				table.remove(segment.entries, entryIndex)

				local nextIndex = math.min(entryIndex, #segment.entries)
				app:jumpTo(
					{ segmentIndex = segmentIndex, entryIndex = nextIndex, entryTime = 0 },
					{ kind = "entry", segmentIndex = segmentIndex, entryIndex = nextIndex }
				)
				app:markDirty()
			end,
			Parent = group,
		})
	end

	-- Rebuilding selected-row styling destroys the list content, which resets a
	-- ScrollingFrame to its top. Restore the old offset after the new layout has
	-- calculated, but only while the same dialogue block remains selected.
	if preserveScroll then
		task.defer(function()
			if self.scrollRestoreGeneration ~= renderGeneration
				or not self.list.Parent then
				return
			end

			local maximumY = math.max(
				0,
				self.list.AbsoluteCanvasSize.Y - self.list.AbsoluteSize.Y
			)
			self.list.CanvasPosition = Vector2.new(
				0,
				math.clamp(previousScroll.Y, 0, maximumY)
			)
		end)
	end
end

return DialogueListView
