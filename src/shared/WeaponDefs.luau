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
-- Mage is here now, but not as the exception DESIGN.md describes. That one —
-- magic *replacing* basic combat — still needs its own combat model. What the
-- Focus is instead is the "magic enhances combat" version: the same five
-- inputs as everyone else, swung at arm's length by a thing that is not a
-- sword, with the class identity carried by reach, by a critical that hits all
-- round, and by its abilities. See DESIGN.md; the real exception is still open.

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

	--[[ The four added in the class pass ]]

	-- Slowest, heaviest, widest. The parry frames are the Tank's minus a
	-- little, because a Berserker who parries as well as a Tank *and* hits
	-- this hard has no reason to ever be a Tank. The payoff is a riposte
	-- rather than control: parrying is how a Berserker gets to keep swinging.
	Greataxe = {
		displayName = "Greataxe",
		classTag = "Berserker",
		parry = {
			earlyTolerance = 0.22,
			lateTolerance = 0.07,
		},
		payoff = {
			staggerMultiplier = 1.2,
			burstHeal = 0,
			burstHealRadius = 0,
			-- Short and sharp. Riposte and the stagger bonus take the larger
			-- rather than stacking, so anything at or below 2 would be worth
			-- nothing at all against the enemy you just parried.
			riposteDuration = 2.0,
			riposteMultiplier = 2.4,
		},
		-- Two horizontal cleaves, a rising cut, then a two-handed overhead
		-- that comes down like a falling tree. The critical is a full spin.
		attack = {
			combo = {
				{ windup = 0.46, damageMultiplier = 1 },
				{ windup = 0.44, damageMultiplier = 1.08 },
				{ windup = 0.42, damageMultiplier = 1.15 },
				{ windup = 0.62, damageMultiplier = 1.9 },
			},
			comboWindow = 0.85,
			finisherRecovery = 0.95,
			lunge = 7,
			critical = { windup = 0.75, damageMultiplier = 3.0, cooldown = 7, range = 13, arcDegrees = 360 },
			pvpTelegraph = 0.62,
			damage = 17,
			range = 12,
			arcDegrees = 150,
			-- Just under MISS_RECOVERY: missing with this has to cost more
			-- than connecting with it, however slow it already is.
			recovery = 0.28,
		},
	},

	-- The widest parry frames in the game, and the lowest damage of any melee
	-- weapon to pay for them. The Duelist is the class for the player who
	-- wants the parry game itself: almost everything it is worth comes out of
	-- the riposte, and a Duelist who never parries is strictly the worst
	-- fighter on the field.
	Rapier = {
		displayName = "Rapier",
		classTag = "Duelist",
		parry = {
			earlyTolerance = 0.34,
			lateTolerance = 0.12,
		},
		payoff = {
			staggerMultiplier = 1.1,
			burstHeal = 0,
			burstHealRadius = 0,
			riposteDuration = 3.5,
			riposteMultiplier = 2.2,
		},
		-- Thrust, thrust, a circular parry-riposte cut, then a lunging
		-- run-through. Narrow and precise: this weapon punishes a crowd badly
		-- and a duel very well.
		attack = {
			combo = {
				{ windup = 0.24, damageMultiplier = 1 },
				{ windup = 0.22, damageMultiplier = 1.05 },
				{ windup = 0.26, damageMultiplier = 1.15 },
				{ windup = 0.34, damageMultiplier = 1.7 },
			},
			comboWindow = 0.6,
			finisherRecovery = 0.6,
			lunge = 14,
			critical = { windup = 0.48, damageMultiplier = 2.4, cooldown = 5, range = 14, arcDegrees = 60 },
			pvpTelegraph = 0.34,
			damage = 8,
			range = 13,
			arcDegrees = 55,
			recovery = 0.16,
		},
	},

	-- Reach instead of weight. The bow's "swing" is a shot: the same
	-- resolution every other weapon uses, at four times the range and through
	-- a sliver of an arc, so it has to be aimed rather than waved.
	--
	-- Resolved where the shot is taken rather than travelling, which is the
	-- one thing about this class that is a compromise rather than a choice —
	-- see DESIGN.md. Everything that makes it feel like a bow at the moment is
	-- the draw: the longest windups of any weapon, and no lunge at all.
	Bow = {
		displayName = "Longbow",
		classTag = "Ranger",
		parry = {
			-- The worst parry frames in the game. A Ranger caught inside its
			-- own range is supposed to be in trouble.
			earlyTolerance = 0.16,
			lateTolerance = 0.05,
		},
		payoff = {
			staggerMultiplier = 0.9,
			burstHeal = 0,
			burstHealRadius = 0,
			-- The shortest riposte in the game, and nearly the hardest: a
			-- Ranger who parries has bought one good answer and the time to
			-- get back out to where the bow works.
			riposteDuration = 1.5,
			riposteMultiplier = 2.3,
		},
		-- Three drawn shots, then a fully-drawn heavy one. The critical is a
		-- long aimed shot that reaches most of a room.
		attack = {
			combo = {
				{ windup = 0.42, damageMultiplier = 1 },
				{ windup = 0.4, damageMultiplier = 1.05 },
				{ windup = 0.4, damageMultiplier = 1.1 },
				{ windup = 0.58, damageMultiplier = 1.75 },
			},
			comboWindow = 0.8,
			finisherRecovery = 0.8,
			lunge = 0,
			critical = { windup = 0.7, damageMultiplier = 2.5, cooldown = 6, range = 70, arcDegrees = 16 },
			pvpTelegraph = 0.55,
			damage = 9,
			range = 52,
			arcDegrees = 22,
			recovery = 0.26,
		},
	},

	-- Reach and area rather than damage. The Focus swings badly on purpose:
	-- its combo is the weakest in the game and its critical is the widest, so
	-- the class is played by controlling where a fight happens rather than by
	-- winning any exchange in it.
	Focus = {
		displayName = "Arcane Focus",
		classTag = "Mage",
		parry = {
			earlyTolerance = 0.26,
			lateTolerance = 0.08,
		},
		payoff = {
			staggerMultiplier = 1.3,
			burstHeal = 0,
			burstHealRadius = 0,
			riposteDuration = 2.5,
			riposteMultiplier = 2.1,
		},
		-- Two swept arcs, a driving push, then a wide outward release. The
		-- critical is a ring that hits everything around.
		attack = {
			combo = {
				{ windup = 0.36, damageMultiplier = 1 },
				{ windup = 0.34, damageMultiplier = 1.05 },
				{ windup = 0.34, damageMultiplier = 1.1 },
				{ windup = 0.5, damageMultiplier = 1.65 },
			},
			comboWindow = 0.7,
			finisherRecovery = 0.7,
			lunge = 5,
			critical = { windup = 0.62, damageMultiplier = 2.2, cooldown = 6, range = 18, arcDegrees = 360 },
			pvpTelegraph = 0.48,
			damage = 7,
			range = 16,
			arcDegrees = 200,
			recovery = 0.2,
		},
	},
}

return WeaponDefs
