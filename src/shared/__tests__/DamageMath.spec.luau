--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CombatConstants = require(Shared.CombatConstants)
local DamageMath = require(Shared.DamageMath)

local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local describe = JestGlobals.describe
local expect = JestGlobals.expect
local it = JestGlobals.it

local ORIGIN: DamageMath.Vec2 = { x = 0, z = 0 }
-- Facing +Z, matching how the slice orients the enemy toward the player spawn.
local FACING_NORTH: DamageMath.Vec2 = { x = 0, z = 1 }

describe("DamageMath.resolveIncoming", function()
	it("passes full damage through when not parried", function()
		expect(DamageMath.resolveIncoming(15, false)).toBe(15)
	end)

	it("fully negates damage on a parry", function()
		expect(DamageMath.resolveIncoming(15, true)).toBe(0)
	end)
end)

describe("DamageMath.resolveOutgoing", function()
	-- Outgoing damage for one combination of stagger, riposte and
	-- multiplier, so the tests read as a table of cases.
	local function outgoing(base: number, staggered: boolean, riposte: boolean, multiplier: number): number
		return DamageMath.resolveOutgoing(base, {
			targetStaggered = staggered,
			riposteActive = riposte,
			riposteMultiplier = multiplier,
		})
	end

	it("passes base damage through with no bonus active", function()
		expect(outgoing(6, false, false, 2.5)).toBe(6)
	end)

	it("amplifies damage during a riposte window", function()
		expect(outgoing(6, false, true, 2.5)).toBe(15)
	end)

	-- Classes without a riposte payoff carry a multiplier of 1, so an active
	-- flag must still be a no-op for them.
	it("is a no-op for a class whose riposte multiplier is 1", function()
		expect(outgoing(12, false, true, 1)).toBe(12)
	end)

	-- The universal punish window: any class hitting a staggered target.
	it("applies the stagger bonus to any class", function()
		expect(outgoing(12, true, false, 1)).toBe(12 * CombatConstants.STAGGER_DAMAGE_MULTIPLIER)
	end)

	-- Both bonuses reward the same parry, so they take the larger instead of
	-- multiplying — otherwise a riposte into a stagger would hit for 5x.
	it("takes the larger bonus rather than stacking them", function()
		expect(outgoing(10, true, true, 2.5)).toBe(25)
		expect(outgoing(10, true, true, 1.5)).toBe(10 * CombatConstants.STAGGER_DAMAGE_MULTIPLIER)
	end)
end)

describe("DamageMath.horizontalDistance", function()
	it("measures on the XZ plane", function()
		expect(DamageMath.horizontalDistance({ x = 0, z = 0 }, { x = 3, z = 4 })).toBe(5)
	end)

	it("is zero for the same point", function()
		expect(DamageMath.horizontalDistance({ x = 7, z = -2 }, { x = 7, z = -2 })).toBe(0)
	end)
end)

describe("DamageMath.staggerDuration", function()
	it("scales the base stagger by the class multiplier", function()
		expect(DamageMath.staggerDuration(1.5, 1.5)).toBeCloseTo(2.25, 6)
		expect(DamageMath.staggerDuration(1.5, 0.8)).toBeCloseTo(1.2, 6)
	end)

	it("leaves the base untouched at a multiplier of 1", function()
		expect(DamageMath.staggerDuration(1.5, 1)).toBe(1.5)
	end)
end)

describe("DamageMath.applyHealing", function()
	it("heals up to but not past the maximum", function()
		expect(DamageMath.applyHealing(80, 100, 14)).toBe(94)
		expect(DamageMath.applyHealing(95, 100, 14)).toBe(100)
	end)

	it("never returns a negative health value", function()
		expect(DamageMath.applyHealing(5, 100, -50)).toBe(0)
	end)
end)

describe("DamageMath.isInHitVolume range", function()
	-- Whether a target at (x, z) is inside a hit volume of this range and
	-- arc, measured from the origin.
	local function hitAt(x: number, z: number, range: number, arcDegrees: number): boolean
		return DamageMath.isInHitVolume({
			attackerPos = ORIGIN,
			attackerFacing = FACING_NORTH,
			targetPos = { x = x, z = z },
			range = range,
			arcDegrees = arcDegrees,
		})
	end

	it("hits a target inside range and directly ahead", function()
		expect(hitAt(0, 5, 10, 120)).toBe(true)
	end)

	it("misses a target beyond range", function()
		expect(hitAt(0, 11, 10, 120)).toBe(false)
	end)

	it("includes a target exactly at maximum range", function()
		expect(hitAt(0, 10, 10, 120)).toBe(true)
	end)

	-- Height is ignored on purpose: the slice's room is flat, and a jumping
	-- player should not dodge a sword swing for free.
	it("hits a target standing on top of the attacker", function()
		expect(hitAt(0, 0, 10, 120)).toBe(true)
	end)
end)

describe("DamageMath.isInHitVolume arc", function()
	-- Whether a target at (x, z) is inside an arc of this width, at a fixed
	-- range.
	local function hitAt(x: number, z: number, arcDegrees: number): boolean
		return DamageMath.isInHitVolume({
			attackerPos = ORIGIN,
			attackerFacing = FACING_NORTH,
			targetPos = { x = x, z = z },
			range = 100,
			arcDegrees = arcDegrees,
		})
	end

	it("misses a target directly behind within a frontal arc", function()
		expect(hitAt(0, -5, 120)).toBe(false)
	end)

	it("hits a target at the edge of the arc", function()
		-- 120 degree arc is +/-60 from facing; this target sits at exactly 60.
		expect(hitAt(math.sin(math.rad(60)) * 5, math.cos(math.rad(60)) * 5, 120)).toBe(true)
	end)

	it("misses a target just outside the arc", function()
		expect(hitAt(math.sin(math.rad(61)) * 5, math.cos(math.rad(61)) * 5, 120)).toBe(false)
	end)

	it("is symmetric on both sides of the facing direction", function()
		expect(hitAt(3, 3, 120)).toBe(hitAt(-3, 3, 120))
	end)

	-- The GroundSlam attack relies on this: no amount of repositioning dodges
	-- it, only leaving its range does.
	it("hits in every direction with a 360 degree arc", function()
		expect(hitAt(0, -5, 360)).toBe(true)
		expect(hitAt(5, 0, 360)).toBe(true)
		expect(hitAt(0, 5, 360)).toBe(true)
	end)
end)

describe("DamageMath.resolveBlock", function()
	it("does nothing without a guard, against an unparryable attack, or from behind", function()
		expect(DamageMath.resolveBlock(20, false, true, true, 10)).toEqual({ outcome = "unguarded", damage = 20, posture = 10 })
		-- Unparryable attacks still have to be dodged, guard or not.
		expect(DamageMath.resolveBlock(20, true, false, true, 10)).toEqual({ outcome = "unguarded", damage = 20, posture = 10 })
		expect(DamageMath.resolveBlock(20, true, true, false, 10)).toEqual({ outcome = "unguarded", damage = 20, posture = 10 })
	end)

	it("takes a guarded hit on posture instead of health", function()
		local result = DamageMath.resolveBlock(20, true, true, true, 10)
		expect(result.outcome).toBe("blocked")
		expect(result.damage).toBe(0)
		expect(result.posture).toBeCloseTo(10 + 20 * CombatConstants.BLOCK_POSTURE_PER_DAMAGE)
	end)

	it("breaks a guard the hit fills, for full damage", function()
		local result = DamageMath.resolveBlock(20, true, true, true, CombatConstants.MAX_POSTURE - 1)
		expect(result.outcome).toBe("broken")
		expect(result.damage).toBe(20)
		expect(result.posture).toBe(0)
	end)
end)

describe("DamageMath.isFacing", function()
	it("covers the front half and not the back", function()
		expect(DamageMath.isFacing(ORIGIN, FACING_NORTH, { x = 3, z = 3 }, 180)).toBe(true)
		expect(DamageMath.isFacing(ORIGIN, FACING_NORTH, { x = 5, z = 0 }, 180)).toBe(true)
		expect(DamageMath.isFacing(ORIGIN, FACING_NORTH, { x = 1, z = -5 }, 180)).toBe(false)
	end)
end)
