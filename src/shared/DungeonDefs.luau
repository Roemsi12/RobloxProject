--!strict
-- The rules a random dungeon is generated from. Pure data — no Roblox API.
--
-- DungeonLayout reads this to decide how many rooms there are, what each is
-- for, how big it is and who's in it; the server then builds that layout.
-- Changing a number here changes every dungeon from the next one generated,
-- with no code change.
--
-- A dungeon is a winding main path from the Start room to the Boss room,
-- always passing through one Elite room, one Ambush room and, right before
-- the boss, a Shrine. Treasure rooms hang off the main path as dead-end
-- branches, sometimes behind an extra fight.

export type RoomPurpose = "Start" | "Combat" | "Elite" | "Treasure" | "Shrine" | "Ambush" | "Boss"
export type SizeClass = "Small" | "Medium" | "Large" | "Huge"
-- The geometry inside a room's four walls (RoomTemplates).
export type RoomVariant = "Empty" | "Pillars" | "Ruins" | "Hall"

export type Range = { min: number, max: number }

export type PurposeDef = {
	displayName: string,
	-- Picked from at random.
	sizes: { SizeClass },
	variants: { RoomVariant },
	-- Enemies placed in the room, by size. A size missing here means none.
	enemyCount: { [SizeClass]: Range },
	-- Counts toward "rooms cleared", once every enemy in it is dead.
	clearable: boolean,
	-- A chest, unlocked once every enemy in the room is dead (at once if none).
	hasChest: boolean,
	-- Extra coins for whoever opens this room's chest.
	chestCoins: number,
	-- The room's torchlight colour, so a room's purpose reads from the door.
	torchColor: { number },
}

export type AmbushDef = {
	-- Enemies in each wave, in order. The next wave comes when the last dies.
	waves: { number },
	-- How far past the doorway a player must walk before the ambush springs.
	triggerDepth: number,
	-- From springing to the gates slamming shut: time for the rest of the party
	-- to get inside.
	sealDelay: number,
	-- Pause between one wave dying and the next arriving.
	waveDelay: number,
	-- If nobody alive is left inside for this long, the ambush gives up: the
	-- gates open and it resets, to spring again on the next attempt.
	resetAfter: number,
}

export type Reward = {
	coins: number,
	-- Of the class each player has equipped; none if unequipped.
	crystals: number,
}

local DungeonDefs = {}

-- Room widths in studs (rooms are square).
--
-- Roughly half again as large as the first pass, to match the hub: a fight
-- should happen in a hall you could lose someone in, not a room you can cross
-- in two dodges. Enemy counts below went up with them — the same three
-- skeletons in a room half again as wide is a longer walk, not a bigger fight.
DungeonDefs.SIZES = {
	Small = 44,
	Medium = 62,
	Large = 80,
	Huge = 104,
} :: { [SizeClass]: number }

-- Corridors grew with the rooms, but deliberately less: they are the low, tight
-- thing the halls are read against.
DungeonDefs.CORRIDOR_LENGTH = 20
DungeonDefs.CORRIDOR_WIDTH = 10

-- Rooms after the Start, counting the Shrine and the Boss. The rooms between
-- (length - 2 of them) always include one Elite and one Ambush.
DungeonDefs.MAIN_PATH_LENGTH = { min = 6, max = 8 } :: Range
-- Treasure branches attempted per dungeon, each one or two rooms long.
DungeonDefs.BRANCHES = { min = 1, max = 3 } :: Range
-- A dungeon with fewer treasure rooms than this is thrown away and redone.
DungeonDefs.MIN_TREASURE_ROOMS = 1
-- Chance a branch is two rooms long (a fight, then the treasure) rather than one.
DungeonDefs.LONG_BRANCH_CHANCE = 0.4
-- Chance a Treasure room has a guard.
DungeonDefs.TREASURE_GUARD_CHANCE = 0.5

DungeonDefs.BOSS = "HollowKing"

-- Enemy pools. Rooms at main-path depth LATE_DEPTH and beyond draw from
-- `late`; an Elite room's first enemy always comes from `elite`.
DungeonDefs.LATE_DEPTH = 3
DungeonDefs.POOLS = {
	early = { "Shambler", "Spitter" },
	late = { "Shambler", "Spitter", "SkeletonWarrior" },
	elite = { "SkeletonWarrior" },
} :: { [string]: { string } }

local NONE: { [SizeClass]: Range } = {}

DungeonDefs.PURPOSES = {
	Start = {
		displayName = "Entry Hall",
		sizes = { "Medium" },
		variants = { "Empty" },
		enemyCount = NONE,
		clearable = false,
		hasChest = false,
		chestCoins = 0,
		torchColor = { 255, 170, 90 },
	},
	Combat = {
		displayName = "Crypt",
		sizes = { "Small", "Medium", "Large" },
		variants = { "Empty", "Pillars", "Ruins" },
		enemyCount = {
			Small = { min = 1, max = 2 },
			Medium = { min = 2, max = 3 },
			Large = { min = 3, max = 4 },
		},
		clearable = true,
		hasChest = false,
		chestCoins = 0,
		torchColor = { 255, 150, 70 },
	},
	Elite = {
		displayName = "Warden's Hall",
		sizes = { "Large" },
		variants = { "Pillars", "Ruins" },
		enemyCount = {
			Large = { min = 3, max = 4 },
		},
		clearable = true,
		hasChest = true,
		chestCoins = 40,
		torchColor = { 255, 70, 50 },
	},
	Treasure = {
		displayName = "Vault",
		sizes = { "Small" },
		variants = { "Empty" },
		-- The guard, if any, is rolled with TREASURE_GUARD_CHANCE instead.
		enemyCount = NONE,
		clearable = false,
		hasChest = true,
		chestCoins = 60,
		torchColor = { 255, 210, 90 },
	},
	Shrine = {
		displayName = "Shrine",
		sizes = { "Small" },
		variants = { "Empty" },
		enemyCount = NONE,
		clearable = false,
		hasChest = false,
		chestCoins = 0,
		torchColor = { 90, 230, 210 },
	},
	-- Walk in and the gates slam shut behind you; the enemies come in waves
	-- (AMBUSH), and the gates open with the chest once the last one falls.
	Ambush = {
		displayName = "Ambush",
		sizes = { "Large" },
		variants = { "Ruins", "Pillars" },
		-- The waves are rolled into RoomNode.waves instead.
		enemyCount = NONE,
		clearable = true,
		hasChest = true,
		chestCoins = 50,
		torchColor = { 190, 90, 255 },
	},
	Boss = {
		displayName = "Throne Room",
		sizes = { "Huge" },
		variants = { "Hall" },
		-- The boss is placed by DungeonLayout, not rolled from a pool.
		enemyCount = NONE,
		clearable = true,
		hasChest = false,
		chestCoins = 0,
		torchColor = { 110, 190, 255 },
	},
} :: { [RoomPurpose]: PurposeDef }

-- A Treasure room with no guard holds this. A guarded one holds its guard's
-- LootTables row, like every other chest.
DungeonDefs.TREASURE_LOOT = {
	itemId = "GildedRelic",
	name = "Gilded Relic",
	flavor = "Someone hid this down here on purpose. Now it's yours.",
	rarity = "rare",
	classTag = nil,
}

DungeonDefs.AMBUSH = {
	waves = { 3, 4 },
	triggerDepth = 14,
	sealDelay = 1.5,
	waveDelay = 1.5,
	resetAfter = 4,
} :: AmbushDef

-- Paid to every player in the dungeon when the boss dies, on top of the
-- boss's own kill reward to whoever lands the last blow.
DungeonDefs.CLEAR_REWARD = { coins = 150, crystals = 2 } :: Reward

-- Seconds between the boss dying and the next dungeon replacing this one.
DungeonDefs.RESET_DELAY = 15

-- How long the boss fight stays "on" (boss bar showing) after every player
-- has left the boss room.
DungeonDefs.BOSS_ENCOUNTER_LINGER = 4

return DungeonDefs
