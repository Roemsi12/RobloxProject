--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local EnemyDefs = require(Shared.EnemyDefs)
local ProgressionDefs = require(Shared.ProgressionDefs)

local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local describe = JestGlobals.describe
local expect = JestGlobals.expect
local it = JestGlobals.it

local STEP = ProgressionDefs.STEP_XP
local MAX = ProgressionDefs.MAX_LEVEL

describe("ProgressionDefs.standing", function()
	it("starts everyone at level 1 with nothing earned", function()
		local standing = ProgressionDefs.standing(0)
		expect(standing.level).toBe(1)
		expect(standing.into).toBe(0)
		expect(standing.points).toBe(0)
	end)

	it("levels up exactly on the step cost", function()
		expect(ProgressionDefs.standing(STEP - 1).level).toBe(1)
		expect(ProgressionDefs.standing(STEP).level).toBe(2)
	end)

	it("reports progress into the current level", function()
		local standing = ProgressionDefs.standing(STEP + 30)
		expect(standing.level).toBe(2)
		expect(standing.into).toBe(30)
		expect(standing.toNext).toBe(ProgressionDefs.stepCost(2))
	end)

	-- Each level costs more than the last, or the back half is free.
	it("charges more for each level", function()
		for level = 1, MAX - 2 do
			expect(ProgressionDefs.stepCost(level + 1)).toBeGreaterThan(ProgressionDefs.stepCost(level))
		end
	end)

	it("stops at the cap", function()
		local standing = ProgressionDefs.standing(ProgressionDefs.totalFor(MAX) * 10)
		expect(standing.level).toBe(MAX)
		expect(standing.toNext).toBe(0)
		expect(standing.into).toBe(0)
	end)

	it("agrees with totalFor at every level boundary", function()
		for level = 1, MAX do
			expect(ProgressionDefs.standing(ProgressionDefs.totalFor(level)).level).toBe(level)
		end
	end)

	-- Saved XP arrives from a DataStore, so it is not to be trusted.
	it("survives junk", function()
		expect(ProgressionDefs.standing(-500).level).toBe(1)
		expect(ProgressionDefs.standing(0 / 0).level).toBe(1)
	end)
end)

describe("ProgressionDefs.pointsFor", function()
	it("pays no point for the level everyone starts at", function()
		expect(ProgressionDefs.pointsFor(1)).toBe(0)
	end)

	it("pays one point per level gained", function()
		expect(ProgressionDefs.pointsFor(2)).toBe(ProgressionDefs.POINTS_PER_LEVEL)
		expect(ProgressionDefs.pointsFor(MAX)).toBe((MAX - 1) * ProgressionDefs.POINTS_PER_LEVEL)
	end)

	it("never pays past the cap", function()
		expect(ProgressionDefs.pointsFor(MAX + 50)).toBe(ProgressionDefs.pointsFor(MAX))
	end)
end)

describe("ProgressionDefs.cap", function()
	it("holds XP at what the level cap is worth", function()
		expect(ProgressionDefs.cap(1e12)).toBe(ProgressionDefs.totalFor(MAX))
	end)

	it("never goes negative", function()
		expect(ProgressionDefs.cap(-1)).toBe(0)
	end)
end)

describe("enemy XP", function()
	it("is set for every enemy", function()
		for _, def in EnemyDefs do
			expect(type(def.xpReward) == "number" and def.xpReward > 0).toBe(true)
		end
	end)

	-- A run has to be worth something, or levelling reads as broken.
	it("pays a first level-up inside a few rooms", function()
		local perRoom = EnemyDefs.SkeletonWarrior.xpReward + EnemyDefs.Shambler.xpReward
		expect(perRoom * 3).toBeGreaterThan(ProgressionDefs.stepCost(1))
	end)

	it("pays most for the boss", function()
		for id, def in EnemyDefs do
			if id ~= "HollowKing" then
				expect(EnemyDefs.HollowKing.xpReward).toBeGreaterThan(def.xpReward)
			end
		end
	end)

	-- The tougher enemies are the ones worth seeking out.
	it("pays more for the enemies that pay more coins", function()
		expect(EnemyDefs.SkeletonWarrior.xpReward).toBeGreaterThan(EnemyDefs.TrainingDummy.xpReward)
	end)
end)
