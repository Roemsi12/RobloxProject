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
