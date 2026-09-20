--!strict
-- The only owner of XP, levels and spent skill points, mirroring
-- EquipService and CurrencyService. Loaded and saved by DataService.
--
-- XP is the progress that belongs to the *player* rather than to the weapon
-- they happen to be carrying: upgrade levels reset when you put a weapon
-- down, levels never do. What a level buys is one skill point, spendable in
-- the tree of whichever weapon you are holding (SkillTreeDefs).
--
-- Each tree has its own points. Your level says how many points every tree
-- gets, not how many you have to divide between them — trying the daggers at
-- level 15 shouldn't mean a bare tree, and shouldn't cost your sword its own.
--
-- Kills pay everyone playing, not just whoever lands the blow. The dungeon is
-- shared and the design is group-first (DESIGN.md); paying only the killer
-- would turn a party into three people racing for last hits. Coins still go
-- to the killer, which is where that tension belongs.
--
-- Combat never reads this module's state directly: it asks `modifiers` for a
-- plain table of numbers under the keys SkillTreeDefs.EFFECTS names.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local ProgressionDefs = require(Shared.ProgressionDefs)
local Remotes = require(Shared.Remotes)
local SkillTreeDefs = require(Shared.SkillTreeDefs)

local EnemyAI = require(script.Parent.Parent.Combat.EnemyAI)
local EquipService = require(script.Parent.Parent.EquipService)

local ProgressionService = {}

-- What an unmodified player is worth. Roblox's own defaults; the skill tree
-- adds to these rather than replacing them.
local BASE_HEALTH = 100
local BASE_WALK_SPEED = 16

-- CombatClient slows walking while you attack or block, and needs to know
-- what it is a fraction *of*. Read from the humanoid at spawn it would miss
-- every later change, so the base is published as an attribute.
local BASE_SPEED_ATTRIBUTE = "BaseWalkSpeed"

type Record = {
	xp: number,
	-- weaponId -> nodeId -> ranks
	skills: { [string]: { [string]: number } },
	-- Modifiers for the weapon currently held, rebuilt on any change rather
	-- than recomputed per swing.
	cached: SkillTreeDefs.Modifiers?,
	cachedWeapon: string?,
}

local records: { [Player]: Record } = {}

-- This player's XP and skill record, created empty on first use.
local function getRecord(player: Player): Record
	local record = records[player]
	if not record then
		record = { xp = 0, skills = {}, cached = nil, cachedWeapon = nil }
		records[player] = record
	end
	return record
end

-- The points this player has spent in one weapon's tree, created empty on
-- first use. Per weapon, because your weapon is your class.
local function allocationFor(record: Record, weaponId: string): SkillTreeDefs.Allocation
	local allocation = record.skills[weaponId]
	if not allocation then
		allocation = {}
		record.skills[weaponId] = allocation
	end
	return allocation
end

--[[ Applying what the tree is worth ]]

local function humanoidOf(player: Player): Humanoid?
	local character = player.Character
	if not character then
		return nil
	end
	return character:FindFirstChildOfClass("Humanoid")
end

-- Health and walk speed are the two modifiers that live on the humanoid
-- rather than being read at the moment of a hit, so they are pushed rather
-- than pulled.
--
-- Raising MaxHealth adds the difference to current health instead of leaving
-- the player at the same number out of a larger bar: a skill point that makes
-- your health bar emptier is a punishment for spending it.
local function applyToCharacter(player: Player)
	local humanoid = humanoidOf(player)
	if not humanoid or humanoid.Health <= 0 then
		return
	end

	local mods = ProgressionService.modifiers(player)

	local wanted = BASE_HEALTH + mods.maxHealth
	local gained = wanted - humanoid.MaxHealth
	if gained ~= 0 then
		humanoid.MaxHealth = wanted
		if gained > 0 then
			humanoid.Health = math.min(humanoid.Health + gained, wanted)
		else
			humanoid.Health = math.min(humanoid.Health, wanted)
		end
	end

	local speed = BASE_WALK_SPEED * (1 + mods.moveSpeed)
	humanoid:SetAttribute(BASE_SPEED_ATTRIBUTE, speed)
	humanoid.WalkSpeed = speed
end

-- Throws away the cached modifiers for a player, so the next read
-- recomputes them. Called whenever anything that feeds them changes:
-- spending a point, gaining a level, or switching weapon.
local function invalidate(player: Player)
	local record = records[player]
	if record then
		record.cached = nil
		record.cachedWeapon = nil
	end
	applyToCharacter(player)
end

--[[ Publishing ]]

local function publish(player: Player)
	local record = getRecord(player)
	local standing = ProgressionDefs.standing(record.xp)
	local weaponId = EquipService.getWeaponId(player)

	Remotes.get("ProgressionChanged"):FireClient(player, {
		xp = record.xp,
		level = standing.level,
		into = standing.into,
		toNext = standing.toNext,
		points = standing.points,
		weaponId = weaponId,
		spent = if weaponId then SkillTreeDefs.spent(weaponId, allocationFor(record, weaponId)) else 0,
		skills = if weaponId then table.clone(allocationFor(record, weaponId)) else {},
	})
end

--[[ Earning ]]

-- Awards XP and announces any level gained. Capped, so a maxed player's
-- profile stops growing.
function ProgressionService.award(player: Player, amount: number)
	if not player.Parent or amount <= 0 then
		return
	end

	local record = getRecord(player)
	local before = ProgressionDefs.standing(record.xp).level
	record.xp = ProgressionDefs.cap(record.xp + amount)

	local after = ProgressionDefs.standing(record.xp).level
	if after > before then
		Remotes.get("LevelGained"):FireClient(player, { level = after, points = after - before })
	end

	-- Nothing to re-apply to the character: a level hands out points, and an
	-- unspent point changes nothing about what you are worth.
	publish(player)
end

-- Pays everyone armed when an enemy dies. Registered per enemy alongside its
-- chest and its coins, by DungeonGenerator.
--
-- Armed, rather than "in the dungeon": asking LobbyService who is in the hub
-- would make this module require the hub, and the dungeon already requires
-- this one. Someone standing in the hub with a weapon drawn while their party
-- fights is close enough, and erring toward paying is the right way to err.
function ProgressionService.trackEnemy(enemy: EnemyAI.Enemy)
	local def = enemy.def

	EnemyAI.onDeath(enemy, function()
		for _, player in Players:GetPlayers() do
			-- Someone who hasn't picked a weapon up yet isn't playing.
			if EquipService.getWeaponId(player) then
				ProgressionService.award(player, def.xpReward)
			end
		end
	end)
end

--[[ Spending ]]

function ProgressionService.standingOf(player: Player): ProgressionDefs.Standing
	return ProgressionDefs.standing(getRecord(player).xp)
end

-- Points left to spend in one weapon's tree.
function ProgressionService.availablePoints(player: Player, weaponId: string): number
	local record = getRecord(player)
	local earned = ProgressionDefs.standing(record.xp).points
	return earned - SkillTreeDefs.spent(weaponId, allocationFor(record, weaponId))
end

-- Buys one rank. The client asks; this decides. Every rule comes from
-- SkillTreeDefs, so the greyed-out button and the refusal agree.
function ProgressionService.trySpend(player: Player, weaponId: unknown, nodeId: unknown): boolean
	if type(weaponId) ~= "string" or type(nodeId) ~= "string" then
		return false
	end

	-- Only in the tree of the weapon you are actually holding, so a client
	-- can't quietly build out a tree it isn't playing.
	if EquipService.getWeaponId(player) ~= weaponId then
		return false
	end

	local record = getRecord(player)
	local allocation = allocationFor(record, weaponId)
	local earned = ProgressionDefs.standing(record.xp).points

	if not SkillTreeDefs.canSpend(weaponId, allocation, nodeId, earned).ok then
		return false
	end

	allocation[nodeId] = (allocation[nodeId] or 0) + 1
	invalidate(player)
	publish(player)
	return true
end

--[[ What combat reads ]]

-- Every effect key, as a number, for the weapon the player is holding. All
-- zeros for a player with no weapon, so callers never branch on it.
function ProgressionService.modifiers(player: Player): SkillTreeDefs.Modifiers
	local record = getRecord(player)
	local weaponId = EquipService.getWeaponId(player)

	if not weaponId then
		return SkillTreeDefs.noModifiers()
	end

	if record.cached and record.cachedWeapon == weaponId then
		return record.cached
	end

	local mods = SkillTreeDefs.modifiers(weaponId, allocationFor(record, weaponId))
	record.cached = mods
	record.cachedWeapon = weaponId
	return mods
end

-- slot -> AbilityDefs id, for the weapon this player is holding. Read from
-- the tree rather than cached with the modifiers: spending the point that
-- unlocks an ability should put it on the key immediately.
function ProgressionService.abilities(player: Player): { [number]: string }
	local weaponId = EquipService.getWeaponId(player)
	if not weaponId then
		return {}
	end
	return SkillTreeDefs.abilities(weaponId, allocationFor(getRecord(player), weaponId))
end

--[[ Persistence hooks, called only by DataService ]]

function ProgressionService.hydrate(player: Player, xp: number, skills: { [string]: { [string]: number } })
	local record = getRecord(player)
	record.xp = ProgressionDefs.cap(xp)
	record.skills = {}
	for weaponId, allocation in skills do
		record.skills[weaponId] = table.clone(allocation)
	end
	record.cached = nil
	record.cachedWeapon = nil

	publish(player)
	applyToCharacter(player)
end

-- Copies, so a save in flight can't see state change underneath it.
function ProgressionService.snapshot(player: Player): (number, { [string]: { [string]: number } })
	local record = records[player]
	if not record then
		return 0, {}
	end

	local skills = {}
	for weaponId, allocation in record.skills do
		skills[weaponId] = table.clone(allocation)
	end
	return record.xp, skills
end

-- No PlayerRemoving cleanup here, for the same reason as CurrencyService:
-- clearing on leave could beat DataService's final save and write zero XP.
function ProgressionService.release(player: Player)
	records[player] = nil
end

-- Listens for skill points being spent, and for the XP awards the dungeon
-- registers on every enemy it spawns.
function ProgressionService.start()
	Remotes.get("SpendSkillPoint").OnServerEvent:Connect(function(player, payload)
		if type(payload) ~= "table" then
			return
		end
		ProgressionService.trySpend(player, payload.weaponId, payload.nodeId)
	end)

	-- A different weapon means a different tree, so the cached modifiers and
	-- the health and speed they were worth are both stale.
	EquipService.onChanged(function(player)
		invalidate(player)
		publish(player)
	end)

	Players.PlayerAdded:Connect(function(player)
		player.CharacterAdded:Connect(function()
			-- The humanoid comes back at Roblox's defaults every respawn.
			task.defer(applyToCharacter, player)
		end)
	end)
end

return ProgressionService
