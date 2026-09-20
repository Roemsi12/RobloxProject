--!strict
-- enemyId -> stats, movement, rewards, and attack timelines.
-- Pure data — no Roblox API.
--
-- Behaviour is data, not code. An enemy is defined by its attack bands
-- (minRange/maxRange), where it wants to stand (preferredRange), and how it
-- weights its options — so a kiting ranged enemy and a charging melee one come
-- out of the same selector with no per-enemy branches. Adding an enemy type
-- should be adding a row here, plus a LootTables entry for its chest.
--
-- Enemies are leashed to their room, and rooms come in several sizes
-- (DungeonDefs), so preferredRange must fit inside the smallest room each
-- enemy can be placed in. A test checks it against the dungeon's pools.

-- Damage that keeps ticking after a hit lands. The "unavoidable chip damage"
-- half of DESIGN.md's healer pillar: a mistimed dodge isn't one number a Tank
-- shrugs off, it's a bleed only sustain fully undoes.
export type DotDef = {
	tickDamage: number,
	tickInterval: number,
	ticks: number,
}

export type AttackDef = {
	-- Seconds from the start of the windup to impact. The parry window is
	-- positioned relative to impact by ParryMath.
	--
	-- Derived, not chosen: it is `leadTime` plus the beat the rig takes to
	-- snap into its tell (AttackChoreography.SETTLE). Setting it by hand would
	-- let the telegraph and the tell drift apart, and the player reads the
	-- tell. A spec keeps the two in step.
	telegraphDuration: number,
	-- Which of AttackChoreography's four tells this attack wears. Decides the
	-- windup silhouette, and has to agree with `parryable` — the whole point
	-- of a fixed vocabulary is that a pose means one answer.
	--
	-- A string rather than the exported type so this module keeps requiring
	-- nothing, the way the projectile `kind` does. The spec checks the name.
	archetype: string,
	-- Seconds the tell is held on screen before the hit lands. This is the
	-- budget the player reads in, and it is the number to change when an
	-- attack feels unreadable — never the telegraph.
	--
	-- Held inside a band, not just above a floor: too long and the parry
	-- window (anchored to impact) has not opened yet when the player reacts to
	-- the tell, so reacting presses early and eats the cooldown. The spec
	-- derives the band from the weapons' windows and enforces both ends.
	leadTime: number,
	-- DESIGN.md requires some attacks to be unparryable, so the answer to
	-- every enemy is never just "parry everything".
	parryable: boolean,
	damage: number,
	-- Server-side hit-reg volume, checked against the character's server
	-- position at the moment of impact. Also bounds who may parry it.
	range: number,
	arcDegrees: number,
	-- Band in which this attack is a legal choice. An attack whose minRange is
	-- above zero is a spacing tool the enemy won't use point-blank.
	minRange: number,
	maxRange: number,
	-- Relative likelihood among all currently-legal attacks.
	weight: number,
	-- Per-attack cooldown, so a heavy hit can't be chained.
	cooldown: number,
	-- Applied only when the hit lands unparried.
	dot: DotDef?,
	-- A thrown or spat attack: the telegraph ends with something leaving the
	-- enemy, and the hit lands where it arrives rather than where the enemy is
	-- aiming. Sidestepping after the throw works, which is what makes a
	-- ranged enemy worth respecting instead of a damage tick at range.
	projectile: ProjectileDef?,
	-- A player's hit can't interrupt this windup. Heavy attacks carry it, so
	-- the answer to them is a parry, a block or a dodge — never just hitting
	-- first. Light attacks don't, so attacking into them is a real option.
	hyperArmor: boolean?,
}

-- `speed` is studs per second in flight; `radius` how far from where it lands
-- the hit reaches. A projectile is aimed at where its target stood when it was
-- launched, so its travel time is the window to move.
export type ProjectileDef = {
	speed: number,
	radius: number,
	-- Picks the look: "acid" or "bone". ProjectileVFX owns what each means.
	kind: string,
}

export type EnemyDef = {
	displayName: string,
	maxHealth: number,
	-- Idle beat between finishing one action and choosing the next.
	attackInterval: number,
	-- Distance the enemy tries to hold. Above it they close, below it they
	-- back off — which is what makes a ranged type kite without special-casing.
	preferredRange: number,
	-- Studs per second. Zero means stationary.
	moveSpeed: number,
	-- Beyond this the enemy ignores the player entirely.
	aggroRange: number,
	-- Paid by CurrencyService to whoever lands the killing blow. Only tougher
	-- enemies pay crystals, which is what keeps trash-mob grinding away from
	-- the top blacksmith tiers (DESIGN.md).
	coinReward: number,
	crystalReward: number,
	-- Paid to everyone who helped, not just the killer: XP is the progress
	-- that is yours rather than your weapon's, and a party shouldn't be
	-- racing each other for last hits (ProgressionDefs).
	xpReward: number,
	-- How this enemy carries itself, added to every tell it throws
	-- (AttackChoreography.Accent). Never touches the joints an archetype is
	-- identified by, so it changes who is swinging without changing which
	-- answer the swing asks for.
	--
	-- This is what stops a skeleton and a zombie reading as the same fighter
	-- wearing different skins: the four tells are a shared grammar on purpose,
	-- and without an accent a shared grammar is all there is.
	--
	-- A plain pose table rather than the exported type, so this module keeps
	-- requiring nothing. The spec checks it.
	accent: { [string]: { [string]: number } }?,
	attacks: { [string]: AttackDef },
}

local EnemyDefs: { [string]: EnemyDef } = {
	-- Stationary. The one enemy that never moves, so parry timing can be
	-- measured without chasing anything.
	TrainingDummy = {
		displayName = "Training Dummy",
		maxHealth = 100,
		attackInterval = 1.0,
		preferredRange = 0,
		moveSpeed = 0,
		aggroRange = 60,
		coinReward = 10,
		crystalReward = 0,
		xpReward = 12,
		attacks = {
			Overhead = {
				archetype = "Raise",
				leadTime = 0.33,
				telegraphDuration = 0.45,
				parryable = true,
				damage = 15,
				range = 10,
				arcDegrees = 120,
				minRange = 0,
				maxRange = 10,
				weight = 3,
				cooldown = 0,
			},
			-- A second parryable one, so the dummy can demonstrate a chain as
			-- well as a single swing. The slowest pair in the game: this is
			-- where the language is meant to be learned.
			Swipe = {
				archetype = "WindBack",
				leadTime = 0.36,
				telegraphDuration = 0.48,
				parryable = true,
				damage = 12,
				range = 10,
				arcDegrees = 130,
				minRange = 0,
				maxRange = 10,
				weight = 3,
				cooldown = 0,
			},
			-- Deliberately unparryable: the player has to move out of it.
			GroundSlam = {
				hyperArmor = true,
				archetype = "Plant",
				leadTime = 0.52,
				telegraphDuration = 0.64,
				parryable = false,
				damage = 20,
				range = 14,
				arcDegrees = 360,
				minRange = 0,
				maxRange = 14,
				weight = 1,
				cooldown = 6,
			},
		},
	},

	-- The tough one, and the only crystal source. A quick parryable Slash, and
	-- an unparryable GroundSlam whose hit volume (14) is wider than the range
	-- it's used from (10) — so escaping it means backing well off, and failing
	-- to leaves a bleed.
	SkeletonWarrior = {
		displayName = "Skeleton Warrior",
		maxHealth = 80,
		attackInterval = 1.0,
		preferredRange = 6,
		moveSpeed = 6,
		aggroRange = 40,
		coinReward = 25,
		crystalReward = 1,
		xpReward = 45,
		-- Upright, square, economical. A trained swordsman spends no motion it
		-- does not need, so its accent is the smallest in the game -- and that
		-- restraint is itself the read, against the Shambler next to it.
		accent = {
			Head = { rx = -6 },
			LowerTorso = { rx = -4 },
			RightUpperLeg = { rx = 4, rz = -3 },
			LeftUpperLeg = { rx = 4, rz = 3 },
		},
		attacks = {
			-- Leads with a thrust. A disciplined swordsman squaring up and
			-- driving forward is a different silhouette from the Shambler's
			-- wide swipe, which is the point: the opener alone should say
			-- which enemy you are fighting.
			Thrust = {
				archetype = "Coil",
				leadTime = 0.29,
				telegraphDuration = 0.41,
				parryable = true,
				damage = 14,
				range = 9,
				arcDegrees = 60,
				minRange = 0,
				maxRange = 9,
				weight = 4,
				cooldown = 0,
			},
			Slash = {
				archetype = "WindBack",
				leadTime = 0.27,
				telegraphDuration = 0.39,
				parryable = true,
				damage = 12,
				range = 8,
				arcDegrees = 110,
				minRange = 0,
				maxRange = 8,
				weight = 3,
				cooldown = 0,
			},
			-- The heavy one in the rotation. Slowest of its parryable three,
			-- and still inside the band that keeps this enemy on one rhythm.
			Overhead = {
				archetype = "Raise",
				leadTime = 0.31,
				telegraphDuration = 0.43,
				parryable = true,
				damage = 18,
				range = 8,
				arcDegrees = 90,
				minRange = 0,
				maxRange = 8,
				weight = 2,
				cooldown = 2.5,
			},
			GroundSlam = {
				hyperArmor = true,
				archetype = "Plant",
				leadTime = 0.40,
				telegraphDuration = 0.52,
				parryable = false,
				damage = 25,
				range = 14,
				arcDegrees = 360,
				minRange = 0,
				maxRange = 10,
				weight = 1,
				cooldown = 5,
				dot = { tickDamage = 5, tickInterval = 1, ticks = 3 },
			},
		},
	},

	-- Aggressive melee. Closes to touching range and pressures with a fast
	-- parryable swing, punishing players who only ever back away.
	Shambler = {
		displayName = "Shambler",
		maxHealth = 70,
		attackInterval = 0.6,
		preferredRange = 6,
		moveSpeed = 9,
		aggroRange = 70,
		coinReward = 15,
		crystalReward = 0,
		xpReward = 20,
		-- Hunched, head thrown forward, knees never straight. Everything it does
		-- arrives from lower down and further out than a skeleton doing the same
		-- thing, which is the whole point of an accent.
		accent = {
			-- Lopsided on purpose. The Spitter also carries itself low, so a
			-- symmetric hunch made the two read as the same animal at
			-- different sizes; this one drags a side, and that asymmetry is
			-- what tells them apart at a glance.
			Head = { rx = 16, ry = -14 },
			LowerTorso = { rx = 10, ry = 9, py = -0.12 },
			RightUpperLeg = { rx = -16, rz = 11 },
			LeftUpperLeg = { rx = -5, rz = -3 },
			RightLowerLeg = { rx = 24 },
			LeftLowerLeg = { rx = 8 },
		},
		attacks = {
			Claw = {
				archetype = "WindBack",
				leadTime = 0.33,
				telegraphDuration = 0.45,
				parryable = true,
				damage = 10,
				range = 9,
				arcDegrees = 100,
				minRange = 0,
				maxRange = 9,
				weight = 4,
				cooldown = 0,
			},
			-- The other half of the flurry, and what makes this thing read as
			-- relentless rather than as one swing on repeat. Shares Claw's
			-- band so the two can run into each other.
			Backhand = {
				archetype = "Raise",
				leadTime = 0.34,
				telegraphDuration = 0.46,
				parryable = true,
				damage = 12,
				range = 9,
				arcDegrees = 110,
				minRange = 0,
				maxRange = 9,
				weight = 3,
				cooldown = 0,
			},
			-- Unparryable, and in the melee band, so a flurry can end on
			-- something that has to be dodged rather than always resolving
			-- into another parry.
			Maul = {
				hyperArmor = true,
				archetype = "Plant",
				leadTime = 0.45,
				telegraphDuration = 0.57,
				parryable = false,
				damage = 18,
				range = 11,
				arcDegrees = 360,
				minRange = 0,
				maxRange = 11,
				weight = 1,
				cooldown = 6,
			},
			-- A long reach: only legal from range, so it reads as a lunge
			-- rather than another melee swing. The Shambler doesn't move while
			-- winding up, so maxRange must not exceed range — a lunge started
			-- beyond its reach could only ever miss.
			-- Deliberately not hyper-armoured, unlike Maul. Parrying staggers an
			-- enemy whatever its armour, so the flag only decides whether the
			-- player may *trade* with the attack instead of answering it
			-- cleanly. Maul is the Shambler's one committed move and keeps it;
			-- giving it to the Lunge as well left Lunge->Maul with no way in at
			-- any point, which is a cutscene rather than a flurry.
			Lunge = {
				archetype = "Coil",
				leadTime = 0.36,
				telegraphDuration = 0.48,
				parryable = true,
				damage = 16,
				range = 18,
				arcDegrees = 60,
				minRange = 9,
				maxRange = 18,
				weight = 3,
				cooldown = 4,
			},
		},
	},

	-- Ranged. Its preferredRange sits outside its own point-blank option, so
	-- the shared movement rule makes it kite without any kiting-specific code.
	Spitter = {
		displayName = "Spitter",
		maxHealth = 45,
		attackInterval = 1.2,
		preferredRange = 16,
		moveSpeed = 7,
		aggroRange = 80,
		coinReward = 15,
		crystalReward = 0,
		xpReward = 22,
		-- Squat and coiled, head carried low. It reads as something that spits
		-- rather than swings even when it is wearing the same tell as a
		-- swordsman.
		accent = {
			-- Deeply squat and square, against the Shambler's lopsided hunch.
			-- The hip drop is the one the leg bend actually implies
			-- (AnimationDefs' crouch: -LEG_LENGTH * (1 - cos)), so it sits low
			-- without its feet leaving the floor.
			Head = { rx = 26 },
			LowerTorso = { rx = 24, py = -0.34 },
			RightUpperLeg = { rx = -34, rz = 20 },
			LeftUpperLeg = { rx = -34, rz = -20 },
			RightLowerLeg = { rx = 44 },
			LeftLowerLeg = { rx = 44 },
		},
		attacks = {
			-- Lobbed high rather than spat flat, and the thing it opens with.
			-- Both are projectiles from the same band, so the pair can run
			-- together — and an overhead wind-up at range reads as a different
			-- animal from the melee enemies' swings.
			Lob = {
				archetype = "Raise",
				leadTime = 0.37,
				telegraphDuration = 0.49,
				parryable = true,
				damage = 14,
				range = 28,
				arcDegrees = 30,
				minRange = 10,
				maxRange = 26,
				weight = 4,
				cooldown = 2,
				projectile = { speed = 42, radius = 8, kind = "acid" },
			},
			Spit = {
				archetype = "Coil",
				leadTime = 0.38,
				telegraphDuration = 0.50,
				parryable = true,
				damage = 12,
				range = 28,
				arcDegrees = 25,
				minRange = 8,
				maxRange = 26,
				weight = 4,
				cooldown = 1.5,
				-- Slow enough to walk out of at range, which is the whole
				-- point of a spitter you can see winding up.
				projectile = { speed = 55, radius = 7, kind = "acid" },
			},
			-- Unparryable panic option when something is in its face, so
			-- closing the gap isn't a free win.
			Spray = {
				hyperArmor = true,
				archetype = "Plant",
				leadTime = 0.50,
				telegraphDuration = 0.62,
				parryable = false,
				damage = 8,
				range = 12,
				arcDegrees = 360,
				minRange = 0,
				maxRange = 8,
				weight = 5,
				cooldown = 5,
			},
		},
	},

	-- The dungeon boss, and the only enemy in the boss room. Group content:
	-- health is tuned for a party, and every tool the game teaches comes back
	-- at once. A fast parryable Cleave, a slow Overhead that hits hardest and
	-- staggers longest when parried, a Shockwave you must run from that leaves
	-- a bleed, and a BoneSpear so backing off to heal is never fully safe.
	-- The rig is 1.6x size (RigDefs), so its centre sits ~3 studs further back
	-- than a normal enemy's; ranges are measured centre to centre and
	-- allow for that.
	HollowKing = {
		displayName = "The Hollow King",
		maxHealth = 600,
		attackInterval = 0.8,
		preferredRange = 8,
		moveSpeed = 7,
		aggroRange = 90,
		coinReward = 250,
		crystalReward = 4,
		xpReward = 600,
		-- Chest up, chin down, weight back. Everything about him is held rather
		-- than thrown.
		accent = {
			-- Chest thrown up, chin down, weight settled onto the back leg and
			-- the stance wide. Where the skeleton is compact and forward, he
			-- is broad and rooted — the same tell arrives looking like it
			-- weighs three times as much.
			Head = { rx = -18 },
			LowerTorso = { rx = -12, py = 0.14 },
			RightUpperLeg = { rx = 14, rz = -14 },
			LeftUpperLeg = { rx = -8, rz = 14 },
			RightLowerLeg = { rx = -10 },
			LeftLowerLeg = { rx = 16 },
		},
		attacks = {
			Cleave = {
				archetype = "WindBack",
				leadTime = 0.30,
				telegraphDuration = 0.42,
				parryable = true,
				damage = 18,
				range = 13,
				arcDegrees = 150,
				minRange = 0,
				maxRange = 12,
				weight = 4,
				cooldown = 0,
			},
			Overhead = {
				hyperArmor = true,
				archetype = "Raise",
				leadTime = 0.38,
				telegraphDuration = 0.50,
				parryable = true,
				damage = 30,
				range = 12,
				arcDegrees = 70,
				minRange = 0,
				maxRange = 11,
				weight = 2,
				cooldown = 3,
			},
			Shockwave = {
				hyperArmor = true,
				archetype = "Plant",
				leadTime = 0.50,
				telegraphDuration = 0.62,
				parryable = false,
				damage = 26,
				range = 20,
				arcDegrees = 360,
				minRange = 0,
				maxRange = 14,
				weight = 2,
				cooldown = 8,
				dot = { tickDamage = 5, tickInterval = 1, ticks = 4 },
			},
			BoneSpear = {
				archetype = "Coil",
				leadTime = 0.36,
				telegraphDuration = 0.48,
				parryable = true,
				damage = 18,
				range = 34,
				arcDegrees = 18,
				minRange = 13,
				maxRange = 32,
				weight = 3,
				cooldown = 3.5,
				-- Faster and tighter than the Spitter's: a king's spear should
				-- be read and parried, not strolled away from.
				projectile = { speed = 95, radius = 5, kind = "bone" },
			},
		},
	},
}

return EnemyDefs
