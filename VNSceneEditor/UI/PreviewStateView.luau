-- Floating panel of the chapter's flags for editor-side condition previewing.
-- A chapter playtest deliberately ignores these overrides and starts from the
-- default values saved in the Chapter Flags panel.

local root = script.Parent.Parent
local Conditions = require(root.Runtime.Conditions)

local Theme = require(script.Parent.Theme)
local Widgets = require(script.Parent.Widgets)

local PreviewStateView = {}
PreviewStateView.__index = PreviewStateView

function PreviewStateView.new(parent, app)
	local self = setmetatable({}, PreviewStateView)

	self.app = app

	self.panel = Widgets.panel({
		Name = "PreviewState",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -16, 0, 96),
		Size = UDim2.new(0, 260, 0, 260),
		BackgroundColor3 = Theme.Panel,
		BackgroundTransparency = 0.05,
		Visible = false,
		ZIndex = 40,
		Parent = parent,
	}, { Widgets.stroke(Theme.Border, 1, 0.3), Widgets.padding(10, 12, 10, 12) })

	Widgets.sectionTitle("Preview flags (editor only)", self.panel)

	Widgets.button({
		Text = "x",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 0, 0, -2),
		Size = UDim2.new(0, 20, 0, 20),
		TextSize = 11,
		ZIndex = 41,
		OnClick = function()
			app:togglePreviewState(false)
		end,
		Parent = self.panel,
	})

	self.list = Widgets.scroll({
		Position = UDim2.new(0, 0, 0, 22),
		Size = UDim2.new(1, 0, 1, -54),
		ZIndex = 41,
		Parent = self.panel,
	}, { Widgets.vlist(4) })

	Widgets.button({
		Text = "Reset to defaults",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 0, 1, 0),
		Size = UDim2.new(1, 0, 0, 26),
		TextSize = 11,
		ZIndex = 41,
		OnClick = function()
			app:resetPreviewFlags()
		end,
		Parent = self.panel,
	})

	return self
end

function PreviewStateView:setVisible(visible)
	self.panel.Visible = visible
end

function PreviewStateView:render()
	local app = self.app
	local chapter = app:getChapter()

	Widgets.clearChildren(self.list)

	if not chapter then
		return
	end

	if #chapter.flags == 0 then
		Widgets.hint("This chapter has no flags. Add some from the flow screen's Flags panel.", self.list, 50)
		return
	end

	local flags = app:getPreviewFlags()

	for index, flag in ipairs(chapter.flags) do
		local row = Widgets.create("Frame", {
			Size = UDim2.new(1, -6, 0, 24),
			BackgroundColor3 = Theme.Row,
			BorderSizePixel = 0,
			LayoutOrder = index,
			ZIndex = 42,
			Parent = self.list,
		}, { Widgets.corner(4), Widgets.padding(0, 6, 0, 8) })

		Widgets.label({
			Text = flag.id,
			Size = UDim2.new(1, -70, 1, 0),
			TextSize = 11,
			ZIndex = 43,
			Parent = row,
		})

		local value = flags[flag.id]
		if value == nil then
			value = flag.default
		end

		if flag.kind == "bool" then
			Widgets.toggle({
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.new(1, 0, 0.5, 0),
				Size = UDim2.new(0, 44, 0, 18),
				Value = value == true,
				ZIndex = 43,
				OnToggle = function(next)
					app:setPreviewFlag(flag.id, next)
				end,
				Parent = row,
			})
		else
			Widgets.textBox({
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.new(1, 0, 0.5, 0),
				Size = UDim2.new(0, 60, 0, 20),
				Text = Conditions.formatValue(value),
				TextYAlignment = Enum.TextYAlignment.Center,
				TextXAlignment = Enum.TextXAlignment.Right,
				TextSize = 11,
				Font = Theme.FontMono,
				Flat = true,
				ZIndex = 43,
				OnCommit = function(text)
					app:setPreviewFlag(flag.id, tonumber(text) or 0)
				end,
				Parent = row,
			})
		end
	end
end

return PreviewStateView
