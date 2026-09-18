--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local AttackSelector = require(Shared.AttackSelector)
local DungeonDefs = require(Shared.DungeonDefs)
local EnemyDefs = require(Shared.EnemyDefs)

local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local describe = JestGlobals.describe
local expect = JestGlobals.expect
local it = JestGlobals.it

local NOW = 100.0

local DUMMY = EnemyDefs.TrainingDummy
local SHAMBLER = EnemyDefs.Shambler
local SPITTER = EnemyDefs.Spitter

-- The band and weight tests run against a made-up enemy rather than a real
-- one. They are testing the selector, not the content, and asserting on real
-- attack names made every moveset change break four unrelated specs — which is
-- how a test stops being a guardrail and becomes a toll booth.
--
-- The movement tests above keep using real enemies on purpose: "the Spitter
-- kites" is a claim about the Spitter, and it should break if that stops
-- being true.
local function fixtureAttack(fields: { [string]: any }): any
	local base = {
		archetype = "WindBack",
		leadTime = 0.5,
		telegraphDuration = 0.62,
		parryable = true,
		damage = 10,
		range = 10,
		arcDegrees = 90,
		minRange = 0,
		maxRange = 10,
		weight = 1,
		cooldown = 0,
	}
	for key, value in fields do
		base[key] = value
	end
	return base
end

-- Near = point blank only; Far = from range only; Wide = legal at both.
local FIXTURE: any = {
	displayName = "Fixture",
	maxHealth = 100,
	attackInterval = 1,
	preferredRange = 6,
	moveSpeed = 8,
	aggroRange = 50,
	coinReward = 0,
	crystalReward = 0,
	xpReward = 0,
	attacks = {
		Near = fixtureAttack({ minRange = 0, maxRange = 8, weight = 3 }),
		Far = fixtureAttack({ minRange = 9, maxRange = 20, range = 20, weight = 2 }),
		Wide = fixtureAttack({ minRange = 0, maxRange = 20, range = 20, weight = 1 }),
	},
}

describe("AttackSelector.movementIntent", function()
	it("ignores a player beyond aggro range", function()
		expect(AttackSelector.movementIntent(SHAMBLER, SHAMBLER.aggroRange + 1)).toBe("idle")
	end)

	it("holds when the enemy cannot move", function()
		-- The dummy is the one enemy that never repositions, so parry timing
		-- can be measured without chasing anything.
		expect(AttackSelector.movementIntent(DUMMY, 30)).toBe("hold")
	end)

	it("approaches when further than preferred range", function()
		expect(AttackSelector.movementIntent(SHAMBLER, SHAMBLER.preferredRange + 10)).toBe("approach")
	end)

	-- This is what makes the Spitter kite without any kiting-specific code:
	-- its preferredRange simply sits outside its own melee.
	it("retreats when closer than preferred range", function()
		expect(AttackSelector.movementIntent(SPITTER, 5)).toBe("retreat")
	end)

	it("holds inside the dead band rather than shuffling", function()
		expect(AttackSelector.movementIntent(SHAMBLER, SHAMBLER.preferredRange)).toBe("hold")
		expect(AttackSelector.movementIntent(SHAMBLER, SHAMBLER.preferredRange + 1)).toBe("hold")
		expect(AttackSelector.movementIntent(SHAMBLER, SHAMBLER.preferredRange - 1)).toBe("hold")
	end)
end)

describe("AttackSelector.legalAttacks", function()
	it("excludes attacks out of band", function()
		-- Point blank: Far (minRange 9) is not available.
		local legal = AttackSelector.legalAttacks(FIXTURE, 2, {}, NOW)
		expect(legal).toEqual({ "Near", "Wide" })
	end)

	it("includes a gap-closer only from range", function()
		local legal = AttackSelector.legalAttacks(FIXTURE, 15, {}, NOW)
		expect(legal).toEqual({ "Far", "Wide" })
	end)

	it("excludes attacks still on cooldown", function()
		local legal = AttackSelector.legalAttacks(FIXTURE, 15, { Far = NOW + 1, Wide = NOW + 1 }, NOW)
		expect(legal).toEqual({})
	end)

	it("includes an attack whose cooldown has just expired", function()
		local legal = AttackSelector.legalAttacks(FIXTURE, 15, { Far = NOW, Wide = NOW + 1 }, NOW)
		expect(legal).toEqual({ "Far" })
	end)

	it("returns a stable sorted order", function()
		-- Reproducibility matters: tuning sessions compare runs against each
		-- other, and table iteration order would make that meaningless.
		local legal = AttackSelector.legalAttacks(FIXTURE, 5, {}, NOW)
		expect(legal).toEqual({ "Near", "Wide" })
	end)
end)

describe("AttackSelector.chooseAttack", function()
	it("returns nil when nothing is legal", function()
		-- Walked down inside its own minimum range, with Spray on cooldown.
		expect(AttackSelector.chooseAttack(SPITTER, 3, { Spray = NOW + 5 }, NOW)).toBeNil()
	end)

	it("returns the only legal attack regardless of roll", function()
		-- Point blank with Wide on cooldown leaves exactly Near.
		local onlyNear = { Wide = NOW + 1 }
		expect(AttackSelector.chooseAttack(FIXTURE, 2, onlyNear, NOW, function()
			return 0
		end)).toBe("Near")

		expect(AttackSelector.chooseAttack(FIXTURE, 2, onlyNear, NOW, function()
			return 0.999
		end)).toBe("Near")
	end)

	-- Fixture at range 15: Far weight 2, Wide weight 1, sorted ["Far", "Wide"],
	-- total weight 3.
	it("respects weights when picking between legal attacks", function()
		local lowRoll = AttackSelector.chooseAttack(FIXTURE, 15, {}, NOW, function()
			return 0.5 -- 1.5 of 3 -> inside Far's weight of 2
		end)
		expect(lowRoll).toBe("Far")

		local highRoll = AttackSelector.chooseAttack(FIXTURE, 15, {}, NOW, function()
			return 0.9 -- 2.7 of 3 -> past Far, inside Wide
		end)
		expect(highRoll).toBe("Wide")
	end)

	it("never returns an out-of-band attack even at roll extremes", function()
		for _, roll in { 0, 0.25, 0.5, 0.75, 0.999999 } do
			local chosen = AttackSelector.chooseAttack(FIXTURE, 15, {}, NOW, function()
				return roll
			end)
			-- Near's band stops at 8, so it must never come out of a roll at 15
			-- however the weights fall.
			expect({ roll, chosen ~= "Near" }).toEqual({ roll, true })
		end
	end)
end)

describe("AttackSelector bounds", function()
	local ROOM: AttackSelector.Bounds = { minX = -17, maxX = 17, minZ = 33, maxZ = 67 }

	it("contains a point inside the room", function()
		expect(AttackSelector.isWithinBounds(ROOM, 0, 50)).toBe(true)
	end)

	it("treats the leash edge as inside", function()
		expect(AttackSelector.isWithinBounds(ROOM, 17, 67)).toBe(true)
		expect(AttackSelector.isWithinBounds(ROOM, -17, 33)).toBe(true)
	end)

	-- The case the leash exists for: a player in the next room over.
	it("excludes a point in the neighbouring room", function()
		expect(AttackSelector.isWithinBounds(ROOM, 0, 100)).toBe(false)
		expect(AttackSelector.isWithinBounds(ROOM, 0, 0)).toBe(false)
	end)

	it("leaves a point inside the room untouched when clamping", function()
		local x, z = AttackSelector.clampToBounds(ROOM, 4, 52)
		expect(x).toBe(4)
		expect(z).toBe(52)
	end)

	-- Enemies move by CFrame, which ignores walls; the clamp is what stops them
	-- walking through one.
	it("clamps a step that would leave the room back to its edge", function()
		local x, z = AttackSelector.clampToBounds(ROOM, 40, 20)
		expect(x).toBe(17)
		expect(z).toBe(33)
	end)
end)

describe("EnemyDefs invariants", function()
	-- Guards the design rather than the code: an enemy whose attacks leave a
	-- gap in its own band will stand there doing nothing, which reads as a bug
	-- rather than as behaviour.
	it("gives every enemy something legal at its preferred range", function()
		for enemyId, def in EnemyDefs do
			local legal = AttackSelector.legalAttacks(def, def.preferredRange, {}, NOW)
			expect({ enemyId, #legal > 0 }).toEqual({ enemyId, true })
		end
	end)

	it("gives every enemy at least one parryable attack", function()
		-- Otherwise that enemy silently opts out of the entire parry system.
		for enemyId, def in EnemyDefs do
			local hasParryable = false
			for _, attack in def.attacks do
				if attack.parryable then
					hasParryable = true
				end
			end
			expect({ enemyId, hasParryable }).toEqual({ enemyId, true })
		end
	end)

	it("keeps every attack band and weight coherent", function()
		for _, def in EnemyDefs do
			for _, attack in def.attacks do
				expect(attack.minRange <= attack.maxRange).toBe(true)
				expect(attack.weight > 0).toBe(true)
				expect(attack.telegraphDuration > 0).toBe(true)
			end
		end
	end)

	-- Enemies hold still through a windup, so an attack chosen from further
	-- away than it reaches is a guaranteed miss.
	it("never lets an attack be chosen from beyond its own reach", function()
		for enemyId, def in EnemyDefs do
			for attackId, attack in def.attacks do
				local label = `{enemyId}.{attackId}`
				expect({ label, attack.maxRange <= attack.range }).toEqual({ label, true })
			end
		end
	end)

	it("keeps every bleed well-formed", function()
		for _, def in EnemyDefs do
			for _, attack in def.attacks do
				local dot = attack.dot
				if dot then
					expect(dot.tickDamage > 0).toBe(true)
					expect(dot.tickInterval > 0).toBe(true)
					expect(dot.ticks >= 1).toBe(true)
				end
			end
		end
	end)

	-- Enemies are leashed inside their room, so one that wants to stand
	-- further away than the room allows would pin itself to a wall and never
	-- reach its preferred spacing. This checks the smallest room of all; the
	-- per-pool check against each enemy's own smallest room is in
	-- DungeonLayout.spec.
	it("keeps every preferred range inside the smallest room", function()
		local smallest = math.huge
		for _, size in DungeonDefs.SIZES do
			smallest = math.min(smallest, size)
		end
		local diagonalHalf = smallest / 2 * math.sqrt(2)
		for enemyId, def in EnemyDefs do
			expect({ enemyId, def.preferredRange <= diagonalHalf }).toEqual({ enemyId, true })
		end
	end)
end)

describe("Enemy economy invariants", function()
	local LootTables = require(Shared.LootTables)

	-- Any enemy type can end up guarding a chest, so a missing loot row would
	-- fail the moment a player tried to open one.
	it("gives every enemy type a loot row", function()
		for enemyId in EnemyDefs do
			expect({ enemyId, LootTables[enemyId] ~= nil }).toEqual({ enemyId, true })
		end
	end)

	it("pays every enemy type some coins", function()
		for enemyId, def in EnemyDefs do
			expect({ enemyId, def.coinReward > 0 }).toEqual({ enemyId, true })
		end
	end)

	-- DESIGN.md: crystals only come from tougher enemies, which is what keeps
	-- trash-mob grinding away from the top blacksmith tiers.
	it("keeps crystals away from the weakest enemy", function()
		local weakestId, weakestHealth = nil, math.huge
		for enemyId, def in EnemyDefs do
			if def.maxHealth < weakestHealth then
				weakestId, weakestHealth = enemyId, def.maxHealth
			end
		end

		expect(EnemyDefs[weakestId :: string].crystalReward).toBe(0)
	end)

	it("has at least one crystal source, or the top tiers are unreachable", function()
		local anyCrystals = false
		for _, def in EnemyDefs do
			if def.crystalReward > 0 then
				anyCrystals = true
			end
		end
		expect(anyCrystals).toBe(true)
	end)
end)
