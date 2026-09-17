--!strict
-- The only place equipped-weapon state lives. Kept separate from CombatServer
-- so the class altars and the blacksmith can equip or upgrade a player
-- without reaching into combat internals. Loaded and saved by DataService.
--
-- Per-weapon upgrade levels live here too, for the same one-place reason: an
-- upgrade is weapon state. BlacksmithService owns the economy side (price,
-- payment) and calls applyUpgrade once paid, so the dependency only ever
-- points blacksmith -> equip, never back.
--
-- A player's class is never stored here: it is always derived from the
-- equipped weapon through Loadout.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local EconomyDefs = require(Shared.EconomyDefs)
local Loadout = require(Shared.Loadout)
local Remotes = require(Shared.Remotes)

local EquipService = {}

local equipped: { [Player]: string } = {}
local upgradeLevels: { [Player]: { [string]: number } } = {}

export type ChangedCallback = (player: Player, weaponId: string, upgradeLevel: number) -> ()
local changedCallbacks: { ChangedCallback } = {}

local function publish(player: Player, weaponId: string)
	local level = EquipService.getUpgradeLevel(player, weaponId)

	Remotes.get("WeaponEquipped"):FireClient(player, {
		weaponId = weaponId,
		classTag = Loadout.classOf(weaponId),
		upgradeLevel = level,
	})

	for _, callback in changedCallbacks do
		-- One failing listener must not stop the others, or the client update
		-- that already went out.
		local ok, err = pcall(callback, player, weaponId, level)
		if not ok then
			warn(`EquipService change listener failed: {err}`)
		end
	end
end

-- Runs whenever a player's equipped weapon or its upgrade level changes,
-- including when saved progress loads. Read-only: listeners draw what changed
-- (WeaponVisuals) and must not change weapon state themselves.
function EquipService.onChanged(callback: ChangedCallback)
	table.insert(changedCallbacks, callback)
end

-- nil until the player takes up a class at an altar. Combat ignores an
-- unequipped player's swings and parries.
function EquipService.getWeaponId(player: Player): string?
	return equipped[player]
end

function EquipService.getUpgradeLevel(player: Player, weaponId: string): number
	local levels = upgradeLevels[player]
	if not levels then
		return 0
	end

	return levels[weaponId] or 0
end

-- Damage for this player's copy of the weapon, with their upgrades applied.
-- Computed on demand rather than stored as a scaled copy of the weapon def,
-- since those defs are shared by every player (see EconomyDefs.upgradedDamage).
function EquipService.getDamage(player: Player, weaponId: string): number
	local base = Loadout.getDef(weaponId).attack.damage
	return EconomyDefs.upgradedDamage(base, EquipService.getUpgradeLevel(player, weaponId))
end

-- Returns whether the weapon was equipped. The id is validated rather than
-- trusted, since one path into here is a client-fired debug remote.
function EquipService.setWeapon(player: Player, weaponId: unknown): boolean
	local result = Loadout.resolve(weaponId)
	if not result.ok then
		return false
	end

	local resolvedId = result.weaponId :: string
	equipped[player] = resolvedId
	publish(player, resolvedId)
	return true
end

-- Called by BlacksmithService only after it has taken payment. Returns the new
-- level. Upgrades are per weapon, so a respec back to a weapon you already
-- upgraded keeps its level.
function EquipService.applyUpgrade(player: Player, weaponId: string): number
	local levels = upgradeLevels[player]
	if not levels then
		levels = {}
		upgradeLevels[player] = levels
	end

	local newLevel = (levels[weaponId] or 0) + 1
	levels[weaponId] = newLevel

	if equipped[player] == weaponId then
		publish(player, weaponId)
	end

	return newLevel
end

--[[ Persistence hooks, called only by DataService ]]

-- Replaces this player's state with what was loaded.
--
-- A saved weapon this server doesn't recognise — newer content, seen during a
-- rollback — can't be held, so the player starts unequipped. Its upgrade level
-- is kept, and written back on the next save.
function EquipService.hydrate(player: Player, weaponId: string?, levels: { [string]: number })
	upgradeLevels[player] = table.clone(levels)

	if weaponId and Loadout.resolve(weaponId).ok then
		equipped[player] = weaponId
		publish(player, weaponId)
	else
		equipped[player] = nil
	end
end

-- Copies, so a save in flight can't see state change underneath it.
function EquipService.snapshot(player: Player): (string?, { [string]: number })
	return equipped[player], table.clone(upgradeLevels[player] or {})
end

-- There is deliberately no PlayerRemoving cleanup here. Roblox doesn't
-- guarantee the order PlayerRemoving handlers run in, so clearing state there
-- could beat DataService's final save and write an empty profile. DataService
-- calls this once that save is done.
function EquipService.release(player: Player)
	equipped[player] = nil
	upgradeLevels[player] = nil
end

return EquipService
