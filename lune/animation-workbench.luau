--!strict
-- Builds the animation workbench: every rig, with every rough animation from
-- AnimationDefs saved on it as a KeyframeSequence, ready to open in Roblox
-- Studio's Animation Editor.
--
--   lune run animation-workbench
--
-- Writes workbench/AnimationWorkbench.rbxm. Drag that file into any Studio
-- place, select a rig, open the Animation Editor, and load an animation from
-- the rig's saves. See AnimationIds.luau for how a refined version gets back
-- into the game.
--
-- The rigs come from the same RigAssembly code the game uses, and poses use
-- the same formula as the in-game player, so what opens here is exactly what
-- plays in game. The output is checked by reading it back before the script
-- reports success.

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
local OUT_FILE = `{OUT_DIR}/AnimationWorkbench.rbxm`
local RIG_SPACING = 14

local shared = SharedModules.load("src/shared")
local AnimationDefs = shared.AnimationDefs
local KeyframeMath = shared.KeyframeMath
local RigAssembly = shared.RigAssembly
local RigDefs = shared.RigDefs
local AttackChoreography = shared.AttackChoreography
local CombatConstants = shared.CombatConstants
local EnemyDefs = shared.EnemyDefs

local api = {
	Instance = Instance,
	CFrame = CFrame,
	Vector3 = Vector3,
	Color3 = Color3,
	Enum = Enum,
}

local EASING = {
	Linear = Enum.PoseEasingStyle.Linear,
	Smooth = Enum.PoseEasingStyle.Cubic,
	Hold = Enum.PoseEasingStyle.Constant,
	In = Enum.PoseEasingStyle.Cubic,
	Out = Enum.PoseEasingStyle.Cubic,
}

-- Roblox's pose easing directions are named the other way round from
-- TweenService's: PoseEasingDirection.Out is the curve that starts slow. So
-- our "In" (slow start) is written as Out, and "Out" as In.
local EASING_DIRECTION = {
	Linear = Enum.PoseEasingDirection.InOut,
	Smooth = Enum.PoseEasingDirection.InOut,
	Hold = Enum.PoseEasingDirection.InOut,
	In = Enum.PoseEasingDirection.Out,
	Out = Enum.PoseEasingDirection.In,
}

local PRIORITY = {
	Idle = Enum.AnimationPriority.Idle,
	Movement = Enum.AnimationPriority.Movement,
	Action = Enum.AnimationPriority.Action,
}

local IMPACT_KEYFRAME = "Impact"

--[[ KeyframeSequences ]]

-- Pose hierarchy mirrors the joint hierarchy, rooted at HumanoidRootPart.
local childrenOf: { [string]: { string } } = {}
for _, part in RigDefs.SKELETON do
	childrenOf[part.parent] = childrenOf[part.parent] or {}
	table.insert(childrenOf[part.parent], part.name)
end

-- Offsets are authored for a size-1 rig and scaled to the rig they play on,
-- exactly as RigAnimation does in game.
local function poseCFrame(values: any, scale: number): any
	return CFrame.new(values.px * scale, values.py * scale, values.pz * scale)
		* CFrame.Angles(math.rad(values.rx), math.rad(values.ry), math.rad(values.rz))
end

-- One animation as a KeyframeSequence the Animation Editor can open.
--
-- Poses use the same formula the game plays them with, so what opens in
-- the editor and what plays in game are the same animation. A strike's
-- impact keyframe is named "Impact": that name is how a refined version
-- keeps its timing when it is published.
local function buildSequence(name: string, anim: any, scale: number): any
	local animated: { [string]: boolean } = {}
	for _, part in KeyframeMath.partsOf(anim) do
		animated[part] = true
	end

	-- Only branches that lead to an animated part get poses at all.
	local leadsToAnimated: { [string]: boolean } = {}
	-- Whether this part, or anything hanging below it, is posed by the
	-- animation. Recursive: the Animation Editor needs the whole chain down
	-- to a posed joint, so a hand that moves drags its arm and shoulder in
	-- with it even though neither is posed itself.
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
	sequence.Loop = anim.looped
	sequence.Priority = PRIORITY[anim.priority]

	for _, keyframe in anim.keyframes do
		local frame = Instance.new("Keyframe")
		frame.Time = keyframe.time
		local isImpact = anim.impact ~= nil and math.abs(keyframe.time - anim.impact) < 1e-9
		frame.Name = if isImpact then IMPACT_KEYFRAME else "Keyframe"
		frame.Parent = sequence

		local style = EASING[keyframe.easing or "Smooth"]
		local direction = EASING_DIRECTION[keyframe.easing or "Smooth"]

		-- Adds one Pose to the keyframe, then its children under it, mirroring
		-- the skeleton's own hierarchy — which is the shape the Animation
		-- Editor expects to find.
		local function addPose(part: string, parent: any)
			local pose = Instance.new("Pose")
			pose.Name = part

			if animated[part] then
				-- Every animated part gets an explicit pose in every keyframe:
				-- a part a keyframe leaves out is at rest there, and writing that
				-- down keeps the editor from interpolating across it.
				pose.CFrame = poseCFrame(KeyframeMath.resolve(keyframe.poses[part]), scale)
				pose.Weight = 1
				pose.EasingStyle = style
				pose.EasingDirection = direction
			else
				-- A structural pose, as the Animation Editor writes for parents
				-- of animated parts: it isn't a key.
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

--[[ Workbench ]]

local rigIds = {}
for rigId in RigDefs.STYLES do
	table.insert(rigIds, rigId)
end
table.sort(rigIds)

local workbench = Instance.new("Model")
workbench.Name = "AnimationWorkbench"

local floor = Instance.new("Part")
floor.Name = "Floor"
floor.Anchored = true
floor.Size = Vector3.new(#rigIds * RIG_SPACING + 8, 1, 20)
floor.CFrame = CFrame.new((#rigIds - 1) * RIG_SPACING / 2, -0.5, 0)
floor.Color = Color3.fromRGB(90, 90, 96)
floor.Material = Enum.Material.SmoothPlastic
floor.Parent = workbench

local notes = Instance.new("StringValue")
notes.Name = "HowToUse"
notes.Value = table.concat({
	"Select a rig, open the Animation Editor, and load an animation from its saves.",
	"Attacks and swings: keep the keyframe named Impact at the moment the hit lands.",
	"Publish, then paste the ID into src/shared/AnimationIds.luau under the rig and animation name.",
	"This file is generated by `lune run animation-workbench`; regenerating replaces it,",
	"so publish your work (or keep your own copy) before importing a new one.",
}, "\n")
notes.Parent = workbench

local sequenceCount = 0

for index, rigId in rigIds do
	-- Root centre at half the hitbox's height puts the feet on the floor.
	local rootHeight = RigDefs.rootSize(rigId)[2]
	local rig = RigAssembly.build(api, rigId, CFrame.new((index - 1) * RIG_SPACING, rootHeight / 2, 0))

	-- Where the Animation Editor keeps a rig's saved animations.
	local saves = Instance.new("ObjectValue")
	saves.Name = "AnimSaves"
	saves.Parent = rig

	local animations = AnimationDefs.BY_RIG[rigId] or {}
	local names = {}
	for name in animations do
		table.insert(names, name)
	end
	table.sort(names)

	for _, name in names do
		buildSequence(name, animations[name], RigDefs.scaleOf(rigId)).Parent = saves
		sequenceCount += 1
	end

	rig.Parent = workbench
end

--[[ Check what was built, from the written file ]]

local problems: { string } = {}
-- Records a check failure. Collected rather than thrown, so one run
-- reports every problem instead of stopping at the first.
local function problem(message: string)
	table.insert(problems, message)
end

if not fs.isDir(OUT_DIR) then
	fs.writeDir(OUT_DIR)
end
fs.writeFile(OUT_FILE, roblox.serializeModel({ workbench }))

local reloaded = roblox.deserializeModel(fs.readFile(OUT_FILE))[1]
local reloadedSequences = 0

for _, rigId in rigIds do
	local rig = reloaded:FindFirstChild(rigId)
	if not rig then
		problem(`{rigId}: missing from the file`)
		continue
	end

	local root = rig:FindFirstChild("HumanoidRootPart")
	if not root or rig.PrimaryPart ~= root then
		problem(`{rigId}: root missing or not the primary part`)
	end

	if not rig:FindFirstChildOfClass("AnimationController") then
		problem(`{rigId}: no AnimationController`)
	end

	-- Every body part hangs from the right parent, through the right joint.
	for _, def in RigDefs.SKELETON do
		local part = rig:FindFirstChild(def.name)
		local joint = part and part:FindFirstChild(def.joint)
		if not part or not joint or not joint:IsA("Motor6D") then
			problem(`{rigId}.{def.name}: part or {def.joint} missing`)
		elseif joint.Part1 ~= part or not joint.Part0 or joint.Part0.Name ~= def.parent then
			problem(`{rigId}.{def.joint}: joins the wrong parts`)
		end
	end

	-- Every decoration is welded to something.
	for _, decoration in RigDefs.styleOf(rigId).decorations do
		local piece = rig:FindFirstChild(decoration.name)
		local weld = piece and piece:FindFirstChild(`{decoration.name}Weld`)
		if not weld or weld.Part0 == nil or weld.Part0.Name ~= decoration.attachTo then
			problem(`{rigId}.{decoration.name}: not welded to {decoration.attachTo}`)
		end
	end

	local saves = rig:FindFirstChild("AnimSaves")
	for name, anim in AnimationDefs.BY_RIG[rigId] or {} do
		local sequence = saves and saves:FindFirstChild(name)
		if not sequence then
			problem(`{rigId}/{name}: not saved`)
			continue
		end
		reloadedSequences += 1

		local frames = sequence:GetChildren()
		if #frames ~= #anim.keyframes then
			problem(`{rigId}/{name}: {#frames} keyframes, expected {#anim.keyframes}`)
		end

		local impacts = 0
		for _, frame in frames do
			if frame.Name == IMPACT_KEYFRAME then
				impacts += 1
			end

			-- Every animated part is keyed in every keyframe.
			local keyed = {}
			for _, pose in frame:GetDescendants() do
				if pose:IsA("Pose") and pose.Weight > 0 then
					keyed[pose.Name] = true
				end
			end
			for _, part in KeyframeMath.partsOf(anim) do
				if not keyed[part] then
					problem(`{rigId}/{name}: {part} not keyed at {frame.Time}`)
				end
			end
		end

		local expectedImpacts = if anim.impact then 1 else 0
		if impacts ~= expectedImpacts then
			problem(`{rigId}/{name}: {impacts} Impact keyframes, expected {expectedImpacts}`)
		end
	end
end

if reloadedSequences ~= sequenceCount then
	problem(`wrote {sequenceCount} animations but read back {reloadedSequences}`)
end

--[[ Check the animations are physically plausible ]]

-- Solves each rig's joints the way the engine does
-- (Part1 = Part0 * C0 * Transform * C1:Inverse()) for sampled moments of
-- every animation, and checks the result against the floor. Catches a pose
-- that sinks a rig into the ground, feet that float or dig in while standing,
-- or a death that doesn't end lying down.

local FLOOR_Y = 0
local SINK_TOLERANCE = 0.6
local PLANTED_TOLERANCE = 0.35
local LYING_MAX_HEIGHT = 1.5

-- Sampled finely, because the thing this catches is usually brief. A roll that
-- unwound its turn over three frames at the end put a head a full stud through
-- the floor and still passed at 24 samples: the grid stepped straight over it.
-- Every animation in the project clears the floor at this rate, so the cost is
-- a moment of startup and the check stops depending on where the samples land.
local SAMPLES = 96

local FEET = { "RightFoot", "LeftFoot" }

-- A handful of seeds per generated attack. The pose variation is a hash of
-- the seed, so this samples the space rather than trusting one point in it.
local GENERATED_SEEDS = { 1, 7, 29, 257, 4099 }

-- The lowest of a part's eight corners in world space. What the floor
-- check measures: a part can be above the floor at its centre and still
-- have a corner through it.
local function lowestPoint(cframe: any, size: any): number
	local lowest = math.huge
	for _, x in { -0.5, 0.5 } do
		for _, y in { -0.5, 0.5 } do
			for _, z in { -0.5, 0.5 } do
				local corner = cframe * CFrame.new(size.X * x, size.Y * y, size.Z * z)
				lowest = math.min(lowest, corner.Position.Y)
			end
		end
	end
	return lowest
end

for _, rigId in rigIds do
	local rig = reloaded:FindFirstChild(rigId)
	if not rig then
		continue
	end

	local root = rig:FindFirstChild("HumanoidRootPart")
	local partsByName: { [string]: any } = {}
	for _, def in RigDefs.SKELETON do
		partsByName[def.name] = rig:FindFirstChild(def.name)
	end

	-- Tolerances grow with the rig, so a bigger rig is held to the same
	-- standard relative to its size.
	local scale = RigDefs.scaleOf(rigId)
	local sinkTolerance = SINK_TOLERANCE * scale
	local plantedTolerance = PLANTED_TOLERANCE * scale
	local lyingMaxHeight = LYING_MAX_HEIGHT * scale

	-- Every part's world CFrame for one pose, solved the way the engine does
	-- it (Part1 = Part0 * C0 * Transform * C1:Inverse()).
	--
	-- This is what makes the floor check trustworthy: it is not an
	-- approximation of where a limb ends up, it is the same arithmetic
	-- Roblox will do.
	local function solve(pose: any): { [string]: any }
		local world: { [string]: any } = { HumanoidRootPart = root.CFrame }
		for _, def in RigDefs.SKELETON do
			local joint = partsByName[def.name]:FindFirstChild(def.joint)
			local values = pose[def.name]
			local transform = if values then poseCFrame(values, scale) else CFrame.new()
			world[def.name] = world[def.parent] * joint.C0 * transform * joint.C1:Inverse()
		end
		return world
	end

	for name, anim in AnimationDefs.BY_RIG[rigId] or {} do
		for sample = 0, SAMPLES do
			local t = anim.length * sample / SAMPLES
			local world = solve(KeyframeMath.sample(anim, t))

			for partName, cframe in world do
				if partName ~= "HumanoidRootPart" then
					local bottom = lowestPoint(cframe, partsByName[partName].Size)
					if bottom < FLOOR_Y - sinkTolerance then
						problem(string.format("%s/%s: %s sinks to y=%.2f at t=%.2f", rigId, name, partName, bottom, t))
					end
				end
			end

			-- Enemies' "idle" and players' "idle_<weapon>" alike: a planted
			-- stance is the one animation where a foot hanging in the air or
			-- pushed through the floor is on screen long enough to be seen.
			if string.sub(name, 1, 4) == "idle" then
				for _, foot in FEET do
					local bottom = lowestPoint(world[foot], partsByName[foot].Size)
					if math.abs(bottom - FLOOR_Y) > plantedTolerance then
						problem(string.format("%s/%s: %s not planted (y=%.2f) at t=%.2f", rigId, name, foot, bottom, t))
					end
				end
			end
		end

		if name == "death" then
			local final = solve(KeyframeMath.sample(anim, anim.length))
			local torsoHeight = final.LowerTorso.Position.Y
			if torsoHeight > lyingMaxHeight then
				problem(string.format("%s/death: ends with the hips %.2f off the floor", rigId, torsoHeight))
			end
		end
	end

	-- Generated attacks are not in `AnimationDefs.BY_RIG`. They are built at
	-- the moment they are thrown, from an archetype and a seed, so nothing
	-- above has ever seen one -- every enemy attack in the game was outside
	-- this check.
	--
	-- That did not matter while the generator barely posed legs. It matters a
	-- great deal now that the archetypes author crouches: hand-posing in
	-- Studio with a fixed root looks right and then ships a rig standing in
	-- the floor, because hip height has to be solved against the leg angles
	-- and that is exactly the sum nobody does by eye.
	--
	-- Both ends of a chain are checked. `carryOut` changes the final pose and
	-- therefore the whole tail of the animation.
	local enemyDef = EnemyDefs[rigId]
	if enemyDef then
		for attackId, attack in enemyDef.attacks do
			for _, seed in GENERATED_SEEDS do
				for _, carryOut in { false, true } do
					local anim = AttackChoreography.generate({
						archetype = attack.archetype,
						leadTime = attack.leadTime,
						recovery = CombatConstants.RECOVER_DURATION,
						seed = seed,
						accent = enemyDef.accent,
						carryOut = carryOut,
					})

					local label = string.format("%s/%s seed %d%s", rigId, attackId, seed, if carryOut then " (chained)" else "")
					for sample = 0, SAMPLES do
						local t = anim.length * sample / SAMPLES
						local world = solve(KeyframeMath.sample(anim, t))
						for partName, cframe in world do
							if partName ~= "HumanoidRootPart" then
								local bottom = lowestPoint(cframe, partsByName[partName].Size)
								if bottom < FLOOR_Y - sinkTolerance then
									problem(string.format("%s: %s sinks to y=%.2f at t=%.2f", label, partName, bottom, t))
								end
							end
						end
					end
				end
			end
		end
	end
end

if #problems > 0 then
	print("Workbench written, but it failed its checks:")
	for _, message in problems do
		print(`  - {message}`)
	end
	process.exit(1)
end

print(`Wrote {OUT_FILE}: {#rigIds} rigs, {sequenceCount} animations, {#fs.readFile(OUT_FILE)} bytes.`)
print("Drag it into a Studio place, select a rig, and open the Animation Editor.")
