--!strict
-- Builds the tell workbench: the four attack tells, on rigs, as animations you
-- can open in Roblox Studio's Animation Editor and pose by hand.
--
--   lune run tell-workbench          -- write the file
--   lune run tell-workbench --read   -- print the snippet that reads your work back
--
-- Writes workbench/TellWorkbench.rbxm. Drag it into a Studio place and you get
-- four rigs standing in their tells, with the idle beside each one — because a
-- tell is only readable as a *change* from the idle, and judging one on a
-- blank field flatters it.
--
-- Why this exists: the four tells are the whole visual vocabulary of every
-- enemy attack in the game (AttackChoreography). Everything after the commit
-- point is generated, so those four poses are the entire readable surface, and
-- they currently live as degrees in a Luau file — which is a bad way to pose a
-- body. This puts them on a rig where they can be dragged.
--
-- The loop is: pose here, read it back with `--read`, paste into
-- AttackChoreography, then `lune run test AttackChoreography` immediately tells
-- you whether the change made two tells too alike to tell apart.

local fs = require("@lune/fs")
local process = require("@lune/process")
local roblox = require("@lune/roblox")

local SharedModules = require("./lib/sharedModules")

local Instance = roblox.Instance
local CFrame = roblox.CFrame
local Vector3 = roblox.Vector3
local Color3 = roblox.Color3
local Enum = roblox.Enum

local OUT_DIR = "workbench"
local OUT_FILE = `{OUT_DIR}/TellWorkbench.rbxm`
local RIG_SPACING = 13

local shared = SharedModules.load("src/shared")
local AttackChoreography = shared.AttackChoreography
local KeyframeMath = shared.KeyframeMath
local RigAssembly = shared.RigAssembly
local RigDefs = shared.RigDefs

-- Which rig wears the tells. Enemies are the ones that throw them, and this is
-- the one the dungeon leans on hardest.
local RIG_ID = "SkeletonWarrior"

-- How long the rig takes to arrive in the tell, in the editor. Not a game
-- number — the game holds the tell for whatever the attack's leadTime says —
-- just long enough here to see the pose snap into place rather than appear.
local ARRIVAL = 0.3

--[[ The read-back snippet ]]

-- Printed rather than written to a file: it is pasted into Studio's command
-- bar, and a file on disk would be one more thing to keep in step.
local READ_SNIPPET = [[
-- Reads the four tells back out of the workbench, as a Luau literal to paste
-- into ARCHETYPE_DEFS in src/shared/AttackChoreography.luau.
-- Paste this into Studio's command bar after saving your poses.
local ServerStorage = game:GetService("ServerStorage")

local bench = workspace:FindFirstChild("TellWorkbench")
assert(bench, "drag TellWorkbench.rbxm into the place first")

-- Studio's Animation Clip Editor moved saved clips from an AnimSaves object on
-- the rig into ServerStorage, and offers to migrate the old ones when a rig
-- carrying them is opened. Either answer is fine: this looks in both, and
-- matches a migrated clip by the rig's name, since the folder layout over
-- there has changed more than once.
local function findClip(rig)
	local saves = rig:FindFirstChild("AnimSaves")
	local legacy = saves and saves:FindFirstChildOfClass("KeyframeSequence")
	if legacy then
		return legacy
	end

	for _, found in ServerStorage:GetDescendants() do
		if found.Name == rig.Name and (found:IsA("KeyframeSequence") or found:IsA("CurveAnimation")) then
			return found
		end
	end
	return nil
end

local out = {}
for _, rig in bench:GetChildren() do
	local sequence = findClip(rig)
	if not sequence then continue end

	-- The newer editor can save a CurveAnimation, which stores channels rather
	-- than a tree of poses and cannot be walked the way below. Say so instead
	-- of quietly reading nothing out of it.
	if sequence:IsA("CurveAnimation") then
		warn(rig.Name .. ": saved as a CurveAnimation. In the Animation Editor's"
			.. " ... menu, Export as a KeyframeSequence, then run this again.")
		continue
	end

	-- The last keyframe is the tell; the first is rest.
	local last
	for _, frame in sequence:GetChildren() do
		if frame:IsA("Keyframe") and (not last or frame.Time > last.Time) then
			last = frame
		end
	end
	if not last then continue end

	local lines = {}
	local function walk(pose)
		for _, child in pose:GetChildren() do
			if child:IsA("Pose") then
				if child.Weight > 0 then
					local rx, ry, rz = child.CFrame:ToEulerAnglesXYZ()
					local px, py, pz = child.CFrame.Position.X, child.CFrame.Position.Y, child.CFrame.Position.Z
					local parts = {}
					if math.abs(math.deg(rx)) > 0.05 then table.insert(parts, string.format("rx = %.1f", math.deg(rx))) end
					if math.abs(math.deg(ry)) > 0.05 then table.insert(parts, string.format("ry = %.1f", math.deg(ry))) end
					if math.abs(math.deg(rz)) > 0.05 then table.insert(parts, string.format("rz = %.1f", math.deg(rz))) end
					if math.abs(px) > 0.005 then table.insert(parts, string.format("px = %.2f", px)) end
					if math.abs(py) > 0.005 then table.insert(parts, string.format("py = %.2f", py)) end
					if math.abs(pz) > 0.005 then table.insert(parts, string.format("pz = %.2f", pz)) end
					if #parts > 0 then
						table.insert(lines, string.format("\t\t\t%s = { %s },", child.Name, table.concat(parts, ", ")))
					end
				end
				walk(child)
			end
		end
	end
	walk(last)

	table.sort(lines)
	table.insert(out, string.format("\t\t-- %s\n\t\ttell = {\n%s\n\t\t},", rig.Name, table.concat(lines, "\n")))
end

print("\n" .. table.concat(out, "\n\n"))
]]

if process.args[1] == "--read" then
	print(READ_SNIPPET)
	return
end

--[[ Building ]]

local api = {
	Instance = Instance,
	CFrame = CFrame,
	Vector3 = Vector3,
	Color3 = Color3,
	Enum = Enum,
}

-- Pose hierarchy mirrors the joint hierarchy, rooted at HumanoidRootPart.
local childrenOf: { [string]: { string } } = {}
for _, part in RigDefs.SKELETON do
	childrenOf[part.parent] = childrenOf[part.parent] or {}
	table.insert(childrenOf[part.parent], part.name)
end

local function poseCFrame(values: any, scale: number): any
	return CFrame.new(values.px * scale, values.py * scale, values.pz * scale)
		* CFrame.Angles(math.rad(values.rx), math.rad(values.ry), math.rad(values.rz))
end

-- Rest, then the tell. Two keyframes, so the editor opens on something you can
-- drag rather than a single frozen frame — and so the snap into the pose can
-- be seen, which is half of whether a tell reads.
local function buildTellSequence(name: string, tell: any, scale: number): any
	local animated: { [string]: boolean } = {}
	for part in tell do
		animated[part] = true
	end

	local leadsToAnimated: { [string]: boolean } = {}
	local function mark(part: string): boolean
		local result = animated[part] == true
		for _, child in childrenOf[part] or {} do
			if mark(child) then
				result = true
			end
		end
		leadsToAnimated[part] = result
		return result
	end
	mark("HumanoidRootPart")

	local sequence = Instance.new("KeyframeSequence")
	sequence.Name = name
	sequence.Loop = false
	sequence.Priority = Enum.AnimationPriority.Action

	for _, moment in { { time = 0, poses = {} }, { time = ARRIVAL, poses = tell } } do
		local frame = Instance.new("Keyframe")
		frame.Time = moment.time
		frame.Name = "Keyframe"
		frame.Parent = sequence

		local function addPose(part: string, parent: any)
			local pose = Instance.new("Pose")
			pose.Name = part

			if animated[part] then
				pose.CFrame = poseCFrame(KeyframeMath.resolve((moment.poses :: any)[part]), scale)
				pose.Weight = 1
				pose.EasingStyle = Enum.PoseEasingStyle.Cubic
				pose.EasingDirection = Enum.PoseEasingDirection.In
			else
				pose.Weight = 0
			end

			pose.Parent = parent

			for _, child in childrenOf[part] or {} do
				if leadsToAnimated[child] then
					addPose(child, pose)
				end
			end
		end

		addPose("HumanoidRootPart", frame)
	end

	return sequence
end

local workbench = Instance.new("Model")
workbench.Name = "TellWorkbench"

local archetypes = AttackChoreography.ARCHETYPES
local scale = RigDefs.scaleOf(RIG_ID)
local rootHeight = RigDefs.rootSize(RIG_ID)[2]

local floor = Instance.new("Part")
floor.Name = "Floor"
floor.Anchored = true
floor.Size = Vector3.new(#archetypes * RIG_SPACING + 8, 1, 20)
floor.CFrame = CFrame.new((#archetypes - 1) * RIG_SPACING / 2, -0.5, 0)
floor.Color = Color3.fromRGB(90, 90, 96)
floor.Material = Enum.Material.SmoothPlastic
floor.Parent = workbench

local notes = Instance.new("StringValue")
notes.Name = "HowToUse"
notes.Value = table.concat({
	"The four tells every enemy attack in the game is read from.",
	"",
	"Select a rig, open the Animation Editor, and load its tell from AnimSaves.",
	"The last keyframe IS the tell -- the pose a player reads. Drag that one.",
	"Each rig also carries the idle: a tell only reads as a change from it, so",
	"check the pair, not the pose on its own.",
	"",
	"Two rules, both enforced by `lune run test AttackChoreography`:",
	"  * the joints listed in `diagnostic` are what identify an archetype, and",
	"    they must stay far from the other three or players cannot tell the",
	"    attacks apart in time;",
	"  * Plant is the one that cannot be parried. It has to stay the most",
	"    different of the four -- mistaking it for a parryable tell is the",
	"    worst mistake the game can ask for.",
	"",
	"Studio may offer to migrate the saved clips into ServerStorage. Say yes;",
	"the read-back looks in both places.",
	"",
	"When you are happy: `lune run tell-workbench --read` prints a snippet.",
	"Paste it into the command bar and it gives you the poses back as Luau,",
	"ready to drop into ARCHETYPE_DEFS in src/shared/AttackChoreography.luau.",
	"",
	"Generated by `lune run tell-workbench`; regenerating replaces this file.",
}, "\n")
notes.Parent = workbench

local sequenceCount = 0

for index, archetype in archetypes do
	local def = AttackChoreography.get(archetype)
	local rig = RigAssembly.build(api, RIG_ID, CFrame.new((index - 1) * RIG_SPACING, rootHeight / 2, 0))
	rig.Name = archetype

	local saves = Instance.new("ObjectValue")
	saves.Name = "AnimSaves"
	saves.Parent = rig

	buildTellSequence(archetype, def.tell, scale).Parent = saves
	sequenceCount += 1

	-- The baseline the tell departs from, on the same rig, so the comparison
	-- is one click away rather than a different file.
	local idle = shared.AnimationDefs.get(RIG_ID, "idle")
	if idle then
		local reference = Instance.new("StringValue")
		reference.Name = "ReadAgainstIdle"
		reference.Value = "A tell is only readable as a change from the idle. Load 'idle'"
			.. " from the animation workbench on this same rig to compare."
		reference.Parent = rig
	end

	-- What it must not look like, written where it will be seen.
	local rules = Instance.new("StringValue")
	rules.Name = "Diagnostic"
	rules.Value = "These joints identify this tell and must stay distinct from the"
		.. " other three: " .. table.concat(def.diagnostic, ", ")
		.. (if def.parryable then "  (parryable)" else "  (UNPARRYABLE -- must look least like the others)")
	rules.Parent = rig

	rig.Parent = workbench
end

--[[ Check what was built, by reading the file back ]]

if not fs.isDir(OUT_DIR) then
	fs.writeDir(OUT_DIR)
end
fs.writeFile(OUT_FILE, roblox.serializeModel({ workbench }))

local problems: { string } = {}
local reloaded = roblox.deserializeModel(fs.readFile(OUT_FILE))[1]
local reloadedSequences = 0

for _, child in reloaded:GetChildren() do
	local saves = child:FindFirstChild("AnimSaves")
	if not saves then
		continue
	end
	for _, sequence in saves:GetChildren() do
		reloadedSequences += 1
		local frames = 0
		for _, frame in sequence:GetChildren() do
			if frame.ClassName == "Keyframe" then
				frames += 1
			end
		end
		if frames ~= 2 then
			table.insert(problems, `{child.Name}: {frames} keyframes, expected rest and tell`)
		end
	end
end

if reloadedSequences ~= sequenceCount then
	table.insert(problems, `wrote {sequenceCount} tells, read back {reloadedSequences}`)
end

-- The round trip, checked the same way the Studio snippet does it: walk the
-- last keyframe's poses and turn them back into degrees. If this drifts, the
-- loop silently corrupts a tell every time it is used, so it is worth proving
-- here rather than discovering later.
local function extractTell(rig: any): { [string]: { rx: number, ry: number, rz: number } }
	local saves = rig:FindFirstChild("AnimSaves")
	local sequence = saves and saves:GetChildren()[1]
	local last = nil
	for _, frame in sequence:GetChildren() do
		if frame.ClassName == "Keyframe" and (not last or frame.Time > last.Time) then
			last = frame
		end
	end

	local found = {}
	local function walk(pose: any)
		for _, child in pose:GetChildren() do
			if child.ClassName == "Pose" then
				if child.Weight > 0 then
					local rx, ry, rz = child.CFrame:ToEulerAnglesXYZ()
					found[child.Name] = { rx = math.deg(rx), ry = math.deg(ry), rz = math.deg(rz) }
				end
				walk(child)
			end
		end
	end
	walk(last)
	return found
end

for _, archetype in archetypes do
	local rig = reloaded:FindFirstChild(archetype)
	if not rig then
		table.insert(problems, `{archetype}: no rig in the written file`)
		continue
	end

	local recovered = extractTell(rig)
	for part, pose in AttackChoreography.get(archetype).tell do
		local back = recovered[part]
		if not back then
			table.insert(problems, `{archetype}.{part}: lost in the round trip`)
			continue
		end
		for _, axis in { "rx", "ry", "rz" } do
			local wrote = (pose :: any)[axis] or 0
			local read = (back :: any)[axis]
			-- Euler decomposition is not unique past a quarter turn, so an
			-- angle that big is only checked for having survived at all.
			if math.abs(wrote) < 90 and math.abs(wrote - read) > 0.5 then
				table.insert(problems, string.format("%s.%s.%s: wrote %.1f, read back %.1f", archetype, part, axis, wrote, read))
			end
		end
	end
end

if #problems > 0 then
	print("Problems:")
	for _, message in problems do
		print("  " .. message)
	end
	process.exit(1)
end

print(`Wrote {OUT_FILE}: {sequenceCount} tells on {RIG_ID} rigs.`)
print("")
print("Drag it into a Studio place. Select a rig, open the Animation Editor,")
print("load its tell from AnimSaves, and drag the last keyframe -- that pose is")
print("what every player reads before deciding to parry.")
print("")
print("When you are done: lune run tell-workbench --read")
