--!strict
-- The only place inventory state lives, mirroring EquipService's shape.
-- Loaded and saved by DataService.
--
-- A plain list rather than a map keyed by itemId: a map can't hold two copies
-- of the same item, and each copy can carry its own upgradeLevel. Items are
-- collectible only for now — they aren't consumed by the blacksmith.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local PlayerDataSchema = require(Shared.PlayerDataSchema)
local Remotes = require(Shared.Remotes)

local InventoryService = {}

export type ItemInstance = PlayerDataSchema.ItemInstance

local inventories: { [Player]: { ItemInstance } } = {}

-- The cap goes out with the list. The client draws "12 / 500" and colours it
-- when the bag is full, and it must not read PlayerDataSchema to do that: that
-- module is the save format's, and the client deliberately never touches it
-- (ARCHITECTURE.md's pure-module rule). Sending the number is how the panel
-- learns it.
local function publish(player: Player, inventory: { ItemInstance })
	Remotes.get("InventoryUpdated"):FireClient(player, {
		items = inventory,
		capacity = PlayerDataSchema.MAX_INVENTORY,
	})
end

-- A deep copy of an item list, so what is handed out or saved can never
-- alias the live inventory.
local function copyItems(items: { ItemInstance }): { ItemInstance }
	local copy = {}
	for _, item in items do
		table.insert(copy, table.clone(item))
	end
	return copy
end

-- Whether another item fits. The cap is the save format's, so the game
-- refuses an item up front rather than letting a save quietly drop it.
function InventoryService.hasRoom(player: Player): boolean
	local inventory = inventories[player]
	return inventory == nil or #inventory < PlayerDataSchema.MAX_INVENTORY
end

-- Returns whether the item was added.
function InventoryService.addItem(player: Player, item: ItemInstance): boolean
	if not InventoryService.hasRoom(player) then
		return false
	end

	local inventory = inventories[player]
	if not inventory then
		inventory = {}
		inventories[player] = inventory
	end

	table.insert(inventory, table.clone(item))
	publish(player, inventory)
	return true
end

-- The player's current item list (empty if they have none).
function InventoryService.getInventory(player: Player): { ItemInstance }
	return inventories[player] or {}
end

--[[ Persistence hooks, called only by DataService ]]

function InventoryService.hydrate(player: Player, items: { ItemInstance })
	local inventory = copyItems(items)
	inventories[player] = inventory
	publish(player, inventory)
end

-- Copies, so a save in flight can't see state change underneath it.
function InventoryService.snapshot(player: Player): { ItemInstance }
	return copyItems(inventories[player] or {})
end

-- No PlayerRemoving cleanup here: clearing on leave could beat DataService's
-- final save and write an empty inventory. DataService calls this after that
-- save.
function InventoryService.release(player: Player)
	inventories[player] = nil
end

return InventoryService
