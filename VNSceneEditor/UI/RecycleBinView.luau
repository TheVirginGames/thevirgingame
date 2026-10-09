-- Deleted chapters, scenes and portraits. Restore puts them back; Delete
-- forever removes them from the project for good.

local root = script.Parent.Parent
local ProjectStore = require(root.Core.ProjectStore)
local Schema = require(root.Core.Schema)

local Theme = require(script.Parent.Theme)
local Widgets = require(script.Parent.Widgets)

local RecycleBinView = {}
RecycleBinView.__index = RecycleBinView

local function formatAge(deletedAt)
	local age = os.time() - (deletedAt or os.time())

	if age < 60 then
		return "just now"
	elseif age < 3600 then
		return string.format("%d min ago", math.floor(age / 60))
	elseif age < 86400 then
		return string.format("%d h ago", math.floor(age / 3600))
	end

	return string.format("%d d ago", math.floor(age / 86400))
end

function RecycleBinView.new(parent, app)
	local self = setmetatable({}, RecycleBinView)

	self.app = app

	self.panel = Widgets.create("Frame", {
		Name = "RecycleBin",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Visible = false,
		Parent = parent,
	})

	self.header = Widgets.label({
		Text = "",
		Size = UDim2.new(1, -150, 0, 20),
		TextSize = 12,
		TextColor3 = Theme.TextDim,
		Parent = self.panel,
	})

	Widgets.button({
		Text = "Empty bin",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 0, 0, -2),
		Size = UDim2.new(0, 110, 0, 24),
		Color = Theme.Danger,
		TextSize = 11,
		OnClick = function()
			app:showConfirm("Empty the recycle bin?", "Everything in it is deleted forever.", function()
				ProjectStore.emptyRecycleBin()
				app:refresh()
			end)
		end,
		Parent = self.panel,
	})

	self.list = Widgets.scroll({
		Position = UDim2.new(0, 0, 0, 30),
		Size = UDim2.new(1, 0, 1, -30),
		Parent = self.panel,
	}, { Widgets.vlist(6) })

	return self
end

function RecycleBinView:setVisible(visible)
	self.panel.Visible = visible
end

function RecycleBinView:_row(order, title, subtitle, onRestore, onPurge, imageId)
	local row = Widgets.create("Frame", {
		Size = UDim2.new(1, -6, 0, 48),
		BackgroundColor3 = Theme.Row,
		BorderSizePixel = 0,
		LayoutOrder = order,
		Parent = self.list,
	}, { Widgets.corner(6) })

	local textX = 12
	if imageId then
		Widgets.create("ImageLabel", {
			Position = UDim2.new(0, 6, 0, 4),
			Size = UDim2.fromOffset(40, 40),
			BackgroundColor3 = Theme.Input,
			BorderSizePixel = 0,
			Image = imageId,
			ScaleType = Enum.ScaleType.Fit,
			Parent = row,
		}, { Widgets.corner(4) })
		textX = 54
	end

	Widgets.label({
		Text = title,
		Position = UDim2.new(0, textX, 0, 7),
		Size = UDim2.new(1, -(textX + 220), 0, 16),
		Font = Theme.FontBold,
		TextSize = 12,
		Parent = row,
	})

	Widgets.label({
		Text = subtitle,
		Position = UDim2.new(0, textX, 0, 26),
		Size = UDim2.new(1, -(textX + 220), 0, 14),
		TextSize = 10,
		TextColor3 = Theme.TextDim,
		Parent = row,
	})

	Widgets.button({
		Text = "Restore",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -108, 0.5, 0),
		Size = UDim2.new(0, 90, 0, 26),
		Color = Theme.Good,
		TextSize = 11,
		OnClick = onRestore,
		Parent = row,
	})

	Widgets.button({
		Text = "Delete forever",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -8, 0.5, 0),
		Size = UDim2.new(0, 94, 0, 26),
		Color = Theme.Danger,
		TextSize = 11,
		OnClick = onPurge,
		Parent = row,
	})
end

function RecycleBinView:_section(order, text)
	Widgets.label({
		Text = string.upper(text),
		Size = UDim2.new(1, 0, 0, 18),
		Font = Theme.FontBold,
		TextSize = 10,
		TextColor3 = Theme.TextFaint,
		LayoutOrder = order,
		Parent = self.list,
	})
end

function RecycleBinView:render()
	local app = self.app
	local bin = ProjectStore.getRecycleBin()

	Widgets.clearChildren(self.list)

	local total = #bin.chapters + #bin.scenes + #bin.portraits
	self.header.Text = total == 0 and "The recycle bin is empty." or string.format("%d item(s) in the bin. Restoring puts them back where they came from.", total)

	local order = 0

	if #bin.chapters > 0 then
		order += 1
		self:_section(order, "Chapters")

		for _, item in ipairs(bin.chapters) do
			order += 1
			self:_row(order, item.chapter.name, string.format("%d scene(s)  .  deleted %s", #item.chapter.scenes, formatAge(item.deletedAt)), function()
				ProjectStore.restoreChapter(item.id)
				app:notify("Chapter restored.", Theme.Good)
				app:refresh()
			end, function()
				app:showConfirm("Delete chapter forever?", item.chapter.name .. " cannot be recovered after this.", function()
					ProjectStore.purgeBinItem("chapters", item.id)
					app:refresh()
				end)
			end)
		end
	end

	if #bin.scenes > 0 then
		order += 1
		self:_section(order, "Scenes")

		for _, item in ipairs(bin.scenes) do
			order += 1
			local chapter = ProjectStore.getChapter(item.chapterId)
			local subscenes = Schema.ensureSubscenes(item.scene)
			local kinds = subscenes[1].kind .. (subscenes[1].kind ~= subscenes[#subscenes].kind and (" → " .. subscenes[#subscenes].kind) or "")
			self:_row(order, item.scene.name, string.format("%s  .  %d line(s)  .  from %s  .  deleted %s", kinds, Schema.countLines(item.scene), chapter and chapter.name or "a deleted chapter", formatAge(item.deletedAt)), function()
				ProjectStore.restoreScene(item.id)
				app:notify("Scene restored.", Theme.Good)
				app:refresh()
			end, function()
				app:showConfirm("Delete scene forever?", item.scene.name .. " cannot be recovered after this.", function()
					ProjectStore.purgeBinItem("scenes", item.id)
					app:refresh()
				end)
			end)
		end
	end

	if #bin.portraits > 0 then
		order += 1
		self:_section(order, "Portraits")

		for _, item in ipairs(bin.portraits) do
			order += 1
			self:_row(order, item.character, item.imageId .. "  .  deleted " .. formatAge(item.deletedAt), function()
				ProjectStore.restorePortrait(item.id)
				app:notify("Portrait restored to " .. item.character .. ".", Theme.Good)
				app:refresh()
			end, function()
				ProjectStore.purgeBinItem("portraits", item.id)
				app:refresh()
			end, item.imageId)
		end
	end
end

return RecycleBinView
