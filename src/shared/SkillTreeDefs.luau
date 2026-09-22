--!strict
-- The skill trees: one per weapon, spent with the points levels pay out.
-- Pure — no Roblox API, so the rules are unit-tested and the client can draw
-- a tree without asking the server anything.
--
-- Keyed by weapon, not by class tag, for the same reason upgrade levels are:
-- your weapon is your class, and a tree per weapon is the shape that already
-- matches how EquipService stores things. Every weapon's points are its own,
-- so picking up the daggers after twenty levels of sword doesn't hand you a
-- filled-in dagger tree, and doesn't wipe the sword one either. You have as
-- many points to spend in each tree as your level grants.
--
-- Three branches per weapon, five tiers deep, and far more ranks than any
-- player will ever have points for. That last part is the whole design: a
-- tree you can fill is a list of chores, and a tree you cannot is a choice.
--
-- Nothing here reaches into combat. Every node's effects are numbers under
-- agreed keys, which the server adds up (`modifiers`) and combat reads. Adding
-- a node is a row in this file; adding a new *kind* of effect is a row in
-- EFFECTS plus wiring it at the one place in combat that uses it.

local SkillTreeDefs = {}

export type Effects = { [string]: number }

export type Node = {
	id: string,
	name: string,
	-- One line of flavour. The numbers are generated from `effects`, so they
	-- can never drift from what the node actually does.
	description: string,
	branch: string,
	-- Where the node sits when the tree is drawn: `tier` is its row (1 is the
	-- root), `column` its place across a nine-wide grid. Data rather than
	-- derived, because the layout is part of the design.
	tier: number,
	column: number,
	maxRank: number,
	requires: string?,
	-- An AbilityDefs id this node unlocks. Only the capstone of a branch has
	-- one, and the branch's position decides which key it lands on — so
	-- taking a branch to the end is how you get something new to press.
	ability: string?,
	-- Per rank.
	effects: Effects,
}

export type Tree = {
	weaponId: string,
	branches: { string },
	-- The one node with no prerequisite. Every branch hangs off it, so the
	-- first point spent in any tree is the same point.
	root: string,
	nodes: { Node },
}

-- nodeId -> ranks bought.
export type Allocation = { [string]: number }

export type SpendResult = {
	ok: boolean,
	-- "unknown_weapon", "unknown_node", "max_rank", "locked", "no_points"
	reason: string,
}

--[[ The effect vocabulary ]]

-- `kind` is only about how a number reads to a player:
--   flat      a count added on (+12 max health)
--   seconds   a duration added on (+0.02s)
--   percent   a fraction added on (+5%)
--   reduction a fraction taken off (-15%)
-- Every effect is additive across ranks and nodes. Nothing multiplies, so no
-- combination can run away.
export type EffectKind = "flat" | "seconds" | "percent" | "reduction"

-- `mechanic` marks an effect that changes what happens in a fight rather than
-- adding to a number the fight already had — a bleed, a counter-blow off a
-- block, a mark. Each class carries its own set of them (see the trees), and
-- the panel draws a node carrying one differently. The rules for each live in
-- TalentMath; CombatServer applies them.
export type EffectMeta = { label: string, kind: EffectKind, mechanic: boolean? }

local EFFECTS: { [string]: EffectMeta } = {
	maxHealth = { label = "Max health", kind = "flat" },
	maxPosture = { label = "Max posture", kind = "flat" },
	postureRegen = { label = "Posture recovery", kind = "flat" },
	damage = { label = "Damage", kind = "percent" },
	parryWindow = { label = "Parry window", kind = "seconds" },
	parryRestore = { label = "Posture restored on parry", kind = "flat" },
	riposte = { label = "Riposte damage", kind = "percent" },
	criticalCooldown = { label = "Critical cooldown", kind = "reduction" },
	criticalDamage = { label = "Critical damage", kind = "percent" },
	dodgeCooldown = { label = "Dodge cooldown", kind = "reduction" },
	dodgeIframes = { label = "Dodge invulnerability", kind = "seconds" },
	moveSpeed = { label = "Movement speed", kind = "percent" },
	backstab = { label = "Damage from behind", kind = "percent" },
	healPower = { label = "Healing", kind = "percent" },
	abilityCooldown = { label = "Ability cooldown", kind = "reduction" },
	abilityPower = { label = "Ability power", kind = "percent" },

	-- Mechanics. Worded so the line explains the rule, not just the number:
	-- "+50% of a blocked hit struck back at the attacker" has to be enough to
	-- understand a node the player has never seen work.
	blockReflect = { label = "of a blocked hit struck back at the attacker", kind = "percent", mechanic = true },
	parryWard = { label = "Ward after a parry (35% less damage, guard holds)", kind = "seconds", mechanic = true },
	finisherStagger = { label = "Stagger from the last hit of a combo", kind = "seconds", mechanic = true },
	execute = { label = "Damage to enemies below 35% health", kind = "percent", mechanic = true },
	dodgeStrike = { label = "Damage on the first hit within 1.5s of a dodge", kind = "percent", mechanic = true },
	bleed = { label = "of each hit bled out again over 3s", kind = "percent", mechanic = true },
	healWard = { label = "Ward on everyone you heal (25% less damage)", kind = "seconds", mechanic = true },
	guardAura = { label = "health a second to you and allies nearby while guarding", kind = "flat", mechanic = true },
	healOnHit = { label = "health to you and allies nearby per hit", kind = "flat", mechanic = true },
	lifesteal = { label = "of damage dealt healed back", kind = "percent", mechanic = true },
	lowHealthDamage = { label = "Damage, scaling up as your health runs out", kind = "percent", mechanic = true },
	frenzy = { label = "Damage per hit landed in a row (up to 5)", kind = "percent", mechanic = true },
	precisionStagger = { label = "Stagger from a split-second parry", kind = "seconds", mechanic = true },
	riposteChain = { label = "added to the riposte by every riposte hit", kind = "seconds", mechanic = true },
	pierce = { label = "of a hit carried into the enemy behind", kind = "percent", mechanic = true },
	markOnCrit = { label = "Damage taken by an enemy your critical marks (6s)", kind = "percent", mechanic = true },
	multishot = { label = "of each shot loosed at a second enemy", kind = "percent", mechanic = true },
	dodgeReload = { label = "off the critical's cooldown per dodge", kind = "seconds", mechanic = true },
	chainArc = { label = "of each hit arcing on to two enemies nearby", kind = "percent", mechanic = true },
	manaShield = { label = "of unblocked damage taken on posture instead", kind = "percent", mechanic = true },
	killHeal = { label = "health to you and allies nearby per kill", kind = "flat", mechanic = true },
}

SkillTreeDefs.EFFECTS = EFFECTS

--[[ The trees ]]

-- Every tree is the same shape, and it is a shape rather than three lists:
-- one root, three branches off it, each branch forking into a pair, each pair
-- leading on: one side through a mastery to the capstone (the branch's
-- ability, always its deepest node), the other to the branch's mechanic. The
-- mastery deepens that same mechanic, so it can be reached either way. Drawn
-- out, that is a tree — which is what was asked for, and also
-- what makes the choices legible. Three parallel columns would have been the
-- same rules and none of the meaning.
--
-- The mechanics are where the classes stop being the same fighter with
-- different numbers: every class has three, one per branch, and no two
-- classes share one (tested). A Tank's guard hits back; an Assassin's cuts
-- keep bleeding; a Ranger's critical marks prey for the whole party.
--
-- `column` is the node's place across a nine-wide grid and `tier` its row.
-- They are data rather than something the panel derives, because the layout
-- *is* the design: which nodes sit beside each other is how a player reads
-- what they are choosing between.
local function node(
	id: string,
	name: string,
	description: string,
	branch: string,
	tier: number,
	column: number,
	maxRank: number,
	requires: string?,
	effects: Effects,
	ability: string?
): Node
	return {
		id = id,
		name = name,
		description = description,
		branch = branch,
		tier = tier,
		column = column,
		maxRank = maxRank,
		requires = requires,
		ability = ability,
		effects = effects,
	}
end

-- The columns each part of the shape sits in. Named rather than written as
-- numbers at twelve call sites, so the shape can be re-proportioned in one
-- place.
local ROOT_COLUMN = 4
local HEADS = { 1, 4, 7 }
local LEFT = { 0, 3, 6 }
local RIGHT = { 2, 5, 8 }

-- The Tank holds ground: the deepest health and posture in the game, the
-- widest parry, and slow heavy payoff rather than speed.
local SWORD: Tree = {
	weaponId = "SwordAndShield",
	branches = { "Bulwark", "Warden", "Onslaught" },
	root = "oathbound",
	nodes = {
		node("oathbound", "Oathbound", "The weight you agreed to carry.", "Bulwark", 1, ROOT_COLUMN, 2, nil, {
			maxHealth = 10,
		}),

		node("iron_frame", "Iron Frame", "Weight you learn to carry.", "Bulwark", 2, HEADS[1], 3, "oathbound", {
			maxHealth = 12,
		}),
		node("deep_stance", "Deep Stance", "Rooted, not braced.", "Bulwark", 3, LEFT[1], 3, "iron_frame", {
			maxPosture = 8,
		}),
		node("second_wind", "Second Wind", "The breath between blows.", "Bulwark", 3, RIGHT[1], 2, "iron_frame", {
			postureRegen = 6,
		}),
		node("unbroken", "Unbroken", "They break first.", "Bulwark", 5, HEADS[1], 1, "bulwark_eternal", { maxHealth = 40 }, "LastStand"),

		node("read_the_blade", "Read the Blade", "Watch the shoulder, not the edge.", "Warden", 2, HEADS[2], 3, "oathbound", {
			parryWindow = 0.02,
		}),
		node("recovery", "Recovery", "A turned blade costs you nothing.", "Warden", 3, LEFT[2], 3, "read_the_blade", {
			parryRestore = 6,
		}),
		node("shield_wall", "Shield Wall", "A wall that walks.", "Warden", 3, RIGHT[2], 2, "read_the_blade", {
			maxPosture = 10,
		}),
		node("perfect_guard", "Perfect Guard", "Late is still in time.", "Warden", 5, HEADS[2], 1, "unyielding", {
			parryWindow = 0.03,
		}, "ShieldBreak"),

		node("heavy_hands", "Heavy Hands", "Put your weight through it.", "Onslaught", 2, HEADS[3], 3, "oathbound", {
			damage = 0.05,
		}),
		node("counterstrike", "Counterstrike", "Their opening, your blade.", "Onslaught", 3, LEFT[3], 2, "heavy_hands", {
			riposte = 0.25,
		}),
		node("break_their_line", "Break Their Line", "Shove, and shove again.", "Onslaught", 3, RIGHT[3], 2, "heavy_hands", {
			abilityCooldown = 0.12,
		}),
		node("sunder", "Sunder", "Through the guard and the arm behind it.", "Onslaught", 5, HEADS[3], 1, "juggernaut", {
			criticalDamage = 0.25,
		}, "Breach"),

		-- The Tank's mechanics: a guard that hits back, a parry that holds the
		-- line behind it, and a combo that ends with the enemy on its heels.
		node("retribution", "Retribution", "The shield is also a weapon.", "Bulwark", 4, RIGHT[1], 2, "second_wind", {
			blockReflect = 0.4,
		}),
		node("bulwark_eternal", "Bulwark Eternal", "Every blow you stop, returned.", "Bulwark", 4, HEADS[1], 1, "deep_stance", {
			blockReflect = 0.4,
			maxHealth = 20,
		}),
		node("bastion", "Bastion", "Turn one blow and the next finds iron.", "Warden", 4, RIGHT[2], 2, "shield_wall", {
			parryWard = 1.25,
		}),
		node("unyielding", "Unyielding", "The wall does not step back.", "Warden", 4, HEADS[2], 1, "recovery", {
			parryWard = 1.5,
			parryRestore = 6,
		}),
		node("shield_slam", "Shield Slam", "End it with the rim.", "Onslaught", 4, RIGHT[3], 2, "break_their_line", {
			finisherStagger = 0.35,
		}),
		node("juggernaut", "Juggernaut", "They are still falling when you arrive.", "Onslaught", 4, HEADS[3], 1, "counterstrike", {
			finisherStagger = 0.4,
			damage = 0.06,
		}),
	},
}

-- The Assassin is the only class that cares where it is standing. The
-- backstab DESIGN.md has promised since step 2 sits at the end of a branch
-- that costs most of a tree to reach — and Shadowstep, the dagger ability,
-- is what gets you there mid-fight.
local DAGGERS: Tree = {
	weaponId = "Daggers",
	branches = { "Shadow", "Reflex", "Edge" },
	root = "lightfoot",
	nodes = {
		node("lightfoot", "Lightfoot", "Nothing announces you.", "Shadow", 1, ROOT_COLUMN, 2, nil, { moveSpeed = 0.03 }),

		node("opening", "Opening", "Wait for the turn.", "Shadow", 2, HEADS[1], 3, "lightfoot", { backstab = 0.10 }),
		node("vital_point", "Vital Point", "Where the armour isn't.", "Shadow", 3, LEFT[1], 2, "opening", {
			criticalDamage = 0.20,
		}),
		node("longer_shadow", "Longer Shadow", "It reaches further than it should.", "Shadow", 3, RIGHT[1], 2, "opening", {
			abilityPower = 0.15,
		}),
		node("assassinate", "Assassinate", "They never see the second one.", "Shadow", 5, HEADS[1], 1, "deathmark", {
			backstab = 0.35,
		}, "Shadowstep"),

		node("quickstep", "Quickstep", "Move again sooner.", "Reflex", 2, HEADS[2], 3, "lightfoot", {
			dodgeCooldown = 0.10,
		}),
		node("afterimage", "Afterimage", "Gone before it lands.", "Reflex", 3, LEFT[2], 2, "quickstep", {
			dodgeIframes = 0.05,
		}),
		node("flow", "Flow", "Reading it is the same as moving.", "Reflex", 3, RIGHT[2], 2, "quickstep", {
			parryWindow = 0.02,
		}),
		node("untouchable", "Untouchable", "Air where you were.", "Reflex", 5, HEADS[2], 1, "phantom", {
			dodgeIframes = 0.08,
		}, "Evasion"),

		node("keen", "Keen", "Sharpened past sensible.", "Edge", 2, HEADS[3], 3, "lightfoot", { damage = 0.05 }),
		node("bloodletting", "Bloodletting", "Punish the parry.", "Edge", 3, LEFT[3], 2, "keen", { riposte = 0.25 }),
		node("no_wasted_motion", "No Wasted Motion", "Step, strike, step.", "Edge", 3, RIGHT[3], 2, "keen", {
			abilityCooldown = 0.15,
		}),
		node("thousand_cuts", "Thousand Cuts", "None of them large.", "Edge", 5, HEADS[3], 1, "exsanguinate", {
			damage = 0.12,
		}, "Flurry"),

		-- The Assassin's mechanics: finishing what is already hurt, striking
		-- out of a dodge, and wounds that keep working after you have gone.
		node("coup_de_grace", "Coup de Grâce", "Weak is the same as finished.", "Shadow", 4, RIGHT[1], 2, "longer_shadow", {
			execute = 0.25,
		}),
		node("deathmark", "Deathmark", "Already dead; only slow to notice.", "Shadow", 4, HEADS[1], 1, "vital_point", {
			execute = 0.3,
			backstab = 0.1,
		}),
		node("ambush", "Ambush", "Out of nowhere, into the ribs.", "Reflex", 4, RIGHT[2], 2, "flow", {
			dodgeStrike = 0.25,
		}),
		node("phantom", "Phantom", "The blow arrives before you do.", "Reflex", 4, HEADS[2], 1, "afterimage", {
			dodgeStrike = 0.3,
			dodgeCooldown = 0.08,
		}),
		node("hemorrhage", "Hemorrhage", "Small cuts, deep enough.", "Edge", 4, RIGHT[3], 3, "no_wasted_motion", {
			bleed = 0.15,
		}),
		node("exsanguinate", "Exsanguinate", "Walk away. It keeps working.", "Edge", 4, HEADS[3], 1, "bloodletting", {
			bleed = 0.25,
		}),
	},
}

-- The Healer's tree is the one that makes a party want one. The parry heal
-- rewards playing well; Mending Pulse, the staff ability, is what rescues a
-- party that didn't. Mercy improves both.
local STAFF: Tree = {
	weaponId = "Staff",
	branches = { "Mercy", "Ward", "Arcana" },
	root = "devotion",
	nodes = {
		node("devotion", "Devotion", "You meant it when you said it.", "Mercy", 1, ROOT_COLUMN, 2, nil, {
			healPower = 0.08,
		}),

		node("kind_hand", "Kind Hand", "It reaches further than it looks.", "Mercy", 2, HEADS[1], 3, "devotion", {
			healPower = 0.12,
		}),
		node("wellspring", "Wellspring", "Turning a blade steadies you too.", "Mercy", 3, LEFT[1], 2, "kind_hand", {
			parryRestore = 8,
		}),
		node("wider_light", "Wider Light", "Let it reach the back rank.", "Mercy", 3, RIGHT[1], 2, "kind_hand", {
			abilityPower = 0.20,
		}),
		node("benediction", "Benediction", "Whole, in one word.", "Mercy", 5, HEADS[1], 1, "saints_mantle", {
			healPower = 0.30,
		}, "MendingPulse"),

		node("aegis", "Aegis", "A held breath, made solid.", "Ward", 2, HEADS[2], 3, "devotion", { maxPosture = 10 }),
		node("mending", "Mending", "Old wounds close cleaner.", "Ward", 3, LEFT[2], 3, "aegis", { maxHealth = 12 }),
		node("foresight", "Foresight", "You saw it coming yesterday.", "Ward", 3, RIGHT[2], 2, "aegis", {
			parryWindow = 0.025,
		}),
		node("sanctified", "Sanctified", "Nothing lands on holy ground.", "Ward", 5, HEADS[2], 1, "hallowed_ground", {
			postureRegen = 5,
		}, "SanctifiedWard"),

		node("focus", "Focus", "The staff is not a stick.", "Arcana", 2, HEADS[3], 3, "devotion", { damage = 0.05 }),
		node("surge", "Surge", "Again, and sooner.", "Arcana", 3, LEFT[3], 2, "focus", { criticalCooldown = 0.15 }),
		node("quickened", "Quickened", "The light comes back faster.", "Arcana", 3, RIGHT[3], 2, "focus", {
			abilityCooldown = 0.15,
		}),
		node("channel", "Channel", "Everything, into one arc.", "Arcana", 5, HEADS[3], 1, "dawnbreaker", {
			criticalDamage = 0.20,
		}, "ArcaneNova"),

		-- The Healer's mechanics: heals that shield, a guard that mends the
		-- people behind it, and a staff that heals with every blow.
		node("blessed_ward", "Blessed Ward", "What you mend, you also cover.", "Mercy", 4, RIGHT[1], 2, "wider_light", {
			healWard = 1.0,
		}),
		node("saints_mantle", "Saint's Mantle", "Held up, and held safe.", "Mercy", 4, HEADS[1], 1, "wellspring", {
			healWard = 1.5,
			healPower = 0.1,
		}),
		node("sanctuary", "Sanctuary", "Stand behind me.", "Ward", 4, RIGHT[2], 2, "foresight", {
			guardAura = 2,
		}),
		node("hallowed_ground", "Hallowed Ground", "Where you plant your feet, wounds close.", "Ward", 4, HEADS[2], 1, "mending", {
			guardAura = 3,
			maxPosture = 10,
		}),
		node("radiant_strikes", "Radiant Strikes", "Every blow a small blessing.", "Arcana", 4, RIGHT[3], 2, "quickened", {
			healOnHit = 1.5,
		}),
		node("dawnbreaker", "Dawnbreaker", "Light, delivered bluntly.", "Arcana", 4, HEADS[3], 1, "surge", {
			healOnHit = 2,
			damage = 0.05,
		}),
	},
}

-- The Berserker spends everything on the swing. Its tree is the only one with
-- no parry-window node anywhere in it: a Berserker that wants to survive buys
-- health and hide, not better defence, because the class is meant to be the
-- one that trades.
local GREATAXE: Tree = {
	weaponId = "Greataxe",
	branches = { "Fury", "Hide", "Ruin" },
	root = "unspent_rage",
	nodes = {
		node("unspent_rage", "Unspent Rage", "It has to go somewhere.", "Fury", 1, ROOT_COLUMN, 2, nil, {
			damage = 0.04,
		}),

		node("momentum", "Momentum", "The axe wants to keep going.", "Fury", 2, HEADS[1], 3, "unspent_rage", {
			damage = 0.05,
		}),
		node("swing_through", "Swing Through", "Not at them. Past them.", "Fury", 3, LEFT[1], 3, "momentum", {
			damage = 0.05,
		}),
		node("red_mist", "Red Mist", "Stop counting them.", "Fury", 3, RIGHT[1], 2, "momentum", {
			abilityPower = 0.12,
		}),
		node("bloodlust", "Bloodlust", "Nothing left to decide.", "Fury", 5, HEADS[1], 1, "gorge", {
			damage = 0.12,
		}, "Bloodlust"),

		node("thick_skin", "Thick Skin", "Most of it does not reach.", "Hide", 2, HEADS[2], 3, "unspent_rage", {
			maxHealth = 14,
		}),
		node("stubborn", "Stubborn", "Falling over is a decision.", "Hide", 3, LEFT[2], 3, "thick_skin", {
			maxHealth = 16,
		}),
		node("second_breath", "Second Breath", "There is always one more.", "Hide", 3, RIGHT[2], 2, "thick_skin", {
			postureRegen = 5,
		}),
		node("ironhide", "Ironhide", "Feel it later.", "Hide", 5, HEADS[2], 1, "deathless_rage", {
			maxHealth = 36,
		}, "Ironhide"),

		node("cleave", "Cleave", "One swing, several answers.", "Ruin", 2, HEADS[3], 3, "unspent_rage", {
			criticalDamage = 0.08,
		}),
		node("follow_through", "Follow Through", "The second one is free.", "Ruin", 3, LEFT[3], 2, "cleave", {
			riposte = 0.3,
		}),
		node("shorter_wind", "Shorter Wind", "Less winding, more up.", "Ruin", 3, RIGHT[3], 2, "cleave", {
			criticalCooldown = 0.12,
		}),
		node("earthsplitter", "Earthsplitter", "Take the floor from them.", "Ruin", 5, HEADS[3], 1, "unstoppable", {
			criticalDamage = 0.3,
		}, "Earthsplitter"),

		-- The Berserker's mechanics: drinking the fight, getting worse the
		-- closer it is to dying, and a rhythm that builds as long as it lands.
		node("bloodthirst", "Bloodthirst", "Take it back from them.", "Fury", 4, RIGHT[1], 3, "red_mist", {
			lifesteal = 0.05,
		}),
		node("gorge", "Gorge", "Never full.", "Fury", 4, HEADS[1], 1, "swing_through", {
			lifesteal = 0.08,
		}),
		node("berserk", "Berserk", "Pain is just more to spend.", "Hide", 4, RIGHT[2], 2, "second_breath", {
			lowHealthDamage = 0.2,
		}),
		node("deathless_rage", "Deathless Rage", "Too angry to fall.", "Hide", 4, HEADS[2], 1, "stubborn", {
			lowHealthDamage = 0.3,
			maxHealth = 20,
		}),
		node("rampage", "Rampage", "Each one easier than the last.", "Ruin", 4, RIGHT[3], 2, "shorter_wind", {
			frenzy = 0.03,
		}),
		node("unstoppable", "Unstoppable", "Nothing between the axe and the end.", "Ruin", 4, HEADS[3], 1, "follow_through", {
			frenzy = 0.04,
			criticalDamage = 0.1,
		}),
	},
}

-- The Duelist's tree is the parry game written out. Two of its three branches
-- buy parry window or what a parry is worth, and the third buys the reach to
-- use what they bought. A Duelist who never parries has spent their whole tree
-- on nothing, which is the intended shape of the class.
local RAPIER: Tree = {
	weaponId = "Rapier",
	branches = { "Form", "Riposte", "Point" },
	root = "en_garde",
	nodes = {
		node("en_garde", "En Garde", "Everything begins from here.", "Form", 1, ROOT_COLUMN, 2, nil, {
			parryWindow = 0.015,
		}),

		node("footwork", "Footwork", "The feet decide it, not the blade.", "Form", 2, HEADS[1], 3, "en_garde", {
			moveSpeed = 0.03,
		}),
		node("measure", "Measure", "Know the distance to a finger's width.", "Form", 3, LEFT[1], 3, "footwork", {
			parryWindow = 0.02,
		}),
		node("recover", "Recover", "Back on guard before they know.", "Form", 3, RIGHT[1], 2, "footwork", {
			parryRestore = 7,
		}),
		node("perfect_form", "Perfect Form", "Nothing wasted, nothing hurried.", "Form", 5, HEADS[1], 1, "masterstroke", {
			parryWindow = 0.03,
		}, "PerfectForm"),

		node("parry_riposte", "Parry-Riposte", "One motion, not two.", "Riposte", 2, HEADS[2], 3, "en_garde", {
			riposte = 0.2,
		}),
		node("in_time", "In Time", "Answer inside their swing.", "Riposte", 3, LEFT[2], 3, "parry_riposte", {
			riposte = 0.22,
		}),
		node("counter_time", "Counter-Time", "Answer the answer.", "Riposte", 3, RIGHT[2], 2, "parry_riposte", {
			abilityPower = 0.12,
		}),
		node("lunge", "Lunge", "The whole body, behind the point.", "Riposte", 5, HEADS[2], 1, "endless_bout", {
			riposte = 0.35,
		}, "Lunge"),

		node("point_control", "Point Control", "It goes where you looked.", "Point", 2, HEADS[3], 3, "en_garde", {
			damage = 0.05,
		}),
		node("thrust", "Thrust", "Straight is shortest.", "Point", 3, LEFT[3], 2, "point_control", {
			criticalDamage = 0.2,
		}),
		node("quick_hand", "Quick Hand", "Faster than it looks.", "Point", 3, RIGHT[3], 2, "point_control", {
			criticalCooldown = 0.12,
		}),
		node("pierce", "Pierce", "Through, and out the other side.", "Point", 5, HEADS[3], 1, "impale", {
			damage = 0.14,
		}, "Pierce"),

		-- The Duelist's mechanics: rewarding the perfect parry over the good
		-- one, keeping a riposte going, and a point that goes through.
		node("split_second", "Split Second", "Not early. Not late. Now.", "Form", 4, RIGHT[1], 2, "recover", {
			precisionStagger = 0.4,
		}),
		node("masterstroke", "Masterstroke", "They will not forget the lesson.", "Form", 4, HEADS[1], 1, "measure", {
			precisionStagger = 0.5,
			parryWindow = 0.01,
		}),
		node("relentless", "Relentless", "The bout is not over.", "Riposte", 4, RIGHT[2], 2, "counter_time", {
			riposteChain = 0.4,
		}),
		node("endless_bout", "Endless Bout", "Every answer earns another.", "Riposte", 4, HEADS[2], 1, "in_time", {
			riposteChain = 0.5,
			riposte = 0.1,
		}),
		node("skewer", "Skewer", "One blade, two problems.", "Point", 4, RIGHT[3], 2, "quick_hand", {
			pierce = 0.4,
		}),
		node("impale", "Impale", "Line them up.", "Point", 4, HEADS[3], 1, "thrust", {
			pierce = 0.4,
			damage = 0.05,
		}),
	},
}

-- The Ranger's tree is about staying at range, and every branch is a different
-- answer to the same question: what happens when something reaches you. Hunt
-- kills it first, Quiver kills several, Flight leaves.
local BOW: Tree = {
	weaponId = "Bow",
	branches = { "Hunt", "Quiver", "Flight" },
	root = "steady_hand",
	nodes = {
		node("steady_hand", "Steady Hand", "The draw does not shake.", "Hunt", 1, ROOT_COLUMN, 2, nil, {
			damage = 0.04,
		}),

		node("sight", "Sight", "See it before it sees you.", "Hunt", 2, HEADS[1], 3, "steady_hand", {
			damage = 0.05,
		}),
		node("heavy_draw", "Heavy Draw", "Further back, further through.", "Hunt", 3, LEFT[1], 3, "sight", {
			damage = 0.06,
		}),
		node("patience", "Patience", "The shot arrives when it arrives.", "Hunt", 3, RIGHT[1], 2, "sight", {
			criticalDamage = 0.18,
		}),
		node("hunters_mark", "Hunter's Mark", "Chosen, and told so.", "Hunt", 5, HEADS[1], 1, "apex_predator", {
			criticalDamage = 0.25,
		}, "HuntersMark"),

		node("full_quiver", "Full Quiver", "Bring more than you need.", "Quiver", 2, HEADS[2], 3, "steady_hand", {
			abilityCooldown = 0.1,
		}),
		node("loose_fast", "Loose Fast", "Nocked before the last one lands.", "Quiver", 3, LEFT[2], 3, "full_quiver", {
			abilityPower = 0.12,
		}),
		node("broadheads", "Broadheads", "Wider, and it stays in.", "Quiver", 3, RIGHT[2], 2, "full_quiver", {
			damage = 0.06,
		}),
		node("volley", "Volley", "All of it, at once.", "Quiver", 5, HEADS[2], 1, "arrowstorm", {
			abilityPower = 0.22,
		}, "Volley"),

		node("light_step", "Light Step", "Never quite where they swing.", "Flight", 2, HEADS[3], 3, "steady_hand", {
			moveSpeed = 0.04,
		}),
		node("give_ground", "Give Ground", "Backwards is a direction.", "Flight", 3, LEFT[3], 2, "light_step", {
			dodgeCooldown = 0.12,
		}),
		node("unencumbered", "Unencumbered", "Carry nothing you will not loose.", "Flight", 3, RIGHT[3], 2, "light_step", {
			dodgeIframes = 0.04,
		}),
		node("disengage", "Disengage", "The fight was never here.", "Flight", 5, HEADS[3], 1, "windrunner", {
			moveSpeed = 0.06,
		}, "Disengage"),

		-- The Ranger's mechanics: marking prey for the whole party, a second
		-- arrow on every string, and a dodge that reloads the big shot.
		node("quarry", "Quarry", "That one. Everyone, that one.", "Hunt", 4, RIGHT[1], 2, "patience", {
			markOnCrit = 0.12,
		}),
		node("apex_predator", "Apex Predator", "Nothing marked walks away.", "Hunt", 4, HEADS[1], 1, "heavy_draw", {
			markOnCrit = 0.15,
			criticalDamage = 0.1,
		}),
		node("split_shot", "Split Shot", "Two arrows, one draw.", "Quiver", 4, RIGHT[2], 2, "broadheads", {
			multishot = 0.3,
		}),
		node("arrowstorm", "Arrowstorm", "The sky, briefly, is yours.", "Quiver", 4, HEADS[2], 1, "loose_fast", {
			multishot = 0.35,
			abilityPower = 0.1,
		}),
		node("nimble_reload", "Nimble Reload", "Nock it mid-roll.", "Flight", 4, RIGHT[3], 2, "unencumbered", {
			dodgeReload = 0.8,
		}),
		node("windrunner", "Windrunner", "Never still long enough to hit.", "Flight", 4, HEADS[3], 1, "give_ground", {
			dodgeReload = 1.0,
			moveSpeed = 0.04,
		}),
	},
}

-- The Mage's tree buys ability power where every other tree buys weapon
-- damage. That is the class: the Focus's own swings stay the weakest in the
-- game however far the tree is filled in, and everything a Mage is worth comes
-- out of the three things at the ends of it.
local FOCUS: Tree = {
	weaponId = "Focus",
	branches = { "Flame", "Veil", "Weave" },
	root = "kindling",
	nodes = {
		node("kindling", "Kindling", "Something to start from.", "Flame", 1, ROOT_COLUMN, 2, nil, {
			abilityPower = 0.06,
		}),

		node("draw_heat", "Draw Heat", "Take it out of the air.", "Flame", 2, HEADS[1], 3, "kindling", {
			abilityPower = 0.08,
		}),
		node("bank_it", "Bank It", "Hold it until it is worth spending.", "Flame", 3, LEFT[1], 3, "draw_heat", {
			abilityPower = 0.09,
		}),
		node("quick_light", "Quick Light", "Sooner, if smaller.", "Flame", 3, RIGHT[1], 2, "draw_heat", {
			abilityCooldown = 0.12,
		}),
		node("cinderburst", "Cinderburst", "All of it, outward.", "Flame", 5, HEADS[1], 1, "stormcaller", {
			abilityPower = 0.2,
		}, "Cinderburst"),

		node("thin_veil", "Thin Veil", "Not much between you and it.", "Veil", 2, HEADS[2], 3, "kindling", {
			maxPosture = 8,
		}),
		node("turn_aside", "Turn Aside", "It was going to miss anyway.", "Veil", 3, LEFT[2], 3, "thin_veil", {
			parryWindow = 0.02,
		}),
		node("borrowed_time", "Borrowed Time", "Pay it back later.", "Veil", 3, RIGHT[2], 2, "thin_veil", {
			maxHealth = 14,
		}),
		node("mirror_ward", "Mirror Ward", "Let it hit the other one.", "Veil", 5, HEADS[2], 1, "arcane_bulwark", {
			abilityPower = 0.18,
		}, "MirrorWard"),

		node("first_thread", "First Thread", "Find where it gives.", "Weave", 2, HEADS[3], 3, "kindling", {
			healPower = 0.08,
		}),
		node("steady_weave", "Steady Weave", "Slow, and it holds.", "Weave", 3, LEFT[3], 2, "first_thread", {
			healPower = 0.1,
		}),
		node("wide_weave", "Wide Weave", "Far enough to reach them.", "Weave", 3, RIGHT[3], 2, "first_thread", {
			abilityCooldown = 0.1,
		}),
		node("wellspring", "Wellspring", "It was under there the whole time.", "Weave", 5, HEADS[3], 1, "lifebloom", {
			healPower = 0.18,
		}, "Wellspring"),

		-- The Mage's mechanics: power that leaps between enemies, a shield
		-- paid for in posture, and life drawn out of every kill.
		node("chain_spark", "Chain Spark", "It does not stop at one.", "Flame", 4, RIGHT[1], 2, "quick_light", {
			chainArc = 0.25,
		}),
		node("stormcaller", "Stormcaller", "Everything nearby is a conductor.", "Flame", 4, HEADS[1], 1, "bank_it", {
			chainArc = 0.3,
			abilityPower = 0.08,
		}),
		node("mana_shield", "Mana Shield", "Pay in focus, not in blood.", "Veil", 4, RIGHT[2], 2, "borrowed_time", {
			manaShield = 0.15,
		}),
		node("arcane_bulwark", "Arcane Bulwark", "The veil thickens.", "Veil", 4, HEADS[2], 1, "turn_aside", {
			manaShield = 0.2,
			maxPosture = 10,
		}),
		node("soul_weave", "Soul Weave", "Nothing that dies is wasted.", "Weave", 4, RIGHT[3], 2, "wide_weave", {
			killHeal = 8,
		}),
		node("lifebloom", "Lifebloom", "Where they fall, something grows.", "Weave", 4, HEADS[3], 1, "steady_weave", {
			killHeal = 12,
			healPower = 0.08,
		}),
	},
}

local trees: { [string]: Tree } = {
	[SWORD.weaponId] = SWORD,
	[DAGGERS.weaponId] = DAGGERS,
	[STAFF.weaponId] = STAFF,
	[GREATAXE.weaponId] = GREATAXE,
	[RAPIER.weaponId] = RAPIER,
	[BOW.weaponId] = BOW,
	[FOCUS.weaponId] = FOCUS,
}

--[[ Reading a tree ]]

-- How wide the grid is. The panel divides its width by this rather than
-- assuming a number, so re-proportioning a tree doesn't need a UI change.
function SkillTreeDefs.columns(tree: Tree): number
	local widest = 0
	for _, entry in tree.nodes do
		widest = math.max(widest, entry.column)
	end
	return widest + 1
end

-- How many rows deep a tree goes, from its deepest node. The panel sizes
-- itself from this rather than assuming four.
function SkillTreeDefs.tiers(tree: Tree): number
	local deepest = 0
	for _, entry in tree.nodes do
		deepest = math.max(deepest, entry.tier)
	end
	return deepest
end

-- The tree for a weapon, or nil if that weapon has none. A weapon with no
-- tree can still be fought with; it just has nothing to spend points on.
function SkillTreeDefs.treeFor(weaponId: string): Tree?
	return trees[weaponId]
end

-- Every weapon that has a tree, sorted for a stable walk order.
function SkillTreeDefs.weaponIds(): { string }
	local ids = {}
	for weaponId in trees do
		table.insert(ids, weaponId)
	end
	table.sort(ids)
	return ids
end

-- One node by weapon and node id, or nil. Returns nil both when the weapon
-- has no tree and when the tree has no such node, which is what a stored
-- allocation naming a node that has since been renamed looks like.
function SkillTreeDefs.findNode(weaponId: string, nodeId: string): Node?
	local tree = trees[weaponId]
	if not tree then
		return nil
	end

	for _, entry in tree.nodes do
		if entry.id == nodeId then
			return entry
		end
	end
	return nil
end

-- Ranks bought in this tree. Counted against the tree's own nodes, so an
-- allocation carrying ids this server doesn't recognise — an older server
-- reading a newer save — can't inflate the total and lock a player out of
-- spending.
function SkillTreeDefs.spent(weaponId: string, allocation: Allocation): number
	local tree = trees[weaponId]
	if not tree then
		return 0
	end

	local total = 0
	for _, entry in tree.nodes do
		local ranks = allocation[entry.id]
		if type(ranks) == "number" then
			total += math.clamp(math.floor(ranks), 0, entry.maxRank)
		end
	end
	return total
end

-- Ranks actually in effect: floored, and never past the node's cap.
local function ranksOf(allocation: Allocation, entry: Node): number
	local ranks = allocation[entry.id]
	if type(ranks) ~= "number" or ranks ~= ranks then
		return 0
	end
	return math.clamp(math.floor(ranks), 0, entry.maxRank)
end

-- Whether a node's prerequisite is met. Tier 1 nodes are always open.
function SkillTreeDefs.isUnlocked(weaponId: string, allocation: Allocation, nodeId: string): boolean
	local entry = SkillTreeDefs.findNode(weaponId, nodeId)
	if not entry then
		return false
	end

	local required = entry.requires
	if not required then
		return true
	end

	local parent = SkillTreeDefs.findNode(weaponId, required)
	return parent ~= nil and ranksOf(allocation, parent) > 0
end

-- Whether one more rank may be bought. The server asks this before writing,
-- and the client asks it to grey buttons out; both get the same answer from
-- the same rules.
function SkillTreeDefs.canSpend(
	weaponId: string,
	allocation: Allocation,
	nodeId: string,
	availablePoints: number
): SpendResult
	if not trees[weaponId] then
		return { ok = false, reason = "unknown_weapon" }
	end

	local entry = SkillTreeDefs.findNode(weaponId, nodeId)
	if not entry then
		return { ok = false, reason = "unknown_node" }
	end

	if ranksOf(allocation, entry) >= entry.maxRank then
		return { ok = false, reason = "max_rank" }
	end

	if not SkillTreeDefs.isUnlocked(weaponId, allocation, nodeId) then
		return { ok = false, reason = "locked" }
	end

	if availablePoints - SkillTreeDefs.spent(weaponId, allocation) < 1 then
		return { ok = false, reason = "no_points" }
	end

	return { ok = true, reason = "ok" }
end

-- Whether a node carries a mechanic (EffectMeta.mechanic) rather than only
-- adding to numbers the fight already has.
function SkillTreeDefs.isMechanic(entry: Node): boolean
	for key in entry.effects do
		local meta = EFFECTS[key]
		if meta and meta.mechanic then
			return true
		end
	end
	return false
end

--[[ Abilities ]]

-- Which key an ability lands on: a branch's position in the tree. The first
-- branch's capstone is the first slot, and so on, so a player who knows the
-- tree knows what their keys do before they press one.
function SkillTreeDefs.slotOf(tree: Tree, branch: string): number?
	for index, name in tree.branches do
		if name == branch then
			return index
		end
	end
	return nil
end

-- slot -> AbilityDefs id, for everything this allocation has unlocked. A
-- capstone bought is a key that now does something.
function SkillTreeDefs.abilities(weaponId: string, allocation: Allocation?): { [number]: string }
	local unlocked: { [number]: string } = {}
	local tree = trees[weaponId]
	if not tree or not allocation then
		return unlocked
	end

	for _, entry in tree.nodes do
		local ability = entry.ability
		if ability and ranksOf(allocation, entry) > 0 then
			local slot = SkillTreeDefs.slotOf(tree, entry.branch)
			if slot then
				unlocked[slot] = ability
			end
		end
	end

	return unlocked
end

--[[ What it all adds up to ]]

export type Modifiers = { [string]: number }

-- Every effect key at zero: combat reads these straight, so a missing key
-- would mean a nil where a number is expected.
function SkillTreeDefs.noModifiers(): Modifiers
	local result: Modifiers = {}
	for key in SkillTreeDefs.EFFECTS do
		result[key] = 0
	end
	return result
end

-- What an allocation is worth. Unknown node ids are ignored rather than
-- rejected: a save written by a newer server may name nodes this one has
-- never heard of, and the rest of the tree still has to work.
function SkillTreeDefs.modifiers(weaponId: string, allocation: Allocation?): Modifiers
	local result = SkillTreeDefs.noModifiers()
	local tree = trees[weaponId]
	if not tree or not allocation then
		return result
	end

	for _, entry in tree.nodes do
		local ranks = ranksOf(allocation, entry)
		if ranks > 0 then
			for key, amount in entry.effects do
				if result[key] then
					result[key] += amount * ranks
				end
			end
		end
	end

	return result
end

--[[ Wording, so the UI never hard-codes a number ]]

local function signed(value: number, digits: number): string
	local rounded = string.format(`%.{digits}f`, math.abs(value))
	-- Trailing zeros read as false precision on a number like 0.20.
	if string.find(rounded, ".", 1, true) then
		rounded = string.gsub(rounded, "0+$", "")
		rounded = string.gsub(rounded, "%.$", "")
	end
	return (if value < 0 then "-" else "+") .. rounded
end

-- One line per effect, e.g. "+12 Max health" or "-15% Critical cooldown".
function SkillTreeDefs.describe(effects: Effects, ranks: number): { string }
	local lines = {}
	for key, amount in effects do
		local meta = SkillTreeDefs.EFFECTS[key]
		if meta then
			local total = amount * math.max(ranks, 1)
			local text
			if meta.kind == "percent" then
				text = `{signed(total * 100, 1)}% {meta.label}`
			elseif meta.kind == "reduction" then
				text = `-{string.format("%.0f", math.abs(total) * 100)}% {meta.label}`
			elseif meta.kind == "seconds" then
				text = `{signed(total, 3)}s {meta.label}`
			else
				text = `{signed(total, 0)} {meta.label}`
			end
			table.insert(lines, text)
		end
	end
	table.sort(lines)
	return lines
end

return SkillTreeDefs
