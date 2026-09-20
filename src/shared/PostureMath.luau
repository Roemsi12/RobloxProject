--!strict
-- Posture: how close a guard is to breaking. Pure Luau — numbers in, numbers
-- out, no Roblox API.
--
-- Blocking a hit fills posture instead of costing health. It drains back on
-- its own once a player stops taking blocked hits for a moment. Fill it and
-- the guard breaks: a stun, and the hit that broke it lands in full.

local CombatConstants = require(script.Parent.CombatConstants)

local PostureMath = {}

-- The skill tree raises a player's posture limits (SkillTreeDefs). Every
-- function here takes the changed number as an optional argument and falls
-- back to the shared constant, so callers that have no player in hand — the
-- HUD drawing a bar, a test — stay simple.
export type Limits = {
	max: number,
	regenPerSecond: number,
	parryRestore: number,
}

-- The unmodified posture limits from CombatConstants. Callers that have a
-- player's skill tree use `limitsFor` instead; this is for everything that
-- has no player, such as tests and enemies.
function PostureMath.defaults(): Limits
	return {
		max = CombatConstants.MAX_POSTURE,
		regenPerSecond = CombatConstants.POSTURE_REGEN_PER_SECOND,
		parryRestore = CombatConstants.PARRY_POSTURE_RESTORE,
	}
end

-- Posture at `now`, given its value when last set (`updatedAt`) and when it
-- last took damage. Drains only after the regen delay.
function PostureMath.regenerate(
	posture: number,
	updatedAt: number,
	lastDamagedAt: number,
	now: number,
	regenPerSecond: number?
): number
	local drainFrom = math.max(updatedAt, lastDamagedAt + CombatConstants.POSTURE_REGEN_DELAY)
	if now <= drainFrom then
		return posture
	end
	local rate = regenPerSecond or CombatConstants.POSTURE_REGEN_PER_SECOND
	return math.max(posture - rate * (now - drainFrom), 0)
end

export type BlockResult = {
	posture: number,
	broken: boolean,
}

-- Posture after blocking a hit of `damage`. A break empties it: the guard
-- starts fresh once the stun wears off.
function PostureMath.block(posture: number, damage: number, maxPosture: number?): BlockResult
	local filled = posture + damage * CombatConstants.BLOCK_POSTURE_PER_DAMAGE
	if filled >= (maxPosture or CombatConstants.MAX_POSTURE) then
		return { posture = 0, broken = true }
	end
	return { posture = filled, broken = false }
end

-- Posture left after a clean parry takes its chunk off, floored at zero.
-- `restore` overrides the default for weapons whose tree raised it.
function PostureMath.afterParry(posture: number, restore: number?): number
	return math.max(posture - (restore or CombatConstants.PARRY_POSTURE_RESTORE), 0)
end

return PostureMath
