-- Thin helpers over Instance.new so the view modules stay readable.

local Theme = require(script.Parent.Theme)

local Widgets = {}

function Widgets.create(className, properties, children)
	local instance = Instance.new(className)

	for key, value in pairs(properties or {}) do
		if key ~= "Parent" then
			instance[key] = value
		end
	end

	for _, child in ipairs(children or {}) do
		child.Parent = instance
	end

	if properties and properties.Parent then
		instance.Parent = properties.Parent
	end

	return instance
end

local create = Widgets.create

function Widgets.corner(radius)
	return create("UICorner", { CornerRadius = UDim.new(0, radius or 6) })
end

function Widgets.stroke(color, thickness, transparency)
	return create("UIStroke", {
		Color = color or Theme.Border,
		Thickness = thickness or 1,
		Transparency = transparency or 0,
	})
end

function Widgets.padding(top, right, bottom, left)
	return create("UIPadding", {
		PaddingTop = UDim.new(0, top or 0),
		PaddingRight = UDim.new(0, right or top or 0),
		PaddingBottom = UDim.new(0, bottom or top or 0),
		PaddingLeft = UDim.new(0, left or right or top or 0),
	})
end

function Widgets.vlist(gap)
	return create("UIListLayout", {
		FillDirection = Enum.FillDirection.Vertical,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0, gap or 4),
	})
end

function Widgets.hlist(gap, verticalAlignment)
	return create("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0, gap or 6),
		VerticalAlignment = verticalAlignment or Enum.VerticalAlignment.Center,
	})
end

local function withDefaults(properties, defaults)
	local merged = table.clone(properties or {})

	for key, value in pairs(defaults) do
		if merged[key] == nil then
			merged[key] = value
		end
	end

	return merged
end

function Widgets.label(properties)
	return create("TextLabel", withDefaults(properties, {
		BackgroundTransparency = 1,
		Font = Theme.Font,
		TextSize = 13,
		TextColor3 = Theme.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
	}))
end

function Widgets.panel(properties, children)
	local merged = withDefaults(properties, {
		BackgroundColor3 = Theme.Panel,
		BorderSizePixel = 0,
	})

	local extra = table.clone(children or {})
	table.insert(extra, Widgets.corner(properties and properties.Radius or 8))

	merged.Radius = nil

	return create("Frame", merged, extra)
end

function Widgets.button(properties)
	local onClick = properties.OnClick
	local color = properties.Color or Theme.Button
	local radius = properties.Radius or 6

	local merged = table.clone(properties)
	merged.OnClick = nil
	merged.Color = nil
	merged.Radius = nil

	merged = withDefaults(merged, {
		AutoButtonColor = false,
		BackgroundColor3 = color,
		BorderSizePixel = 0,
		Font = Theme.FontBold,
		TextSize = 13,
		TextColor3 = Theme.Text,
	})

	local button = create("TextButton", merged, { Widgets.corner(radius) })

	button.MouseEnter:Connect(function()
		button.BackgroundColor3 = color:Lerp(Color3.new(1, 1, 1), 0.14)
	end)

	button.MouseLeave:Connect(function()
		button.BackgroundColor3 = color
	end)

	if onClick then
		button.MouseButton1Click:Connect(onClick)
	end

	return button
end

function Widgets.textBox(properties)
	local onCommit = properties.OnCommit
	local flat = properties.Flat

	local merged = table.clone(properties)
	merged.OnCommit = nil
	merged.Flat = nil

	merged = withDefaults(merged, {
		BackgroundColor3 = Theme.Input,
		BorderSizePixel = 0,
		ClearTextOnFocus = false,
		Font = Theme.Font,
		TextSize = 13,
		TextColor3 = Theme.Text,
		PlaceholderColor3 = Theme.TextFaint,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
	})

	local children = {
		Widgets.corner(4),
		Widgets.padding(5, 8, 5, 8),
	}

	if not flat then
		table.insert(children, Widgets.stroke(Theme.Border, 1, 0.4))
	end

	local box = create("TextBox", merged, children)

	if onCommit then
		box.FocusLost:Connect(function(enterPressed)
			onCommit(box.Text, enterPressed)
		end)
	end

	return box
end

function Widgets.scroll(properties, children)
	local axis = properties.Axis or Enum.AutomaticSize.Y

	local merged = table.clone(properties)
	merged.Axis = nil

	merged = withDefaults(merged, {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = axis,
		ScrollBarThickness = 5,
		ScrollBarImageColor3 = Theme.Border,
		ScrollingDirection = axis == Enum.AutomaticSize.X and Enum.ScrollingDirection.X or Enum.ScrollingDirection.Y,
	})

	return create("ScrollingFrame", merged, children)
end

-- Removes rendered content while leaving layout objects (UIListLayout, padding,
-- corners) in place, so views can rebuild themselves cheaply.
function Widgets.clearChildren(instance)
	for _, child in ipairs(instance:GetChildren()) do
		if not child:IsA("UIComponent") then
			child:Destroy()
		end
	end
end

-- Small caps heading used at the top of each panel column.
function Widgets.sectionTitle(text, parent)
	return Widgets.label({
		Text = string.upper(text),
		Size = UDim2.new(1, 0, 0, 16),
		Font = Theme.FontBold,
		TextSize = 11,
		TextColor3 = Theme.TextFaint,
		Parent = parent,
	})
end

-- Wrapping hint paragraph.
function Widgets.hint(text, parent, height)
	return Widgets.label({
		Text = text,
		Size = UDim2.new(1, -6, 0, height or 40),
		TextSize = 11,
		TextColor3 = Theme.TextFaint,
		TextWrapped = true,
		TextTruncate = Enum.TextTruncate.None,
		TextYAlignment = Enum.TextYAlignment.Top,
		Parent = parent,
	})
end

-- A row of small text buttons that behaves like a segmented control.
-- options = { { id, label }, ... }
function Widgets.segmented(properties)
	local options = properties.Options
	local value = properties.Value
	local onPick = properties.OnPick

	local merged = table.clone(properties)
	merged.Options = nil
	merged.Value = nil
	merged.OnPick = nil

	local frame = create("Frame", withDefaults(merged, {
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 24),
	}), { Widgets.hlist(4) })

	for index, option in ipairs(options) do
		local selected = option.id == value
		Widgets.button({
			Text = option.label,
			Size = UDim2.new(0, 0, 1, 0),
			AutomaticSize = Enum.AutomaticSize.X,
			Color = selected and Theme.Accent or Theme.Button,
			TextColor3 = selected and Theme.Text or Theme.TextDim,
			TextSize = 11,
			Radius = 4,
			LayoutOrder = index,
			OnClick = function()
				if onPick then
					onPick(option.id)
				end
			end,
			Parent = frame,
		}).Size = UDim2.new(0, math.max(34, #option.label * 7 + 16), 1, 0)
	end

	return frame
end

-- Toggle drawn as a pill button.
function Widgets.toggle(properties)
	local value = properties.Value
	local onToggle = properties.OnToggle

	local merged = table.clone(properties)
	merged.Value = nil
	merged.OnToggle = nil
	merged.Text = value and "ON" or "OFF"
	merged.Color = value and Theme.Good or Theme.Button
	merged.TextSize = merged.TextSize or 11
	merged.Size = merged.Size or UDim2.new(0, 44, 0, 20)
	merged.Radius = 10
	merged.OnClick = function()
		if onToggle then
			onToggle(not value)
		end
	end

	return Widgets.button(merged)
end

-- Horizontal slider. Calls OnChange(value) while dragging and OnRelease(value)
-- when the mouse comes up.
function Widgets.slider(properties)
	local min = properties.Min or 0
	local max = properties.Max or 1
	local value = math.clamp(properties.Value or min, min, max)
	local onChange = properties.OnChange
	local onRelease = properties.OnRelease

	local merged = table.clone(properties)
	merged.Min = nil
	merged.Max = nil
	merged.Value = nil
	merged.OnChange = nil
	merged.OnRelease = nil

	local track = Widgets.button(withDefaults(merged, {
		Text = "",
		Size = UDim2.new(1, 0, 0, 18),
		Color = Theme.Input,
		Radius = 9,
	}))

	local fill = create("Frame", {
		Name = "Fill",
		Size = UDim2.new((value - min) / math.max(1e-6, max - min), 0, 1, 0),
		BackgroundColor3 = Theme.Accent,
		BorderSizePixel = 0,
		Parent = track,
	}, { Widgets.corner(9) })

	local UserInputService = game:GetService("UserInputService")
	local dragging = false

	local function update()
		local absolute = track.AbsolutePosition.X
		local width = math.max(1, track.AbsoluteSize.X)
		local alpha = math.clamp((UserInputService:GetMouseLocation().X - absolute) / width, 0, 1)
		value = min + (max - min) * alpha
		fill.Size = UDim2.new(alpha, 0, 1, 0)
		if onChange then
			onChange(value)
		end
	end

	track.MouseButton1Down:Connect(function()
		dragging = true
		update()
	end)

	local moveConnection = UserInputService.InputChanged:Connect(function(input)
		if dragging and input.UserInputType == Enum.UserInputType.MouseMovement then
			update()
		end
	end)

	local upConnection = UserInputService.InputEnded:Connect(function(input)
		if dragging and input.UserInputType == Enum.UserInputType.MouseButton1 then
			dragging = false
			if onRelease then
				onRelease(value)
			end
		end
	end)

	track.Destroying:Connect(function()
		moveConnection:Disconnect()
		upConnection:Disconnect()
	end)

	return track
end

-- Drop down list anchored under a button. items = { { id, label, color? }, ... }
-- Clicking outside closes it.
function Widgets.popupList(gui, anchor, items, onPick, options)
	options = options or {}

	local existing = gui:FindFirstChild("PopupList")
	if existing then
		existing:Destroy()
	end

	local blocker = create("TextButton", {
		Name = "PopupList",
		Text = "",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		AutoButtonColor = false,
		ZIndex = 500,
		Parent = gui,
	})

	local rowHeight = 24
	local visible = math.min(#items, options.maxRows or 10)
	local height = math.max(rowHeight, visible * (rowHeight + 2) + 8)
	local width = math.max(anchor.AbsoluteSize.X, options.width or 180)

	local x = anchor.AbsolutePosition.X
	local y = anchor.AbsolutePosition.Y + anchor.AbsoluteSize.Y + 4

	local viewport = gui.AbsoluteSize
	if y + height > viewport.Y then
		y = anchor.AbsolutePosition.Y - height - 4
	end
	if x + width > viewport.X then
		x = viewport.X - width - 8
	end

	local panel = Widgets.panel({
		Position = UDim2.fromOffset(x, y),
		Size = UDim2.fromOffset(width, height),
		BackgroundColor3 = Theme.PanelAlt,
		ZIndex = 501,
		Parent = blocker,
	}, { Widgets.stroke(Theme.Border, 1, 0.2), Widgets.padding(4, 4, 4, 4) })

	local list = Widgets.scroll({
		Size = UDim2.fromScale(1, 1),
		ZIndex = 502,
		Parent = panel,
	}, { Widgets.vlist(2) })

	for index, item in ipairs(items) do
		local row = Widgets.button({
			Text = (item.color and "      " or "  ") .. item.label,
			Size = UDim2.new(1, -6, 0, rowHeight),
			Color = item.selected and Theme.Accent or Theme.Row,
			TextColor3 = item.selected and Theme.Text or Theme.TextDim,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			TextSize = 11,
			Font = Theme.Font,
			Radius = 4,
			ZIndex = 503,
			LayoutOrder = index,
			OnClick = function()
				blocker:Destroy()
				onPick(item.id, item)
			end,
			Parent = list,
		})

		if item.color then
			create("Frame", {
				AnchorPoint = Vector2.new(0, 0.5),
				Position = UDim2.new(0, 8, 0.5, 0),
				Size = UDim2.new(0, 8, 0, 8),
				BackgroundColor3 = item.color,
				BorderSizePixel = 0,
				ZIndex = 504,
				Parent = row,
			}, { Widgets.corner(4) })
		end
	end

	blocker.MouseButton1Click:Connect(function()
		blocker:Destroy()
	end)

	return blocker
end

-- Button that shows the current choice and opens a popupList.
-- items = { { id, label } }, Value = current id
function Widgets.dropdown(gui, properties)
	local items = properties.Items
	local value = properties.Value
	local onPick = properties.OnPick
	local placeholder = properties.Placeholder or "(none)"

	local merged = table.clone(properties)
	merged.Items = nil
	merged.Value = nil
	merged.OnPick = nil
	merged.Placeholder = nil

	local current = nil
	for _, item in ipairs(items) do
		if item.id == value then
			current = item
		end
	end

	local button
	button = Widgets.button(withDefaults(merged, {
		Text = "  " .. (current and current.label or placeholder) .. "   v",
		Size = UDim2.new(1, 0, 0, 24),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextSize = 11,
		Font = Theme.Font,
		TextColor3 = current and Theme.Text or Theme.TextFaint,
		Color = Theme.Input,
		Radius = 4,
		OnClick = function()
			local decorated = {}
			for _, item in ipairs(items) do
				local copy = table.clone(item)
				copy.selected = item.id == value
				table.insert(decorated, copy)
			end
			Widgets.popupList(gui, button, decorated, function(id)
				onPick(id)
			end)
		end,
	}))

	Widgets.stroke(Theme.Border, 1, 0.4).Parent = button

	return button
end

return Widgets
