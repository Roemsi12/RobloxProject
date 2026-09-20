--!strict
-- Enemy decision-making: which attack to use, and whether to move.
-- Pure Luau — no Roblox API, no instances, no randomness it doesn't receive.
--
-- This is the "generalized across enemy types" half of build-order step 3.
-- There are no per-enemy branches here: a charging melee type and a kiting
-- ranged type differ only in the numbers they bring. If a new enemy needs a
-- branch in this file, that's a sign the behaviour belongs in EnemyDefs as
-- data instead.

local EnemyDefs = require(script.Parent.EnemyDefs)

local AttackSelector = {}

-- Dead band around preferredRange. Without it an enemy sitting almost exactly
-- at its preferred distance flips between approach and retreat every tick and
-- visibly shuffles on the spot.
local HOLD_TOLERANCE = 2

export type MovementIntent = "approach" | "retreat" | "hold" | "idle"

-- Cooldown bookkeeping is passed in rather than held here, so this stays pure
-- and the caller owns all enemy state.
export type CooldownMap = { [string]: number }

-- An enemy's leash: the XZ rectangle of the room it belongs to, already inset
-- from the walls.
--
-- Enemies move by stepping an anchored part rather than through physics, so
-- nothing else stops them walking through a wall. The leash is what keeps each
-- one in its own room, and what stops one aggroing on a player in the next
-- room over.
export type Bounds = {
	minX: number,
	maxX: number,
	minZ: number,
	maxZ: number,
}

-- Whether a point is inside a room's rectangle. Used to keep an enemy
-- leashed: movement and aggro both stop at its own room's walls.
function AttackSelector.isWithinBounds(bounds: Bounds, x: number, z: number): boolean
	return x >= bounds.minX and x <= bounds.maxX and z >= bounds.minZ and z <= bounds.maxZ
end

-- The nearest point inside the rectangle, per axis. Where an enemy that
-- tried to walk out of its room is actually put.
function AttackSelector.clampToBounds(bounds: Bounds, x: number, z: number): (number, number)
	return math.clamp(x, bounds.minX, bounds.maxX), math.clamp(z, bounds.minZ, bounds.maxZ)
end

-- What an enemy wants to do about its distance to the player, before any
-- attack is considered.
--
-- Four answers, in priority order: "idle" beyond aggro range, "hold" if it
-- cannot move at all, then "approach" or "retreat" to get back to
-- `preferredRange`. HOLD_TOLERANCE is the dead band around that range —
-- without it an enemy sitting exactly at its preferred distance jitters
-- between approaching and retreating every frame.
function AttackSelector.movementIntent(def: EnemyDefs.EnemyDef, distance: number): MovementIntent
	if distance > def.aggroRange then
		return "idle"
	end

	if def.moveSpeed <= 0 then
		return "hold"
	end

	if distance > def.preferredRange + HOLD_TOLERANCE then
		return "approach"
	end

	if distance < def.preferredRange - HOLD_TOLERANCE then
		return "retreat"
	end

	return "hold"
end

-- Attacks legal right now: in band, and off cooldown. Returned sorted so the
-- weighted pick below is reproducible for a given rng sequence — otherwise
-- table iteration order would make tuning sessions non-repeatable.
function AttackSelector.legalAttacks(
	def: EnemyDefs.EnemyDef,
	distance: number,
	cooldowns: CooldownMap,
	now: number
): { string }
	local legal = {}

	for attackId, attack in def.attacks do
		local inBand = distance >= attack.minRange and distance <= attack.maxRange
		local ready = now >= (cooldowns[attackId] or 0)

		if inBand and ready then
			table.insert(legal, attackId)
		end
	end

	table.sort(legal)
	return legal
end

export type Rng = () -> number

-- Weighted pick among the legal attacks. Returns nil when the enemy has
-- nothing it can legally do, which the caller reads as "wait and reposition"
-- rather than as an error — it's the normal state for a ranged enemy that has
-- been walked down.
-- A weighted pick out of an already-legal list.
--
-- Split out of `chooseAttack` so chain links roll exactly the way openers do.
-- Two weighted pickers would drift, and the difference would show up as an
-- enemy whose flurries favour a different attack than its openers for no
-- reason anybody chose.
function AttackSelector.pickWeighted(def: EnemyDefs.EnemyDef, legal: { string }, rng: Rng?): string?
	if #legal == 0 then
		return nil
	end

	local totalWeight = 0
	for _, attackId in legal do
		totalWeight += def.attacks[attackId].weight
	end

	if totalWeight <= 0 then
		return legal[1]
	end

	local roll = (rng or math.random)() * totalWeight
	local cumulative = 0

	for _, attackId in legal do
		cumulative += def.attacks[attackId].weight
		if roll < cumulative then
			return attackId
		end
	end

	-- Only reachable through floating-point drift when roll lands on the very
	-- top of the range; the last legal attack is the correct answer there.
	return legal[#legal]
end

-- Which attack an enemy throws now, or nil if none is legal.
--
-- Weighted among the attacks that are in range and off cooldown. `roll`
-- is injectable, which is what makes the weighting testable — and the
-- legal list is sorted first, so the same roll always picks the same
-- attack rather than depending on table order.
function AttackSelector.chooseAttack(
	def: EnemyDefs.EnemyDef,
	distance: number,
	cooldowns: CooldownMap,
	now: number,
	rng: Rng?
): string?
	return AttackSelector.pickWeighted(def, AttackSelector.legalAttacks(def, distance, cooldowns, now), rng)
end

return AttackSelector
