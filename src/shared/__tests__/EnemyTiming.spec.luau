--!strict
-- What every enemy attack has to be true of, timing-wise, whatever produces
-- its animation.
--
-- These properties used to live in AttackChoreography.spec, because the
-- generator was what enforced them. They are not about generation: they are
-- about whether a player can answer what they are shown, and they outlive any
-- particular way of making the animation. Hence a file of their own.
--
-- A failure here means a player somewhere would have been asked to parry
-- something they could not read, or to learn a fighter that has no consistent
-- tempo to learn.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local DungeonDefs = require(Shared.DungeonDefs)
local EnemyDefs = require(Shared.EnemyDefs)
local ParryMath = require(Shared.ParryMath)

local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local describe = JestGlobals.describe
local expect = JestGlobals.expect
local it = JestGlobals.it

-- expect() on a { label, value } pair, so a failure names what failed.
local function check(label: string, value: boolean)
	expect({ label, value }).toEqual({ label, true })
end

describe("Reactable attacks", function()
	it("keeps every attack answerable by reacting to what the player saw", function()
		for enemyId, def in EnemyDefs do
			for attackId, attack in def.attacks do
				local lowest, highest = ParryMath.readableLead(attack.parryable)
				check(
					`{enemyId}.{attackId} lead {attack.leadTime} is below {lowest}`,
					attack.leadTime >= lowest - 1e-9
				)
				check(
					`{enemyId}.{attackId} lead {attack.leadTime} is above {highest} — reacting to it would press early`,
					attack.leadTime <= highest + 1e-9
				)
			end
		end
	end)

	it("leaves the band wide enough to be worth having", function()
		-- If the weapons' windows ever tighten to the point where no lead time
		-- satisfies every class, that is a combat-tuning problem and this is
		-- where it should surface — not as every enemy slowly becoming
		-- unparryable for one class.
		for _, parryable in { true, false } do
			local lowest, highest = ParryMath.readableLead(parryable)
			check(`{if parryable then "parry" else "dodge"} band {lowest}..{highest} is non-empty`, highest > lowest)
		end
	end)
end)

describe("Enemy tempo", function()
	-- Reactability itself is checked above, for every attack including the
	-- boss's. The boss used to be exempt from it on the grounds that "the
	-- dungeon teaches the language and the boss tests it" — but that exemption
	-- was written when the only failure imagined was a tell being too *fast*.
	-- A tell that is too slow punishes the player for reacting, which is not a
	-- test of anything. The boss is fast, not unreadable.
	--
	-- It keeps its exemption from the one-rhythm rule below, which is a
	-- different claim: breaking his own tempo is a real boss mechanic.
	it("keeps a common enemy's attacks on one rhythm", function()
		-- One timing per enemy, not one per attack: a player should be
		-- learning the fighter, not a table.
		for enemyId, def in EnemyDefs do
			if enemyId == DungeonDefs.BOSS then
				continue
			end

			local shortest, longest = math.huge, 0
			for _, attack in def.attacks do
				if not attack.parryable then
					continue
				end
				shortest = math.min(shortest, attack.leadTime)
				longest = math.max(longest, attack.leadTime)
			end
			if longest > 0 then
				check(`{enemyId} parryable attacks share a rhythm`, longest - shortest <= 0.2 + 1e-9)
			end
		end
	end)

	-- The complaint this answers, in the user's words: "zombies and skeletons
	-- both just have a general hit animation, to an average user they cant
	-- tell the difference as the timing feels mostly the same".
	--
	-- Only enemies that can actually share a room are compared. The rule is
	-- about telling two fighters apart in front of you, so an enemy in no
	-- dungeon pool has nothing to be confused with, and the boss fights alone.
	it("gives every enemy you can meet its own rhythm, distinct from the others", function()
		local inAPool: { [string]: boolean } = {}
		for _, pool in DungeonDefs.POOLS do
			for _, enemyId in pool do
				inAPool[enemyId] = true
			end
		end

		local bands = {}
		for enemyId, def in EnemyDefs do
			if enemyId == DungeonDefs.BOSS or not inAPool[enemyId] then
				continue
			end
			local lo, hi = math.huge, 0
			for _, attack in def.attacks do
				if attack.parryable then
					lo = math.min(lo, attack.leadTime)
					hi = math.max(hi, attack.leadTime)
				end
			end
			if hi > 0 then
				table.insert(bands, { id = enemyId, lo = lo, hi = hi })
			end
		end

		check("more than one enemy is in a dungeon pool", #bands > 1)

		for i, a in bands do
			for j, b in bands do
				if j <= i then
					continue
				end
				local overlap = math.min(a.hi, b.hi) - math.max(a.lo, b.lo)
				check(`{a.id} ({a.lo}-{a.hi}) and {b.id} ({b.lo}-{b.hi}) share a tempo`, overlap < 0)
			end
		end
	end)

	it("derives every telegraph from its tell, so the two cannot drift", function()
		-- Playback stretches everything before the impact keyframe to fit the
		-- telegraph (KeyframeMath.alignedTime). If the telegraph were set by
		-- hand it would squeeze or stretch the tell with it, and the budget the
		-- band test just checked would not be the budget on screen.
		for enemyId, def in EnemyDefs do
			for attackId, attack in def.attacks do
				check(
					`{enemyId}.{attackId} telegraph = tell + settle`,
					math.abs(attack.telegraphDuration - (attack.leadTime + ParryMath.SETTLE)) < 1e-9
				)
			end
		end
	end)
end)
