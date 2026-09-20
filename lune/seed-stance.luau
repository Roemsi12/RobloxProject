--!strict
-- Emits the lower body for each archetype's tell and hit, as Luau to paste
-- into AttackChoreography's ARCHETYPE_DEFS.
--
--   lune run seed-stance
--
-- Why this exists rather than calling `crouch`/`footwork` from the generator:
-- a generated swing whose legs are a formula is the same crouch on every seed
-- of every archetype, which is "generated weight" -- the thing being
-- complained about. The helpers get the hip-height arithmetic right, which is
-- the part that is genuinely easy to get wrong by hand, so they produce the
-- *starting* numbers and then leave. What ships is authored literals, and the
-- workbench is where they get dragged into shape.
--
-- It also unions the part sets: every part either pose touches is written into
-- both, with `{}` where a joint is flat. A joint present in one pose and
-- absent from the other does not hold its value between them -- it unwinds to
-- flat, mid-swing, which is the defect this whole pass started from.

local SharedModules = require("./lib/sharedModules")
local shared = SharedModules.load("src/shared")
local AnimationDefs = shared.AnimationDefs
local AttackChoreography = shared.AttackChoreography

local crouch = AnimationDefs.crouch
local footwork = AnimationDefs.footwork

-- Starting points only. Each is "where is the weight, and which way are the
-- hips turned", per stage of the swing.
-- How much of the hit the arms are still holding at the carry.
--
-- 1.0: the upper body stays where the swing left it, and all the change is
-- underneath -- the feet gathering back under a body that has not stood up.
--
-- Tried at 0.55 first, on the theory that arms recovering toward a ready
-- position reads as "about to go again". It does not: scaling the whole upper
-- body toward neutral is just *standing up slowly*, and it measured 56-67% of
-- the hit's distance from rest -- closer to standing than the old derived
-- carry, which is the opposite of making a chain obvious.
--
-- The read that works is a body still committed from the waist up while the
-- feet reset under it. That is unmistakably not a finished swing, and it is
-- not any tell either, because no tell has its feet already gathered.
local CARRY_RECOVERY = 1.0

local STANCES: { [string]: { tell: any, hit: any, carry: any } } = {
	-- A flat swing. Weight sits back with the drawn weapon, then drives onto
	-- the front foot as the hips turn through the arc.
	WindBack = {
		tell = footwork(4, 14, 14),
		hit = footwork(24, 8, -20),
		-- Weight gathering back under the body, hips still turned through.
		carry = footwork(16, 14, -8),
	},
	-- Overhead. Rises onto the balls of the feet to gather, then drops into
	-- the blow -- the sink is what sells an overhead as heavy.
	Raise = {
		tell = crouch(6),
		hit = crouch(26),
		carry = crouch(16),
	},
	-- Gathered low on the back leg, then driven forward behind the thrust.
	Coil = {
		tell = footwork(-2, 20, -12),
		hit = footwork(30, 12, 14),
		carry = footwork(18, 14, 6),
	},
	-- Already the most grounded of the four, and the only one whose legs were
	-- posed by hand. Keeps its wide splay and gains the sink under it.
	Plant = {
		tell = {},
		hit = crouch(30),
		carry = crouch(20),
	},
}

local COMPONENTS = { "rx", "ry", "rz", "px", "py", "pz" }

-- The weight. At the carry these come from the braced stance rather than
-- from the hit, because the arms recovering and the legs staying loaded is
-- exactly the shape being aimed for -- a body that has its weapon back but
-- not its posture.
local LOWER = {
	LowerTorso = true,
	RightUpperLeg = true, RightLowerLeg = true, RightFoot = true,
	LeftUpperLeg = true, LeftLowerLeg = true, LeftFoot = true,
}

-- The archetype's own numbers win: these are seeds, not overrides.
local function under(base: any, stance: any): any
	local out: any = {}
	for part, pose in stance do
		out[part] = table.clone(pose)
	end
	for part, pose in base do
		local existing = out[part] or {}
		for _, axis in COMPONENTS do
			if (pose :: any)[axis] then
				existing[axis] = (pose :: any)[axis]
			end
		end
		out[part] = existing
	end
	return out
end

local function literal(pose: any): string
	local parts = {}
	for _, axis in COMPONENTS do
		local value = pose[axis]
		-- Rotations to a tenth, positions to a hundredth -- the same precision
		-- the workbench reads back, so hand-posing and seeding produce
		-- diffable numbers of the same shape.
		local isPosition = axis == "px" or axis == "py" or axis == "pz"
		local threshold = if isPosition then 0.005 else 0.05
		if value and math.abs(value) > threshold then
			local scale = if isPosition then 100 else 10
			local rounded = math.round(value * scale) / scale
			table.insert(parts, string.format("%s = %s", axis, tostring(rounded)))
		end
	end
	if #parts == 0 then
		return "{}"
	end
	return "{ " .. table.concat(parts, ", ") .. " }"
end

local function emit(name: string, poses: any, order: { string })
	print(string.format("\t\t%s = {", name))
	for _, part in order do
		print(string.format("\t\t\t%s = %s,", part, literal(poses[part] or {})))
	end
	print("\t\t},")
end

for _, archetype in AttackChoreography.ARCHETYPES do
	local def = AttackChoreography.get(archetype)
	local stance = STANCES[archetype]

	local tell = under(def.tell, stance.tell)
	local hit = under(def.hit, stance.hit)

	-- The carry: arms partway back from the hit, over legs that are still
	-- braced. The upper body comes from the hit rather than being posed
	-- separately, because a carry is the same swing still unfinished -- not a
	-- new shape, which is what would make it read as another tell.
	local recovered: any = {}
	for part, pose in hit do
		if LOWER[part] then
			continue
		end
		local copy: any = {}
		for _, axis in COMPONENTS do
			local value = (pose :: any)[axis]
			if value then
				copy[axis] = value * CARRY_RECOVERY
			end
		end
		recovered[part] = copy
	end
	local carry = under(recovered, stance.carry)

	-- One body: every part either stage touches is written into both.
	local names: { string } = {}
	local seen: { [string]: boolean } = {}
	for _, source in { tell, hit, carry } do
		for part in source do
			if not seen[part] then
				seen[part] = true
				table.insert(names, part)
			end
		end
	end
	table.sort(names)

	print(string.format("\t-- %s", archetype))
	emit("tell", tell, names)
	emit("hit", hit, names)
	emit("carry", carry, names)
	print("")
end
