--!strict
-- The abilities, and what each one does. Pure — no Roblox API.
--
-- Abilities are not handed out with a weapon; they are the reward at the end
-- of a branch of that weapon's skill tree (SkillTreeDefs). Each of the three
-- branches ends in one, and the branch you took decides which key you have
-- something on.
--
-- Unlocking all three is possible at the level cap, and costs more than half
-- of everything you will ever earn — which leaves nowhere near enough to also
-- fill in the ranks that make them hit hard. So the choice is not whether you
-- get abilities, it is whether you want three shallow ones or one you have
-- actually invested in.
--
-- The combo, the critical, the parry and the dodge are the same five inputs
-- whatever you carry; only their numbers change. An ability is the thing that
-- is only yours, and it is what makes swapping weapon feel like changing
-- class rather than changing damage numbers.
--
-- `kind` is what the server does with it, and the four are deliberately
-- different verbs rather than four damage numbers:
--   "burst"  damage in a circle around you, and a guaranteed stagger
--   "blink"  move behind your target, and strike from there
--   "mend"   heal yourself and everyone near you
--   "ward"   for a few seconds, take less damage and hold an unbreakable guard
--
-- Adding a fifth kind means writing it in CombatServer. Adding an ability
-- that reuses a kind is a row in this file plus a node that grants it.

local AbilityDefs = {}

export type AbilityKind = "burst" | "blink" | "mend" | "ward"

export type AbilityDef = {
	id: string,
	name: string,
	description: string,
	kind: AbilityKind,
	-- Seconds before it can be cast again. The skill tree can cut this; the
	-- client draws the cooldown from what the server reports rather than from
	-- this number.
	cooldown: number,
	-- How long the cast takes before it resolves. Short, but never zero: an
	-- ability that lands on the frame you press it can't be read by anyone
	-- you are fighting, and everything else in this game can be.
	windup: number,
	-- Damage for "burst" and "blink", health for "mend", and the fraction of
	-- incoming damage turned away for "ward".
	power: number,
	-- Seconds the effect lasts. Only "ward" has one.
	duration: number,
	-- Studs. How far a burst or a mend reaches, and how far a blink will look
	-- for something to land behind.
	radius: number,
	-- Only "burst" and "blink" care; "mend" and "ward" reach all round.
	arcDegrees: number,
	-- Seconds of stagger forced on everything hit. Zero for "mend" and "ward".
	stagger: number,
}

-- A ward's reduction never scales, so nothing can stack its way to immunity;
-- ability power buys seconds instead.
local MAX_WARD_REDUCTION = 0.75

local ABILITIES: { [string]: AbilityDef } = {
	--[[ Sword & Shield — the Tank ]]

	-- Bulwark's end: the answer to a fight you cannot win by winning, only by
	-- still being there afterwards.
	LastStand = {
		id = "LastStand",
		name = "Last Stand",
		description = "Plant yourself: far less damage taken, and a guard that cannot be broken.",
		kind = "ward",
		cooldown = 26,
		windup = 0.3,
		power = 0.4,
		duration = 6,
		radius = 0,
		arcDegrees = 360,
		stagger = 0,
	},

	-- Warden's end: the answer to being surrounded, which is the one thing a
	-- shield is no use against.
	ShieldBreak = {
		id = "ShieldBreak",
		name = "Shield Break",
		description = "Slam the shield outward: everything around you is hit, and all of it opens up.",
		kind = "burst",
		cooldown = 14,
		windup = 0.35,
		power = 22,
		duration = 0,
		radius = 14,
		arcDegrees = 360,
		stagger = 1.8,
	},

	-- Onslaught's end: a Tank that can pick who it is fighting.
	Breach = {
		id = "Breach",
		name = "Breach",
		description = "Charge the nearest enemy ahead and put your shoulder through them.",
		kind = "blink",
		cooldown = 16,
		windup = 0.3,
		power = 34,
		duration = 0,
		radius = 30,
		arcDegrees = 120,
		stagger = 1.2,
	},

	--[[ Daggers — the Assassin ]]

	-- Shadow's end, and the reason the backstab nodes above it are worth
	-- taking: this is how you get behind someone in the middle of a fight.
	Shadowstep = {
		id = "Shadowstep",
		name = "Shadowstep",
		description = "Step through your target's shadow and strike their back.",
		kind = "blink",
		cooldown = 11,
		windup = 0.2,
		power = 26,
		duration = 0,
		radius = 26,
		arcDegrees = 140,
		stagger = 0.9,
	},

	-- Reflex's end. An Assassin's ward is not armour; it is not being there.
	Evasion = {
		id = "Evasion",
		name = "Evasion",
		description = "Read everything coming for a few seconds, and take almost none of it.",
		kind = "ward",
		cooldown = 22,
		windup = 0.2,
		power = 0.5,
		duration = 5,
		radius = 0,
		arcDegrees = 360,
		stagger = 0,
	},

	-- Edge's end: the one answer the daggers have to being outnumbered.
	Flurry = {
		id = "Flurry",
		name = "Flurry",
		description = "Too many cuts to count, in every direction at once.",
		kind = "burst",
		cooldown = 12,
		windup = 0.25,
		power = 18,
		duration = 0,
		radius = 10,
		arcDegrees = 360,
		stagger = 0.6,
	},

	--[[ Staff — the Healer ]]

	-- Mercy's end. The parry heal rewards playing well; this one rescues a
	-- party that didn't, and asks nothing of you first.
	MendingPulse = {
		id = "MendingPulse",
		name = "Mending Pulse",
		description = "A pulse of light that heals you and everyone near you.",
		kind = "mend",
		cooldown = 20,
		windup = 0.4,
		power = 45,
		duration = 0,
		radius = 26,
		arcDegrees = 360,
		stagger = 0,
	},

	-- Ward's end: the Healer surviving the hit that was meant to stop them
	-- healing, which is how a party actually loses one.
	SanctifiedWard = {
		id = "SanctifiedWard",
		name = "Sanctified Ward",
		description = "Hold consecrated ground: much less damage taken, and a guard that holds.",
		kind = "ward",
		cooldown = 24,
		windup = 0.35,
		power = 0.35,
		duration = 6,
		radius = 0,
		arcDegrees = 360,
		stagger = 0,
	},

	-- Arcana's end: proof the staff was never a stick.
	ArcaneNova = {
		id = "ArcaneNova",
		name = "Arcane Nova",
		description = "Everything the staff has been holding, released at once.",
		kind = "burst",
		cooldown = 15,
		windup = 0.45,
		power = 24,
		duration = 0,
		radius = 16,
		arcDegrees = 360,
		stagger = 1.2,
	},
}

function AbilityDefs.get(abilityId: string): AbilityDef?
	return ABILITIES[abilityId]
end

function AbilityDefs.ids(): { string }
	local ids = {}
	for id in ABILITIES do
		table.insert(ids, id)
	end
	table.sort(ids)
	return ids
end

-- What an ability is worth to this player, after their skill tree. Kept here
-- rather than in the server so the HUD can show the same numbers without
-- asking.
export type Resolved = {
	cooldown: number,
	power: number,
	duration: number,
}

function AbilityDefs.resolve(def: AbilityDef, abilityCooldown: number, abilityPower: number): Resolved
	local ward = def.kind == "ward"
	return {
		-- Floored at a second: a cooldown the tree could drive to nothing
		-- would make the ability the whole rotation.
		cooldown = math.max(def.cooldown * (1 - abilityCooldown), 1),
		-- A ward's reduction is fixed; power buys it seconds instead, so no
		-- combination of nodes can add up to being invulnerable.
		power = if ward then math.min(def.power, MAX_WARD_REDUCTION) else def.power * (1 + abilityPower),
		duration = if ward then def.duration * (1 + abilityPower) else def.duration,
	}
end

return AbilityDefs
