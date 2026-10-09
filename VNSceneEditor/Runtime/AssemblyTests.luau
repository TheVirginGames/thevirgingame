-- Opt-in Studio CLIENT tests: require(this ModuleScript).run(). No startup side effects.
local root=script.Parent.Parent
local Assembly=require(root.Core.RoomAssembly)
local Schema=require(root.Core.Schema)
local Codec=require(root.Core.JSONCodec)
local Evaluator=require(script.Parent.AssemblyEvaluator)
local Bindings=require(root.Render.WorldBindings)
local Session=require(root.Render.AssemblySession)
local CameraRig=require(root.Render.CameraRig)
local Tests={}
local function near(a,b)
	local delta=a:ToObjectSpace(b)
	local _,angle=delta:ToAxisAngle()
	return delta.Position.Magnitude<0.0001 and math.abs(angle)<0.0001
end
function Tests.run()
	local folder=Instance.new("Folder"); folder.Name=Assembly.id(); folder.Parent=workspace
	local rig=CameraRig.new()
	local session
	local ok,err=pcall(function()
		local part=Instance.new("Part"); part.Name="Part"; part.Anchored=true; part.Size=Vector3.new(8,0.5,6)
		part.CFrame=CFrame.new(100,10,100); part.Transparency=0.2; part.Parent=folder
		local definition=Assembly.new("Test room")
		local g=Assembly.group("Floor",Bindings.assemblyReferenceFor(part)); g.role="Floor"; table.insert(definition.groups,g)
		Assembly.generate(definition)
		local compiled=assert(Evaluator.compile(definition))
		local bindings={[g.id]=part.CFrame}
		for _,recipe in ipairs(Assembly.RECIPES) do
			g.motion.recipe=recipe
			for _,t in ipairs({0,0.2,0.75,1,5}) do
				local first=Evaluator.sample(compiled,t,bindings)[g.id]
				Evaluator.sample(compiled,0.8,bindings)
				local second=Evaluator.sample(compiled,t,bindings)[g.id]
				assert(near(first.delta,second.delta),"Seek order affected pose")
			end
			assert(near(Evaluator.sample(compiled,compiled.duration,bindings)[g.id].delta,CFrame.identity),"Final pose not exact")
		end
		local project=Schema.newProject("Assembly persistence")
		table.insert(project.roomDefinitions,definition)
		local chapter=Schema.newChapter("Test",project); table.insert(project.chapters,chapter)
		local scene=chapter.scenes[1]
		local first=Schema.newSubscene("Root","Room3D",project)
		local second=Schema.newSubscene("Linked","Room3D",project)
		first.assemblyEnabled=true; first.roomDefinitionId=definition.id
		second.linkPreviousRoom=true; second.linkedRoomId=first.id
		scene.subscenes={first,second}
		assert(Schema.assemblyOwner(scene,second)==first,"Linked room lost root ownership")
		assert(Schema.subsceneView(scene,second).roomDefinitionId==definition.id,"Linked room lost definition")
		assert(Schema.isValidMergeBetween(scene,first,second),"Assembly broke valid Merge")
		local exported=assert(Codec.encodeProject(project,false))
		local restored=assert(Codec.decodeProject(exported))
		assert(restored.roomDefinitions[1].groups[1].reference.path[1].name==folder.Name,"Lost binding during JSON round trip")
		assert(restored.roomDefinitions[1].camera.duration==definition.camera.duration,"Lost camera settings")
		assert(restored.chapters[1].scenes[1].subscenes[1].assemblyEnabled,"Lost assembly enablement")
		local legacy=Assembly.copy(project); legacy.formatVersion=18; legacy.roomDefinitions=nil; legacy.assemblyPresets=nil
		legacy.chapters[1].scenes[1].subscenes[1].assemblyEnabled=nil
		legacy.chapters[1].scenes[1].subscenes[1].roomDefinitionId=nil
		local migrated=assert(Schema.normalizeProject(legacy))
		assert(#migrated.roomDefinitions==0 and migrated.chapters[1].scenes[1].subscenes[1].assemblyEnabled==false,"Legacy migration should opt out")
		local original=part.CFrame
		local finalCamera=rig:getCFrame()
		session=assert(Session.create(definition,rig,finalCamera))
		assert(part.LocalTransparencyModifier==1,"Source not hidden")
		session:seek(0.5); session:seek(0); session:seek(compiled.duration)
		assert(near(part.CFrame,original),"Source transform changed")
		assert(near(session.pieces[1].clone.CFrame,original),"Final clone misaligned")
		session:close(true); session:close(true)
		assert(part.LocalTransparencyModifier==0 and part.Transparency==0.2,"Visibility not restored")
		assert(rig.cameraLease==nil,"Leaked camera owner")
		local duplicate=part:Clone(); duplicate.Parent=folder
		local resolved=Bindings.resolveStrict(g.reference)
		assert(resolved==nil,"Ambiguous structural reference silently resolved")
		local rejected=Session.create(definition,rig,finalCamera)
		assert(rejected==nil and part.LocalTransparencyModifier==0,"Validation failure modified source")
		duplicate:Destroy()
		g.panels.x=2; g.motion.recipe="Hinge Fold"; g.motion.axis="Z"
		session=assert(Session.create(definition,rig,finalCamera)); session:seek(session.compiled.duration)
		assert(#session.pieces==2,"Panel generation failed")
		for _,piece in ipairs(session.pieces) do assert(near(piece.clone.CFrame,piece.final),"Panel did not settle") end
		session:close(true)
		local template=Assembly.template(definition)
		assert(template.groups[1].reference==nil,"Template leaked room binding")
	end)
	if session then session:close(true) end
	rig:destroy(); folder:Destroy()
	assert(ok,err)
	print("Room Assembly Studio tests passed")
	return true
end
return Tests
