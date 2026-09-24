-- Second screen: the scenes of one chapter as draggable nodes with the links
-- between them (next scene, exits, Go To events) drawn as lines. Also hosts the
-- chapter's flag list.

local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")

local root = script.Parent.Parent
local ProjectStore = require(root.Core.ProjectStore)
local Schema = require(root.Core.Schema)

local Theme = require(script.Parent.Theme)
local Widgets = require(script.Parent.Widgets)

local ChapterFlowView = {}
ChapterFlowView.__index = ChapterFlowView

local NODE_WIDTH = 210
local NODE_BASE_HEIGHT = 106
local ROUTE_ROW_HEIGHT = 18
local FLAGS_WIDTH = 260

local LINK_COLORS = {
	next = Theme.Accent,
	exit = Color3.fromRGB(255, 120, 120),
	goto = Color3.fromRGB(255, 160, 90),
	finish = Color3.fromRGB(230, 90, 120),
}

local KIND_COLORS = {
	Novel2D = Theme.Dialogue,
	Room3D = Color3.fromRGB(255, 196, 84),
	Explore3D = Color3.fromRGB(96, 214, 200),
}

function ChapterFlowView.new(parent, app)
	local self = setmetatable({}, ChapterFlowView)

	self.app = app
	self.chapterId = nil
	self.selectedSceneId = nil
	self.dragging = nil
	self.connecting = nil
	self.addingFlag = false
	self.nodes = {}
	self.ports = {}

	self.root = Widgets.create("Frame", {
		Name = "ChapterFlow",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Theme.Backdrop,
		BackgroundTransparency = 0.05,
		BorderSizePixel = 0,
		ZIndex = 10,
		Visible = false,
		Parent = parent,
	})

	self.toolbar = Widgets.create("Frame", {
		Size = UDim2.new(1, 0, 0, 52),
		BackgroundColor3 = Theme.Panel,
		BorderSizePixel = 0,
		ZIndex = 11,
		Parent = self.root,
	}, { Widgets.padding(10, 16, 10, 16), Widgets.hlist(8) })

	Widgets.button({
		Text = "< Chapters",
		Size = UDim2.new(0, 110, 1, 0),
		LayoutOrder = 1,
		ZIndex = 12,
		OnClick = function()
			app:showBrowser()
		end,
		Parent = self.toolbar,
	})

	self.nameBox = Widgets.textBox({
		Size = UDim2.new(0, 260, 1, 0),
		Font = Theme.FontBold,
		TextSize = 15,
		TextYAlignment = Enum.TextYAlignment.Center,
		Flat = true,
		BackgroundTransparency = 1,
		LayoutOrder = 2,
		ZIndex = 12,
		OnCommit = function(text)
			if self.chapterId then
				ProjectStore.renameChapter(self.chapterId, text)
			end
			self:render()
		end,
		Parent = self.toolbar,
	})

	for index, kind in ipairs(Schema.SCENE_KINDS) do
		Widgets.button({
			Text = "+ " .. kind,
			Size = UDim2.new(0, 110, 1, 0),
			Color = KIND_COLORS[kind]:Lerp(Theme.Button, 0.5),
			TextSize = 11,
			LayoutOrder = 10 + index,
			ZIndex = 12,
			OnClick = function()
				local scene = ProjectStore.createScene(self.chapterId, "New " .. kind, kind)
				if scene then
					self.selectedSceneId = scene.id
					self:render()
				end
			end,
			Parent = self.toolbar,
		})
	end

	Widgets.button({
		Text = "Play Chapter",
		Size = UDim2.new(0, 120, 1, 0),
		Color = Theme.Good,
		LayoutOrder = 20,
		ZIndex = 12,
		OnClick = function()
			app:playChapter(self.chapterId)
		end,
		Parent = self.toolbar,
	})

	Widgets.button({
		Text = "Save",
		Size = UDim2.new(0, 80, 1, 0),
		LayoutOrder = 21,
		ZIndex = 12,
		OnClick = function()
			app:saveNow()
		end,
		Parent = self.toolbar,
	})

	self.hintLabel = Widgets.label({
		Text = "drag headers to arrange  .  drag ports to connect  .  right click a connection for options",
		Size = UDim2.new(0, 360, 1, 0),
		TextSize = 11,
		TextColor3 = Theme.TextFaint,
		LayoutOrder = 30,
		ZIndex = 12,
		Parent = self.toolbar,
	})

	self.canvas = Widgets.create("ScrollingFrame", {
		Name = "Canvas",
		Position = UDim2.new(0, 0, 0, 52),
		Size = UDim2.new(1, -FLAGS_WIDTH, 1, -52),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		CanvasSize = UDim2.fromOffset(3000, 2000),
		ScrollBarThickness = 6,
		ScrollBarImageColor3 = Theme.Border,
		ScrollingDirection = Enum.ScrollingDirection.XY,
		ZIndex = 11,
		Parent = self.root,
	})

	self.edgeLayer = Widgets.create("Frame", {
		Name = "Edges",
		Size = UDim2.fromOffset(3000, 2000),
		BackgroundTransparency = 1,
		ZIndex = 11,
		Parent = self.canvas,
	})

	self.nodeLayer = Widgets.create("Frame", {
		Name = "Nodes",
		Size = UDim2.fromOffset(3000, 2000),
		BackgroundTransparency = 1,
		ZIndex = 12,
		Parent = self.canvas,
	})

	self.flagsPanel = Widgets.create("Frame", {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 0, 0, 52),
		Size = UDim2.new(0, FLAGS_WIDTH, 1, -52),
		BackgroundColor3 = Theme.Panel,
		BorderSizePixel = 0,
		ZIndex = 11,
		Parent = self.root,
	}, { Widgets.padding(12, 14, 12, 14) })

	Widgets.sectionTitle("Chapter flags", self.flagsPanel).ZIndex = 12

	self.flagList = Widgets.scroll({
		Position = UDim2.new(0, 0, 0, 22),
		Size = UDim2.new(1, 0, 1, -100),
		ZIndex = 12,
		Parent = self.flagsPanel,
	}, { Widgets.vlist(4) })

	self.flagFooter = Widgets.create("Frame", {
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 0, 1, 0),
		Size = UDim2.new(1, 0, 0, 70),
		BackgroundTransparency = 1,
		ZIndex = 12,
		Parent = self.flagsPanel,
	})

	self.moveConnection = UserInputService.InputChanged:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseMovement then
			local mousePosition = self:_mouseGuiPosition()
			if self.dragging then
				self:_dragTo(mousePosition)
			elseif self.connecting then
				self:_updateConnectionPreview(mousePosition)
			end
		end
	end)

	self.releaseConnection = UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			if self.dragging then
				self:_endDrag()
			elseif self.connecting then
				self:_endConnection(self:_mouseGuiPosition())
			end
		end
	end)

	return self
end

function ChapterFlowView:setVisible(visible)
	self.root.Visible = visible
	if not visible then
		self.dragging = nil
		self.connecting = nil
	end
end

function ChapterFlowView:setChapter(chapterId)
	self.chapterId = chapterId
	self.selectedSceneId = nil
	self.dragging = nil
	self.connecting = nil
end

function ChapterFlowView:_chapter()
	return ProjectStore.getChapter(self.chapterId)
end

--------------------------------------------------------------------------------
-- Dragging
--------------------------------------------------------------------------------

function ChapterFlowView:_nodeHeight(scene)
	local routes = 0
	for _, link in ipairs(Schema.sceneLinks(scene)) do
		if link.kind ~= "next" then
			routes += 1
		end
	end
	routes += #Schema.sceneFlowMarkers(scene)
	return NODE_BASE_HEIGHT + math.max(0, routes) * ROUTE_ROW_HEIGHT
end

function ChapterFlowView:_beginDrag(scene, node, mousePosition)
	self.connecting = nil
	self.dragging = {
		scene = scene,
		node = node,
		offset = Vector2.new(mousePosition.X, mousePosition.Y) - node.AbsolutePosition,
		moved = false,
	}
end

function ChapterFlowView:_mouseGuiPosition()
	local mousePosition = UserInputService:GetMouseLocation()
	local guiInset = GuiService:GetGuiInset()

	return Vector2.new(
		mousePosition.X - guiInset.X,
		mousePosition.Y - guiInset.Y
	)
end

function ChapterFlowView:_dragTo(mousePosition)
	local drag = self.dragging
	local canvasOrigin = self.nodeLayer.AbsolutePosition
	local x = mousePosition.X - drag.offset.X - canvasOrigin.X
	local y = mousePosition.Y - drag.offset.Y - canvasOrigin.Y

	drag.node.Position = UDim2.fromOffset(math.max(0, x), math.max(0, y))
	drag.moved = true
	self:_drawEdges()
end

function ChapterFlowView:_endDrag()
	local drag = self.dragging
	self.dragging = nil

	if drag.moved then
		local position = drag.node.Position
		ProjectStore.setScenePosition(self.chapterId, drag.scene.id, position.X.Offset, position.Y.Offset)
	end

	self:render()
end

--------------------------------------------------------------------------------
-- Connection editing
--------------------------------------------------------------------------------

function ChapterFlowView:_beginConnection(scene, kind, link)
	self.dragging = nil
	self.connecting = {
		scene = scene,
		kind = kind,
		link = link,
		mousePosition = self:_mouseGuiPosition(),
	}
	self:_drawEdges()
end	

function ChapterFlowView:_updateConnectionPreview(mousePosition)
	if self.connecting then
		self.connecting.mousePosition = mousePosition
		self:_drawEdges()
	end
end

function ChapterFlowView:_sceneAtInput(mousePosition)
	for sceneId, ports in pairs(self.ports) do
		local port = ports.input
		if port and port.button and port.button.Parent then
			local position = port.button.AbsolutePosition
			local size = port.button.AbsoluteSize
			if mousePosition.X >= position.X and mousePosition.X <= position.X + size.X
				and mousePosition.Y >= position.Y and mousePosition.Y <= position.Y + size.Y then
				return sceneId
			end
		end
	end

	return nil
end

function ChapterFlowView:_endConnection(mousePosition)
	local connection = self.connecting
	self.connecting = nil

	if not connection then
		return
	end

	local destinationSceneId = self:_sceneAtInput(mousePosition)
	if not destinationSceneId then
		self:render()
		return
	end

	local changed = false
	if connection.kind == "next" then
		changed = ProjectStore.setSceneNext(self.chapterId, connection.scene.id, destinationSceneId)
	elseif connection.kind == "exit" then
		changed = ProjectStore.setExitDestination(self.chapterId, connection.scene.id, connection.link.interactionId, destinationSceneId)
	end

	if not changed then
		self.app:notify("That connection is not valid for this scene.", Theme.Danger)
	end

	self:render()
end

--------------------------------------------------------------------------------
-- Nodes
--------------------------------------------------------------------------------

function ChapterFlowView:_flowLocation(scene, link)
	local anchor = link.anchor or {}
	local owner = link.owner == "outro" and "Outro" or "Intro"
	if link.owner == "interaction" then
		local interaction = Schema.findInteraction(scene, link.interactionId)
		owner = interaction and interaction.name or "Interaction"
		if anchor.kind == "Complete" then
			owner = owner .. " completion"
		end
	end

	if anchor.kind == "Timed" then
		return string.format("%s at %.2fs", owner, link.eventTime or 0)
	elseif anchor.kind == "Dialogue" then
		return string.format("%s line %d", owner, anchor.entryIndex or 1)
	end

	return owner
end

function ChapterFlowView:_makePort(node, name, x, y, color, active)
	local button = Widgets.create("TextButton", {
		Name = name,
		Text = "",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset(x, y),
		Size = UDim2.fromOffset(16, 16),
		BackgroundColor3 = color,
		BackgroundTransparency = active and 0 or 0.55,
		BorderSizePixel = 0,
		AutoButtonColor = false,
		ZIndex = 17,
		Parent = node,
	}, { Widgets.corner(8), Widgets.stroke(Theme.PanelAlt, 2, 0) })

	return { button = button, x = x, y = y }
end

function ChapterFlowView:_portKey(link)
	if link.kind == "next" then
		return "next"
	end

	return link.kind .. ":" .. link.id
end

function ChapterFlowView:_buildNode(scene, chapter)
	local app = self.app
	local isStart = chapter.startSceneId == scene.id
	local isSelected = self.selectedSceneId == scene.id
	local color = KIND_COLORS[scene.stage.kind]
	local links = Schema.sceneLinks(scene)
	local markers = Schema.sceneFlowMarkers(scene)
	local routes = {}
	local normalLink = nil

	for _, link in ipairs(links) do
		if link.kind == "next" then
			normalLink = link
		else
			table.insert(routes, link)
		end
	end
	for _, marker in ipairs(markers) do
		table.insert(routes, marker)
	end

	local node = Widgets.panel({
		Name = "Node_" .. scene.id,
		Position = UDim2.fromOffset(scene.flow.x, scene.flow.y),
		Size = UDim2.fromOffset(NODE_WIDTH, self:_nodeHeight(scene)),
		BackgroundColor3 = Theme.Row,
		Radius = 8,
		ZIndex = 13,
		Parent = self.nodeLayer,
	}, { Widgets.stroke(isSelected and Theme.Accent or color, isSelected and 2 or 1, isSelected and 0 or 0.5) })

	self.nodes[scene.id] = node
	self.ports[scene.id] = { outputs = {} }

	local header = Widgets.create("TextButton", {
		Name = "Header",
		Text = "",
		Size = UDim2.new(1, 0, 0, 30),
		BackgroundColor3 = color,
		BackgroundTransparency = 0.75,
		BorderSizePixel = 0,
		AutoButtonColor = false,
		ZIndex = 14,
		Parent = node,
	}, { Widgets.corner(8) })

	local lastClick = 0
	header.MouseButton1Down:Connect(function()
		self.selectedSceneId = scene.id
		local now = os.clock()
		if now - lastClick < 0.35 then
			self.dragging = nil
			app:openScene(self.chapterId, scene.id)
			return
		end
		lastClick = now
		self:_beginDrag(scene, node, self:_mouseGuiPosition())
	end)

	Widgets.label({
		Text = scene.name,
		Position = UDim2.new(0, 10, 0, 0),
		Size = UDim2.new(1, -70, 1, 0),
		Font = Theme.FontBold,
		TextSize = 12,
		ZIndex = 15,
		Parent = header,
	})

	Widgets.label({
		Text = scene.stage.kind,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -8, 0.5, 0),
		Size = UDim2.new(0, 60, 0, 16),
		TextXAlignment = Enum.TextXAlignment.Right,
		TextSize = 9,
		Font = Theme.FontBold,
		TextColor3 = color,
		ZIndex = 15,
		Parent = header,
	})

	self.ports[scene.id].input = self:_makePort(node, "Input", 0, 48, Theme.Good, true)
	Widgets.label({
		Text = "IN",
		Position = UDim2.new(0, 10, 0, 41),
		Size = UDim2.fromOffset(26, 14),
		TextSize = 9,
		Font = Theme.FontBold,
		TextColor3 = Theme.Good,
		ZIndex = 15,
		Parent = node,
	})

	local canSetNext = scene.stage.kind == "Novel2D"
	local nextPort = self:_makePort(node, "Next", NODE_WIDTH, 48, LINK_COLORS.next, canSetNext)
	self.ports[scene.id].outputs.next = nextPort
	nextPort.button.MouseButton1Down:Connect(function()
		if canSetNext then
			self:_beginConnection(scene, "next", normalLink)
		else
			app:notify("Normal next-scene flow is available to Novel2D scenes. Use an Exit or Go To Scene effect for 3D scenes.", Theme.Danger)
		end
	end)
	nextPort.button.MouseButton2Click:Connect(function()
		if normalLink then
			self:_showConnectionMenu(scene, normalLink, nextPort.button)
		end
	end)

	Widgets.label({
		Text = canSetNext and (normalLink and "NEXT" or "NEXT · UNSET") or "NEXT (N/A)",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -10, 0, 41),
		Size = UDim2.fromOffset(76, 14),
		TextXAlignment = Enum.TextXAlignment.Right,
		TextSize = 9,
		Font = Theme.FontBold,
		TextColor3 = canSetNext and LINK_COLORS.next or Theme.TextFaint,
		ZIndex = 15,
		Parent = node,
	})

	if isStart then
		Widgets.label({
			Text = "START",
			Position = UDim2.new(0, 10, 0, 31),
			Size = UDim2.fromOffset(44, 12),
			TextSize = 9,
			Font = Theme.FontBold,
			TextColor3 = Theme.Good,
			ZIndex = 15,
			Parent = node,
		})
	end

	local summary = string.format("%d lines  .  %d effects", Schema.countLines(scene), Schema.countEvents(scene))
	Widgets.label({
		Text = summary,
		Position = UDim2.new(0, isStart and 56 or 10, 0, 31),
		Size = UDim2.new(1, -(isStart and 66 or 86), 0, 12),
		TextSize = 9,
		TextColor3 = Theme.TextDim,
		ZIndex = 14,
		Parent = node,
	})

	for index, route in ipairs(routes) do
		local y = 68 + (index - 1) * ROUTE_ROW_HEIGHT
		local routeColor = route.kind == "end" and LINK_COLORS.finish or LINK_COLORS[route.kind]
		local port = self:_makePort(node, "Route_" .. route.id, NODE_WIDTH, y, routeColor, true)
		self.ports[scene.id].outputs[self:_portKey(route)] = port

		local routeText
		if route.kind == "goto" then
			routeText = "GO TO  .  " .. self:_flowLocation(scene, route) .. (route.toSceneId == "" and "  .  unassigned" or "")
		elseif route.kind == "end" then
			routeText = "END CHAPTER  .  " .. self:_flowLocation(scene, route)
		else
			routeText = route.label .. (route.conditional and "  .  conditional" or "") .. (route.toSceneId == "" and "  .  unassigned" or "")
		end

		Widgets.label({
			Text = routeText,
			Position = UDim2.new(0, 10, 0, y - 7),
			Size = UDim2.new(1, -30, 0, 14),
			TextXAlignment = Enum.TextXAlignment.Right,
			TextTruncate = Enum.TextTruncate.AtEnd,
			TextSize = 9,
			TextColor3 = routeColor,
			ZIndex = 15,
			Parent = node,
		})

		if route.kind == "exit" then
			port.button.MouseButton1Down:Connect(function()
				self:_beginConnection(scene, "exit", route)
			end)
		else
			port.button.MouseButton1Click:Connect(function()
				app:openFlowEvent(self.chapterId, scene.id, route)
			end)
		end

		port.button.MouseButton2Click:Connect(function()
			self:_showConnectionMenu(scene, route, port.button)
		end)
	end

	local actions = Widgets.create("Frame", {
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 8, 1, -6),
		Size = UDim2.new(1, -16, 0, 20),
		BackgroundTransparency = 1,
		ZIndex = 14,
		Parent = node,
	}, { Widgets.hlist(4) })

	local function small(text, width, color2, onClick, order)
		Widgets.button({
			Text = text,
			Size = UDim2.new(0, width, 1, 0),
			Color = color2 or Theme.Button,
			TextSize = 10,
			Radius = 4,
			ZIndex = 15,
			LayoutOrder = order,
			OnClick = onClick,
			Parent = actions,
		})
	end

	small("Open", 46, Theme.Accent, function()
		app:openScene(self.chapterId, scene.id)
	end, 1)
	small("Start", 42, isStart and Theme.Good or nil, function()
		ProjectStore.setStartScene(self.chapterId, scene.id)
		self:render()
	end, 2)
	small("Play", 40, nil, function()
		app:playChapter(self.chapterId, scene.id)
	end, 3)
	small("Dup", 36, nil, function()
		ProjectStore.duplicateScene(self.chapterId, scene.id)
		self:render()
	end, 4)
	small("x", 22, Theme.Danger, function()
		app:showConfirm("Delete " .. scene.name .. "?", "It moves to the recycle bin. Incoming flow destinations are cleared, while timeline effects remain available to retarget.", function()
			ProjectStore.deleteScene(self.chapterId, scene.id)
			self:render()
		end)
	end, 5)
end

--------------------------------------------------------------------------------
-- Edges and connection menus
--------------------------------------------------------------------------------

function ChapterFlowView:_portCanvasPoint(sceneId, port)
	local node = self.nodes[sceneId]
	if not node or not port then
		return nil
	end

	local position = node.Position
	return Vector2.new(position.X.Offset + port.x, position.Y.Offset + port.y)
end

function ChapterFlowView:_drawSegment(first, second, color, thickness, onContext)
	local delta = second - first
	local length = delta.Magnitude
	if length < 0.5 then
		return
	end

	local properties = {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset((first.X + second.X) / 2, (first.Y + second.Y) / 2),
		Size = UDim2.fromOffset(length, thickness),
		Rotation = math.deg(math.atan2(delta.Y, delta.X)),
		BackgroundColor3 = color,
		BackgroundTransparency = 0.1,
		BorderSizePixel = 0,
		ZIndex = 11,
		Parent = self.edgeLayer,
	}
	if onContext then
		properties.Text = ""
		properties.AutoButtonColor = false
	end

	local segment = Widgets.create(onContext and "TextButton" or "Frame", properties)
	if onContext then
		segment.MouseButton2Click:Connect(function()
			onContext(segment)
		end)
	end
end

function ChapterFlowView:_drawWire(start, finish, color, dashed, onContext)
	local bend = math.max(54, math.abs(finish.X - start.X) * 0.45)
	local controlA = start + Vector2.new(bend, 0)
	local controlB = finish - Vector2.new(bend, 0)
	local function curve(t)
		local inverse = 1 - t
		return start * (inverse * inverse * inverse)
			+ controlA * (3 * inverse * inverse * t)
			+ controlB * (3 * inverse * t * t)
			+ finish * (t * t * t)
	end

	local previous = curve(0)
	for index = 1, 16 do
		local current = curve(index / 16)
		if not dashed or index % 2 == 1 then
			self:_drawSegment(previous, current, color, dashed and 2 or 3, onContext)
		end
		previous = current
	end

	local tangent = finish - controlB
	local angle = tangent.Magnitude > 0 and math.deg(math.atan2(tangent.Y, tangent.X)) or 0
	Widgets.create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset(finish.X - 4, finish.Y),
		Size = UDim2.fromOffset(8, 8),
		Rotation = angle + 45,
		BackgroundColor3 = color,
		BorderSizePixel = 0,
		ZIndex = 11,
		Parent = self.edgeLayer,
	})

	return curve(0.5)
end

function ChapterFlowView:_transitionItems(items)
	table.insert(items, { id = "transition:", label = "Transition: Cut" })
	for _, preset in ipairs(ProjectStore.getProject().transitionPresets) do
		table.insert(items, { id = "transition:" .. preset.id, label = "Transition: " .. preset.name })
	end
end

function ChapterFlowView:_showConnectionMenu(scene, link, anchor)
	local items = {}
	if link.kind == "next" then
		table.insert(items, { id = "open", label = "Open scene settings" })
		self:_transitionItems(items)
		table.insert(items, { id = "delete", label = "Delete normal connection", color = Theme.Danger })
	elseif link.kind == "exit" then
		table.insert(items, { id = "open", label = "Open Exit settings" })
		self:_transitionItems(items)
		table.insert(items, { id = "delete", label = "Disconnect Exit" , color = Theme.Danger })
	elseif link.kind == "goto" then
		table.insert(items, { id = "open", label = "Locate Go To Scene effect" })
		self:_transitionItems(items)
		table.insert(items, { id = "delete", label = "Delete Go To Scene effect", color = Theme.Danger })
	else
		table.insert(items, { id = "open", label = "Locate End Chapter effect" })
		table.insert(items, { id = "delete", label = "Delete End Chapter effect", color = Theme.Danger })
	end

	Widgets.popupList(self.app.gui, anchor, items, function(action)
		if action == "open" then
			if link.kind == "next" then
				self.app:openScene(self.chapterId, scene.id)
			elseif link.kind == "exit" then
				self.app:openInteraction(self.chapterId, scene.id, link.interactionId)
			else
				self.app:openFlowEvent(self.chapterId, scene.id, link)
			end
			return
		end

		local transitionId = action:match("^transition:(.*)$")
		if transitionId ~= nil then
			if link.kind == "next" then
				ProjectStore.setSceneNextTransition(self.chapterId, scene.id, transitionId)
			elseif link.kind == "exit" then
				ProjectStore.setExitTransition(self.chapterId, scene.id, link.interactionId, transitionId)
			elseif link.kind == "goto" then
				ProjectStore.setFlowGotoTransition(self.chapterId, scene.id, link.eventId, transitionId)
			end
			self:render()
			return
		end

		if action == "delete" then
			if link.kind == "next" then
				ProjectStore.setSceneNext(self.chapterId, scene.id, "")
				self:render()
			elseif link.kind == "exit" then
				ProjectStore.setExitDestination(self.chapterId, scene.id, link.interactionId, "")
				self:render()
			else
				local effectName = link.kind == "goto" and "Go To Scene" or "End Chapter"
				self.app:showConfirm("Delete " .. effectName .. "?", "This removes the timeline effect itself.", function()
					ProjectStore.deleteFlowEvent(self.chapterId, scene.id, link.eventId)
					self:render()
				end)
			end
		end
	end, { width = 230, maxRows = 9 })
end

function ChapterFlowView:_drawConnectionLabel(scene, link, position, color)
	local transition = Schema.findTransition(ProjectStore.getProject(), link.transitionId)
	local text = string.format("%s  .  %s", link.label, transition and transition.name or "cut")
	if link.kind == "goto" then
		text = text .. "  .  " .. self:_flowLocation(scene, link)
	elseif link.conditional then
		text = text .. "  .  conditional"
	end

	local label = Widgets.create("TextButton", {
		Name = "Connection_" .. link.kind .. "_" .. link.id,
		Text = text,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.fromOffset(position.X, position.Y - 5),
		Size = UDim2.fromOffset(210, 17),
		BackgroundColor3 = Theme.PanelAlt,
		BackgroundTransparency = 0.67,
		BorderSizePixel = 0,
		TextColor3 = color,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextSize = 9,
		ZIndex = 16,
		Parent = self.edgeLayer,
	}, { Widgets.corner(4), Widgets.stroke(color, 1, 0.45) })

	label.MouseButton2Click:Connect(function()
		self:_showConnectionMenu(scene, link, label)
	end)
end

function ChapterFlowView:_drawEdges()
	local chapter = self:_chapter()
	Widgets.clearChildren(self.edgeLayer)
	if not chapter then
		return
	end

	for _, scene in ipairs(chapter.scenes) do
		local ports = self.ports[scene.id]
		if ports then
			for index, link in ipairs(Schema.sceneLinks(scene)) do
				local source = ports.outputs[self:_portKey(link)]
				local destinationPorts = self.ports[link.toSceneId]
				if source and destinationPorts and destinationPorts.input then
					local start = self:_portCanvasPoint(scene.id, source)
					local finish = self:_portCanvasPoint(link.toSceneId, destinationPorts.input)
					local color = LINK_COLORS[link.kind]
					local midpoint = self:_drawWire(start, finish, color, link.kind == "goto", function(anchor)
						self:_showConnectionMenu(scene, link, anchor)
					end)
					self:_drawConnectionLabel(scene, link, midpoint + Vector2.new(0, (index - 1) * 16), color)
				end
			end
		end
	end

	if self.connecting then
		local sourcePorts = self.ports[self.connecting.scene.id]
		local sourceKey = self.connecting.kind == "next" and "next" or self:_portKey(self.connecting.link)
		local source = sourcePorts and sourcePorts.outputs[sourceKey]
		if source then
			local start = self:_portCanvasPoint(self.connecting.scene.id, source)
			local origin = self.edgeLayer.AbsolutePosition
			local mouse = self.connecting.mousePosition
			local finish = Vector2.new(mouse.X - origin.X, mouse.Y - origin.Y)
			self:_drawWire(start, finish, LINK_COLORS[self.connecting.kind], true)
		end
	end
end

--------------------------------------------------------------------------------
-- Flags
--------------------------------------------------------------------------------

function ChapterFlowView:_renderFlags(chapter)
	local app = self.app

	Widgets.clearChildren(self.flagList)
	Widgets.clearChildren(self.flagFooter)

	if #chapter.flags == 0 then
		Widgets.hint("Flags remember what the player did. Conditions read them; Set Flag and Increment events write them.", self.flagList, 56).ZIndex = 13
	end

	for index, flag in ipairs(chapter.flags) do
		local row = Widgets.create("Frame", {
			Size = UDim2.new(1, -6, 0, 48),
			BackgroundColor3 = Theme.Row,
			BorderSizePixel = 0,
			LayoutOrder = index,
			ZIndex = 13,
			Parent = self.flagList,
		}, { Widgets.corner(4), Widgets.padding(6, 8, 6, 8) })

		Widgets.label({
			Text = flag.id,
			Size = UDim2.new(1, -30, 0, 16),
			Font = Theme.FontBold,
			TextSize = 12,
			ZIndex = 14,
			Parent = row,
		})

		Widgets.button({
			Text = "x",
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, 0, 0, 0),
			Size = UDim2.new(0, 20, 0, 18),
			Color = Theme.Danger,
			TextSize = 10,
			ZIndex = 14,
			OnClick = function()
				ProjectStore.removeFlag(chapter.id, flag.id)
				self:render()
			end,
			Parent = row,
		})

		Widgets.segmented({
			Options = { { id = "bool", label = "bool" }, { id = "int", label = "int" } },
			Value = flag.kind,
			Position = UDim2.new(0, 0, 0, 20),
			Size = UDim2.new(0, 110, 0, 18),
			ZIndex = 14,
			OnPick = function(kind)
				ProjectStore.updateFlag(chapter.id, flag.id, { kind = kind })
				self:render()
			end,
			Parent = row,
		})

		if flag.kind == "bool" then
			Widgets.toggle({
				AnchorPoint = Vector2.new(1, 0),
				Position = UDim2.new(1, 0, 0, 20),
				Size = UDim2.new(0, 44, 0, 18),
				Value = flag.default == true,
				ZIndex = 14,
				OnToggle = function(next)
					ProjectStore.updateFlag(chapter.id, flag.id, { default = next })
					self:render()
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
				ZIndex = 14,
				OnCommit = function(text)
					ProjectStore.updateFlag(chapter.id, flag.id, { default = tonumber(text) or 0 })
					self:render()
				end,
				Parent = row,
			})
		end
	end

	Widgets.label({
		Text = "default values are what a new playthrough starts with",
		Size = UDim2.new(1, 0, 0, 14),
		TextSize = 10,
		TextColor3 = Theme.TextFaint,
		ZIndex = 13,
		Parent = self.flagFooter,
	})

	if self.addingFlag then
		local box
		box = Widgets.textBox({
			PlaceholderText = "flagName (letters, no spaces)",
			Position = UDim2.new(0, 0, 0, 20),
			Size = UDim2.new(1, 0, 0, 26),
			TextYAlignment = Enum.TextYAlignment.Center,
			ZIndex = 13,
			OnCommit = function(text, enterPressed)
				self.addingFlag = false
				if enterPressed then
					local id = Schema.trimName(text):gsub("%s+", "_")
					if not ProjectStore.addFlag(chapter.id, id, "bool") then
						app:notify("Flag names must be unique and not empty.", Theme.Danger)
					end
				end
				self:render()
			end,
			Parent = self.flagFooter,
		})
		task.defer(function()
			if box.Parent then
				box:CaptureFocus()
			end
		end)
	else
		Widgets.button({
			Text = "+ Flag",
			Position = UDim2.new(0, 0, 0, 20),
			Size = UDim2.new(1, 0, 0, 26),
			Color = Theme.Accent,
			TextSize = 11,
			ZIndex = 13,
			OnClick = function()
				self.addingFlag = true
				self:render()
			end,
			Parent = self.flagFooter,
		})
	end
end

--------------------------------------------------------------------------------
-- Render
--------------------------------------------------------------------------------

function ChapterFlowView:render()
	local chapter = self:_chapter()

	Widgets.clearChildren(self.nodeLayer)
	self.nodes = {}
	self.ports = {}

	if not chapter then
		Widgets.clearChildren(self.edgeLayer)
		return
	end

	self.nameBox.Text = chapter.name

	local maxX, maxY = 800, 600
	for _, scene in ipairs(chapter.scenes) do
		self:_buildNode(scene, chapter)
		maxX = math.max(maxX, scene.flow.x + NODE_WIDTH + 400)
		maxY = math.max(maxY, scene.flow.y + self:_nodeHeight(scene) + 300)
	end

	self.canvas.CanvasSize = UDim2.fromOffset(maxX, maxY)
	self.edgeLayer.Size = UDim2.fromOffset(maxX, maxY)
	self.nodeLayer.Size = UDim2.fromOffset(maxX, maxY)

	self:_drawEdges()
	self:_renderFlags(chapter)
end

function ChapterFlowView:destroy()
	self.moveConnection:Disconnect()
	self.releaseConnection:Disconnect()
	self.root:Destroy()
end

return ChapterFlowView
