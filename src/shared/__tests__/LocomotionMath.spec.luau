--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local LocomotionMath = require(Shared.LocomotionMath)

local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local describe = JestGlobals.describe
local expect = JestGlobals.expect
local it = JestGlobals.it

local MAX_HIP = LocomotionMath.MAX_HIP

describe("LocomotionMath.resolve", function()
	it("reads standing still as not moving", function()
		local motion = LocomotionMath.resolve(0, 0, false)
		expect(motion.moving).toBe(false)
		expect(motion.angle).toBeNil()
	end)

	-- A stick resting a hair off centre is not a direction.
	it("treats a tiny movement vector as still", function()
		expect(LocomotionMath.resolve(0.01, -0.01, false).moving).toBe(false)
	end)

	it("reads forward as zero degrees", function()
		expect(LocomotionMath.resolve(1, 0, false).angle).toBeCloseTo(0)
	end)

	it("reads right as +90 and left as -90", function()
		expect(LocomotionMath.resolve(0, 1, false).angle).toBeCloseTo(90)
		expect(LocomotionMath.resolve(0, -1, false).angle).toBeCloseTo(-90)
	end)

	it("reads straight back as 180", function()
		expect(math.abs(LocomotionMath.resolve(-1, 0, false).angle :: number)).toBeCloseTo(180)
	end)

	it("keeps the walk cycle forward while heading forward", function()
		expect(LocomotionMath.resolve(1, 0.2, false).reversed).toBe(false)
	end)

	it("reverses the walk cycle while heading backwards", function()
		expect(LocomotionMath.resolve(-1, 0, false).reversed).toBe(true)
	end)

	-- Without hysteresis, strafing on the boundary flips every frame.
	it("holds its answer inside the hysteresis gap", function()
		local between = (LocomotionMath.FORWARD_ANGLE + LocomotionMath.BACKWARD_ANGLE) / 2
		local forward = math.cos(math.rad(between))
		local right = math.sin(math.rad(between))
		expect(LocomotionMath.resolve(forward, right, false).reversed).toBe(false)
		expect(LocomotionMath.resolve(forward, right, true).reversed).toBe(true)
	end)

	it("leaves the gap once past either edge", function()
		local function at(degrees: number, wasReversed: boolean): boolean
			local radians = math.rad(degrees)
			return LocomotionMath.resolve(math.cos(radians), math.sin(radians), wasReversed).reversed
		end
		expect(at(LocomotionMath.BACKWARD_ANGLE + 5, false)).toBe(true)
		expect(at(LocomotionMath.FORWARD_ANGLE - 5, true)).toBe(false)
	end)
end)

describe("LocomotionMath.twist", function()
	it("leaves the body square while standing still", function()
		expect(LocomotionMath.twist({ angle = nil, moving = false, reversed = false })).toEqual({ hip = 0, shoulder = 0 })
	end)

	it("leaves the body square while walking forward", function()
		expect(LocomotionMath.twist({ angle = 0, moving = true, reversed = false }).hip).toBeCloseTo(0)
	end)

	it("turns the hips toward the direction of travel", function()
		expect(LocomotionMath.twist({ angle = 40, moving = true, reversed = false }).hip).toBeCloseTo(40)
	end)

	it("counter-turns the shoulders against the hips", function()
		local twist = LocomotionMath.twist({ angle = 40, moving = true, reversed = false })
		expect(twist.shoulder).toBeCloseTo(-40 * LocomotionMath.SHOULDER_RECOVERY)
	end)

	-- The shoulders never fully undo the hips, so the chest leans into the turn.
	it("leaves the chest leading the facing", function()
		local twist = LocomotionMath.twist({ angle = 60, moving = true, reversed = false })
		expect(twist.hip + twist.shoulder).toBeGreaterThan(0)
	end)

	it("clamps a hard sidestep to the waist's limit", function()
		expect(LocomotionMath.twist({ angle = 90, moving = true, reversed = false }).hip).toBe(MAX_HIP)
		expect(LocomotionMath.twist({ angle = -90, moving = true, reversed = false }).hip).toBe(-MAX_HIP)
	end)

	-- Backing up turns the hips the short way; the reversed cycle does the rest.
	it("mirrors the hips when the cycle is reversed", function()
		expect(LocomotionMath.twist({ angle = 170, moving = true, reversed = true }).hip).toBeCloseTo(-10)
		expect(LocomotionMath.twist({ angle = -170, moving = true, reversed = true }).hip).toBeCloseTo(10)
	end)

	it("keeps the hips square walking straight back", function()
		expect(math.abs(LocomotionMath.twist({ angle = 180, moving = true, reversed = true }).hip)).toBeCloseTo(0)
	end)
end)

describe("LocomotionMath.approach", function()
	it("moves toward the goal at the turn rate", function()
		expect(LocomotionMath.approach(0, 90, 0.1)).toBeCloseTo(LocomotionMath.TURN_RATE * 0.1)
	end)

	it("lands exactly on the goal rather than overshooting", function()
		expect(LocomotionMath.approach(0, 10, 1)).toBe(10)
		expect(LocomotionMath.approach(0, -10, 1)).toBe(-10)
	end)

	it("stays put with no time passed", function()
		expect(LocomotionMath.approach(30, -30, 0)).toBe(30)
	end)

	-- A frame delta is never negative, but a paused clock shouldn't rewind.
	it("ignores negative time", function()
		expect(LocomotionMath.approach(30, -30, -1)).toBe(30)
	end)
end)
