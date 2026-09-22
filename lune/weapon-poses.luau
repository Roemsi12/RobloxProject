--!strict
-- Weapon poses: every player animation with the weapon actually in the hand,
-- drawn, and checked for the mistakes that make a weapon look badly held.
--
--   lune run weapon-poses                -- every weapon
--   lune run weapon-poses Bow            -- one weapon
--   lune run weapon-poses Bow swing_     -- one weapon, animations matching
--   lune run weapon-poses --check        -- the checks only, no drawing
--
-- Writes workbench/WeaponPoses-<weapon>.html: each animation's keyframes as
-- flat-shaded drawings from the front, the side and three-quarters, with the
-- weapon built from WeaponModelDefs exactly the way WeaponVisuals welds it on
-- in game. Open it in a browser.
--
-- The animation workbench checks bodies against the floor, but a body is only
-- half of what a player sees during a swing. The other half is the weapon, and
-- nothing checked it at all: a blade can point at the sky at the moment it is
-- meant to be cutting, a staff can be "two-handed" with the second hand a
-- stud away from it, and a point can go through the floor on a downward chop
-- -- all without a single body part being wrong. So this checks:
--
--   * no piece of the weapon goes through the floor;
--   * the blade is in front of the body, not inside it, at the moment of impact;
--   * a weapon held in both hands has both hands on it, in every pose that is
--     meant to hold it that way;
--   * a bow is loosed standing upright, the arrow at the target, and the string
--     hand on the string, drawn well back (BowVFX draws the string to it).
--
-- Swings are drawn and checked the way the game plays them: laid over the
-- walking stance, faded in and out the way RigAnimation fades them.
--
-- It solves joints the same way the workbench does (Part0 * C0 * Transform *
-- C1:Inverse()), on the same stand-in R15 rig the player animations are
-- authored on.

local fs = require("@lune/fs")
local process = require("@lune/process")
local roblox = require("@lune/roblox")

local SharedModules = require("./lib/sharedModules")

local CFrame = roblox.CFrame
local Vector3 = roblox.Vector3

local shared = SharedModules.load("src/shared")
local AnimationDefs = shared.AnimationDefs
local KeyframeMath = shared.KeyframeMath
local RigDefs = shared.RigDefs
local WeaponModelDefs = shared.WeaponModelDefs

-- What "held properly" means for each weapon, in the space of the hand it
-- hangs from (the same space as WeaponModelDefs, measured from the grip).
--
-- `tip` is the business end: the point that has to be out in front of the
-- body when a hit lands. `offHand` is the length of haft the other hand
-- belongs on for a two-handed weapon, and `offHandFree` the animations
-- where it is allowed to let go (carrying an axe on one shoulder, say).
-- `aim` is for a bow: at the release, the axis `upright` (in the bow hand's
-- grip space) has to stand within `tilt` degrees of vertical, and `forward`
-- (the arrow) has to point at the target.
type TipDef = { hand: string, at: { number }, minAhead: number? }
type ShaftDef = { hand: string, from: { number }, to: { number }, name: string }
type AimDef = { hand: string, upright: { number }, forward: { number }, tilt: number }
type GripDef = { tip: TipDef?, offHand: ShaftDef?, offHandFree: { [string]: boolean }, aim: AimDef? }

local GRIPS: { [string]: GripDef } = {
	SwordAndShield = { tip = { hand = "RightHand", at = { 0, 0, -4.3 } }, offHandFree = {} },
	Daggers = { tip = { hand = "RightHand", at = { 0, 0, -1.85 } }, offHandFree = {} },
	Rapier = { tip = { hand = "RightHand", at = { 0, 0, -5.8 } }, offHandFree = {} },
	Focus = { tip = { hand = "RightHand", at = { 0, 0, -1.3 }, minAhead = 0.3 }, offHandFree = {} },
	Staff = {
		tip = { hand = "RightHand", at = { 0, 0, -4.3 }, minAhead = 0.3 },
		offHand = { hand = "RightHand", from = { 0, 0, 1.9 }, to = { 0, 0, -3.6 }, name = "staff" },
		offHandFree = { stance_Staff = true },
	},
	Greataxe = {
		tip = { hand = "RightHand", at = { 0, -1.8, -3.2 } },
		offHand = { hand = "RightHand", from = { 0, 0, 1.85 }, to = { 0, 0, -2.8 }, name = "haft" },
		offHandFree = { stance_Greataxe = true },
	},
	Bow = {
		offHandFree = {},
		aim = { hand = "LeftHand", upright = { 0, 0, -1 }, forward = { 0, -1, 0 }, tilt = 30 },
	},
}

local WeaponGrips = {
	of = function(weaponId: string): GripDef?
		return GRIPS[weaponId]
	end,
}

local OUT_DIR = "workbench"
local OUT_PREFIX = "WeaponPoses-"

local args = process.args
local checkOnly = table.find(args, "--check") ~= nil
local positional = {}
for _, arg in args do
	if string.sub(arg, 1, 2) ~= "--" then
		table.insert(positional, arg)
	end
end
local only: string? = positional[1]
local animFilter: string? = positional[2]

--[[ Solving the rig ]]

local ORIGIN = { 0, 0, 0 }
local centers: { [string]: { number } } = { HumanoidRootPart = ORIGIN }
local sizes: { [string]: any } = {}
for _, def in RigDefs.SKELETON do
	centers[def.name] = def.center
	sizes[def.name] = Vector3.new(def.size[1], def.size[2], def.size[3])
end

local function offset(from: { number }, to: { number }): any
	return CFrame.new(to[1] - from[1], to[2] - from[2], to[3] - from[3])
end

local joints: { [string]: { c0: any, c1: any, parent: string } } = {}
for _, def in RigDefs.SKELETON do
	joints[def.name] = {
		parent = def.parent,
		c0 = offset(centers[def.parent], def.pivot),
		c1 = offset(def.center, def.pivot),
	}
end

-- The floor, relative to the root: the soles of the feet at rest.
local FLOOR_Y = -3.0

local function poseCFrame(values: any): any
	return CFrame.new(values.px, values.py, values.pz)
		* CFrame.Angles(math.rad(values.rx), math.rad(values.ry), math.rad(values.rz))
end

-- Every part's world CFrame for one pose map.
local function solve(pose: any): { [string]: any }
	local world: { [string]: any } = { HumanoidRootPart = CFrame.new() }
	for _, def in RigDefs.SKELETON do
		local joint = joints[def.name]
		local values = pose[def.name]
		local transform = if values then poseCFrame(values) else CFrame.new()
		world[def.name] = world[joint.parent] * joint.c0 * transform * joint.c1:Inverse()
	end
	return world
end

--[[ Placing the weapon ]]

-- Where a real avatar's RightGripAttachment / LeftGripAttachment sits in its
-- hand, which is where WeaponVisuals hangs the weapon from.
local GRIP = CFrame.new(0, -0.15, 0)
local IS_HAND = { RightHand = true, LeftHand = true }

local function pieceOffset(piece: any): any
	local r = piece.rotation or { 0, 0, 0 }
	return CFrame.new(piece.offset[1], piece.offset[2], piece.offset[3])
		* CFrame.Angles(math.rad(r[1]), math.rad(r[2]), math.rad(r[3]))
end

type Box = { cframe: any, size: any, color: { number }, shape: string, alpha: number, name: string, weapon: boolean }

local function weaponBoxes(weaponId: string, world: { [string]: any }): { Box }
	local def = WeaponModelDefs.MODELS[weaponId]
	local boxes: { Box } = {}
	if not def then
		return boxes
	end
	local hold = CFrame.new()
	if def.hold then
		local r = def.hold.rotation
		hold = CFrame.new(def.hold.offset[1], def.hold.offset[2], def.hold.offset[3])
			* CFrame.Angles(math.rad(r[1]), math.rad(r[2]), math.rad(r[3]))
	end
	for _, piece in def.pieces do
		local host = world[piece.attachTo]
		local anchor = if IS_HAND[piece.attachTo] then GRIP * hold else CFrame.new()
		table.insert(boxes, {
			cframe = host * anchor * pieceOffset(piece),
			size = Vector3.new(piece.size[1], piece.size[2], piece.size[3]),
			color = piece.color,
			shape = piece.shape or "Block",
			alpha = 1 - (piece.transparency or 0),
			name = piece.name,
			weapon = true,
		})
	end
	return boxes
end

local BODY_COLORS: { [string]: { number } } = {
	Head = { 236, 200, 150 },
	UpperTorso = { 92, 104, 128 },
	LowerTorso = { 72, 80, 98 },
}
local LIMB = { 150, 132, 112 }
local LEG = { 70, 64, 60 }

local function bodyBoxes(world: { [string]: any }): { Box }
	local boxes: { Box } = {}
	for _, def in RigDefs.SKELETON do
		local color = BODY_COLORS[def.name]
			or if string.find(def.name, "Leg") or string.find(def.name, "Foot") then LEG else LIMB
		table.insert(boxes, {
			cframe = world[def.name],
			size = sizes[def.name],
			color = color,
			shape = "Block",
			alpha = 1,
			name = def.name,
			weapon = false,
		})
	end
	return boxes
end

--[[ Checks ]]

-- Problems are grouped by animation and kind, keeping the worst moment, so a
-- pose that is wrong for half a second reads as one line rather than twenty.
type Problem = { key: string, message: string, worst: number }
local problems: { Problem } = {}
local problemIndex: { [string]: Problem } = {}
local function problem(message: string, key: string?, amount: number?)
	local k = key or message
	local existing = problemIndex[k]
	local worst = amount or 0
	if existing then
		if worst > existing.worst then
			existing.worst = worst
			existing.message = message
		end
		return
	end
	local entry = { key = k, message = message, worst = worst }
	problemIndex[k] = entry
	table.insert(problems, entry)
end

local function lowestPoint(box: Box): number
	local lowest = math.huge
	for _, x in { -0.5, 0.5 } do
		for _, y in { -0.5, 0.5 } do
			for _, z in { -0.5, 0.5 } do
				local corner = box.cframe * CFrame.new(box.size.X * x, box.size.Y * y, box.size.Z * z)
				lowest = math.min(lowest, corner.Position.Y)
			end
		end
	end
	return lowest
end

-- Whether a world point is inside a body part, shrunk by `margin` so that a
-- blade merely brushing a sleeve does not count.
local function inside(world: { [string]: any }, partName: string, point: any, margin: number): boolean
	local localPoint = world[partName]:PointToObjectSpace(point)
	local size = sizes[partName]
	return math.abs(localPoint.X) < size.X / 2 - margin
		and math.abs(localPoint.Y) < size.Y / 2 - margin
		and math.abs(localPoint.Z) < size.Z / 2 - margin
end

local CORE = { "UpperTorso", "LowerTorso", "Head" }

-- Distance from a point to the segment a..b.
local function segmentDistance(p: any, a: any, b: any): number
	local ab = b - a
	local t = math.clamp((p - a):Dot(ab) / ab:Dot(ab), 0, 1)
	return (p - (a + ab * t)).Magnitude
end

local SINK_TOLERANCE = 0.15
local OFF_HAND_TOLERANCE = 0.75
local THROUGH_BODY_MARGIN = 0.12

-- Every check for one sampled moment of one animation.
local function checkMoment(weaponId: string, animName: string, t: number, world: any, atImpact: boolean, fading: boolean?)
	local label = string.format("%s/%s t=%.2f", weaponId, animName, t)
	local anim = `{weaponId}/{animName}`
	local grips = WeaponGrips.of(weaponId)

	for _, box in weaponBoxes(weaponId, world) do
		local bottom = lowestPoint(box)
		if bottom < FLOOR_Y - SINK_TOLERANCE then
			local depth = FLOOR_Y - bottom
			problem(string.format("%s: %s goes %.2f through the floor", label, box.name, depth), `{anim}/floor`, depth)
		end
	end

	-- The business end has to be out in front of the body at the moment the
	-- hit lands, not buried in it or pointing back over the shoulder.
	if grips and grips.tip and atImpact then
		local hand = world[grips.tip.hand] * GRIP
		local tip = hand * Vector3.new(grips.tip.at[1], grips.tip.at[2], grips.tip.at[3])
		for _, part in CORE do
			if inside(world, part, tip, THROUGH_BODY_MARGIN) then
				problem(`{label}: the tip is inside the {part} at impact`, `{anim}/inside`)
			end
		end
		-- Measured along the way the character faces, which is where the
		-- server looks for a target, not the way the chest has twisted to.
		local ahead = -tip.Z
		if ahead < (grips.tip.minAhead or 1.5) then
			problem(string.format("%s: the tip is only %.2f in front of the body at impact", label, ahead), `{anim}/ahead`)
		end
	end

	-- A bow is loosed standing up, with the arrow at the target.
	if grips and grips.aim and atImpact then
		local aim = grips.aim
		local hand = world[aim.hand] * GRIP
		local up = hand:VectorToWorldSpace(Vector3.new(aim.upright[1], aim.upright[2], aim.upright[3]))
		local tilt = math.deg(math.acos(math.clamp(up.Y, -1, 1)))
		if tilt > aim.tilt then
			problem(string.format("%s: the bow leans %.0f degrees off upright at the release", label, tilt), `{anim}/upright`)
		end
		local arrow = hand:VectorToWorldSpace(Vector3.new(aim.forward[1], aim.forward[2], aim.forward[3]))
		-- The string hand has to be on the string at the release, well back
		-- along the arrow: BowVFX only draws the string back to a hand that is.
		local stringHand = (world.RightHand * GRIP).Position
		local onBow = hand:PointToObjectSpace(stringHand)
		local bowDef = WeaponModelDefs.BOW
		local drawn = onBow.Y - bowDef.braceY
		if drawn < 2 or math.abs(onBow.X) > 0.8 or math.abs(onBow.Z - bowDef.arrowZ) > 0.8 then
			problem(
				string.format("%s: the string hand is off the string at the release (drawn %.2f, off %.2f / %.2f)", label, drawn, onBow.X, onBow.Z - bowDef.arrowZ),
				`{anim}/draw`
			)
		end

		-- The server shoots along the character's facing, not the chest's.
		local off = math.deg(math.acos(math.clamp(arrow:Dot(Vector3.new(0, 0, -1)), -1, 1)))
		if off > 20 then
			problem(string.format("%s: the arrow points %.0f degrees away from where the shot goes", label, off), `{anim}/arrow`)
		end
	end

	-- A two-handed weapon has both hands on it whenever the pose says so.
	-- Not while an action is still fading in from (or out to) the stance under
	-- it: that blend is between two different grips by design.
	if grips and grips.offHand and not grips.offHandFree[animName] and not fading then
		local shaft = grips.offHand
		local host = world[shaft.hand] * GRIP
		local a = host * Vector3.new(shaft.from[1], shaft.from[2], shaft.from[3])
		local b = host * Vector3.new(shaft.to[1], shaft.to[2], shaft.to[3])
		local other = if shaft.hand == "RightHand" then "LeftHand" else "RightHand"
		local otherGrip = (world[other] * GRIP).Position
		local distance = segmentDistance(otherGrip, a, b)
		if distance > OFF_HAND_TOLERANCE then
			problem(string.format("%s: off hand is %.2f from the %s", label, distance, shaft.name), `{anim}/offhand`, distance)
		end
	end
end

--[[ Drawing ]]

type View = { name: string, forward: any, right: any, up: any }

local function view(name: string, forward: any): View
	local f = forward.Unit
	local right = f:Cross(Vector3.new(0, 1, 0)).Unit
	local up = right:Cross(f).Unit
	return { name = name, forward = f, right = right, up = up }
end

local VIEWS: { View } = {
	view("front", Vector3.new(0, -0.12, 1)),
	view("side", Vector3.new(-1, -0.12, 0)),
	view("3/4", Vector3.new(-0.62, -0.3, 0.72)),
}

local LIGHT = Vector3.new(0.35, 0.85, -0.4).Unit
local SCALE = 20
local W, H = 190, 190
local CX, CY = W / 2, 84

local FACES = {
	{ n = { 1, 0, 0 }, c = { { 1, -1, -1 }, { 1, 1, -1 }, { 1, 1, 1 }, { 1, -1, 1 } } },
	{ n = { -1, 0, 0 }, c = { { -1, -1, 1 }, { -1, 1, 1 }, { -1, 1, -1 }, { -1, -1, -1 } } },
	{ n = { 0, 1, 0 }, c = { { -1, 1, -1 }, { -1, 1, 1 }, { 1, 1, 1 }, { 1, 1, -1 } } },
	{ n = { 0, -1, 0 }, c = { { -1, -1, 1 }, { -1, -1, -1 }, { 1, -1, -1 }, { 1, -1, 1 } } },
	{ n = { 0, 0, 1 }, c = { { -1, -1, 1 }, { 1, -1, 1 }, { 1, 1, 1 }, { -1, 1, 1 } } },
	{ n = { 0, 0, -1 }, c = { { 1, -1, -1 }, { -1, -1, -1 }, { -1, 1, -1 }, { 1, 1, -1 } } },
}

local function shade(color: { number }, k: number): string
	return string.format(
		"rgb(%d,%d,%d)",
		math.clamp(math.floor(color[1] * k), 0, 255),
		math.clamp(math.floor(color[2] * k), 0, 255),
		math.clamp(math.floor(color[3] * k), 0, 255)
	)
end

local function project(v: View, p: any): (number, number, number)
	return CX + p:Dot(v.right) * SCALE, CY - p:Dot(v.up) * SCALE, p:Dot(v.forward)
end

local function drawBoxes(v: View, boxes: { Box }): string
	local polys: { { depth: number, svg: string } } = {}

	-- The floor, as a quad under the rig.
	do
		local pts = {}
		for _, c in { { -4, -4 }, { 4, -4 }, { 4, 4 }, { -4, 4 } } do
			local x, y = project(v, Vector3.new(c[1], FLOOR_Y, c[2]))
			table.insert(pts, string.format("%.1f,%.1f", x, y))
		end
		table.insert(polys, { depth = math.huge, svg = `<polygon points="{table.concat(pts, " ")}" fill="#2a2d33" stroke="#3a3e46"/>` })
	end

	for _, box in boxes do
		local half = box.size / 2
		if box.shape == "Ball" then
			local x, y, depth = project(v, box.cframe.Position)
			table.insert(polys, {
				depth = depth,
				svg = string.format(
					'<circle cx="%.1f" cy="%.1f" r="%.1f" fill="%s" fill-opacity="%.2f"/>',
					x,
					y,
					half.X * SCALE,
					shade(box.color, 1),
					box.alpha
				),
			})
			continue
		end

		for _, face in FACES do
			local normal = box.cframe:VectorToWorldSpace(Vector3.new(face.n[1], face.n[2], face.n[3]))
			if normal:Dot(v.forward) >= 0 then
				continue
			end
			local pts = {}
			local depth = 0
			for _, c in face.c do
				local p = box.cframe * Vector3.new(c[1] * half.X, c[2] * half.Y, c[3] * half.Z)
				local x, y, d = project(v, p)
				depth += d / 4
				table.insert(pts, string.format("%.1f,%.1f", x, y))
			end
			local light = 0.5 + 0.5 * math.max(0, normal:Dot(LIGHT))
			table.insert(polys, {
				depth = depth,
				svg = string.format(
					'<polygon points="%s" fill="%s" fill-opacity="%.2f"%s/>',
					table.concat(pts, " "),
					shade(box.color, light),
					box.alpha,
					if box.weapon then "" else ' stroke="#00000030" stroke-width="0.5"'
				),
			})
		end
	end

	table.sort(polys, function(a, b)
		return a.depth > b.depth
	end)

	local out = {}
	for _, poly in polys do
		table.insert(out, poly.svg)
	end
	return table.concat(out)
end

local function drawMoment(title: string, boxes: { Box }, flagged: boolean): string
	local cells = {}
	for _, v in VIEWS do
		table.insert(
			cells,
			`<svg viewBox="0 0 {W} {H}" width="{W}" height="{H}"><rect width="{W}" height="{H}" fill="#16181c"/>{drawBoxes(v, boxes)}<text x="6" y="{H - 8}" fill="#8a8f98" font-size="11">{v.name}</text></svg>`
		)
	end
	local cls = if flagged then "moment flagged" else "moment"
	return `<div class="{cls}"><h3>{title}</h3><div class="views">{table.concat(cells)}</div></div>`
end

--[[ Which moments to look at ]]

local function isAction(name: string): boolean
	return string.sub(name, 1, 6) == "swing_" or string.sub(name, 1, 9) == "critical_"
end


local function momentsOf(name: string, anim: any): { { t: number, label: string } }
	local out = {}
	if anim.looped then
		table.insert(out, { t = 0, label = "loop" })
		table.insert(out, { t = anim.length * 0.5, label = "loop half" })
	elseif isAction(name) then
		-- Fixed beats around the impact rather than the keyframes: some
		-- animations are densely resampled (two-handed ones), and the
		-- keyframes of those say nothing about where the beats are.
		local impact = anim.impact or anim.length / 2
		local tail = anim.length - impact
		for _, beat in { { impact * 0.2, "gather" }, { impact * 0.6, "windup" }, { impact * 0.85, "coil" }, { impact, "impact" }, { impact + tail * 0.2, "follow" }, { impact + tail * 0.6, "recover" } } do
			table.insert(out, { t = beat[1], label = beat[2] })
		end
	else
		table.insert(out, { t = anim.length, label = "held" })
	end
	return out
end

--[[ Run ]]

local PLAYER = AnimationDefs.BY_RIG[RigDefs.PLAYER_RIG]

local weaponIds = {}
for weaponId in WeaponModelDefs.MODELS do
	if not only or only == weaponId then
		table.insert(weaponIds, weaponId)
	end
end
table.sort(weaponIds)

local sections: { [string]: string } = {}
local SAMPLES = 48

for _, weaponId in weaponIds do
	local names = {}
	for name in PLAYER do
		local suffix = `_{weaponId}`
		local ours = string.sub(name, -#suffix) == suffix or string.find(name, `_{weaponId}_`, 1, true) ~= nil
		if ours and (not animFilter or string.find(name, animFilter, 1, true)) then
			table.insert(names, name)
		end
	end
	table.sort(names)

	-- On a player an action is laid over the stance, and a part the action
	-- does not animate keeps the stance's pose (RigAnimation.step). So a
	-- swing that never mentions the wrist swings with whatever wrist the
	-- stance had. Drawn and checked the way the game plays it: over the
	-- walking stance, which is what a swing is mostly thrown from.
	--
	-- An action also fades in and out over the stance rather than cutting
	-- (RigAnimation's OVERLAY_FADE_IN / OUT), which is reproduced here: a
	-- swing's first frame is the stance, not the rest pose it is keyed from.
	local stance = PLAYER[AnimationDefs.stance(weaponId)]
	local base = if stance then KeyframeMath.sample(stance, 0) else {}
	local FADE_IN, FADE_OUT = 0.06, 0.12
	local function poseAt(anim: any, t: number, name: string): (any, boolean)
		local weight = 1
		if anim.priority == "Action" and not anim.looped then
			weight = math.min(t / FADE_IN, 1)
			-- A guard is held on its last frame rather than let go.
			if string.sub(name, 1, 6) ~= "guard_" then
				weight = math.min(weight, math.max((anim.length - t) / FADE_OUT, 0))
			end
		end
		local pose = table.clone(base)
		for part, values in KeyframeMath.sample(anim, t) do
			-- Blended the way RigAnimation does it, as CFrames (Lerp), not angle by
			-- angle: the two turn through different in-betweens.
			local under = base[part] or KeyframeMath.REST
			local mixed = poseCFrame(under):Lerp(poseCFrame(values), weight)
			local rx, ry, rz = mixed:ToEulerAnglesXYZ()
			pose[part] = {
				rx = math.deg(rx),
				ry = math.deg(ry),
				rz = math.deg(rz),
				px = mixed.Position.X,
				py = mixed.Position.Y,
				pz = mixed.Position.Z,
			}
		end
		return pose, weight < 1
	end

	local blocks = {}
	for _, name in names do
		local anim = PLAYER[name]
		local before = #problems

		for sample = 0, SAMPLES do
			local t = anim.length * sample / SAMPLES
			local pose, fading = poseAt(anim, t, name)
			checkMoment(weaponId, name, t, solve(pose), false, fading)
		end
		if anim.impact then
			checkMoment(weaponId, name, anim.impact, solve(poseAt(anim, anim.impact, name)), true)
		end
		local flagged = #problems > before

		if not checkOnly then
			local moments = {}
			for _, moment in momentsOf(name, anim) do
				local world = solve(poseAt(anim, moment.t, name))
				local boxes = bodyBoxes(world)
				for _, box in weaponBoxes(weaponId, world) do
					table.insert(boxes, box)
				end
				table.insert(moments, drawMoment(string.format("%s  %.2fs", moment.label, moment.t), boxes, false))
			end
			local cls = if flagged then "anim flagged" else "anim"
			table.insert(blocks, `<section class="{cls}"><h2>{name}</h2><div class="moments">{table.concat(moments)}</div></section>`)
		end
	end
	sections[weaponId] = table.concat(blocks)
end

-- One page per weapon: all of them on one page is too many drawings for a
-- browser to lay out comfortably.
if not checkOnly then
	if not fs.isDir(OUT_DIR) then
		fs.writeDir(OUT_DIR)
	end
	local nav = {}
	for _, weaponId in weaponIds do
		table.insert(nav, `<a href="{OUT_PREFIX}{weaponId}.html">{weaponId}</a>`)
	end
	for _, weaponId in weaponIds do
		local problemList = {}
		for _, entry in problems do
			if string.sub(entry.key, 1, #weaponId + 1) == `{weaponId}/` then
				table.insert(problemList, `<li>{entry.message}</li>`)
			end
		end
		local html = table.concat({
			`<!doctype html><meta charset=utf-8><title>{weaponId} poses</title><style>`,
			"body{background:#0e0f12;color:#d8dce3;font:13px system-ui;margin:16px}",
			"a{color:#8ab4f8;margin-right:12px}",
			"h2{font-size:14px;margin:18px 0 6px}h3{font-size:11px;margin:4px 0;color:#9aa0aa;font-weight:500}",
			".moments{display:flex;flex-wrap:wrap;gap:10px}.views{display:flex;gap:2px}",
			".anim.flagged h2{color:#f28b82}.problems{color:#f28b82}",
			"</style>",
			`<nav>{table.concat(nav)}</nav><h1>{weaponId}</h1>`,
			`<ul class="problems">{table.concat(problemList)}</ul>`,
			sections[weaponId],
		})
		fs.writeFile(`{OUT_DIR}/{OUT_PREFIX}{weaponId}.html`, html)
	end
	print(`Wrote {OUT_DIR}/{OUT_PREFIX}<weapon>.html for {#weaponIds} weapon(s)`)
end

if #problems > 0 then
	print(`{#problems} problem(s):`)
	for _, message in problems do
		print(`  - {message.message}`)
	end
	process.exit(1)
end
print("Every weapon pose passed.")
