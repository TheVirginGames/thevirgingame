-- First screen: chapters, presets and the recycle bin.

local root = script.Parent.Parent
local ProjectStore = require(root.Core.ProjectStore)
local Schema = require(root.Core.Schema)

local Theme = require(script.Parent.Theme)
local Widgets = require(script.Parent.Widgets)
local PresetsView = require(script.Parent.PresetsView)
local RecycleBinView = require(script.Parent.RecycleBinView)

local ProjectBrowserView = {}
ProjectBrowserView.__index = ProjectBrowserView

local TABS = {
	{ id = "chapters", label = "Chapters" },
	{ id = "presets", label = "Presets" },
	{ id = "bin", label = "Recycle Bin" },
}

function ProjectBrowserView.new(parent, app)
	local self = setmetatable({}, ProjectBrowserView)

	self.app = app
	self.tab = "chapters"

	self.root = Widgets.panel({
		Name = "ProjectBrowser",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(0.86, 0, 0.84, 0),
		BackgroundColor3 = Theme.Backdrop,
		BackgroundTransparency = 0.03,
		Radius = 12,
		ZIndex = 10,
		Visible = false,
		Parent = parent,
	}, {
		Widgets.stroke(Theme.Border, 1, 0.2),
		Widgets.padding(18, 22, 18, 22),
	})

	self.nameBox = Widgets.textBox({
		Size = UDim2.new(0, 320, 0, 30),
		Font = Theme.FontBold,
		TextSize = 18,
		TextYAlignment = Enum.TextYAlignment.Center,
		Flat = true,
		BackgroundTransparency = 1,
		OnCommit = function(text)
			local trimmed = Schema.trimName(text)
			if trimmed ~= "" then
				ProjectStore.getProject().name = trimmed
				ProjectStore.markChanged()
			end
			self:render()
		end,
		Parent = self.root,
	})

	self.status = Widgets.label({
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 0, 0, 0),
		Size = UDim2.new(0, 520, 0, 30),
		TextXAlignment = Enum.TextXAlignment.Right,
		TextSize = 11,
		TextColor3 = Theme.TextDim,
		Parent = self.root,
	})

	self.tabBar = Widgets.create("Frame", {
		Position = UDim2.new(0, 0, 0, 40),
		Size = UDim2.new(1, 0, 0, 26),
		BackgroundTransparency = 1,
		Parent = self.root,
	})

	self.content = Widgets.create("Frame", {
		Position = UDim2.new(0, 0, 0, 78),
		Size = UDim2.new(1, 0, 1, -78),
		BackgroundTransparency = 1,
		Parent = self.root,
	})

	self.chaptersPanel = Widgets.create("Frame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Parent = self.content,
	})

	self.chapterList = Widgets.scroll({
		Size = UDim2.new(1, 0, 1, -44),
		Parent = self.chaptersPanel,
	}, { Widgets.vlist(8), Widgets.padding(0, 6, 0, 0) })

	local footer = Widgets.create("Frame", {
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 0, 1, 0),
		Size = UDim2.new(1, 0, 0, 34),
		BackgroundTransparency = 1,
		Parent = self.chaptersPanel,
	}, { Widgets.hlist(8) })

	Widgets.button({
		Text = "+ New Chapter",
		Size = UDim2.new(0, 150, 1, 0),
		Color = Theme.Accent,
		LayoutOrder = 1,
		OnClick = function()
			local chapter = ProjectStore.createChapter("Chapter " .. (#ProjectStore.listChapters() + 1))
			app:openChapter(chapter.id)
		end,
		Parent = footer,
	})

	Widgets.button({
		Text = "Import JSON",
		Size = UDim2.new(0, 120, 1, 0),
		LayoutOrder = 2,
		OnClick = function()
			app:showImport()
		end,
		Parent = footer,
	})

	Widgets.button({
		Text = "Export Project JSON",
		Size = UDim2.new(0, 160, 1, 0),
		LayoutOrder = 3,
		OnClick = function()
			app:exportProject()
		end,
		Parent = footer,
	})

	Widgets.button({
		Text = "Save to Database",
		Size = UDim2.new(0, 150, 1, 0),
		Color = Theme.Good,
		LayoutOrder = 4,
		OnClick = function()
			app:saveNow()
		end,
		Parent = footer,
	})

	self.presetsView = PresetsView.new(self.content, app)
	self.recycleBinView = RecycleBinView.new(self.content, app)

	return self
end

function ProjectBrowserView:setVisible(visible)
	self.root.Visible = visible
end

function ProjectBrowserView:showTab(tab)
	self.tab = tab
	self:render()
end

function ProjectBrowserView:_renderChapters()
	local app = self.app
	local chapters = ProjectStore.listChapters()

	Widgets.clearChildren(self.chapterList)

	if #chapters == 0 then
		Widgets.hint("No chapters yet. Create one to start laying out scenes.", self.chapterList, 40)
		return
	end

	for index, chapter in ipairs(chapters) do
		local card = Widgets.create("Frame", {
			Size = UDim2.new(1, -6, 0, 78),
			BackgroundColor3 = Theme.Row,
			BorderSizePixel = 0,
			LayoutOrder = index,
			Parent = self.chapterList,
		}, { Widgets.corner(8), Widgets.padding(10, 12, 10, 14) })

		Widgets.label({
			Text = string.format("%02d", index),
			Size = UDim2.new(0, 34, 0, 26),
			Font = Theme.FontBold,
			TextSize = 18,
			TextColor3 = Theme.Accent,
			Parent = card,
		})

		Widgets.textBox({
			Text = chapter.name,
			Position = UDim2.new(0, 40, 0, 0),
			Size = UDim2.new(0, 320, 0, 26),
			Font = Theme.FontBold,
			TextSize = 14,
			TextYAlignment = Enum.TextYAlignment.Center,
			Flat = true,
			OnCommit = function(text)
				ProjectStore.renameChapter(chapter.id, text)
				self:render()
			end,
			Parent = card,
		})

		local kinds = { Novel2D = 0, Room3D = 0, Explore3D = 0 }
		local lines = 0
		local subsceneCount = 0
		for _, scene in ipairs(chapter.scenes) do
			for _, subscene in ipairs(Schema.ensureSubscenes(scene)) do
				kinds[subscene.kind] += 1
				subsceneCount += 1
			end
			lines += Schema.countLines(scene)
		end

		Widgets.label({
			Text = string.format(
				"%d scene(s), %d subscene(s): %d novel, %d room, %d explore   .   %d line(s)   .   %d flag(s)",
				#chapter.scenes, subsceneCount, kinds.Novel2D, kinds.Room3D, kinds.Explore3D, lines, #chapter.flags
			),
			Position = UDim2.new(0, 40, 0, 30),
			Size = UDim2.new(1, -60, 0, 16),
			TextSize = 11,
			TextColor3 = Theme.TextDim,
			Parent = card,
		})

		local actions = Widgets.create("Frame", {
			AnchorPoint = Vector2.new(1, 1),
			Position = UDim2.new(1, 0, 1, 0),
			Size = UDim2.new(0, 0, 0, 26),
			AutomaticSize = Enum.AutomaticSize.X,
			BackgroundTransparency = 1,
			Parent = card,
		}, { Widgets.hlist(6) })

		local function action(text, width, color, onClick, order)
			Widgets.button({
				Text = text,
				Size = UDim2.new(0, width, 1, 0),
				Color = color or Theme.Button,
				TextSize = 11,
				LayoutOrder = order,
				OnClick = onClick,
				Parent = actions,
			})
		end

		action("^", 26, nil, function()
			ProjectStore.moveChapter(chapter.id, -1)
			self:render()
		end, 1)
		action("v", 26, nil, function()
			ProjectStore.moveChapter(chapter.id, 1)
			self:render()
		end, 2)
		action("Open", 90, Theme.Accent, function()
			app:openChapter(chapter.id)
		end, 3)
		action("Play", 70, Theme.Good, function()
			app:playChapter(chapter.id)
		end, 4)
		action("Duplicate", 90, nil, function()
			ProjectStore.duplicateChapter(chapter.id)
			self:render()
		end, 5)
		action("Export", 70, nil, function()
			app:exportChapter(chapter.id)
		end, 6)
		action("Publish", 80, nil, function()
			app:publishChapter(chapter.id)
		end, 7)
		action("Delete", 70, Theme.Danger, function()
			app:showConfirm("Delete " .. chapter.name .. "?", "It moves to the recycle bin and can be restored.", function()
				ProjectStore.deleteChapter(chapter.id)
				self:render()
			end)
		end, 8)
	end
end

function ProjectBrowserView:render()
	local project = ProjectStore.getProject()

	self.nameBox.Text = project.name

	local status, message = ProjectStore.getPersistStatus()
	local colors = { saved = Theme.Good, saving = Theme.TextDim, error = Theme.Danger, offline = Theme.Danger }
	self.status.Text = message or ""
	self.status.TextColor3 = colors[status] or Theme.TextDim

	Widgets.clearChildren(self.tabBar)
	local options = table.clone(TABS)
	local binCount = 0
	local bin = ProjectStore.getRecycleBin()
	binCount = #bin.chapters + #bin.scenes + #bin.portraits
	options[3] = { id = "bin", label = binCount > 0 and string.format("Recycle Bin (%d)", binCount) or "Recycle Bin" }

	Widgets.segmented({
		Options = options,
		Value = self.tab,
		Size = UDim2.new(1, 0, 1, 0),
		OnPick = function(id)
			self:showTab(id)
		end,
		Parent = self.tabBar,
	})

	self.chaptersPanel.Visible = self.tab == "chapters"
	self.presetsView:setVisible(self.tab == "presets")
	self.recycleBinView:setVisible(self.tab == "bin")

	if self.tab == "chapters" then
		self:_renderChapters()
	elseif self.tab == "presets" then
		self.presetsView:render()
	else
		self.recycleBinView:render()
	end
end

return ProjectBrowserView
