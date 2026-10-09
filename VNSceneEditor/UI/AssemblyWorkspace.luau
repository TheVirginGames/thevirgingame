-- Dedicated room choreography editor. The preview uses the runtime session.
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local root = script.Parent.Parent
local Assembly = require(root.Core.RoomAssembly)
local Schema = require(root.Core.Schema)
local Store = require(root.Core.ProjectStore)
local Evaluator = require(root.Runtime.AssemblyEvaluator)
local Bindings = require(root.Render.WorldBindings)
local Widgets = require(script.Parent.Widgets)
local Theme = require(script.Parent.Theme)
local View = {}
View.__index = View
local function vecText(v) return table.concat(v, ", ") end
local function parseVector(text, count)
	local result = {}
	for token in text:gmatch("[^,]+") do
		local n = tonumber(token)
		if not n or n ~= n or math.abs(n) == math.huge then return nil end
		table.insert(result, n)
	end
	return #result == count and result or nil
end
local function pointIn(instance, point)
	if not instance or not instance.Visible then return false end
	local position, size = instance.AbsolutePosition, instance.AbsoluteSize
	return point.X >= position.X and point.Y >= position.Y
		and point.X <= position.X + size.X and point.Y <= position.Y + size.Y
end

-- A Room Definition owns rendered geometry, not merely the selected Instance.
-- Models/Folders and their descendants therefore overlap even when every
-- object has a unique name.  Keep this test beside the editor picker so a
-- marquee selection cannot create a definition the renderer has to recover.
local function geometryParts(instance)
	local parts = {}
	if instance and instance:IsA("BasePart") then table.insert(parts, instance) end
	if instance then
		for _, descendant in ipairs(instance:GetDescendants()) do
			if descendant:IsA("BasePart") then table.insert(parts, descendant) end
		end
	end
	return parts
end

local function referenceLabel(group)
	local path = group.reference and group.reference.path
	if type(path) ~= "table" or #path == 0 then return "Virtual group" end
	local last = path[#path]
	local parent = path[#path - 1]
	local name = tostring(last.name or group.name)
	if parent then name = tostring(parent.name) .. " / " .. name end
	if last.ordinal and last.ordinal > 1 then name ..= " #" .. tostring(last.ordinal) end
	return name
end

-- Preserve the identity owned by project.roomDefinitions while replacing its
-- contents. Other editor systems hold references to that table.
local function reconcile(target, source)
	for key in pairs(target) do if source[key] == nil then target[key] = nil end end
	for key, value in pairs(source) do
		if type(value) == "table" and type(target[key]) == "table" then reconcile(target[key], value)
		else target[key] = value end
	end
end

local function compiledMarker(compiled, group, marker)
	local node = compiled and compiled.groups[group.id]
	if not node then return 0 end
	if marker == "Start" then return node.start end
	if marker == "Impact" then return node.start + group.motion.duration * group.motion.impact end
	return node.start + node.length
end
function View.new(app)
	local self = setmetatable({ app = app, time = 0, order = 0, generateMode = "Generate" }, View)
	self.panel = Widgets.create("Frame", { Name = "RoomAssemblyWorkspace", Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Visible = false, Parent = app.gui })
	self.header = Widgets.panel({ Size = UDim2.new(1, -24, 0, 66), Position = UDim2.fromOffset(12, 10), Parent = self.panel }, { Widgets.padding(5) })
	self.generateMenu = Widgets.panel({ Visible = false, Position = UDim2.fromOffset(170, 76), Size = UDim2.fromOffset(182, 92), ZIndex = 15, Parent = self.panel }, { Widgets.padding(5), Widgets.vlist(4) })
	Widgets.button({ Text = "Generate", Size = UDim2.new(1, 0, 0, 24), TextSize = 11, ZIndex = 16, OnClick = function() self:setGenerateMode("Generate") end, Parent = self.generateMenu })
	Widgets.button({ Text = "Randomize variation", Size = UDim2.new(1, 0, 0, 24), TextSize = 11, ZIndex = 16, OnClick = function() self:setGenerateMode("Randomize") end, Parent = self.generateMenu })
	Widgets.button({ Text = "Repeat last variation", Size = UDim2.new(1, 0, 0, 24), TextSize = 11, ZIndex = 16, OnClick = function() self:setGenerateMode("Repeat variation") end, Parent = self.generateMenu })
	self:buildHeader()
	self.left = Widgets.scroll({ Position = UDim2.fromOffset(12, 88), Size = UDim2.new(0, 215, 1, -292), BackgroundColor3 = Theme.Panel, BackgroundTransparency = 0.05, Parent = self.panel }, { Widgets.vlist(5), Widgets.padding(8) })
	self.right = Widgets.scroll({ AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -12, 0, 88), Size = UDim2.new(0, 285, 1, -292), BackgroundColor3 = Theme.Panel, BackgroundTransparency = 0.05, Parent = self.panel }, { Widgets.vlist(5), Widgets.padding(8) })
	self.timeline = Widgets.scroll({ Position = UDim2.new(0, 12, 1, -194), Size = UDim2.new(1, -24, 0, 182), BackgroundColor3 = Theme.Panel, BackgroundTransparency = 0, Parent = self.panel }, { Widgets.vlist(4), Widgets.padding(8) })
	self.status = Widgets.label({ Position = UDim2.new(0, 240, 0, 89), Size = UDim2.new(1, -550, 0, 48), TextWrapped = true, Text = "", Parent = self.panel })
	self.inputConnection = UserInputService.InputBegan:Connect(function(input, processed)
		if processed or not self.panel.Visible or input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
		local point = UserInputService:GetMouseLocation()
		if pointIn(self.header, point) or pointIn(self.generateMenu, point) or pointIn(self.left, point) or pointIn(self.right, point)
			or pointIn(self.timeline, point) or pointIn(self.status, point) then return end
		self:selectComponentAtCursor()
	end)
	self.connection = RunService.RenderStepped:Connect(function(dt)
		if not self.panel.Visible then return end
		if self.dragBar and UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1) then
			local bar = self.dragBar
			local t = math.clamp((UserInputService:GetMouseLocation().X-bar.AbsolutePosition.X)/math.max(1,bar.AbsoluteSize.X),0,1)
			self:seek(t * self.duration)
		else self.dragBar = nil end
		if self.playing then
			self:seek(self.time + dt, true, true)
			if self.time >= self.duration then
				self.playing = false
				self:seek(self.time, nil, false)
			end
		end
		if self.cursor and self.duration then self.cursor.Position = UDim2.new(self.time / self.duration, 0, 0, 0) end
	end)
	return self
end

function View:buildHeader()
	Widgets.clearChildren(self.header)
	local actions = {
		{ "Back", function() self:close() end },
		{ "Pick component", function() self:pick(false) end },
		{ "Pick room", function() self:pick(true) end },
		{ "+ Empty group", function() self:addEmptyGroup() end },
		{ self.generateMode or "Generate", function() self:runGenerateMode() end },
		{ "v", function() self.generateMenu.Visible = not self.generateMenu.Visible end },
		{ "Play / Pause", function() self:play() end },
		{ "Replay", function() self:stop(); self.time = 0; self:play() end },
		{ "Final room", function() self:stop() end },
		{ "Compare", function() self:toggleCompare() end },
		{ "Validate", function() self:showValidation() end },
		{ "Undo", function() self:undo() end },
		{ "Redo", function() self:redo() end },
		{ "Duplicate", function() self:duplicateDefinition() end },
		{ "Save", function() self:save() end },
	}
	for index, action in ipairs(actions) do
		local column = (index - 1) % 8
		local row = math.floor((index - 1) / 8)
		Widgets.button({ Text = action[1], Position = UDim2.new(column / 8, 1, row / 2, 1), Size = UDim2.new(1 / 8, -3, 0.5, -3), TextSize = 10, OnClick = action[2], Parent = self.header })
	end
end

function View:beginHistory()
	self.history = { Assembly.copy(self.definition) }
	self.historyIndex = 1
end

function View:recordHistory()
	if self.restoringHistory or not self.definition then return end
	self.history = self.history or {}
	for index = #self.history, (self.historyIndex or 0) + 1, -1 do table.remove(self.history, index) end
	table.insert(self.history, Assembly.copy(self.definition))
	self.historyIndex = #self.history
	-- Enough room for natural experimentation without retaining an unlimited
	-- clone of every definition after a long editing session.
	if #self.history > 40 then
		table.remove(self.history, 1)
		self.historyIndex -= 1
	end
end

function View:restoreHistory(index)
	local snapshot = self.history and self.history[index]
	if not snapshot or not self.definition then return end
	self:stop()
	self.restoringHistory = true
	reconcile(self.definition, Assembly.copy(snapshot))
	self.restoringHistory = false
	self.historyIndex = index
	if self.selected and not Schema.findById(self.definition.groups, self.selected) then self.selected = nil end
	local compiled = Evaluator.compile(self.definition)
	self.duration = compiled and compiled.duration or 0
	self.time = math.clamp(self.time or self.duration, 0, self.duration)
	Store.markChanged()
	self:render()
end
function View:undo() if self.historyIndex and self.historyIndex > 1 then self:restoreHistory(self.historyIndex - 1) end end
function View:redo() if self.history and self.historyIndex and self.historyIndex < #self.history then self:restoreHistory(self.historyIndex + 1) end end

function View:addEmptyGroup(parentId)
	if not self.definition then return end
	local group = Assembly.group("Group")
	group.reference = nil
	group.parentId = parentId or ""
	table.insert(self.definition.groups, group)
	self.selected = group.id
	self:changed(true)
end

function View:makeParent(group)
	local parent = Assembly.group(group.name .. " group")
	parent.reference = nil
	parent.role = group.role
	parent.parentId = group.parentId
	group.parentId = parent.id
	local _, index = Schema.findById(self.definition.groups, group.id)
	table.insert(self.definition.groups, index or (#self.definition.groups + 1), parent)
	self.selected = parent.id
	self:changed(true)
end

function View:setGenerateMode(mode)
	self.generateMode = mode
	self.generateMenu.Visible = false
	self:buildHeader()
end

function View:runGenerateMode()
	if self.generateMode == "Randomize" then return self:generate(true) end
	if self.generateMode == "Repeat variation" then
		return self:generate(true, self.definition and self.definition.variationSeed)
	end
	return self:generate(false)
end

function View:generate(randomized, seed)
	if not self.definition then return end
	self.generateMenu.Visible = false
	local title = randomized and "Randomize choreography" or "Generate choreography"
	local description = randomized
		and "Replace the group motions using their roles, then make a restrained saved variation?"
		or "Replace group motions and timings using their roles?"
	self.app:showConfirm(title, description, function()
		self:stop()
		if randomized then Assembly.randomize(self.definition, seed) else Assembly.generate(self.definition) end
		self:changed(true)
		self.status.Text = randomized and "Variation generated. It is saved as ordinary editable motion data." or "Role choreography generated."
	end)
end

function View:toggleCompare()
	if not self.definition then return end
	local session = self.app.presenter.assemblySession
	if not session then
		self:seek(self.time)
		session = self.app.presenter.assemblySession
	end
	if session then
		local compare = not session.compareFinal
		session:setCompareFinal(compare)
		if not compare then self:seek(self.time) end
		self.status.Text = compare and "Comparing the authored final room. Click Compare again to return to the assembly pose." or "Assembly preview restored."
	end
end

function View:validateDefinition()
	local result = { errors = {}, warnings = {} }
	local compiled, compileError = Evaluator.compile(self.definition)
	if not compiled then table.insert(result.errors, tostring(compileError)) end
	if #self.definition.groups == 0 then table.insert(result.warnings, "No components are assigned. Pick a room or individual geometry first.") end
	local claimed, claimedParts = {}, {}
	for _, group in ipairs(self.definition.groups) do
		if group.reference then
			local source, err = Bindings.resolveStrict(group.reference)
			if not source then
				local message = group.name .. ": " .. tostring(err)
				if group.required then table.insert(result.errors, message) else table.insert(result.warnings, message) end
			elseif claimed[source] then
				table.insert(result.warnings, group.name .. " overlaps " .. claimed[source] .. ". The first component renders; this duplicate is skipped.")
			else
				claimed[source] = group.name
				local owners = {}
				for _, part in ipairs(geometryParts(source)) do
					if claimedParts[part] and claimedParts[part] ~= group.name then owners[claimedParts[part]] = true end
				end
				local names = {}
				for owner in pairs(owners) do table.insert(names, owner) end
				table.sort(names)
				if #names > 0 then
					table.insert(result.warnings, group.name .. " shares geometry with " .. table.concat(names, ", ") .. ". Use Repair overlaps to remove the later duplicate.")
				end
				for _, part in ipairs(geometryParts(source)) do
					claimedParts[part] = claimedParts[part] or group.name
				end
			end
		elseif group.parentId == "" then
			table.insert(result.warnings, group.name .. " is a virtual group without a parent. It has no geometry of its own.")
		end
	end
	for _, reference in ipairs(self.definition.hideReferences) do
		local _, err = Bindings.resolveStrict(reference)
		if err then table.insert(result.warnings, "Additional hidden object: " .. tostring(err)) end
	end
	return result
end

-- Removes the *later* component when two definition entries claim any of the
-- same parts. This follows the renderer's deterministic first-owner rule and
-- is intentionally undoable through the workspace history.
function View:repairOverlaps()
	if not self.definition then return end
	local claimed, removeIds, removed = {}, {}, {}
	for _, group in ipairs(self.definition.groups) do
		if group.reference then
			local source = Bindings.resolveStrict(group.reference)
			if source then
				local overlaps = false
				for _, part in ipairs(geometryParts(source)) do
					if claimed[part] then overlaps = true; break end
				end
				if overlaps then
					removeIds[group.id] = true
					table.insert(removed, group.name)
				else
					for _, part in ipairs(geometryParts(source)) do claimed[part] = group.id end
				end
			end
		end
	end
	if #removed == 0 then
		self.status.Text = "No overlapping component entries were found."
		return
	end
	for index = #self.definition.groups, 1, -1 do
		if removeIds[self.definition.groups[index].id] then table.remove(self.definition.groups, index) end
	end
	for _, group in ipairs(self.definition.groups) do
		if removeIds[group.parentId] then group.parentId = "" end
		if removeIds[group.sync.groupId] then group.sync.groupId = "" end
	end
	if self.selected and removeIds[self.selected] then self.selected = nil end
	self:changed(true)
	self.status.Text = "Removed " .. tostring(#removed) .. " later overlapping component" .. (#removed == 1 and ". Use Undo if needed." or "s. Use Undo if needed.")
end

function View:showValidation()
	self.validationVisible = true
	self.selected = nil
	self:render()
end

function View:duplicateDefinition()
	if not self.definition then return end
	local duplicate = Assembly.duplicate(self.definition)
	local project = self.app:getProject()
	local list = self.isTemplate and project.assemblyPresets or project.roomDefinitions
	table.insert(list, duplicate)
	if not self.isTemplate then
		local subscene = self.app:getActiveSubscene()
		if self.app.scene and subscene then
			Schema.assemblyOwner(self.app.scene, subscene).roomDefinitionId = duplicate.id
		end
	end
	self.definition = duplicate
	self.isTemplate = self.isTemplate
	self.selected = nil
	self:beginHistory()
	Store.markChanged()
	self:render()
	self.status.Text = "Created an independent copy. Changes no longer affect the original choreography."
end
function View:save()
	Store.markChanged()
	if self.app.scene and self.returnMode == "scene" then Store.commit(self.app.chapterId, self.app.scene); self.app.dirty = false end
	self.status.Text = "Saved room definition and choreography."
end
function View:open(definition, destinationOverride, cleanup)
	self.returnMode = self.app.mode
	self.savedCamera = self.app.presenter:getRig():getCFrame()
	self.definition = definition; self.selected = nil; self.selectedSourceLabel = nil
	self.destinationOverride = destinationOverride
	self.cleanup = cleanup
	self.isTemplate = table.find(self.app:getProject().assemblyPresets, definition) ~= nil
	self.validationVisible = false
	self.generateMenu.Visible = false
	local compiled = Evaluator.compile(definition)
	self.duration = compiled and compiled.duration or 0
	-- Entering the workspace should show the authored room. Selection is a
	-- selection operation, not a request to jump to the opening frame.
	self.time = self.duration
	self:beginHistory()
	self.app.runner:stop()
	self.app.mode = "assembly"; self.app:_applyMode()
	self.app.presenter:setAssemblyAppearance(definition)
	local destination = self:destination()
	if destination then self.app.presenter:getRig():setCFrame(destination) end
	self:render()
end
function View:close()
	self:stop()
	self:clearIdleHighlights()
	self.app.worldPicker:stop(false)
	self.app.mode = self.returnMode or "scene"
	self.panel.Visible = false
	self.app:_applyMode(); self.app:refresh()
	local active = self.app.scene and self.app:getActiveSubscene()
	local owner = active and Schema.assemblyOwner(self.app.scene, active)
	local definition = owner and type(owner.roomDefinitionId) == "string" and owner.roomDefinitionId ~= ""
		and Schema.findById(self.app:getProject().roomDefinitions, owner.roomDefinitionId) or nil
	self.app.presenter:setAssemblyAppearance(definition)
	if self.savedCamera then self.app.presenter:getRig():setCFrame(self.savedCamera) end
	if self.cleanup then self.cleanup(); self.cleanup = nil end
	self.definition = nil
	self.history = nil
	self.generateMenu.Visible = false
end
function View:stop()
	self.playing = false; self.dragBar = nil
	self.app.presenter:closeAssembly(true)
	if self.guideFolder then self.guideFolder:Destroy(); self.guideFolder = nil end
	if self.panel.Visible then self:showIdleSelection() end
end

function View:clearIdleHighlights()
	if self.idleHighlightFolder then self.idleHighlightFolder:Destroy(); self.idleHighlightFolder = nil end
end

-- Browsing a definition should not acquire the scripted assembly camera lease.
-- Use ordinary world Highlights for the resting room instead.
function View:showIdleSelection()
	self:clearIdleHighlights()
	if not self.definition or not self.selected then return end
	local folder = Instance.new("Folder")
	folder.Name = "VNAssemblyIdleSelection"
	folder.Parent = Workspace
	local function belongsToSelected(groupId)
		local current, seen = groupId, {}
		while current ~= "" and not seen[current] do
			if current == self.selected then return true end
			seen[current] = true
			local group = Schema.findById(self.definition.groups, current)
			current = group and group.parentId or ""
		end
		return false
	end
	local function highlight(adornee)
		local item = Instance.new("Highlight")
		item.Name = "VNAssemblyIdleHighlight"
		item.Adornee = adornee
		item.FillColor = Color3.fromRGB(255, 196, 84)
		item.FillTransparency = 0.86
		item.OutlineColor = Color3.fromRGB(255, 224, 142)
		item.OutlineTransparency = 0
		item.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
		item.Parent = folder
	end
	for _, group in ipairs(self.definition.groups) do
		if group.reference and belongsToSelected(group.id) then
			local source = Bindings.resolveStrict(group.reference)
			if source then
				if source:IsA("PVInstance") then highlight(source)
				else
					for _, descendant in ipairs(source:GetDescendants()) do
						if descendant:IsA("BasePart") then highlight(descendant) end
					end
				end
			end
		end
	end
	self.idleHighlightFolder = folder
end
function View:destination()
	if self.destinationOverride then return self.destinationOverride end
	local subscene = self.app:getActiveSubscene()
	if self.returnMode == "scene" and subscene then
		local pose = Schema.findCameraPose(self.app:getProject(), Schema.effectivePoseId(self.app.scene, subscene))
		if pose then return Schema.decodeCFrame(pose.cframe) or self.savedCamera end
	end
	-- Opening a saved room definition from Presets still has a meaningful
	-- authored location when a Room3D in this project uses it. Prefer that
	-- room's effective pose instead of leaving the editor at its fly/spawn pose.
	if self.definition then
		local project = self.app:getProject()
		for _, chapter in ipairs(project.chapters or {}) do
			for _, scene in ipairs(chapter.scenes or {}) do
				for _, candidate in ipairs(scene.subscenes or {}) do
					local owner = Schema.assemblyOwner(scene, candidate)
					if candidate.kind == "Room3D" and owner and owner.roomDefinitionId == self.definition.id then
						local pose = Schema.findCameraPose(project, Schema.effectivePoseId(scene, candidate))
						if pose then return Schema.decodeCFrame(pose.cframe) or self.savedCamera end
					end
				end
			end
		end
	end
	return self.savedCamera
end
function View:seek(time, sounds, cameraDriven)
	cameraDriven = cameraDriven == true
	local session = self.app.presenter.assemblySession
	if session and session.cameraDriven ~= cameraDriven then
		-- Keep the current pose when changing a preview from cinematic playback
		-- back to free-fly inspection; restoring the opening pose causes a jump.
		self.app.presenter:closeAssembly(false)
		session = nil
	end
	if not session then
		local err
		self:clearIdleHighlights()
		session, err = self.app.presenter:prepareAssembly(self.definition, self:destination(), { cameraDriven = cameraDriven, hideCharacters = cameraDriven })
		if not session then self.status.Text = tostring(err); self.playing = false; return end
		self.sessionWarningCount = #(session.warnings or {})
	end
	self.duration = session.compiled.duration
	session.soloGroup = self.soloSelected and self.selected or nil
	session.selectedGroup = self.selected
	self.time = math.clamp(time, 0, self.duration)
	local ok, err = pcall(function() session:seek(self.time, sounds) end)
	if not ok then self:stop(); self.status.Text = tostring(err); return end
	local note = (self.sessionWarningCount or 0) > 0 and ("  •  " .. tostring(self.sessionWarningCount) .. " assembly note(s); use Validate for details.") or ""
	self.status.Text = string.format("%s   %.2f / %.2fs%s", self.definition.name, self.time, self.duration, note)
end

function View:selectGroup(groupId, sourceLabel)
	if not Schema.findById(self.definition.groups, groupId) then return end
	self.selected = groupId
	self.selectedSourceLabel = sourceLabel or referenceLabel(Schema.findById(self.definition.groups, groupId))
	if self.playing then
		local session = self.app.presenter.assemblySession
		if session then session.selectedGroup = groupId; session:setSelectedGroup(groupId) end
	else
		self:stop()
	end
	self:render()
	-- Put the selected component back into view even for a long definition.
	task.defer(function()
		local row = self.componentRows[groupId]
		if row and self.left and row.Parent then
			local target = math.max(0, row.AbsolutePosition.Y - self.left.AbsolutePosition.Y + self.left.CanvasPosition.Y - 45)
			self.left.CanvasPosition = Vector2.new(0, target)
		end
	end)
end

function View:selectComponentAtCursor()
	local session = self.app.presenter.assemblySession
	if not session then
		self:seek(self.time)
		session = self.app.presenter.assemblySession
	end
	if not session then return end
	local camera = Workspace.CurrentCamera
	if not camera then return end
	local cursor = UserInputService:GetMouseLocation()
	local ray = camera:ViewportPointToRay(cursor.X, cursor.Y)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local excluded = { session.folder }
	local character = Players.LocalPlayer and Players.LocalPlayer.Character
	if character then table.insert(excluded, character) end
	params.FilterDescendantsInstances = excluded
	local result = Workspace:Raycast(ray.Origin, ray.Direction * 2000, params)
	local groupId = result and session:groupForInstance(result.Instance)
	if groupId then
		self:selectGroup(groupId, referenceLabel(Schema.findById(self.definition.groups, groupId)))
	else
		self.status.Text = "That object is not a Room Definition component. Use Pick component to add it."
	end
end
function View:play()
	if self.playing then
		self.playing = false
		self:seek(self.time, nil, false)
		return
	end
	if self.time >= (self.duration or 0) then self.time = 0 end
	self.playing = true
	self:seek(self.time, nil, true)
	self.playing = self.app.presenter.assemblySession ~= nil
end

function View:showGuides()
	self:seek(self.time)
	local session=self.app.presenter.assemblySession
	if not session then return end
	if self.guideFolder then self.guideFolder:Destroy(); self.guideFolder=nil; return end
	local folder=Instance.new("Folder"); folder.Name="VNAssemblyGuides"; folder.Parent=Workspace; self.guideFolder=folder
	local anchor=Instance.new("Part"); anchor.Name="Guide origin"; anchor.Anchored=true; anchor.Transparency=1
	anchor.CanCollide=false; anchor.CanTouch=false; anchor.CanQuery=false; anchor.CFrame=CFrame.identity; anchor.Parent=folder
	local function dot(position,radius,color)
		local marker=Instance.new("SphereHandleAdornment"); marker.Adornee=anchor; marker.CFrame=CFrame.new(position)
		marker.Radius=radius; marker.Color3=color; marker.AlwaysOnTop=true; marker.ZIndex=1; marker.Parent=folder
	end
	for _,piece in ipairs(session.pieces) do
		if not self.selected or piece.group==self.selected then
			local box=Instance.new("BoxHandleAdornment"); box.Adornee=anchor; box.CFrame=piece.final; box.Size=piece.clone.Size
			box.Transparency=0.8; box.Color3=Theme.Timed; box.Parent=folder
			local pivot=piece.subdivided and piece.pivot or session.pivots[piece.group]
			dot(pivot.Position,0.15,Theme.Gold)
			local axis=session.compiled.groups[piece.group].data.motion.axis
			local direction=axis=="X" and pivot.RightVector or axis=="Y" and pivot.UpVector or -pivot.LookVector
			for _,offset in ipairs({-1,-0.5,0.5,1}) do dot(pivot.Position+direction*offset,0.06,Theme.Gold) end
			for i=0,12 do
				local t=session.compiled.duration*i/12
				local states=Evaluator.sample(session.compiled,t,session.pivots)
				local delta=session:pieceState(piece,t,states)
				dot((delta*piece.final).Position,0.06,Theme.Accent)
			end
		end
	end
end
function View:changed(rebuild)
	self:stop()
	-- Normalize numeric edits without changing the working definition identity.
	local normalized = Assembly.normalize(self.definition)
	reconcile(self.definition, normalized)
	self.app.presenter:setAssemblyAppearance(self.definition)
	self:recordHistory()
	Store.markChanged()
	if rebuild then self:render() else
		task.defer(function() if self.definition and self.app.mode == "assembly" then self:renderTimeline() end end)
	end
end
function View:pick(expand, hidden, rebind, parentId)
	if self.isTemplate then self.status.Text = "Templates contain roles, not world references. Apply this template to a room to preview it."; return end
	self:stop()
	local function addTargets(targets)
		-- Seed ownership from the definition before accepting anything from the
		-- picker. A Model and one of its parts cannot both be components: they
		-- would produce two visual copies of exactly the same geometry.
		local claimed = {}
		for _, group in ipairs(self.definition.groups) do
			if group ~= rebind and group.reference then
				local source = Bindings.resolveStrict(group.reference)
				if source then
					for _, part in ipairs(geometryParts(source)) do claimed[part] = group.name end
				end
			end
		end
		local added, skipped = 0, {}
		for _, target in ipairs(targets) do
			if hidden then
				table.insert(self.definition.hideReferences, Bindings.assemblyReferenceFor(target, true))
			elseif rebind then
				local conflict
				for _, part in ipairs(geometryParts(target)) do
					if claimed[part] then conflict = claimed[part]; break end
				end
				if conflict then
					table.insert(skipped, target.Name .. " (already owned by " .. conflict .. ")")
				else
					rebind.reference = Bindings.assemblyReferenceFor(target, true)
					added += 1
				end
			else
				local objects = expand and target:GetChildren() or { target }
				for _, object in ipairs(objects) do
					if object:IsA("BasePart") or object:IsA("Model") or object:IsA("Folder") then
						local conflict
						for _, part in ipairs(geometryParts(object)) do
							if claimed[part] then conflict = claimed[part]; break end
						end
						if conflict then
							table.insert(skipped, object.Name .. " (already owned by " .. conflict .. ")")
						else
							-- Give every picked source its own identity now. This avoids
							-- relying on display names such as repeated "Union" parts.
							local g = Assembly.group(object.Name, Bindings.assemblyReferenceFor(object, true))
							g.parentId = parentId or ""
							if object:IsA("BasePart") then
								local size = object.Size
								if size.Y < math.min(size.X,size.Z)*0.15 then g.role = "Floor"
								elseif math.min(size.X,size.Z) < size.Y*0.2 then g.role = "Wall" end
							end
							for _, part in ipairs(geometryParts(object)) do claimed[part] = g.name end
							table.insert(self.definition.groups,g); self.selected = g.id; added += 1
						end
					end
				end
			end
		end
		if added > 0 or hidden then self:changed(true) end
		if #skipped > 0 then
			self.status.Text = "Skipped " .. tostring(#skipped) .. " overlapping selection" .. (#skipped == 1 and "" or "s") .. ". A part can only belong to one component."
		elseif added == 0 and not hidden then
			self.status.Text = "No new assembly geometry was added."
		end
	end
	self.app:pickTarget(function(_, target)
		addTargets({ target })
	end, { assignId = false, partOnly = true, allowAncestors = true, marquee = parentId ~= nil,
		onMarqueePick = parentId and function(targets) addTargets(targets) end or nil,
		prompt = parentId and "Click one component, or hold and drag to add multiple children. Tab: parent selection. Esc cancels." or "Select room geometry. Tab: parent selection. Esc cancels.", validate = function(target)
		return not target:FindFirstChildWhichIsA("Humanoid",true)
	end })
end
function View:label(parent, text)
	local label = Widgets.hint(text,parent,30); return label
end
function View:button(parent, text, callback)
	self.orders[parent] = (self.orders[parent] or 0) + 1
	return Widgets.button({ Text = text, Size = UDim2.new(1,0,0,26), TextSize = 11, LayoutOrder=self.orders[parent], OnClick = callback, Parent = parent })
end
function View:field(parent, label, value, setter)
	self.orders[parent] = (self.orders[parent] or 0) + 1
	Widgets.sectionTitle(label,parent).LayoutOrder=self.orders[parent]
	self.orders[parent] += 1
	return Widgets.textBox({ Text = tostring(value), Size = UDim2.new(1,0,0,28), OnCommit = function(text)
		self:stop(); setter(text); self:changed(false)
	end, LayoutOrder=self.orders[parent], Parent = parent })
end
function View:cycle(parent,label,values,current,setter)
	self:button(parent,label .. ": " .. tostring(current),function()
		local index = table.find(values,current) or 0
		setter(values[index%#values+1]); self:changed(true)
	end)
end
function View:renderTimeline()
	Widgets.clearChildren(self.timeline)
	self.dragBar = nil
	local compiled, errorMessage = Evaluator.compile(self.definition)
	self.duration = compiled and compiled.duration or 2.5
	self.status.Text = errorMessage or "Select a component to highlight it. Use S / I / F to jump to start, impact, or settled."
	local scrub = Widgets.button({ Text = "Scrub assembly", Size = UDim2.new(1,0,0,26), LayoutOrder=0, Parent=self.timeline })
	self.cursor = Widgets.create("Frame",{Size=UDim2.new(0,2,1,0),BackgroundColor3=Theme.Accent,BorderSizePixel=0,Parent=scrub})
	scrub.InputBegan:Connect(function(input)
		if input.UserInputType==Enum.UserInputType.MouseButton1 then self.playing=false; self.dragBar=scrub end
	end)
	for index, group in ipairs(self.definition.groups) do
		local row=Widgets.create("Frame",{Size=UDim2.new(1,0,0,24),LayoutOrder=index,BackgroundTransparency=1,Parent=self.timeline})
		Widgets.label({Text=group.name,Size=UDim2.new(0.16,0,1,0),TextSize=11,Parent=row})
		local node=compiled and compiled.groups[group.id]
		local start=node and node.start or group.motion.start
		for markerIndex, marker in ipairs({ "Start", "Impact", "Settled" }) do
			local short = marker == "Start" and "S" or marker == "Impact" and "I" or "F"
			Widgets.button({ Text = short, TextSize = 10, Position = UDim2.new(0.16 + (markerIndex - 1) * 0.02, 0, 0, 1), Size = UDim2.new(0.02, -1, 1, -2),
				OnClick = function() self.selected = group.id; self:seek(compiledMarker(compiled, group, marker)); self:render() end, Parent = row })
		end
		Widgets.button({Text=string.format("%s  %.2fs",group.motion.recipe,start),TextSize=10,
			Position=UDim2.new(0.23+0.77*start/self.duration,0,0,0),Size=UDim2.new(0.77*(node and node.length or group.motion.duration)/self.duration,0,1,0),
			Color=Theme.Accent,OnClick=function() self.selected=group.id; self:render(); self:seek(start) end,Parent=row})
	end
end
function View:render()
	if not self.definition then return end
	Widgets.clearChildren(self.left); Widgets.clearChildren(self.right); Widgets.clearChildren(self.timeline)
	self.orders={}
	self.componentRows = {}
	self:field(self.left,"Room definition",self.definition.name,function(v) self.definition.name=v end)
	if #self.definition.groups == 0 then
		self.orders[self.left] += 1; Widgets.sectionTitle("Getting started", self.left).LayoutOrder = self.orders[self.left]
		self.orders[self.left] += 1; Widgets.hint("1. Pick room or Pick component.\n2. Give pieces useful roles.\n3. Generate, then refine the movement.\n\nA Group is a virtual parent: it holds components together and gives them one shared pivot/motion. It is not another map object.", self.left, 98).LayoutOrder = self.orders[self.left]
	else
		self.orders[self.left] += 1; Widgets.hint("Click a component here to highlight it. Click an already-added object in the preview to select it here. The source path stays in the inspector so this list remains compact.", self.left, 43).LayoutOrder = self.orders[self.left]
	end
	self:button(self.left,"Ghost / pivot / path guides",function() self:showGuides() end)
	self:button(self.left,self.soloSelected and "Solo selected: On" or "Solo selected: Off",function() self.soloSelected=not self.soloSelected; self:seek(self.time); self:render() end)
	self:button(self.left,"Order wave left to right",function() self:sortGroups(false) end)
	self:button(self.left,"Order wave near to far",function() self:sortGroups(true) end)
	self:button(self.left,"Camera / room settings",function() self.selected=nil; self:render() end)
	for _, group in ipairs(self.definition.groups) do
		local depth, parent, seen = 0, group.parentId, {}
		while parent ~= "" and not seen[parent] do
			seen[parent]=true; depth+=1
			local p=Schema.findById(self.definition.groups,parent); parent=p and p.parentId or ""
		end
		local label = string.rep("  ",math.min(depth,4)) .. (self.selected==group.id and "> " or "") .. group.name
		local button = self:button(self.left,label,function() self:selectGroup(group.id) end)
		button.TextColor3 = self.selected == group.id and Theme.Gold or Theme.Text
		self.componentRows[group.id] = button
	end
	self:renderTimeline()
	local g = Schema.findById(self.definition.groups,self.selected)
	if not g then self:renderCamera(); return end
	self:field(self.right,"Name",g.name,function(v) g.name=v end)
	self.orders[self.right] += 1
	Widgets.hint("Selected: " .. (self.selectedSourceLabel or referenceLabel(g)), self.right, 30).LayoutOrder = self.orders[self.right]
	if g.reference then
		self:button(self.right,"Rebind source part",function() self:pick(false,false,g) end)
		self:button(self.right,"Create parent group",function() self:makeParent(g) end)
	else
		self.orders[self.right] += 1
		Widgets.hint("Virtual group: this is an animation parent, not a map object. Add components beneath it to move them as one unit, or parent existing components to it.", self.right, 45).LayoutOrder = self.orders[self.right]
		self:button(self.right,"Pick child component",function() self:pick(false,false,nil,g.id) end)
		self:button(self.right,"+ Child virtual group",function() self:addEmptyGroup(g.id) end)
		self:button(self.right,"Set direct children to Follow only",function()
			for _, child in ipairs(self.definition.groups) do
				if child.parentId == g.id then child.motion.recipe = "Static Reveal" end
			end
			self:changed(true)
		end)
	end
	if g.reference then
		g.edgeFades = g.edgeFades or {}
		self.orders[self.right] += 1
		Widgets.sectionTitle("Black edge fades", self.right).LayoutOrder = self.orders[self.right]
		self.orders[self.right] += 1
		Widgets.hint("Asset-free SurfaceGui gradients that make this component fade into a dark Room3D edge. Face chooses the visible surface; Edge chooses which side is black.", self.right, 43).LayoutOrder = self.orders[self.right]
		self:button(self.right,"+ Add black edge fade",function()
			table.insert(g.edgeFades, Assembly.edgeFade())
			self:changed(true)
		end)
		for index, fade in ipairs(g.edgeFades) do
			self:cycle(self.right,"Fade " .. tostring(index) .. " face",{"Top","Bottom","Left","Right","Front","Back"},fade.face,function(value) fade.face=value end)
			self:cycle(self.right,"Fade " .. tostring(index) .. " edge",{"Left","Right","Top","Bottom"},fade.edge,function(value) fade.edge=value end)
			self:field(self.right,"Fade " .. tostring(index) .. " width inward (studs)",fade.width,function(value) fade.width=tonumber(value) or fade.width end)
			self:field(self.right,"Fade " .. tostring(index) .. " black opacity",fade.opacity,function(value) fade.opacity=tonumber(value) or fade.opacity end)
			self:button(self.right,"Remove fade " .. tostring(index),function()
				table.remove(g.edgeFades,index)
				self:changed(true)
			end)
		end
	end
	self:cycle(self.right,"Role",Assembly.ROLES,g.role,function(v) g.role=v end)
	self:button(self.right,g.required and "Required: Yes" or "Required: No",function() g.required=not g.required; self:changed(true) end)
	local parents={""}; local labels={ [""]="Room" }
	local function wouldCycle(candidateId)
		local current, seen = candidateId, {}
		while current ~= "" and not seen[current] do
			if current == g.id then return true end
			seen[current] = true
			local node = Schema.findById(self.definition.groups, current)
			current = node and node.parentId or ""
		end
		return false
	end
	for _, other in ipairs(self.definition.groups) do
		if other.id ~= g.id and not wouldCycle(other.id) then table.insert(parents,other.id); labels[other.id]=other.name end
	end
	self:button(self.right,"Parent: " .. (labels[g.parentId] or "Missing"),function()
		g.parentId=parents[((table.find(parents,g.parentId) or 0)%#parents)+1]; self:changed(true)
	end)
	self:cycle(self.right,"Entrance",Assembly.RECIPES,g.motion.recipe,function(v) g.motion.recipe=v end)
	local compiled = Evaluator.compile(self.definition)
	for _, marker in ipairs({ "Start", "Impact", "Settled" }) do
		self:button(self.right,"Jump: " .. marker,function() self:seek(compiledMarker(compiled,g,marker)) end)
	end
	self:button(self.right,"Copy motion",function()
		self.copiedMotion = { motion = Assembly.copy(g.motion), sync = Assembly.copy(g.sync), panels = Assembly.copy(g.panels) }
		self.status.Text = "Copied motion settings. Select another component and choose Paste motion."
	end)
	if self.copiedMotion then self:button(self.right,"Paste motion",function()
		g.motion = Assembly.copy(self.copiedMotion.motion); g.sync = Assembly.copy(self.copiedMotion.sync); g.panels = Assembly.copy(self.copiedMotion.panels); self:changed(true)
	end) end
	self:button(self.right,"Reset motion",function()
		g.motion = Assembly.motion(); g.sync = { groupId = "", marker = "Impact", offset = 0 }; g.panels = { x = 1, z = 1, stagger = 0.04, mirror = true }; self:changed(true)
	end)
	self:button(self.right,"Save motion as preset",function()
		local preset=Assembly.new(g.name .. " motion")
		local copy=Assembly.copy(g); copy.reference=nil; copy.parentId=""; copy.sync.groupId=""
		preset.groups={copy}; table.insert(self.app:getProject().assemblyPresets,preset); Store.markChanged(); self:render()
	end)
	for _,preset in ipairs(self.app:getProject().assemblyPresets) do
		if #preset.groups==1 then self:button(self.right,"Motion: " .. preset.name,function() g.motion=Assembly.copy(preset.groups[1].motion); self:changed(true) end) end
	end
	for _, field in ipairs({{"Start", "start"},{"Duration","duration"},{"Travel distance","distance"},{"Rotation degrees","angle"},{"Impact fraction","impact"},{"Anticipation fraction","anticipation"},{"Directional rebound","overshoot"}}) do
		self:field(self.right,field[1],g.motion[field[2]],function(v) g.motion[field[2]]=tonumber(v) or g.motion[field[2]] end)
	end
	self:cycle(self.right,"Settle style",{"Bounce","Wobble"},g.motion.settleStyle,function(v) g.motion.settleStyle=v end)
	if g.motion.settleStyle == "Wobble" then
		self:field(self.right,"Wobble degrees",g.motion.wobble,function(v) g.motion.wobble=tonumber(v) or g.motion.wobble end)
		self:field(self.right,"Oscillations",g.motion.frequency,function(v) g.motion.frequency=tonumber(v) or g.motion.frequency end)
		self:field(self.right,"Damping",g.motion.damping,function(v) g.motion.damping=tonumber(v) or g.motion.damping end)
	end
	self:cycle(self.right,"Rotation axis",{"X","Y","Z"},g.motion.axis,function(v) g.motion.axis=v end)
	self:field(self.right,"Travel direction (x,y,z)",vecText(g.motion.direction),function(v) g.motion.direction=parseVector(v,3) or g.motion.direction end)
	self:field(self.right,"Orientation degrees (x,y,z)",vecText(g.motion.rotation),function(v) g.motion.rotation=parseVector(v,3) or g.motion.rotation end)
	self:field(self.right,"Virtual pivot offset (x,y,z)",vecText(g.pivot),function(v) g.pivot=parseVector(v,3) or g.pivot end)
	self:button(self.right,"Pick hinge point in world",function()
		self:stop()
		self.app:pickTarget(function(_,_,_,hit)
			local source=g.reference and Bindings.resolveStrict(g.reference)
			if source and source:IsA("PVInstance") and hit then
				local p=source:GetPivot():PointToObjectSpace(hit.Position); g.pivot={p.X,p.Y,p.Z}; self:changed(true)
			end
		end,{assignId=false,partOnly=true})
	end)
	for _, edge in ipairs({"Left","Right","Bottom","Back","Front","Center"}) do
		self:button(self.right,"Hinge: " .. edge,function()
			local source=g.reference and Bindings.resolveStrict(g.reference)
			if source and source:IsA("BasePart") then
				local s=source.Size/2
				g.pivot=edge=="Left" and {-s.X,0,0} or edge=="Right" and {s.X,0,0} or edge=="Bottom" and {0,-s.Y,0} or edge=="Back" and {0,0,s.Z} or edge=="Front" and {0,0,-s.Z} or {0,0,0}
				self:changed(true)
			end
		end)
	end
	for _, key in ipairs({"moveCurve","rotateCurve"}) do self:field(self.right,key .. " (x1,y1,x2,y2)",vecText(g.motion[key]),function(v) g.motion[key]=parseVector(v,4) or g.motion[key] end) end
	self:button(self.right,"Synchronize: " .. (labels[g.sync.groupId] or "Missing"),function() g.sync.groupId=parents[((table.find(parents,g.sync.groupId) or 0)%#parents)+1]; self:changed(true) end)
	self:cycle(self.right,"Marker",{"Start","Impact","Settled"},g.sync.marker,function(v) g.sync.marker=v end)
	self:field(self.right,"Marker offset seconds",g.sync.offset,function(v) g.sync.offset=tonumber(v) or 0 end)
	for _, key in ipairs({"x","z","stagger"}) do self:field(self.right,"Panels " .. key,g.panels[key],function(v) g.panels[key]=tonumber(v) or g.panels[key] end) end
	self:button(self.right,"Mirror folds: " .. tostring(g.panels.mirror),function() g.panels.mirror=not g.panels.mirror; self:changed(true) end)
	self:button(self.right,"Up in wave",function()
		local _,i=Schema.findById(self.definition.groups,g.id)
		if i>1 then self.definition.groups[i],self.definition.groups[i-1]=self.definition.groups[i-1],g; self:changed(true) end
	end)
	self:button(self.right,"Down in wave",function()
		local _,i=Schema.findById(self.definition.groups,g.id)
		if i<#self.definition.groups then self.definition.groups[i],self.definition.groups[i+1]=self.definition.groups[i+1],g; self:changed(true) end
	end)
	self:button(self.right,"Delete component",function()
		local _,i=Schema.findById(self.definition.groups,g.id); table.remove(self.definition.groups,i)
		for _,other in ipairs(self.definition.groups) do
			if other.parentId==g.id then other.parentId="" end
			if other.sync.groupId==g.id then other.sync.groupId="" end
		end
		self.selected=nil; self:changed(true)
	end)
end
function View:sortGroups(byDistance)
	self:stop()
	local camera=self:destination()
	local keys={}
	for i,g in ipairs(self.definition.groups) do
		local source=g.reference and Bindings.resolveStrict(g.reference)
		local position=source and source:IsA("PVInstance") and source:GetPivot().Position or camera.Position
		keys[g.id]={value=byDistance and (position-camera.Position).Magnitude or camera:PointToObjectSpace(position).X,index=i}
	end
	table.sort(self.definition.groups,function(a,b)
		local ka,kb=keys[a.id],keys[b.id]
		return if ka.value==kb.value then ka.index<kb.index else ka.value<kb.value
	end)
	self:changed(true)
	self.status.Text="Wave order saved. Generate applies role-specific stagger in this order."
end
function View:renderCamera()
	if self.validationVisible then
		local result = self:validateDefinition()
		self.orders[self.right] += 1; Widgets.sectionTitle("Assembly validation", self.right).LayoutOrder = self.orders[self.right]
		if #result.errors == 0 and #result.warnings == 0 then
			self.orders[self.right] += 1; Widgets.hint("Ready to preview. All required references resolve and the timing graph is valid.", self.right, 34).LayoutOrder = self.orders[self.right]
		end
		for _, message in ipairs(result.errors) do
			self.orders[self.right] += 1; Widgets.hint("Error: " .. message, self.right, 34).LayoutOrder = self.orders[self.right]
		end
		for _, message in ipairs(result.warnings) do
			self.orders[self.right] += 1; Widgets.hint("Note: " .. message, self.right, 34).LayoutOrder = self.orders[self.right]
		end
		self:button(self.right,"Repair overlapping components",function() self:repairOverlaps() end)
		self:button(self.right,"Close validation",function() self.validationVisible=false; self:render() end)
	end
	local c=self.definition.camera
	self:field(self.right,"Camera duration",c.duration,function(v) c.duration=tonumber(v) or c.duration end)
	for _, key in ipairs({"offset","rotation"}) do self:field(self.right,"Opening camera " .. key,vecText(c[key]),function(v) c[key]=parseVector(v,3) or c[key] end) end
	self:field(self.right,"Opening FOV offset",c.fovOffset,function(v) c.fovOffset=tonumber(v) or 0 end)
	self:button(self.right,"Backdrop: " .. tostring(self.definition.backdrop),function() self.definition.backdrop=not self.definition.backdrop; self:changed(true) end)
	self:button(self.right,"Pick additional object to hide",function() self:pick(false,true) end)
	self:button(self.right,"Clear hidden objects (" .. #self.definition.hideReferences .. ")",function() self.definition.hideReferences={}; self:changed(true) end)
	self:button(self.right,"Save choreography as preset",function()
		table.insert(self.app:getProject().assemblyPresets,Assembly.template(self.definition)); Store.markChanged(); self:render()
	end)
	for _,preset in ipairs(self.app:getProject().assemblyPresets) do
		self:button(self.right,"Apply: " .. preset.name,function() Assembly.applyTemplate(self.definition,preset); self:changed(true) end)
	end
	self:button(self.right,"+ Sound cue",function() table.insert(self.definition.sounds,{time=0.5,assetId="",volume=0.5}); self:changed(true) end)
	for index,cue in ipairs(self.definition.sounds) do
		self:field(self.right,"Sound " .. index .. " ID",cue.assetId,function(v) cue.assetId=v end)
		self:field(self.right,"At seconds",cue.time,function(v) cue.time=tonumber(v) or 0 end)
		self:field(self.right,"Volume",cue.volume,function(v) cue.volume=tonumber(v) or 0.5 end)
		self:button(self.right,"Remove sound " .. index,function() table.remove(self.definition.sounds,index); self:changed(true) end)
	end
end
function View:destroy() self:stop(); self.connection:Disconnect(); self.inputConnection:Disconnect(); self.panel:Destroy() end
return View
