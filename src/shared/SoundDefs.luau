--!strict
-- Every sound the game plays, by name. Pure data — no Roblox API.
--
-- Swap an `id` for a better clip and it's used everywhere that sound plays,
-- with no code change. Browse Studio's Toolbox → Audio for replacements;
-- anything published by the "Roblox" account can be used in any experience.
--
-- What's here now, and why:
--   rbxassetid://12222216 swordslash, 12222208 swordlunge, 12222225 unsheath,
--   12221984 collide, 12222140 snap, 12221976 clickfast, 12221967 button,
--   12222030 HalloweenThunder —
--   Roblox's own classic sounds, published by the Roblox account and marked
--   public domain (checked Sept 2026).
--   rbxasset://sounds/... — files shipped inside the Roblox client itself, so
--   they need no asset at all. Only a handful exist (checked against the
--   installed client, Sept 2026).
-- One clip covers several sounds by playing at a different pitch.

export type SoundDef = {
	id: string,
	volume: number,
	-- Each play picks a pitch in this range, so repeats don't sound robotic.
	pitchMin: number,
	pitchMax: number,
}

local SWORD_SLASH = "rbxassetid://12222216"
local SWORD_LUNGE = "rbxassetid://12222208"
local UNSHEATH = "rbxassetid://12222225"
local COLLIDE = "rbxassetid://12221984"
local SNAP = "rbxassetid://12222140"
local CLICK_FAST = "rbxassetid://12221976"
local BUTTON = "rbxassetid://12221967"
local THUNDER = "rbxassetid://12222030"
local EXPLOSION = "rbxasset://sounds/impact_explosion_03.mp3"
local OUCH = "rbxasset://sounds/ouch.ogg"

local SoundDefs = {}

SoundDefs.SOUNDS = {
	-- Player swings, keyed `swing_<weaponId>` like the animations.
	swing_SwordAndShield = { id = SWORD_SLASH, volume = 0.6, pitchMin = 0.88, pitchMax = 0.98 },
	swing_Daggers = { id = SWORD_SLASH, volume = 0.45, pitchMin = 1.3, pitchMax = 1.45 },
	swing_Staff = { id = SWORD_LUNGE, volume = 0.5, pitchMin = 0.72, pitchMax = 0.82 },
	-- The four from the class pass. Pitch is doing the characterisation here:
	-- the same few sounds, dropped for weight and raised for speed, which is
	-- most of what tells a greataxe from a rapier by ear.
	swing_Greataxe = { id = SWORD_SLASH, volume = 0.75, pitchMin = 0.55, pitchMax = 0.64 },
	swing_Rapier = { id = SWORD_LUNGE, volume = 0.42, pitchMin = 1.4, pitchMax = 1.55 },
	swing_Bow = { id = SNAP, volume = 0.55, pitchMin = 0.9, pitchMax = 1.0 },
	swing_Focus = { id = SWORD_LUNGE, volume = 0.5, pitchMin = 1.05, pitchMax = 1.18 },

	-- Your blow landing on an enemy; a riposte lands lower and louder.
	hit = { id = COLLIDE, volume = 0.8, pitchMin = 0.85, pitchMax = 1.0 },
	hit_riposte = { id = COLLIDE, volume = 1.0, pitchMin = 0.6, pitchMax = 0.68 },

	-- A landed parry: a bright metallic ring over a sharp crack.
	parry = { id = UNSHEATH, volume = 0.9, pitchMin = 1.4, pitchMax = 1.5 },
	parry_crack = { id = SNAP, volume = 0.7, pitchMin = 1.0, pitchMax = 1.1 },

	-- Enemies. The windup whoosh is an audio cue for the parry beat.
	enemy_windup = { id = SWORD_LUNGE, volume = 0.3, pitchMin = 0.55, pitchMax = 0.65 },
	enemy_slam = { id = EXPLOSION, volume = 0.45, pitchMin = 0.7, pitchMax = 0.8 },
	enemy_death = { id = COLLIDE, volume = 0.9, pitchMin = 0.45, pitchMax = 0.52 },

	player_hurt = { id = OUCH, volume = 0.5, pitchMin = 0.95, pitchMax = 1.05 },
	-- Your own moves.
	dodge = { id = SWORD_LUNGE, volume = 0.4, pitchMin = 1.5, pitchMax = 1.65 },
	feint = { id = CLICK_FAST, volume = 0.5, pitchMin = 0.8, pitchMax = 0.85 },
	critical_windup = { id = UNSHEATH, volume = 0.7, pitchMin = 0.6, pitchMax = 0.65 },

	-- A guard taking a hit: a short metallic ting.
	block = { id = UNSHEATH, volume = 0.6, pitchMin = 1.8, pitchMax = 1.95 },
	guard_break = { id = COLLIDE, volume = 1.0, pitchMin = 0.35, pitchMax = 0.4 },

	-- Stations and loot.
	equip = { id = UNSHEATH, volume = 0.7, pitchMin = 1.0, pitchMax = 1.0 },
	upgrade = { id = UNSHEATH, volume = 0.9, pitchMin = 0.75, pitchMax = 0.8 },
	chest_open = { id = SNAP, volume = 0.8, pitchMin = 0.65, pitchMax = 0.7 },
	coins = { id = CLICK_FAST, volume = 0.4, pitchMin = 1.2, pitchMax = 1.3 },
	heal = { id = CLICK_FAST, volume = 0.45, pitchMin = 0.7, pitchMax = 0.75 },
	refused = { id = BUTTON, volume = 0.4, pitchMin = 0.7, pitchMax = 0.7 },

	-- The dungeon run.
	ambush = { id = EXPLOSION, volume = 0.5, pitchMin = 0.55, pitchMax = 0.6 },
	room_cleared = { id = UNSHEATH, volume = 0.6, pitchMin = 1.15, pitchMax = 1.2 },
	boss_awakens = { id = THUNDER, volume = 0.8, pitchMin = 0.7, pitchMax = 0.75 },
	dungeon_cleared = { id = UNSHEATH, volume = 1.0, pitchMin = 0.55, pitchMax = 0.6 },
} :: { [string]: SoundDef }

-- The whoosh of a weapon's swing. One sound per weapon, whichever combo step.
function SoundDefs.swingSound(weaponId: string): string
	return `swing_{weaponId}`
end

function SoundDefs.get(name: string): SoundDef?
	return SoundDefs.SOUNDS[name]
end

-- The pitch for one play, from a roll in [0, 1).
function SoundDefs.pitchFor(def: SoundDef, roll: number): number
	return def.pitchMin + (def.pitchMax - def.pitchMin) * math.clamp(roll, 0, 1)
end

return SoundDefs
