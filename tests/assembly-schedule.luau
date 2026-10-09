-- Standalone: luau tests/assembly-schedule.luau (no Roblox or Rojo needed).
local Evaluator = require("../VNSceneEditor/Runtime/AssemblyEvaluator")
local checks = 0
local function expect(condition, message) checks += 1; assert(condition, message) end
local function group(id, start, duration)
	return { id=id, name=id, parentId="", motion={start=start or 0,duration=duration or 1,impact=0.7},
		sync={groupId="",marker="Impact",offset=0},panels={x=1,z=1,stagger=0.1} }
end
local function definition(groups) return { groups=groups,camera={duration=2.5} } end
local floor,wall,lamp = group("floor"),group("wall"),group("lamp")
wall.sync={groupId="floor",marker="Impact",offset=-0.1}
lamp.parentId="wall"; lamp.sync={groupId="wall",marker="Settled",offset=0.05}
local score,err=Evaluator.compile(definition({lamp,wall,floor}))
expect(score~=nil,err)
expect(math.abs(score.groups.wall.start-0.6)<1e-9,"Impact overlap")
expect(math.abs(score.groups.lamp.start-1.65)<1e-9,"Settle dependency")
expect(math.abs(score.duration-2.65)<1e-9,"Includes lamp settling")
expect(score.order[1].data.id=="floor","Stable dependency order")
expect(score.order[3].data.id=="lamp","Child after parent")
for _=1,30 do
	local again=assert(Evaluator.compile(definition({lamp,wall,floor})))
	expect(again.duration==score.duration,"Deterministic recompilation")
end
local panels=group("panels"); panels.panels={x=2,z=3,stagger=0.2}
local dependent=group("dependent"); dependent.sync={groupId="panels",marker="Settled",offset=0}
local split=assert(Evaluator.compile(definition({panels,dependent})))
expect(split.groups.panels.length==2,"Panel stagger included in settle marker")
expect(split.groups.dependent.start==2,"Dependent waits for final panel")
expect(split.duration==3,"Final panel included in duration")
local duplicate,duplicateError=Evaluator.compile(definition({group("same"),group("same")}))
expect(duplicate==nil and duplicateError:find("Duplicate")~=nil,"Reject duplicate IDs")
local a,b=group("a"),group("b"); a.parentId="b"; b.parentId="a"
expect(Evaluator.compile(definition({a,b}))==nil,"Reject parent cycles")
a,b=group("a"),group("b"); a.sync.groupId="b"; b.sync.groupId="a"
expect(Evaluator.compile(definition({a,b}))==nil,"Reject timing cycles")
a,b=group("a"),group("b"); a.parentId="b"; b.sync.groupId="a"
expect(Evaluator.compile(definition({a,b}))==nil,"Reject mixed cycles")
a=group("a"); a.parentId="missing"
expect(Evaluator.compile(definition({a}))==nil,"Reject missing parent")
a,b=group("a"),group("b"); b.sync={groupId="a",marker="Start",offset=-0.5}
expect(Evaluator.compile(definition({a,b}))==nil,"Reject negative calculated time")
local empty=assert(Evaluator.compile(definition({})))
expect(empty.duration==2.5,"Camera-only duration")
local recipes={"Hinge Fold","Drop and Settle","Rise and Unfold","Slide and Rebound","Swing and Settle","Static Reveal"}
for _,recipe in ipairs(recipes) do
	local motion={recipe=recipe,duration=1,anticipation=0.06,impact=0.7,distance=8,angle=85,overshoot=0.06,wobble=4,frequency=2,damping=4,
		moveCurve={0.22,0,0.35,1},rotateCurve={0.22,0,0.35,1}}
	local _,_,_,visible=Evaluator.channels(motion,-0.01)
	expect(not visible,"Hidden before entrance")
	for _,fps in ipairs({30,60,144}) do
		for i=0,fps do
			local t=i/fps
			local d,r,q,v=Evaluator.channels(motion,t)
			Evaluator.channels(motion,0.92)
			local dd,rr,qq,vv=Evaluator.channels(motion,t)
			expect(d==dd and r==rr and q==qq and v==vv,"Sample depends on history/frame rate")
			expect(d==d and r==r and q==q,"Non-finite channel")
		end
	end
	local d,r,q,v=Evaluator.channels(motion,1)
	expect(d==0 and r==0 and q==0 and v,"Must settle exactly")
end
print(string.format("Assembly schedule and motion: %d checks passed",checks))
