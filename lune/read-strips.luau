--!strict
-- Read strips: what each of AttackChoreography's tells looks like at the
-- moment a player has to decide what to do about it.
--
--   lune run read-strips                -- the four tells side by side
--   lune run read-strips WindBack       -- one tell, through its whole run-up
--   lune run read-strips accent Coil    -- that tell as each enemy wears it
--   lune run read-strips chain Raise    -- a carry pose, then what follows it
--
-- The last two answer questions the numbers cannot. `accent` is the check on
-- whether enemies actually look different: the four tells are a shared
-- grammar on purpose, so without an accent every enemy would be the same
-- fighter reskinned. `chain` photographs the seam -- if a carry pose already
-- looks like one of the tells that can follow it, players will answer a beat
-- nobody asked for.
--
-- The fuzz harness proves the four tells are far apart as numbers. This is how
-- a person checks they are far apart to an eye, which is the only measure that
-- finally matters — it is an eye that has to parry them.
--
-- Lune has no renderer, so this emits a ready-to-paste Luau script instead of
-- an image. Run it, paste the output into Studio's command bar during a
-- playtest, and it builds the rigs posed and lit for the photograph. Keeping
-- the maths here means the poses in the picture are the same numbers the game
-- plays and the tests check, rather than a second implementation free to
-- drift from both.
--
-- Two things about that Studio half are load-bearing, both learned the hard
-- way:
--
--   * only the root part is anchored. Anchoring every part pins each one where
--     it stands and the Motor6Ds stop moving anything, which comes out as a
--     row of identical statues.
--   * the poses are applied on the client. `Motor6D.Transform` written on the
--     server does not replicate, so the server sees the pose and the camera
--     does not.

local process = require("@lune/process")

local SharedModules = require("./lib/sharedModules")

local Shared = SharedModules.load("src/shared")
local AttackChoreography = Shared.AttackChoreography
local KeyframeMath = Shared.KeyframeMath
local EnemyDefs = Shared.EnemyDefs

-- Where along the run-up to sample, as seconds before impact. Dense either
-- side of the reaction floor (0.35) and the decision (0.25), sparse elsewhere.
local OFFSETS = { 0.50, 0.40, 0.35, 0.30, 0.25, 0.15, 0.0 }

-- Long enough that the tell is still being held at the decision moment, so
-- what is photographed is the pose a player reads rather than the strike.
local LEAD = 0.45
local RECOVERY = 0.6
local SEED = 7

-- Modes:
--   (none)            the four tells at the decision moment
--   <Archetype>       one tell, through its whole run-up
--   accent <A>        the same tell worn by every enemy, side by side
--   chain <A>         a carry pose beside the tells that may follow it
local mode = process.args[1]
local modeArg = process.args[2]

if mode and not AttackChoreography.isParryable then
	error("AttackChoreography did not load")
end

-- The pose an archetype is in `beforeImpact` seconds before its hit
-- lands. What the strips photograph: the same moment for every
-- archetype, so four tells can be compared side by side.
local function poseAt(archetype: string, beforeImpact: number): KeyframeMath.PoseMap
	local anim = AttackChoreography.generate({
		archetype = archetype,
		leadTime = LEAD,
		recovery = RECOVERY,
		seed = SEED,
	})
	return KeyframeMath.sample(anim, math.max(anim.impact - beforeImpact, 0))
end

-- Tolerant of the sparse pose tables `tellPose` and `carryPose` return, where
-- an axis a pose does not touch is simply absent rather than zero.
local function poseLiteral(pose: any): string
	local parts = {}
	for part, v in pose do
		table.insert(parts, string.format("%s={%.1f,%.1f,%.1f}", part, v.rx or 0, v.ry or 0, v.rz or 0))
	end
	table.sort(parts)
	return "{" .. table.concat(parts, ",") .. "}"
end

--[[ What to photograph ]]

local labels: { string } = {}
local poses: { string } = {}
local title: string

if mode == "accent" then
	-- The check on whether the accent is doing its job. The four tells are a
	-- shared grammar on purpose, which is what makes them learnable and also
	-- what would make every enemy look alike without this. If a Shambler and
	-- a SkeletonWarrior are indistinguishable in this row, the accent is
	-- decorative and the enemies really are the same fighter reskinned.
	local archetype = modeArg or "WindBack"
	local names = {}
	for enemyId in EnemyDefs do
		table.insert(names, enemyId)
	end
	table.sort(names)

	for _, enemyId in names do
		local def = EnemyDefs[enemyId]
		table.insert(labels, enemyId)
		table.insert(poses, poseLiteral(AttackChoreography.tellPose(archetype, SEED, def.accent)))
	end
	title = `the {archetype} tell as each enemy wears it`
elseif mode == "chain" then
	-- The seam, as an eye sees it. Column one is where the body is left by
	-- the attack that just landed; the rest are the tells that may come out
	-- of it. The hazard being looked for is a carry that already looks like
	-- one of them, which would have players answering a beat that is not
	-- being asked.
	local from = modeArg or "WindBack"
	table.insert(labels, `carry({from})`)
	table.insert(poses, poseLiteral(AttackChoreography.carryPose(from, SEED)))

	for _, target in AttackChoreography.follows(from) do
		local answer = if AttackChoreography.isParryable(target) then "parry" else "DODGE"
		table.insert(labels, `-> {target} ({answer})`)
		table.insert(poses, poseLiteral(AttackChoreography.tellPose(target, SEED)))
	end
	title = `what follows a {from}: its carry pose, then each tell it can become`
elseif mode then
	for _, offset in OFFSETS do
		table.insert(labels, string.format("-%dms", math.floor(offset * 1000 + 0.5)))
		table.insert(poses, poseLiteral(poseAt(mode, offset)))
	end
	title = `{mode}, from 500ms before impact to the hit`
else
	for _, archetype in AttackChoreography.ARCHETYPES do
		local answer = if AttackChoreography.isParryable(archetype) then "parry" else "DODGE"
		table.insert(labels, `{archetype} ({answer})`)
		table.insert(poses, poseLiteral(poseAt(archetype, AttackChoreography.DECISION_AT)))
	end
	title = `the four tells at {math.floor(AttackChoreography.DECISION_AT * 1000)}ms before impact`
end

--[[ The Studio half ]]


print(`-- Read strip: {title}`)
print("-- Generated by `lune run read-strips`. Paste into Studio's command bar")
print("-- while playing. Builds the row, then poses it from the client.")
print("local Workspace = game:GetService(\"Workspace\")")
print("local RunService = game:GetService(\"RunService\")")
print("local Players = game:GetService(\"Players\")")
print("")
print("local LABELS = { \"" .. table.concat(labels, '", "') .. "\" }")
print("local POSES = {")
for _, pose in poses do
	print(`\t{pose},`)
end
print("}")
print([[

local ORIGIN = Vector3.new(0, 300, 0)
local SPACING = 13

local old = Workspace:FindFirstChild("ReadStrip")
if old then old:Destroy() end

local template
for _, m in Workspace:GetDescendants() do
	if m:IsA("Model") and m:GetAttribute("EnemyDefId") and m.PrimaryPart then
		template = m
		break
	end
end
assert(template, "no enemy rig in the world to pose")

local strip = Instance.new("Folder")
strip.Name = "ReadStrip"
strip.Parent = Workspace

-- A Neon field behind them: unlit, so it stays bright whatever the colour
-- grade is doing, and the rigs read as dark shapes against it. Silhouette is
-- what is being judged, and that is how you judge one.
local back = Instance.new("Part")
back.Anchored = true
back.CanCollide = false
back.Size = Vector3.new(SPACING * #POSES + 34, 40, 1)
back.CFrame = CFrame.new(ORIGIN + Vector3.new(0, 11, 12))
back.Color = Color3.fromRGB(132, 132, 138)
back.Material = Enum.Material.Neon
back.Parent = strip

local rigs = {}
for index, pose in POSES do
	local rig = template:Clone()
	rig.Name = "Frame" .. index
	rig:RemoveTag("Enemy")
	rig:SetAttribute("EnemyId", nil)
	rig:SetAttribute("EnemyDefId", nil)
	local humanoid = rig:FindFirstChildOfClass("Humanoid")
	if humanoid then humanoid:Destroy() end

	for _, d in rig:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = false
			d.CanCollide = false
			d.Massless = true
			d.Color = Color3.fromRGB(18, 16, 22)
			d.Material = Enum.Material.SmoothPlastic
		elseif d:IsA("Fire") or d:IsA("ParticleEmitter") or d:IsA("Light") then
			d:Destroy()
		end
	end

	local x = -(#POSES - 1) * SPACING / 2 + (index - 1) * SPACING
	rig:PivotTo(CFrame.new(ORIGIN + Vector3.new(x, 3.2, 0)) * CFrame.Angles(0, math.pi, 0))
	-- Only the root. Anchoring the rest stops the motors moving anything.
	rig.PrimaryPart.Anchored = true
	rig.Parent = strip

	local sign = Instance.new("Part")
	sign.Anchored = true
	sign.CanCollide = false
	sign.Transparency = 1
	sign.Size = Vector3.new(1, 1, 1)
	sign.CFrame = CFrame.new(ORIGIN + Vector3.new(x, 0.4, 0))
	sign.Parent = strip
	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.fromOffset(200, 34)
	gui.AlwaysOnTop = true
	gui.Parent = sign
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.TextSize = 22
	label.TextColor3 = Color3.fromRGB(20, 18, 24)
	label.Text = LABELS[index]
	label.Parent = gui

	rigs[index] = rig
end

-- Client-side, and every frame. Motor6D.Transform set on the server does not
-- replicate, and nothing else is driving these joints.
task.spawn(function()
	local deadline = os.clock() + 120
	while os.clock() < deadline do
		for index, rig in rigs do
			for part, angles in POSES[index] do
				local limb = rig:FindFirstChild(part)
				local joint = limb and limb:FindFirstChildWhichIsA("Motor6D")
				if joint then
					joint.Transform = CFrame.Angles(math.rad(angles[1]), math.rad(angles[2]), math.rad(angles[3]))
				end
			end
		end
		RunService.PreSimulation:Wait()
	end
end)

-- Streaming is on, so the camera has to be there for any of it to load.
local character = Players.LocalPlayer.Character
if character then
	character:PivotTo(CFrame.new(ORIGIN + Vector3.new(0, 4, -24)))
end

print("Read strip up for two minutes. Look from about " .. tostring(ORIGIN + Vector3.new(0, 5.5, -23)) .. ".")]])
