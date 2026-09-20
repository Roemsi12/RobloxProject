--!strict
-- The chaining contract.
--
-- This is a graph walk, not a pose fuzz: what is being checked is that every
-- chain an enemy could actually throw stays answerable, over every opener,
-- every follow-up and every distance either is legal at. The 2000-seed pose
-- loops live in AttackChoreography.spec and are already the slowest thing in
-- the suite; there is nothing to gain by running them again here.
--
-- The property that matters, and the one that is easy to get wrong:
--
--     a link landing within 0.50s of the previous impact is unparryable by
--     construction, because the player is still in hitstun and the parry
--     press is discarded rather than mistimed.
--
-- So "the tell is long enough" is not the question. The question is how much
-- of the tell landed *after the player could act again*, which is what
-- `effectiveLead` measures and what these tests assert against.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local AttackChain = require(Shared.AttackChain)
local AttackChoreography = require(Shared.AttackChoreography)
local AttackSelector = require(Shared.AttackSelector)
local CombatConstants = require(Shared.CombatConstants)
local DungeonDefs = require(Shared.DungeonDefs)
local EnemyDefs = require(Shared.EnemyDefs)

local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local describe = JestGlobals.describe
local expect = JestGlobals.expect
local it = JestGlobals.it

local NOW = 100.0

-- expect() on a { label, value } pair, so a failure names what failed
-- rather than just saying false was not true.
local function check(label: string, value: boolean)
	expect({ label, value }).toEqual({ label, true })
end

-- Every whole and half stud from point blank to the furthest any attack
-- reaches, so a chain that only breaks at one awkward spacing still gets
-- caught.
local function distanceSweep(def: any): { number }
	local furthest = 0
	for _, attack in def.attacks do
		furthest = math.max(furthest, attack.maxRange)
	end

	local out = {}
	local step = 0
	while step <= furthest do
		table.insert(out, step)
		step += 0.5
	end
	return out
end

describe("AttackChain timing", function()
	-- The headline property. If this ever fails, some enemy somewhere is
	-- throwing a follow-up that a player physically cannot answer.
	it("leaves every link answerable after the hitstun it lands in", function()
		for enemyId, def in EnemyDefs do
			for openerId, opener in def.attacks do
				for _, distance in distanceSweep(def) do
					for _, linkId in AttackChain.candidates(def, openerId, distance, {}, NOW) do
						local link = def.attacks[linkId]
						local timing = AttackChain.linkTiming(
							NOW + opener.telegraphDuration,
							link.leadTime,
							link.parryable
						)
						local floor = AttackChain.floorFor(link.parryable)
						check(
							`{enemyId} {openerId}->{linkId} at {distance}: effective lead `
								.. `{math.floor(timing.effectiveLead * 1000) / 1000} under {floor}`,
							timing.effectiveLead >= floor - 1e-9
						)
					end
				end
			end
		end
	end)


	-- The invariant that makes the seam work on screen rather than only on
	-- paper.
	--
	-- A strike that carries into another holds its carry pose until its own
	-- animation ends, which is `impact + RECOVER_DURATION`. The link then
	-- crossfades out of whatever the rig is holding at that moment. So long as
	-- the link starts inside that window, it starts from the carry pose and
	-- the blend is the no-op the seam tests prove it to be.
	--
	-- If the link started *after* it, the rig would visibly stand back up and
	-- then wind again -- the exact stutter the whole no-anticipation-beat
	-- design exists to avoid, and it would not fail any other test here.
	-- Currently the gap tops out around 0.44s against a 0.8s hold, so there is
	-- room; this fails if RECOVER_DURATION is lowered or a floor is raised
	-- enough to close it.
	it("starts every link while the previous carry pose is still held", function()
		for enemyId, def in EnemyDefs do
			for openerId, opener in def.attacks do
				for _, linkId in AttackChain.candidates(def, openerId, def.preferredRange, {}, NOW) do
					local link = def.attacks[linkId]
					local previousImpact = NOW + opener.telegraphDuration
					local timing = AttackChain.linkTiming(previousImpact, link.leadTime, link.parryable)
					local gap = timing.startsAt - previousImpact

					check(
						`{enemyId} {openerId}->{linkId} waits {math.floor(gap * 1000) / 1000}s, `
							.. `carry is held for {CombatConstants.RECOVER_DURATION}s`,
						gap <= CombatConstants.RECOVER_DURATION
					)
				end
			end
		end
	end)
	it("never starts a link before its carry pose has been seen", function()
		for _, def in EnemyDefs do
			for openerId, opener in def.attacks do
				for _, linkId in AttackChain.candidates(def, openerId, def.preferredRange, {}, NOW) do
					local previousImpact = NOW + opener.telegraphDuration
					local resolveAt = previousImpact + CombatConstants.STRIKE_RESOLUTION_GRACE
					local timing = AttackChain.linkTiming(
						previousImpact,
						def.attacks[linkId].leadTime,
						def.attacks[linkId].parryable
					)
					check(
						`{openerId}->{linkId} holds the carry for CARRY_MIN`,
						timing.startsAt >= resolveAt + AttackChain.CARRY_MIN - 1e-9
					)
				end
			end
		end
	end)

	-- The reason chaining exists at all. If a chained link were not faster
	-- than simply attacking again, the whole mechanism would be cost with no
	-- benefit.
	it("gets the next attack out sooner than starting over would", function()
		for enemyId, def in EnemyDefs do
			for openerId, opener in def.attacks do
				for _, linkId in AttackChain.candidates(def, openerId, def.preferredRange, {}, NOW) do
					local link = def.attacks[linkId]
					local previousImpact = NOW + opener.telegraphDuration
					local chained = AttackChain.linkTiming(previousImpact, link.leadTime, link.parryable).impactAt

					-- What the enemy would do without chaining: resolve, stand
					-- through the full recovery, wait out its idle beat, then
					-- telegraph from scratch.
					local restarted = previousImpact
						+ CombatConstants.STRIKE_RESOLUTION_GRACE
						+ CombatConstants.RECOVER_DURATION
						+ def.attackInterval
						+ link.telegraphDuration

					check(`{enemyId} {openerId}->{linkId} is faster chained`, chained < restarted)
				end
			end
		end
	end)

	it("derives the same timing from the same inputs on both sides of the wire", function()
		for _, def in EnemyDefs do
			for _, attack in def.attacks do
				local a = AttackChain.linkTiming(NOW + 1, attack.leadTime, attack.parryable)
				local b = AttackChain.linkTiming(NOW + 1, attack.leadTime, attack.parryable)
				check("startsAt", a.startsAt == b.startsAt)
				check("impactAt", a.impactAt == b.impactAt)
				check("effectiveLead", a.effectiveLead == b.effectiveLead)
			end
		end
	end)

	-- A link settles faster than a standalone attack because the rig is
	-- already wound. If these ever matched, the link would be starting from
	-- rest and the seam would be doing nothing.
	it("settles a link faster than an attack thrown from neutral", function()
		check("LINK_SETTLE is shorter than SETTLE", AttackChoreography.LINK_SETTLE < AttackChoreography.SETTLE)
		check("LINK_SETTLE is still visible", AttackChoreography.LINK_SETTLE > 0)
	end)
end)

describe("AttackChain candidates", function()
	it("never offers the attack that was just thrown", function()
		for enemyId, def in EnemyDefs do
			for openerId in def.attacks do
				for _, distance in distanceSweep(def) do
					local candidates = AttackChain.candidates(def, openerId, distance, {}, NOW)
					check(
						`{enemyId} {openerId} at {distance} does not follow itself`,
						table.find(candidates, openerId) == nil
					)
				end
			end
		end
	end)

	-- Repeating a tell is exactly the repetition that made enemies feel
	-- interchangeable, so a chain never asks the same question twice running.
	it("never offers the same question twice in a row", function()
		for enemyId, def in EnemyDefs do
			for openerId, opener in def.attacks do
				for _, linkId in AttackChain.candidates(def, openerId, def.preferredRange, {}, NOW) do
					check(
						`{enemyId} {openerId}->{linkId} changes archetype`,
						def.attacks[linkId].archetype ~= opener.archetype
					)
				end
			end
		end
	end)

	it("respects cooldowns", function()
		for _, def in EnemyDefs do
			for openerId in def.attacks do
				local blocked: { [string]: number } = {}
				for attackId in def.attacks do
					blocked[attackId] = NOW + 5
				end
				local candidates = AttackChain.candidates(def, openerId, def.preferredRange, blocked, NOW)
				check(`{openerId} has nothing to follow with on cooldown`, #candidates == 0)
			end
		end
	end)

	it("keeps a chain-only attack out of the openers", function()
		for enemyId, def in EnemyDefs do
			for _, distance in distanceSweep(def) do
				for _, attackId in AttackSelector.legalAttacks(def, distance, {}, NOW) do
					check(
						`{enemyId} opens with {attackId}, which is chain-only`,
						not def.attacks[attackId].chainOnly
					)
				end
			end
		end
	end)
end)

describe("AttackChain reachability", function()
	-- An enemy with chaining switched on and no reachable follow-up would
	-- simply never chain, and the tuning would look like it was doing
	-- something when it was not.
	it("gives every enemy a reachable two-link chain at its preferred range", function()
		for enemyId, def in EnemyDefs do
			local reachable = 0
			for openerId in def.attacks do
				reachable += #AttackChain.candidates(def, openerId, def.preferredRange, {}, NOW)
			end
			check(`{enemyId} has a chain available at its preferred range`, reachable > 0)
		end
	end)

	it("ships chaining dark until an enemy opts in", function()
		-- maxChain defaults to 1. Turning it on is a deliberate per-enemy
		-- edit, because a chain that reads badly is worse than no chain.
		for enemyId, def in EnemyDefs do
			local limit = AttackChain.maxLinks(def)
			check(`{enemyId} maxLinks at least 1`, limit >= 1)
			check(`{enemyId} maxLinks within MAX_LINKS`, limit <= AttackChain.MAX_LINKS)
			if def.maxChain == nil then
				check(`{enemyId} defaults to no chaining`, limit == 1)
			end
		end
	end)

	it("never lets a whole chain be hyper-armoured", function()
		-- A flurry the player cannot interrupt at any point is a cutscene. At
		-- least one link has to be breakable by hitting into it.
		--
		-- The boss is exempt, and deliberately. Hyper armour governs whether
		-- *damage* interrupts, not whether the player can answer: every
		-- HollowKing link still clears the effective-lead contract above, so
		-- each one can be parried or dodged on its own terms. What a boss
		-- loses by this exemption is the option to be staggered out of a
		-- sequence it has committed to, which is the thing that makes it read
		-- as a boss rather than a large skeleton. On a common enemy the same
		-- pairing would remove aggressive counterplay entirely, which is why
		-- the rule still holds for everything else.
		for enemyId, def in EnemyDefs do
			if enemyId == DungeonDefs.BOSS then
				continue
			end
			for openerId, opener in def.attacks do
				for _, linkId in AttackChain.candidates(def, openerId, def.preferredRange, {}, NOW) do
					local both = opener.hyperArmor and def.attacks[linkId].hyperArmor
					check(`{enemyId} {openerId}->{linkId} is not all hyper armour`, not both)
				end
			end
		end
	end)
end)

describe("AttackChain floors", function()
	it("holds a parryable link to the parry floor and an unparryable one to the dodge floor", function()
		local parryFloor = AttackChain.floorFor(true)
		local dodgeFloor = AttackChain.floorFor(false)

		check(`parry floor {parryFloor} is positive`, parryFloor > 0)
		check(`dodge floor {dodgeFloor} is positive`, dodgeFloor > 0)

		-- An unparryable ender is answered by moving, and a dodge has to be
		-- committed to earlier than a parry does.
		check("the dodge floor is the higher of the two", dodgeFloor >= parryFloor)
	end)

	-- The floor is the band's floor, not a second number that could drift
	-- away from it.
	it("takes its floor from the same band the tells are tuned against", function()
		for _, parryable in { true, false } do
			local lowest = AttackChoreography.readableLead(parryable)
			check(`floor matches the band for parryable={parryable}`, AttackChain.floorFor(parryable) == lowest)
		end
	end)
end)
