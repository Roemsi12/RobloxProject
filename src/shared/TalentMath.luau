--!strict
-- The arithmetic behind the skill-tree mechanics: the nodes that change what
-- happens in a fight rather than adding to a number (SkillTreeDefs calls them
-- mechanics). Pure — no Roblox API — so every rule here is unit-tested, and
-- CombatServer only has to decide *when* each one applies.
--
-- Every mechanic is keyed by an effect, never by a class: a mechanic is a row
-- in a tree, and any tree could carry any of them. Which tree carries which is
-- what makes the classes different (SkillTreeDefs).

local TalentMath = {}

-- An enemy at or below this share of its health counts as finishable
-- (`execute`).
TalentMath.EXECUTE_THRESHOLD = 0.35

-- How long after a dodge starts the next hit counts as an ambush
-- (`dodgeStrike`).
TalentMath.AMBUSH_WINDOW = 1.5

-- `frenzy` stacks up to this many hits.
TalentMath.FRENZY_MAX = 5

-- How long a critical's mark lasts (`markOnCrit`).
TalentMath.MARK_DURATION = 6

-- A parry pressed within this many seconds of the hit landing is a
-- split-second parry (`precisionStagger`). Tighter than every weapon's parry
-- window, so it is a skill on top of parrying rather than the same thing.
TalentMath.PRECISE_PARRY = 0.08

-- A bleed (`bleed`) is paid out in this many ticks over this many seconds.
TalentMath.BLEED_TICKS = 3
TalentMath.BLEED_DURATION = 3

-- `chainArc` leaps to up to this many other enemies, each within this many
-- studs of the one struck.
TalentMath.CHAIN_JUMPS = 2
TalentMath.CHAIN_RADIUS = 10

-- How far `pierce` reaches past the enemy struck, and how narrow its line is.
TalentMath.PIERCE_REACH = 6
TalentMath.PIERCE_ARC = 40

-- Reach of the healing mechanics that touch allies.
TalentMath.AURA_RADIUS = 14
TalentMath.HEAL_ON_HIT_RADIUS = 14
TalentMath.KILL_HEAL_RADIUS = 16
-- `guardAura` heals on this clock rather than every frame.
TalentMath.AURA_TICK = 0.5

-- The share of damage a mechanic's ward turns away. The parry ward is the
-- Tank's and is heavier; the heal ward is spread over a whole party.
TalentMath.PARRY_WARD_REDUCTION = 0.35
TalentMath.HEAL_WARD_REDUCTION = 0.25

export type Bonus = {
	-- The attacker's modifiers (SkillTreeDefs.modifiers).
	mods: { [string]: number },
	-- The target's health as a share of its maximum, 0..1.
	targetHealth: number,
	-- The attacker's own health as a share of its maximum, 0..1.
	ownHealth: number,
	-- Consecutive hits counted toward `frenzy`.
	frenzyStacks: number,
	-- Whether this hit is the first since a dodge, inside AMBUSH_WINDOW.
	ambush: boolean,
	-- Extra damage the target takes from a mark someone put on it (0 if none).
	mark: number,
}

-- What the mechanics add to a hit's damage, as a fraction to add to the
-- multiplier alongside the tree's flat `damage`. Additive, like every effect
-- in the trees: nothing multiplies, so no combination can run away.
function TalentMath.outgoingBonus(bonus: Bonus): number
	local mods = bonus.mods
	local total = 0

	if (mods.execute or 0) > 0 and bonus.targetHealth <= TalentMath.EXECUTE_THRESHOLD then
		total += mods.execute
	end

	-- Scales with how much health is missing: nothing at full, all of it
	-- with none left.
	if (mods.lowHealthDamage or 0) > 0 then
		total += mods.lowHealthDamage * (1 - math.clamp(bonus.ownHealth, 0, 1))
	end

	if (mods.frenzy or 0) > 0 then
		total += mods.frenzy * math.clamp(bonus.frenzyStacks, 0, TalentMath.FRENZY_MAX)
	end

	if bonus.ambush and (mods.dodgeStrike or 0) > 0 then
		total += mods.dodgeStrike
	end

	total += math.max(bonus.mark, 0)
	return total
end

-- The next frenzy count: one more after a hit, up to the cap.
function TalentMath.nextFrenzy(stacks: number): number
	return math.min(stacks + 1, TalentMath.FRENZY_MAX)
end

-- Whether a hit at `now` is still an ambush for a dodge that started at
-- `dodgeStartedAt`, and that dodge's ambush has not been spent already.
function TalentMath.isAmbush(dodgeStartedAt: number?, spentFor: number?, now: number): boolean
	if not dodgeStartedAt or spentFor == dodgeStartedAt then
		return false
	end
	local since = now - dodgeStartedAt
	return since >= 0 and since <= TalentMath.AMBUSH_WINDOW
end

-- Whether a parry pressed at `pressAt` against a hit landing at `impactTime`
-- was split-second.
function TalentMath.isPreciseParry(pressAt: number, impactTime: number): boolean
	return math.abs(pressAt - impactTime) <= TalentMath.PRECISE_PARRY + 1e-9
end

-- One tick of a bleed worth `total` in all.
function TalentMath.bleedTick(total: number): number
	return math.max(total, 0) / TalentMath.BLEED_TICKS
end

-- Splits an unblocked hit between health and posture for `manaShield`: the
-- shield takes `fraction` of it, but only as much as posture has room for, so
-- it can never break a guard by itself. Returns (to health, to posture).
function TalentMath.manaShieldSplit(damage: number, fraction: number, postureRoom: number): (number, number)
	local wanted = math.max(damage, 0) * math.clamp(fraction, 0, 1)
	local absorbed = math.clamp(wanted, 0, math.max(postureRoom, 0))
	return damage - absorbed, absorbed
end

-- A damage multiplier's worth of a hit carried on to another enemy, for
-- `pierce`, `multishot` and `chainArc`.
function TalentMath.carried(damage: number, fraction: number): number
	return math.max(damage, 0) * math.max(fraction, 0)
end

return TalentMath
