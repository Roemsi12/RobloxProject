--!strict
-- Hip and shoulder separation for a locked camera. Pure — no Roblox API.
--
-- With the camera locked the character always faces the camera, so walking
-- sideways or backwards plays a forward walk cycle while the body slides the
-- other way. That is the moonwalk.
--
-- The fix is not four hand-authored walk cycles. It is what a real body does:
-- the hips turn toward where you are going and the shoulders stay with your
-- eyes, twisting the spine between them. Roblox's own walk cycle is then
-- correct, because the legs it moves are pointing the right way — and it
-- covers every direction, not just the four we would have authored.
--
-- Walking backwards is the one case turning the hips cannot fix: at 180 the
-- hips would have to face straight back, which no spine does. There the hips
-- mirror instead (they turn the *short* way) and the caller plays the walk
-- cycle in reverse, so the feet stride backwards with the body.
--
-- Angles are degrees, measured from the character's facing: 0 is forward,
-- +90 is right, ±180 is straight back.

local LocomotionMath = {}

-- How far the hips may turn from the character's facing. Full 90 on a pure
-- strafe would aim the legs perfectly but twist the waist further than a body
-- reads as able to; the rest is absorbed as a cross-step, which is what a
-- person actually does when they sidestep.
LocomotionMath.MAX_HIP = 65

-- How much of the hip turn the shoulders take back. Not 1: leaving a little
-- through means the upper body leans into the direction of travel rather than
-- staying bolted to the camera, which is the difference between a person
-- moving and a turret on legs.
LocomotionMath.SHOULDER_RECOVERY = 0.8

-- Past this far from forward, the walk cycle reverses. Coming back, it stays
-- reversed until inside FORWARD_ANGLE. The gap is hysteresis: without it,
-- strafing at exactly the boundary flickers between the two every frame.
LocomotionMath.BACKWARD_ANGLE = 100
LocomotionMath.FORWARD_ANGLE = 80

-- How fast the hips turn toward their goal, in degrees per second. Crossing
-- between forward and reversed flips the goal from one side to the other, and
-- this is what makes that read as a pivot instead of a pop.
LocomotionMath.TURN_RATE = 540

-- Below this the character is standing still: a movement vector this short is
-- a controller resting off-centre, not a direction.
LocomotionMath.MOVE_EPSILON = 0.05

export type Motion = {
	-- Degrees from facing to the direction of travel, or nil when still.
	angle: number?,
	moving: boolean,
	-- Whether the walk cycle should play backwards.
	reversed: boolean,
}

export type Twist = {
	-- Degrees to turn the hips (LowerTorso) by.
	hip: number,
	-- Degrees to turn the chest (UpperTorso) by, against the hips.
	shoulder: number,
}

-- Clamps to +/- `limit`, for angles that may be negative.
local function clamp(value: number, limit: number): number
	return math.clamp(value, -limit, limit)
end

-- Which way the character is travelling relative to where it faces.
-- `forward` and `right` are the movement direction in the character's own
-- space — scalars rather than a Vector3, so this module stays Roblox-free.
--
-- `wasReversed` is last frame's answer, which is what makes the hysteresis
-- work; pass false on the first call.
function LocomotionMath.resolve(forward: number, right: number, wasReversed: boolean): Motion
	if math.abs(forward) < LocomotionMath.MOVE_EPSILON and math.abs(right) < LocomotionMath.MOVE_EPSILON then
		return { angle = nil, moving = false, reversed = false }
	end

	local angle = math.deg(math.atan2(right, forward))
	local magnitude = math.abs(angle)

	local reversed
	if wasReversed then
		reversed = magnitude > LocomotionMath.FORWARD_ANGLE
	else
		reversed = magnitude > LocomotionMath.BACKWARD_ANGLE
	end

	return { angle = angle, moving = true, reversed = reversed }
end

-- Where the hips and chest want to be for a given direction of travel.
--
-- Going backwards, the hips turn the short way rather than all the way round:
-- at 170 (back and slightly right) they sit at 10, and the reversed walk cycle
-- carries the body the other way.
function LocomotionMath.twist(motion: Motion): Twist
	local angle = motion.angle
	if not angle or not motion.moving then
		return { hip = 0, shoulder = 0 }
	end

	local goal = angle
	if motion.reversed then
		goal = if angle >= 0 then angle - 180 else angle + 180
	end

	local hip = clamp(goal, LocomotionMath.MAX_HIP)
	return { hip = hip, shoulder = -hip * LocomotionMath.SHOULDER_RECOVERY }
end

--[[ Carriage ]]

-- How fast a player's fighting stance breathes, given how fast they're moving.
--
-- The stance is a slow loop — breath, the arms lagging behind it, a sway — laid
-- over Roblox's own walk and run. At a standstill that is exactly right. At a
-- run it is not: the legs are going at a sprint and the chest above them is
-- breathing as though the character were leaning on a wall, which reads as the
-- top and bottom halves belonging to different people.
--
-- Enemies have done this since they were built (EnemyAnimation scales the walk
-- cycle by real speed against the rig's own); this is players catching up.
LocomotionMath.MIN_TEMPO = 1
LocomotionMath.MAX_TEMPO = 2.1

-- Measured against a fixed speed, not against the character's current
-- `WalkSpeed`. Combat slows walking a long way — to 40% while attacking, 25%
-- while stunned — and dividing by a speed that moves with the slowdown would
-- have a stunned character crawling along and breathing as hard as a sprint,
-- because they are still going "full speed" for what they are allowed. Full
-- pace is full pace. Roblox's default walk speed, which is what a player has
-- when nothing is slowing them.
LocomotionMath.FULL_PACE = 16

-- Standing still enough to plant the feet, and moving enough to pick them up
-- again. Two thresholds rather than one, for the same reason the walk cycle's
-- reversal has two: at a single boundary, a character drifting at exactly that
-- speed swaps between a planted idle and a walking stance every frame.
--
-- The lower one is not zero. A character standing on a moving platform, or
-- settling after a roll, has a speed that never quite reaches it.
LocomotionMath.PLANT_BELOW = 0.6
LocomotionMath.UNPLANT_ABOVE = 2.2

-- Whether the feet should be planted at this speed, given whether they
-- were last frame. Two thresholds rather than one, so a character
-- drifting at the boundary cannot flicker between the two.
function LocomotionMath.planted(speed: number, wasPlanted: boolean): boolean
	if wasPlanted then
		return speed < LocomotionMath.UNPLANT_ABOVE
	end
	return speed < LocomotionMath.PLANT_BELOW
end

-- `speed` is studs per second, horizontally. Clamped at both ends: a stance
-- slower than its authored tempo reads as slow motion, and one much faster
-- reads as panic.
function LocomotionMath.stanceTempo(speed: number): number
	local pace = math.max(speed, 0) / LocomotionMath.FULL_PACE
	return math.clamp(
		LocomotionMath.MIN_TEMPO + pace * (LocomotionMath.MAX_TEMPO - LocomotionMath.MIN_TEMPO),
		LocomotionMath.MIN_TEMPO,
		LocomotionMath.MAX_TEMPO
	)
end

--[[ Rolling ]]

-- Which of the four rolls a dodge press calls for. The roll that plays has to
-- be the one the body is actually travelling along: a forward roll while
-- backing away is the moonwalk again, in a single burst.
export type RollDirection = "forward" | "back" | "left" | "right"

-- The four quadrants, each centred on its axis: anything within 45 degrees of
-- straight ahead rolls forward, and so on round. Sideways is decided before
-- forward and back, because a roll that is mostly lateral reads far worse as a
-- forward roll than the other way about — the body would tumble across the
-- direction it is sliding.
--
-- Standing still rolls backwards, which is what the dodge already does when
-- there is no movement to take a direction from: a step away from whatever is
-- in front of you.
function LocomotionMath.rollDirection(forward: number, right: number): RollDirection
	if math.abs(forward) < LocomotionMath.MOVE_EPSILON and math.abs(right) < LocomotionMath.MOVE_EPSILON then
		return "back"
	end

	if math.abs(right) > math.abs(forward) then
		return if right > 0 then "right" else "left"
	end

	return if forward >= 0 then "forward" else "back"
end

-- Move `current` toward `goal` at TURN_RATE, so nothing snaps between frames.
function LocomotionMath.approach(current: number, goal: number, deltaTime: number): number
	local step = LocomotionMath.TURN_RATE * math.max(deltaTime, 0)
	local difference = goal - current
	if math.abs(difference) <= step then
		return goal
	end
	return current + (if difference > 0 then step else -step)
end

return LocomotionMath
