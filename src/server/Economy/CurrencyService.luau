--!strict
-- The only place currency state lives, mirroring EquipService and
-- InventoryService. Loaded and saved by DataService.
--
-- Two currencies (DESIGN.md): coins drop from every kill, crystals only from
-- enemies whose EnemyDefs entry sets crystalReward. Crystals are keyed by
-- class, and you earn the class you were *playing* when the kill landed — so
-- switching weapon doesn't carry your upgrade materials across. That is where
-- respeccing's real cost comes from.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Loadout = require(Shared.Loadout)
local Remotes = require(Shared.Remotes)

local EnemyAI = require(script.Parent.Parent.Combat.EnemyAI)
local EquipService = require(script.Parent.Parent.EquipService)

local CurrencyService = {}

export type Balance = {
	coins: number,
	-- classTag -> count
	crystals: { [string]: number },
}

local balances: { [Player]: Balance } = {}

-- This player's coins and crystals, created empty on first use.
local function getBalance(player: Player): Balance
	local balance = balances[player]
	if not balance then
		balance = { coins = 0, crystals = {} }
		balances[player] = balance
	end

	return balance
end

-- Sends a player their balance, after it changed.
local function publish(player: Player, balance: Balance)
	Remotes.get("CurrencyUpdated"):FireClient(player, {
		coins = balance.coins,
		crystals = balance.crystals,
	})
end

-- This player's balance. The read every other service goes through, so
-- none of them has to know whether the player has been seen before.
function CurrencyService.getBalance(player: Player): Balance
	return getBalance(player)
end

-- Spends only if the player can afford the whole cost — never partially.
-- `crystalClass` is irrelevant when `crystals` is 0 (the coin-only tiers).
function CurrencyService.trySpend(player: Player, coins: number, crystalClass: string, crystals: number): boolean
	local balance = getBalance(player)
	local heldCrystals = balance.crystals[crystalClass] or 0

	if balance.coins < coins or heldCrystals < crystals then
		return false
	end

	balance.coins -= coins
	if crystals > 0 then
		balance.crystals[crystalClass] = heldCrystals - crystals
	end

	publish(player, balance)
	return true
end

-- Pays out an enemy's EnemyDefs reward to whoever lands the killing blow, every
-- time it dies. Registered per enemy by DungeonGenerator, alongside its chest.
function CurrencyService.trackEnemy(enemy: EnemyAI.Enemy)
	local def = enemy.def

	EnemyAI.onDeath(enemy, function(killer)
		if not killer or not killer.Parent then
			return
		end

		local balance = getBalance(killer)
		balance.coins += def.coinReward

		if def.crystalReward > 0 then
			local weaponId = EquipService.getWeaponId(killer)
			if weaponId then
				local class = Loadout.classOf(weaponId)
				balance.crystals[class] = (balance.crystals[class] or 0) + def.crystalReward
			end
		end

		publish(killer, balance)
	end)
end

-- Pays a reward that isn't a kill: a treasure chest's coins, the dungeon
-- clear bonus. Crystals are of the player's equipped class, as with kills;
-- a player with no weapon gets none.
function CurrencyService.grant(player: Player, coins: number, crystals: number)
	if not player.Parent then
		return
	end

	local balance = getBalance(player)
	balance.coins += coins

	if crystals > 0 then
		local weaponId = EquipService.getWeaponId(player)
		if weaponId then
			local class = Loadout.classOf(weaponId)
			balance.crystals[class] = (balance.crystals[class] or 0) + crystals
		end
	end

	publish(player, balance)
end

--[[ Persistence hooks, called only by DataService ]]

function CurrencyService.hydrate(player: Player, coins: number, crystals: { [string]: number })
	local balance: Balance = { coins = coins, crystals = table.clone(crystals) }
	balances[player] = balance
	publish(player, balance)
end

-- Copies, so a save in flight can't see state change underneath it.
function CurrencyService.snapshot(player: Player): (number, { [string]: number })
	local balance = balances[player]
	if not balance then
		return 0, {}
	end

	return balance.coins, table.clone(balance.crystals)
end

-- No PlayerRemoving cleanup here: clearing on leave could beat DataService's
-- final save and write zero coins. DataService calls this after that save.
function CurrencyService.release(player: Player)
	balances[player] = nil
end

return CurrencyService
