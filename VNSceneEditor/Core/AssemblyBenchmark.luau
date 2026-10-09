-- Explicitly invoked visual fixture; never runs when the editor starts.
-- Returned cleanup owns only this generated Folder, never user's geometry.
local Assembly = require(script.Parent.RoomAssembly)
local Bindings = require(script.Parent.Parent.Render.WorldBindings)
local Benchmark = {}
function Benchmark.create(origin)
	local folder=Instance.new("Folder"); folder.Name="VNAssemblyBenchmark_" .. Assembly.id(); folder.Parent=workspace
	local definition=Assembly.new("Pop-up room benchmark")
	definition.backdrop=true
	local function part(name, position, size, color, role)
		local object=Instance.new("Part"); object.Name=name; object.Anchored=true
		object.Size=size; object.CFrame=origin*CFrame.new(position); object.Color=color; object.Parent=folder
		local group=Assembly.group(name,Bindings.assemblyReferenceFor(object)); group.role=role
		table.insert(definition.groups,group)
		return group,object
	end
	local floor=part("Folding floor",Vector3.zero,Vector3.new(30,0.5,24),Color3.fromRGB(90,70,82),"Floor")
	floor.panels.x=2; floor.panels.stagger=0
	local back=part("Back wall",Vector3.new(0,6,-12),Vector3.new(30,12,0.5),Color3.fromRGB(176,160,153),"Wall")
	back.pivot={0,-6,0}
	local left=part("Left wall",Vector3.new(-15,6,0),Vector3.new(0.5,12,24),Color3.fromRGB(126,139,160),"Wall")
	left.pivot={0,-6,0}
	local right=part("Right wall",Vector3.new(15,6,0),Vector3.new(0.5,12,24),Color3.fromRGB(126,139,160),"Wall")
	right.pivot={0,-6,0}
	local ceiling=part("Ceiling",Vector3.new(0,12,0),Vector3.new(30,0.5,24),Color3.fromRGB(95,101,117),"Ceiling")
	local deskModel=Instance.new("Model"); deskModel.Name="Desk"; deskModel.Parent=folder
	local function deskPiece(name,p,s)
		local object=Instance.new("Part"); object.Name=name; object.Anchored=true; object.Size=s; object.CFrame=origin*CFrame.new(p); object.Color=Color3.fromRGB(137,84,57); object.Parent=deskModel
	end
	deskPiece("Top",Vector3.new(-5,3,-4),Vector3.new(7,0.5,4))
	for _,x in ipairs({-7.7,-2.3}) do for _,z in ipairs({-5.3,-2.7}) do deskPiece("Leg",Vector3.new(x,1.5,z),Vector3.new(0.4,3,0.4)) end end
	local desk=Assembly.group("Desk",Bindings.assemblyReferenceFor(deskModel)); table.insert(definition.groups,desk)
	part("Chair",Vector3.new(5,1.5,-4),Vector3.new(3,3,3),Color3.fromRGB(91,58,67),"Furniture")
	local lamp=part("Hanging lamp",Vector3.new(0,9,-3),Vector3.new(3,1,3),Color3.fromRGB(244,204,101),"Fixture")
	lamp.pivot={0,3,0}; lamp.parentId=ceiling.id
	Assembly.generate(definition)
	floor.motion.axis="Z"; floor.motion.angle=85
	left.motion.axis="Z"; left.motion.angle=-85; right.motion.axis="Z"; right.motion.angle=85
	back.motion.angle=-85
	lamp.sync={groupId=ceiling.id,marker="Impact",offset=0.05}
	return definition, origin*CFrame.lookAt(Vector3.new(0,6,20),Vector3.new(0,5,-3)), function() folder:Destroy() end
end
return Benchmark
