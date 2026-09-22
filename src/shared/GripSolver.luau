--!strict
-- Where a weapon is, turned into where the arms have to be to hold it. Pure —
-- no Roblox API.
--
-- The player animations were written joint by joint: so many degrees at the
-- shoulder, so many at the elbow. That is a fine way to pose a body and a
-- poor way to pose a weapon, because the weapon is at the end of the chain
-- and nobody can add up three rotations in their head. It showed: blades
-- pointing at the sky at the moment they were meant to be cutting, and
-- two-handed weapons whose second hand was three studs off the haft.
--
-- So a weapon pose can now be written the way a person would describe it —
-- "the fist here, the head pointing there, the edge leading" — and this works
-- out the joint angles that put it there:
--
--   hold     the whole arm, from where the fist is and which way the weapon
--            points (two-bone IK for shoulder and elbow, then the wrist)
--   aim      the wrist only, keeping an authored arm and turning the weapon
--            to point where it should
--   offHand  the other arm, onto the haft of whatever the first hand holds
--
-- Everything is in *chest space*: the UpperTorso's own frame, +X to the rig's
-- right, +Y up, +Z back (so -Z is forward). Chest space is what makes a pose
-- independent of the legs and hips under it: the torso twist that drives a
-- swing carries the weapon with it, and the footwork can change without
-- moving the hands off the haft.
--
-- Weapon axes, in the space of the hand that holds it (as WeaponModelDefs
-- builds them): the haft or blade runs along -Z from the grip, toward the head
-- or point, and the edge faces -Y, out of the fingers. Angles come out in the
-- same Euler convention every pose uses (CFrame.Angles order: Rx * Ry * Rz),
-- on the same stand-in skeleton the player animations are authored on
-- (RigDefs).

local RigDefs = require(script.Parent.RigDefs)

export type Vec = { number }
-- A 3x3 rotation, row-major.
type Mat = { number }
export type Angles = { rx: number, ry: number, rz: number }
type Poses = { [string]: { rx: number?, ry: number?, rz: number?, px: number?, py: number?, pz: number? } }

local GripSolver = {}

--[[ Vectors and rotations ]]

local function add(a: Vec, b: Vec): Vec
	return { a[1] + b[1], a[2] + b[2], a[3] + b[3] }
end

local function sub(a: Vec, b: Vec): Vec
	return { a[1] - b[1], a[2] - b[2], a[3] - b[3] }
end

local function scale(a: Vec, s: number): Vec
	return { a[1] * s, a[2] * s, a[3] * s }
end

local function dot(a: Vec, b: Vec): number
	return a[1] * b[1] + a[2] * b[2] + a[3] * b[3]
end

local function cross(a: Vec, b: Vec): Vec
	return { a[2] * b[3] - a[3] * b[2], a[3] * b[1] - a[1] * b[3], a[1] * b[2] - a[2] * b[1] }
end

local function length(a: Vec): number
	return math.sqrt(dot(a, a))
end

local function unit(a: Vec): Vec
	local l = length(a)
	if l < 1e-9 then
		return { 0, 0, 0 }
	end
	return scale(a, 1 / l)
end

-- `a` with its component along the unit vector `n` removed.
local function perpendicular(a: Vec, n: Vec): Vec
	return sub(a, scale(n, dot(a, n)))
end

local function mul(a: Mat, b: Mat): Mat
	local out = table.create(9, 0)
	for row = 0, 2 do
		for col = 1, 3 do
			out[row * 3 + col] = a[row * 3 + 1] * b[col] + a[row * 3 + 2] * b[3 + col] + a[row * 3 + 3] * b[6 + col]
		end
	end
	return out
end

local function apply(m: Mat, v: Vec): Vec
	return {
		m[1] * v[1] + m[2] * v[2] + m[3] * v[3],
		m[4] * v[1] + m[5] * v[2] + m[6] * v[3],
		m[7] * v[1] + m[8] * v[2] + m[9] * v[3],
	}
end

local function transpose(m: Mat): Mat
	return { m[1], m[4], m[7], m[2], m[5], m[8], m[3], m[6], m[9] }
end

-- The rotation whose columns are these three axes.
local function columns(x: Vec, y: Vec, z: Vec): Mat
	return { x[1], y[1], z[1], x[2], y[2], z[2], x[3], y[3], z[3] }
end

local function rotX(degrees: number): Mat
	local c, s = math.cos(math.rad(degrees)), math.sin(math.rad(degrees))
	return { 1, 0, 0, 0, c, -s, 0, s, c }
end

local function rotY(degrees: number): Mat
	local c, s = math.cos(math.rad(degrees)), math.sin(math.rad(degrees))
	return { c, 0, s, 0, 1, 0, -s, 0, c }
end

local function rotZ(degrees: number): Mat
	local c, s = math.cos(math.rad(degrees)), math.sin(math.rad(degrees))
	return { c, -s, 0, s, c, 0, 0, 0, 1 }
end

-- A pose's rotation, as CFrame.Angles builds it: Rx * Ry * Rz.
local function fromAngles(pose: any?): Mat
	if not pose then
		return rotX(0)
	end
	return mul(mul(rotX(pose.rx or 0), rotY(pose.ry or 0)), rotZ(pose.rz or 0))
end

-- `angle` moved by whole turns to sit as close to `near` as it can.
local function unwrap(angle: number, near: number): number
	return angle + 360 * math.floor((near - angle) / 360 + 0.5)
end

-- Euler angles for a rotation, in the Rx * Ry * Rz convention.
--
-- Every rotation has two such readings (and a gimbal-locked one has a whole
-- family). Which one comes back matters more than it looks: poses are
-- interpolated component by component, so two keyframes that describe
-- neighbouring rotations with different readings spin the limb the long way
-- round between them. The reading closest to `near` is chosen — the previous
-- keyframe's, or rest — so the numbers move as little as the rotation does.
local function toAngles(m: Mat, near: Angles?): Angles
	local ref = near or { rx = 0, ry = 0, rz = 0 }
	local sinY = math.clamp(m[3], -1, 1)

	local candidates: { Angles } = {}
	if math.abs(sinY) > 1 - 1e-10 then
		-- Gimbal lock: only rx + rz (or rz - rx) is fixed. Keep rx where the
		-- reference had it and put the rest on rz.
		local ry = if sinY > 0 then 90 else -90
		local rx = ref.rx
		local combined = math.deg(math.atan2(m[4], m[5]))
		local rz = if sinY > 0 then combined - rx else combined + rx
		table.insert(candidates, { rx = rx, ry = ry, rz = rz })
	else
		local ry = math.deg(math.asin(sinY))
		local rx = math.deg(math.atan2(-m[6], m[9]))
		local rz = math.deg(math.atan2(-m[2], m[1]))
		table.insert(candidates, { rx = rx, ry = ry, rz = rz })
		table.insert(candidates, { rx = rx + 180, ry = 180 - ry, rz = rz + 180 })
	end

	-- Unwrapped toward the reference, but never past a full turn either way:
	-- a chain of keyframes each nudged toward the last can otherwise creep
	-- out to -400 and beyond, which is the same rotation and a nonsense number.
	local function fit(angle: number, toward: number): number
		local value = unwrap(angle, toward)
		if value > 360 then
			value -= 360
		elseif value < -360 then
			value += 360
		end
		return value
	end

	local best: Angles = candidates[1]
	local bestCost = math.huge
	for _, c in candidates do
		local fitted = {
			rx = fit(c.rx, ref.rx),
			ry = fit(c.ry, ref.ry),
			rz = fit(c.rz, ref.rz),
		}
		local cost = math.abs(fitted.rx - ref.rx) + math.abs(fitted.ry - ref.ry) + math.abs(fitted.rz - ref.rz)
		if cost < bestCost then
			best = fitted
			bestCost = cost
		end
	end
	return best
end

-- The shortest rotation taking unit vector `from` onto unit vector `to`.
local function between(from: Vec, to: Vec): Mat
	local axis = cross(from, to)
	local s = length(axis)
	local c = dot(from, to)
	if s < 1e-9 then
		if c > 0 then
			return rotX(0)
		end
		-- Opposite: half a turn about anything perpendicular.
		local other = if math.abs(from[1]) < 0.9 then { 1, 0, 0 } else { 0, 1, 0 }
		axis = unit(cross(from, other))
		s, c = 0, -1
	else
		axis = scale(axis, 1 / s)
	end
	-- Rodrigues: I + sin * K + (1 - cos) * K^2.
	local x, y, z = axis[1], axis[2], axis[3]
	local t = 1 - c
	return {
		c + x * x * t, x * y * t - z * s, x * z * t + y * s,
		y * x * t + z * s, c + y * y * t, y * z * t - x * s,
		z * x * t - y * s, z * y * t + x * s, c + z * z * t,
	}
end

--[[ The arm ]]

local byName: { [string]: any } = {}
for _, def in RigDefs.SKELETON do
	byName[def.name] = def
end

local CHEST = byName.UpperTorso.center

-- A skeleton point in chest space.
local function chestPoint(point: { number }): Vec
	return { point[1] - CHEST[1], point[2] - CHEST[2], point[3] - CHEST[3] }
end

-- How far below the hand's centre a real avatar's grip attachment sits,
-- which is the point WeaponVisuals hangs a weapon from.
GripSolver.GRIP_DROP = 0.15

type Arm = {
	shoulder: Vec,
	upper: number,
	lower: number,
	-- Wrist pivot to grip point, straight down the hand.
	hand: number,
	-- Where the elbow goes when nothing says otherwise: down, out and back.
	pole: Vec,
}

local function measureArm(side: string, outward: number): Arm
	local shoulder = byName[`{side}UpperArm`].pivot
	local elbow = byName[`{side}LowerArm`].pivot
	local wrist = byName[`{side}Hand`].pivot
	local handCentre = byName[`{side}Hand`].center
	return {
		shoulder = chestPoint(shoulder),
		upper = length(sub(elbow, shoulder)),
		lower = length(sub(wrist, elbow)),
		hand = (wrist[2] - handCentre[2]) + GripSolver.GRIP_DROP,
		pole = { 0.8 * outward, -1, 0.5 },
	}
end

local ARMS: { [string]: Arm } = {
	Right = measureArm("Right", 1),
	Left = measureArm("Left", -1),
}

local function other(side: string): string
	return if side == "Right" then "Left" else "Right"
end

-- Where the grip is and which way the hand faces, in chest space, for an arm
-- posed by `poses`. `side` is "Right" or "Left".
function GripSolver.gripFrame(poses: Poses, side: string): (Vec, Mat)
	local arm = ARMS[side]
	local upper = fromAngles(poses[`{side}UpperArm`])
	local elbow = add(arm.shoulder, apply(upper, { 0, -arm.upper, 0 }))
	local fore = mul(upper, fromAngles(poses[`{side}LowerArm`]))
	local wrist = add(elbow, apply(fore, { 0, -arm.lower, 0 }))
	local hand = mul(fore, fromAngles(poses[`{side}Hand`]))
	return add(wrist, apply(hand, { 0, -arm.hand, 0 })), hand
end

-- Which way a held weapon points (-Z of the hand), in chest space.
function GripSolver.pointing(poses: Poses, side: string): Vec
	local _, hand = GripSolver.gripFrame(poses, side)
	return apply(hand, { 0, 0, -1 })
end

-- The hand's orientation for a weapon pointing along `point` with its edge
-- toward `edge`. With no edge, the fingers carry on the line from `from`
-- (the shoulder) to the fist, which is the wrist doing nothing unusual.
local function handFacing(point: Vec, edge: Vec?, from: Vec, at: Vec): Mat
	local z = scale(unit(point), -1)
	local lead = edge or sub(at, from)
	local down = unit(perpendicular(lead, z))
	if length(down) < 1e-6 then
		down = unit(perpendicular({ 0, -1, 0 }, z))
	end
	local y = scale(down, -1)
	return columns(cross(y, z), y, z)
end

export type HoldSpec = {
	-- The grip, in chest space.
	at: Vec,
	-- The way the weapon points from the grip (its head, point or tip).
	point: Vec,
	-- The way the edge faces. Optional: see handFacing.
	edge: Vec?,
	-- Where the elbow should go, as a direction from the shoulder.
	pole: Vec?,
}

-- Joint angles putting `side`'s grip at `spec.at` with the weapon pointing
-- along `spec.point`. Returns the three arm poses and how far short the fist
-- fell (0 when it reached).
--
-- Two-bone IK for the shoulder and elbow, the elbow chosen toward the pole,
-- then the wrist makes up the rest. `near` is the previous keyframe's poses,
-- to keep the Euler readings continuous (see toAngles).
function GripSolver.hold(side: string, spec: HoldSpec, near: Poses?): (Poses, number)
	local arm = ARMS[side]
	local hand = handFacing(spec.point, spec.edge, arm.shoulder, spec.at)
	local wrist = add(spec.at, apply(hand, { 0, arm.hand, 0 }))

	local toWrist = sub(wrist, arm.shoulder)
	local wanted = length(toWrist)
	local reach = math.clamp(wanted, math.abs(arm.upper - arm.lower) + 1e-3, arm.upper + arm.lower - 1e-3)
	local shortfall = math.max(wanted - reach, 0)
	local along = unit(toWrist)
	if length(along) < 1e-6 then
		along = { 0, -1, 0 }
	end
	wrist = add(arm.shoulder, scale(along, reach))

	local pole = unit(perpendicular(spec.pole or arm.pole, along))
	if length(pole) < 1e-6 then
		pole = unit(perpendicular({ 0, 0, 1 }, along))
	end

	local cosA = math.clamp((arm.upper ^ 2 + reach ^ 2 - arm.lower ^ 2) / (2 * arm.upper * reach), -1, 1)
	local sinA = math.sqrt(1 - cosA * cosA)
	local elbow = add(arm.shoulder, add(scale(along, arm.upper * cosA), scale(pole, arm.upper * sinA)))

	-- The upper arm's frame: +Y back up to the shoulder, and the bend toward
	-- its -Z, because a positive elbow angle folds the forearm forward.
	local upY = unit(sub(arm.shoulder, elbow))
	local forearm = unit(sub(wrist, elbow))
	local bend = perpendicular(forearm, upY)
	local upZ = if length(bend) > 1e-6 then scale(unit(bend), -1) else unit(perpendicular(pole, upY))
	local upper = columns(cross(upY, upZ), upY, upZ)
	local elbowAngle = math.deg(math.acos(math.clamp(-dot(upY, forearm), -1, 1)))

	local fore = mul(upper, rotX(elbowAngle))
	local wristRotation = mul(transpose(fore), hand)

	local ref = near or {}
	local shoulderAngles = toAngles(upper, ref[`{side}UpperArm`] :: any)
	local wristAngles = toAngles(wristRotation, ref[`{side}Hand`] :: any)

	return {
		[`{side}UpperArm`] = shoulderAngles,
		[`{side}LowerArm`] = { rx = elbowAngle },
		[`{side}Hand`] = wristAngles,
	},
		shortfall
end

-- The wrist angles that turn a weapon in `side`'s hand to point along
-- `point`, leaving the arm as posed. With no `edge` the wrist takes the
-- shortest turn there, which is the least twist a real wrist would use.
function GripSolver.aim(poses: Poses, side: string, point: Vec, edge: Vec?): Angles
	local upper = fromAngles(poses[`{side}UpperArm`])
	local fore = mul(upper, fromAngles(poses[`{side}LowerArm`]))
	local toFore = transpose(fore)
	local wanted = unit(apply(toFore, point))

	local wrist: Mat
	if edge then
		local arm = ARMS[side]
		local grip = GripSolver.gripFrame(poses, side)
		wrist = mul(toFore, handFacing(point, edge, arm.shoulder, grip))
	else
		wrist = between({ 0, 0, -1 }, wanted)
	end
	return toAngles(wrist, poses[`{side}Hand`] :: any)
end

-- The other arm's poses, putting that hand on the haft `along` studs from
-- the first hand's grip (positive toward the head, negative toward the butt),
-- facing the same way — two fists on one haft grip it the same way round.
function GripSolver.offHand(poses: Poses, side: string, along: number, pole: Vec?, near: Poses?): (Poses, number)
	local grip, hand = GripSolver.gripFrame(poses, side)
	local point = apply(hand, { 0, 0, -1 })
	return GripSolver.hold(other(side), {
		at = add(grip, scale(point, along)),
		point = point,
		edge = apply(hand, { 0, -1, 0 }),
		pole = pole,
	}, near)
end

export type ChestFrame = {
	toPoint: (Vec) -> Vec,
	toVector: (Vec) -> Vec,
}

-- Converts from *root space* — the character's own frame, origin at the
-- hips at rest, +Y up and -Z the way it faces — into chest space, through
-- the hips and waist as `poses` has them turned.
--
-- This is what lets a strike be written as "the axe head at the target"
-- while the body twists however it likes on the way: the target is fixed in
-- root space, and the chest is not.
function GripSolver.chestFrame(poses: Poses): ChestFrame
	local lower = poses.LowerTorso or {}
	local upper = poses.UpperTorso or {}
	local waist = byName.UpperTorso.pivot
	local lowerCentre = byName.LowerTorso.center

	local lowerRotation = fromAngles(lower)
	local lowerPosition = { lower.px or 0, lower.py or 0, lower.pz or 0 }
	local rotation = mul(lowerRotation, fromAngles(upper))
	local toWaist = sub(waist, lowerCentre)
	local waistToChest = sub(CHEST, waist)
	local position = add(
		lowerPosition,
		apply(lowerRotation, add(toWaist, add({ upper.px or 0, upper.py or 0, upper.pz or 0 }, apply(fromAngles(upper), waistToChest))))
	)
	local inverse = transpose(rotation)

	return {
		toPoint = function(p: Vec): Vec
			return apply(inverse, sub(p, position))
		end,
		toVector = function(v: Vec): Vec
			return apply(inverse, v)
		end,
	}
end

-- The same rotation as `angles`, read as the Euler angles closest to `near`
-- (see toAngles). Used to keep a chain of solved poses on one reading, so the
-- animation between them turns the short way.
function GripSolver.reread(angles: Angles, near: Angles): Angles
	return toAngles(fromAngles(angles), near)
end

-- Exposed for tests and tooling.
GripSolver.toAngles = function(rx: number, ry: number, rz: number): Angles
	return toAngles(fromAngles({ rx = rx, ry = ry, rz = rz }))
end

GripSolver.sameRotation = function(a: Angles, b: Angles): number
	local ma, mb = fromAngles(a), fromAngles(b)
	local worst = 0
	for i = 1, 9 do
		worst = math.max(worst, math.abs(ma[i] - mb[i]))
	end
	return worst
end

GripSolver.distance = function(a: Vec, b: Vec): number
	return length(sub(a, b))
end

return GripSolver
