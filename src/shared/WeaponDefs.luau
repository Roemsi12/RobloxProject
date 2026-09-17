--!strict
-- weaponId -> class, parry profile, attack profile, parry payoff.
-- Pure data — no Roblox API.
--
-- Class is derived from the equipped weapon (DESIGN.md: "Class = equipped
-- weapon"), so classTag lives here and there is deliberately no ClassDefs
-- module. Keying by weapon rather than by class also leaves room for a class
-- to have more than one weapon (ARCHITECTURE.md lists "Staff / Mace" for the
-- Healer) without restructuring.
--
-- Everything that differentiates a class is data in this file. Adding a class
-- is adding a row, not writing code — there should never be an
-- `if classTag == "..."` branch anywhere in combat.
--
-- Mage isn't here yet: DESIGN.md flags it as the deliberate exception where
-- magic replaces basic combat, which needs its own combat model rather than
-- another row.

export type ParryProfile = {
	-- Pressing block opens parry frames: a hit landing up to earlyTolerance
	-- seconds after the press is parried. lateTolerance is the slack for a hit
	-- landing a hair before the press, within a frame or two. See
	-- ParryMath.catches.
	earlyTolerance: number,
	lateTolerance: number,
}

-- What a successful parry buys you, on top of the universal stagger punish
-- bonus in CombatConstants. This is where "skill must count as much as
-- level/gear" is expressed per class: every class can parry, but each converts
-- a parry into a different advantage.
export type ParryPayoff = {
	-- Scales CombatConstants.STAGGER_DURATION — a longer punish window for
	-- everyone attacking that enemy.
	staggerMultiplier: number,
	-- Health restored to the parrying player AND every other player within
	-- burstHealRadius. Tied to the parry rather than a passive heal-over-time,
	-- per DESIGN.md's healer pillar.
	burstHeal: number,
	burstHealRadius: number,
	-- Seconds of amplified outgoing damage after a successful parry.
	riposteDuration: number,
	riposteMultiplier: number,
}

-- One swing of a combo.
export type ComboStep = {
	-- Seconds from the press to the hit landing.
	windup: number,
	-- Multiplies the weapon's (upgraded) damage.
	damageMultiplier: number,
}

-- The heavy attack on its own key: slower, harder, wider, on a cooldown.
export type CriticalProfile = {
	windup: number,
	damageMultiplier: number,
	cooldown: number,
	range: number,
	arcDegrees: number,
}

export type AttackProfile = {
	-- Pressing attack again soon after a swing lands continues into the next
	-- step; the last step is the finisher, which hits hardest and takes
	-- longest to recover from. Each step has its own animation.
	combo: { ComboStep },
	-- Seconds after a swing lands in which the next press continues the combo.
	comboWindow: number,
	-- Lock after the finisher (or a critical) lands.
	finisherRecovery: number,
	-- A short forward step (studs per second) on each swing. Visual feel; the
	-- server resolves the hit from wherever the player actually is.
	lunge: number,
	critical: CriticalProfile,
	-- How long this weapon's swing telegraphs to a duel opponent before it
	-- resolves. Players have no EnemyDefs entry to read this from, so it lives
	-- here. Tracks each class's parry identity: the Tank is slowest and easiest
	-- to punish, the Assassin fastest and hardest to react to.
	pvpTelegraph: number,
	-- Base damage before blacksmith upgrades (EconomyDefs.upgradedDamage).
	damage: number,
	range: number,
	arcDegrees: number,
	-- Pause after a non-finisher swing lands before the next can start.
	--
	-- This is the number that decides whether melee is a rhythm or a mash. It
	-- was 0.06-0.1s, which is no pause at all: the answer to everything was to
	-- hold the button down. A swing now costs real time, whether it lands or
	-- not (CombatConstants.MISS_RECOVERY).
	recovery: number,
}

export type WeaponDef = {
	displayName: string,
	classTag: string,
	parry: ParryProfile,
	payoff: ParryPayoff,
	attack: AttackProfile,
}

local WeaponDefs: { [string]: WeaponDef } = {
	-- The longest parry frames in the game (ARCHITECTURE.md: Tank is
	-- "wide/forgiving"). Converts a parry into control rather than damage: the
	-- longer stagger is a longer double-damage window for the whole group.
	SwordAndShield = {
		displayName = "Sword & Shield",
		classTag = "Tank",
		parry = {
			earlyTolerance = 0.28,
			lateTolerance = 0.08,
		},
		payoff = {
			staggerMultiplier = 1.5,
			burstHeal = 0,
			burstHealRadius = 0,
			riposteDuration = 0,
			riposteMultiplier = 1,
		},
		-- Diagonal cut, rising cut, flat cut, then an overhead chop. The
		-- critical is a spinning cleave.
		attack = {
			combo = {
				{ windup = 0.34, damageMultiplier = 1 },
				{ windup = 0.32, damageMultiplier = 1.05 },
				{ windup = 0.32, damageMultiplier = 1.1 },
				{ windup = 0.46, damageMultiplier = 1.6 },
			},
			comboWindow = 0.7,
			finisherRecovery = 0.75,
			lunge = 9,
			critical = { windup = 0.6, damageMultiplier = 2.6, cooldown = 6, range = 12, arcDegrees = 170 },
			pvpTelegraph = 0.5,
			damage = 12,
			range = 11,
			arcDegrees = 120,
			recovery = 0.22,
		},
	},

	-- The shortest parry frames, the biggest payoff (ARCHITECTURE.md: "tight
	-- parry window, high backstab payoff"). The riposte is where that payoff
	-- lives until positional backstabs exist.
	Daggers = {
		displayName = "Daggers",
		classTag = "Assassin",
		parry = {
			earlyTolerance = 0.2,
			lateTolerance = 0.06,
		},
		payoff = {
			staggerMultiplier = 0.8,
			burstHeal = 0,
			burstHealRadius = 0,
			riposteDuration = 2.5,
			riposteMultiplier = 2.5,
		},
		-- Right jab, left jab, cross cut, then a double downward stab. The
		-- critical is a leaping X-slash.
		attack = {
			combo = {
				{ windup = 0.2, damageMultiplier = 1 },
				{ windup = 0.19, damageMultiplier = 1.05 },
				{ windup = 0.19, damageMultiplier = 1.1 },
				{ windup = 0.28, damageMultiplier = 1.6 },
			},
			comboWindow = 0.55,
			finisherRecovery = 0.55,
			lunge = 11,
			critical = { windup = 0.42, damageMultiplier = 2.2, cooldown = 5, range = 9, arcDegrees = 100 },
			pvpTelegraph = 0.3,
			damage = 6,
			range = 8,
			arcDegrees = 80,
			recovery = 0.14,
		},
	},

	-- The parry-triggered burst heal is what makes the Healer near-
	-- indispensable (DESIGN.md): healing lives in the skill loop, and it reaches
	-- allies, so a group without a Healer can't undo the chip damage and bleeds
	-- that dungeons are tuned around.
	Staff = {
		displayName = "Staff",
		classTag = "Healer",
		parry = {
			earlyTolerance = 0.24,
			lateTolerance = 0.07,
		},
		payoff = {
			staggerMultiplier = 1.0,
			burstHeal = 25,
			burstHealRadius = 20,
			riposteDuration = 0,
			riposteMultiplier = 1,
		},
		-- Sweep, return sweep, thrust, then a two-handed overhead slam. The
		-- critical is a full spinning sweep that hits all around.
		attack = {
			combo = {
				{ windup = 0.3, damageMultiplier = 1 },
				{ windup = 0.29, damageMultiplier = 1.05 },
				{ windup = 0.29, damageMultiplier = 1.1 },
				{ windup = 0.4, damageMultiplier = 1.55 },
			},
			comboWindow = 0.65,
			finisherRecovery = 0.65,
			lunge = 7,
			critical = { windup = 0.55, damageMultiplier = 2.3, cooldown = 6, range = 13, arcDegrees = 360 },
			pvpTelegraph = 0.45,
			damage = 8,
			range = 12,
			arcDegrees = 110,
			recovery = 0.18,
		},
	},
}

return WeaponDefs
