--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local TalentMath = require(Shared.TalentMath)

local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local describe = JestGlobals.describe
local expect = JestGlobals.expect
local it = JestGlobals.it

-- A hit with nothing special about it: full health all round, no stacks.
local function plain(mods: { [string]: number }): TalentMath.Bonus
	return { mods = mods, targetHealth = 1, ownHealth = 1, frenzyStacks = 0, ambush = false, mark = 0 }
end

describe("TalentMath.outgoingBonus", function()
	it("adds nothing without mechanics", function()
		expect(TalentMath.outgoingBonus(plain({}))).toBe(0)
	end)

	it("finishes only what is already finishable", function()
		local bonus = plain({ execute = 0.3 })
		expect(TalentMath.outgoingBonus(bonus)).toBe(0)
		bonus.targetHealth = TalentMath.EXECUTE_THRESHOLD
		expect(TalentMath.outgoingBonus(bonus)).toBeCloseTo(0.3)
	end)

	it("grows with missing health, all of it only at none", function()
		local bonus = plain({ lowHealthDamage = 0.4 })
		expect(TalentMath.outgoingBonus(bonus)).toBe(0)
		bonus.ownHealth = 0.5
		expect(TalentMath.outgoingBonus(bonus)).toBeCloseTo(0.2)
		bonus.ownHealth = 0
		expect(TalentMath.outgoingBonus(bonus)).toBeCloseTo(0.4)
	end)

	it("stacks frenzy per hit, up to the cap", function()
		local bonus = plain({ frenzy = 0.05 })
		bonus.frenzyStacks = 3
		expect(TalentMath.outgoingBonus(bonus)).toBeCloseTo(0.15)
		bonus.frenzyStacks = 99
		expect(TalentMath.outgoingBonus(bonus)).toBeCloseTo(0.05 * TalentMath.FRENZY_MAX)
	end)

	it("only pays an ambush when there was one", function()
		local bonus = plain({ dodgeStrike = 0.25 })
		expect(TalentMath.outgoingBonus(bonus)).toBe(0)
		bonus.ambush = true
		expect(TalentMath.outgoingBonus(bonus)).toBeCloseTo(0.25)
	end)

	it("adds a mark whoever's tree it came from", function()
		local bonus = plain({})
		bonus.mark = 0.15
		expect(TalentMath.outgoingBonus(bonus)).toBeCloseTo(0.15)
	end)
end)

describe("TalentMath.isAmbush", function()
	it("counts a hit inside the window after a dodge", function()
		expect(TalentMath.isAmbush(10, nil, 10 + TalentMath.AMBUSH_WINDOW)).toBe(true)
	end)

	it("refuses one after the window, or with no dodge", function()
		expect(TalentMath.isAmbush(10, nil, 10 + TalentMath.AMBUSH_WINDOW + 0.01)).toBe(false)
		expect(TalentMath.isAmbush(nil, nil, 10)).toBe(false)
	end)

	it("spends a dodge's ambush on the first hit only", function()
		expect(TalentMath.isAmbush(10, 10, 10.2)).toBe(false)
	end)
end)

describe("TalentMath.isPreciseParry", function()
	it("is tighter than the parry itself, on either side of the hit", function()
		expect(TalentMath.isPreciseParry(5 - TalentMath.PRECISE_PARRY, 5)).toBe(true)
		expect(TalentMath.isPreciseParry(5 + TalentMath.PRECISE_PARRY, 5)).toBe(true)
		expect(TalentMath.isPreciseParry(5 - 0.15, 5)).toBe(false)
	end)
end)

describe("TalentMath.manaShieldSplit", function()
	it("moves its share of the hit onto posture", function()
		local health, posture = TalentMath.manaShieldSplit(20, 0.25, 100)
		expect(health).toBeCloseTo(15)
		expect(posture).toBeCloseTo(5)
	end)

	it("never takes more than posture has room for", function()
		local health, posture = TalentMath.manaShieldSplit(20, 0.5, 3)
		expect(posture).toBeCloseTo(3)
		expect(health).toBeCloseTo(17)
	end)

	it("keeps the whole hit accounted for", function()
		local health, posture = TalentMath.manaShieldSplit(37, 0.3, 50)
		expect(health + posture).toBeCloseTo(37)
	end)
end)

describe("the small rules", function()
	it("caps frenzy", function()
		expect(TalentMath.nextFrenzy(TalentMath.FRENZY_MAX)).toBe(TalentMath.FRENZY_MAX)
		expect(TalentMath.nextFrenzy(0)).toBe(1)
	end)

	it("pays a bleed out in equal ticks that add back up", function()
		expect(TalentMath.bleedTick(9) * TalentMath.BLEED_TICKS).toBeCloseTo(9)
	end)

	it("carries a share of a hit, never a negative one", function()
		expect(TalentMath.carried(20, 0.4)).toBeCloseTo(8)
		expect(TalentMath.carried(-5, 0.4)).toBe(0)
	end)
end)
