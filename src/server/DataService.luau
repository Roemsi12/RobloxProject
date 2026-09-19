--!strict
-- Loads and saves player progress: coins, crystals, the equipped weapon,
-- upgrade levels and inventory.
--
-- The live state belongs to EquipService, CurrencyService and
-- InventoryService. This module only moves snapshots of it to and from the
-- DataStore. Every judgement about the stored data — migrating it, trusting
-- it, who owns it — is PlayerDataSchema's, which is pure and tested.
--
-- Safety rules:
--
--   * Session locks. Loading takes a lock inside the stored record, every
--     save renews it, and leaving releases it. A server that finds its lock
--     taken stops writing, so two servers never write one profile at once.
--   * Never overwrite what can't be read. A record from a newer game version,
--     or one that isn't a record at all, stops the load instead of being
--     replaced with defaults.
--   * No session that won't save. In a live server, a profile that can't be
--     loaded safely kicks the player with an explanation, rather than letting
--     them play and lose everything.
--   * Studio is separate. Studio uses its own DataStore, so playtests can
--     never touch live progress, and it falls back to an unsaved session
--     instead of kicking when DataStores aren't reachable.

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage.Shared
local PlayerDataSchema = require(Shared.PlayerDataSchema)
local Remotes = require(Shared.Remotes)

local AppearanceService = require(script.Parent.AppearanceService)
local CurrencyService = require(script.Parent.Economy.CurrencyService)
local ProgressionService = require(script.Parent.Progression.ProgressionService)
local EquipService = require(script.Parent.EquipService)
local InventoryService = require(script.Parent.InventoryService)
local SpawnService = require(script.Parent.SpawnService)

local DataService = {}

local IS_STUDIO = RunService:IsStudio()

-- Bump the suffix only for a deliberate wipe. Schema changes go through
-- PlayerDataSchema migrations instead.
local STORE_NAME = if IS_STUDIO then "PlayerData_v1_Studio" else "PlayerData_v1"

local AUTOSAVE_INTERVAL = 60

-- A lock not renewed for this long is treated as abandoned, e.g. by a server
-- that crashed. Three missed autosaves: short enough that a crash doesn't lock
-- players out for long, long enough to ride out a brief DataStore outage.
local SESSION_STALE_AFTER = 3 * AUTOSAVE_INTERVAL

-- Studio gets one attempt: a failure there means "run unsaved", and waiting
-- through backoff first would only delay the playtest.
local LOAD_ATTEMPTS = if IS_STUDIO then 1 else 5
local LOCK_WAITS = 5
local LOCK_WAIT_SECONDS = 3
local SAVE_ATTEMPTS = 3
local BUDGET_WAIT_LIMIT = 30
local SHUTDOWN_TIMEOUT = 25

type LoadOutcome = "loaded" | "locked" | "future_version" | "corrupt" | "error" | "left"

local KICK_MESSAGES: { [string]: string } = {
	locked = "Your progress is still being saved by another server. Please rejoin in a minute.",
	future_version = "This server is running an older version of the game. Please rejoin to reach a newer one.",
	corrupt = "We couldn't read your saved progress, so we stopped before changing it. Please contact the developer.",
	error = "We couldn't load your progress right now. Please try again shortly.",
	unavailable = "Saving is unavailable on this server right now. Please try again shortly.",
}

type Profile = {
	-- false for a Studio session running without saves.
	persistent: boolean,
	-- A write is in flight. Writes for one profile never overlap.
	saving: boolean,
	-- The final save has started; no more autosaves.
	releasing: boolean,
	-- The lock has been given up; nothing more may be written.
	released: boolean,
}

local store: DataStore? = nil
local profiles: { [Player]: Profile } = {}

-- Players whose load has started. A player joining between connecting
-- PlayerAdded and walking the existing player list would otherwise be loaded
-- twice.
local started: { [Player]: boolean } = {}

local function keyFor(player: Player): string
	return `player_{player.UserId}`
end

local function waitForBudget()
	local waited = 0
	while
		DataStoreService:GetRequestBudgetForRequestType(Enum.DataStoreRequestType.UpdateAsync) < 1
		and waited < BUDGET_WAIT_LIMIT
	do
		waited += task.wait(1)
	end
end

--[[ Loading ]]

-- One attempt to read the profile and take its lock, in a single atomic
-- UpdateAsync. The transform may run more than once if the write races, so it
-- decides from scratch every time and never yields.
local function tryClaim(player: Player, dataStore: DataStore): (PlayerDataSchema.PlayerData?, LoadOutcome)
	local claimed: PlayerDataSchema.PlayerData? = nil
	local outcome: LoadOutcome = "error"

	waitForBudget()

	local ok, err = pcall(function()
		dataStore:UpdateAsync(keyFor(player), function(stored: any)
			claimed = nil

			if stored ~= nil and type(stored) ~= "table" then
				outcome = "corrupt"
				return nil
			end

			local now = os.time()
			local session = if stored then stored.session else nil
			if not PlayerDataSchema.canClaim(session, game.JobId, now, SESSION_STALE_AFTER) then
				outcome = "locked"
				return nil
			end

			local data, status = PlayerDataSchema.migrate(if stored then stored.data else nil)
			if status == "future_version" or status == "corrupt" then
				outcome = status
				-- Returning nil cancels the write: the stored record stays
				-- exactly as it was.
				return nil
			end

			outcome = "loaded"
			claimed = data
			return {
				data = data,
				session = { jobId = game.JobId, heartbeat = now },
			}
		end)
	end)

	if not ok then
		warn(`[DataService] Loading {player.Name} failed: {err}`)
		return nil, "error"
	end

	return claimed, outcome
end

local function loadProfile(player: Player, dataStore: DataStore): (PlayerDataSchema.PlayerData?, LoadOutcome)
	local failures = 0
	local lockWaits = 0

	while player.Parent do
		local data, outcome = tryClaim(player, dataStore)

		if outcome == "loaded" then
			return data, outcome
		elseif outcome == "locked" then
			-- Usually a server that is mid-way through saving this player on
			-- their way out; its release lands within seconds.
			lockWaits += 1
			if lockWaits > LOCK_WAITS then
				return nil, "locked"
			end
			task.wait(LOCK_WAIT_SECONDS)
		elseif outcome == "error" then
			failures += 1
			if failures >= LOAD_ATTEMPTS then
				return nil, "error"
			end
			task.wait(2 ^ failures)
		else
			-- future_version or corrupt: retrying can't change the answer.
			return nil, outcome
		end
	end

	return nil, "left"
end

--[[ Saving ]]

local function snapshot(player: Player): PlayerDataSchema.PlayerData
	local weaponId, upgradeLevels = EquipService.snapshot(player)
	local coins, crystals = CurrencyService.snapshot(player)
	local xp, skills = ProgressionService.snapshot(player)

	-- Sanitising also deep-copies, so the write can't alias live state.
	return PlayerDataSchema.sanitize({
		version = PlayerDataSchema.CURRENT_VERSION,
		coins = coins,
		crystals = crystals,
		equipped = { weapon = weaponId },
		upgradeLevels = upgradeLevels,
		inventory = InventoryService.snapshot(player),
		xp = xp,
		skills = skills,
		appearance = AppearanceService.snapshot(player),
	})
end

type SaveOutcome = "saved" | "lost" | "error"

local function trySave(player: Player, dataStore: DataStore, data: PlayerDataSchema.PlayerData, release: boolean): SaveOutcome
	local outcome: SaveOutcome = "error"

	waitForBudget()

	local ok, err = pcall(function()
		dataStore:UpdateAsync(keyFor(player), function(stored: any)
			local session = if type(stored) == "table" then stored.session else nil
			if not PlayerDataSchema.isOwnedBy(session, game.JobId) then
				outcome = "lost"
				return nil
			end

			outcome = "saved"
			return {
				data = data,
				session = if release then nil else { jobId = game.JobId, heartbeat = os.time() },
			}
		end)
	end)

	if not ok then
		warn(`[DataService] Saving {player.Name} failed: {err}`)
		return "error"
	end

	return outcome
end

-- Saves this player's current state. With `release`, also gives up the lock.
-- Returns whether the write landed.
local function saveProfile(player: Player, release: boolean): boolean
	local profile = profiles[player]
	local dataStore = store
	if not profile or not profile.persistent or profile.released or not dataStore then
		return true
	end

	-- Serialise writes. Without this, an autosave landing after the final
	-- release would re-lock the profile, and the player's next server would
	-- wait out the full stale timeout before letting them in.
	while profile.saving do
		task.wait()
	end

	if profile.released or (profile.releasing and not release) then
		return true
	end

	profile.saving = true

	-- Taken once, before any yield, so every retry writes the same moment.
	local data = snapshot(player)
	local saved = false

	for attempt = 1, SAVE_ATTEMPTS do
		local outcome = trySave(player, dataStore, data, release)

		if outcome == "saved" then
			saved = true
			if release then
				profile.released = true
			end
			break
		elseif outcome == "lost" then
			-- Another server took this profile over, so its copy wins. Stop
			-- writing from here, and don't let the player carry on in a
			-- session whose progress can no longer be saved.
			warn(`[DataService] Lost the session lock for {player.Name}; no longer saving here`)
			profile.persistent = false
			if player.Parent then
				player:Kick("Your session moved to another server. Please rejoin.")
			end
			break
		end

		if attempt < SAVE_ATTEMPTS then
			task.wait(2 ^ attempt)
		end
	end

	profile.saving = false
	return saved
end

--[[ Joining and leaving ]]

local function hydrate(player: Player, data: PlayerDataSchema.PlayerData)
	EquipService.hydrate(player, data.equipped.weapon, data.upgradeLevels)
	CurrencyService.hydrate(player, data.coins, data.crystals)
	ProgressionService.hydrate(player, data.xp, data.skills)
	InventoryService.hydrate(player, data.inventory)
	-- Last of the four: it respawns the character to put the new body on, and
	-- a character rebuilt before the others have hydrated would come back
	-- holding nothing.
	AppearanceService.hydrate(player, data.appearance)
end

local function releaseServices(player: Player)
	EquipService.release(player)
	CurrencyService.release(player)
	ProgressionService.release(player)
	InventoryService.release(player)
	AppearanceService.release(player)
end

local function begin(player: Player, data: PlayerDataSchema.PlayerData, persistent: boolean)
	profiles[player] = {
		persistent = persistent,
		saving = false,
		releasing = false,
		released = false,
	}

	hydrate(player, data)
	Remotes.get("ProfileLoaded"):FireClient(player, { persistent = persistent })
	SpawnService.spawn(player)
end

local function onPlayerAdded(player: Player)
	if started[player] then
		return
	end
	started[player] = true

	local dataStore = store

	if not dataStore then
		if IS_STUDIO then
			begin(player, PlayerDataSchema.default(), false)
		else
			player:Kick(KICK_MESSAGES.unavailable)
		end
		return
	end

	local data, outcome = loadProfile(player, dataStore)

	if outcome == "left" then
		return
	end

	if outcome == "loaded" and data then
		if player.Parent then
			begin(player, data, true)
		else
			-- Left while the load was finishing: hand the lock straight back,
			-- with the data unchanged, so their next server isn't kept waiting.
			trySave(player, dataStore, data, true)
		end
		return
	end

	if IS_STUDIO then
		warn(`[DataService] Couldn't load {player.Name} ({outcome}); playing this Studio session without saves`)
		begin(player, PlayerDataSchema.default(), false)
		return
	end

	player:Kick(KICK_MESSAGES[outcome] or KICK_MESSAGES.error)
end

local function onPlayerRemoving(player: Player)
	started[player] = nil

	local profile = profiles[player]
	if not profile then
		-- Never finished loading, so there's nothing of theirs to save.
		return
	end

	profile.releasing = true
	saveProfile(player, true)

	profiles[player] = nil
	releaseServices(player)
end

-- Give every profile a final save and release before the server goes away.
-- PlayerRemoving also fires during shutdown; saveProfile's released flag makes
-- whichever runs second a no-op.
local function onClose()
	local pending = 0

	for player, profile in profiles do
		if profile.persistent and not profile.released then
			pending += 1
			profile.releasing = true

			task.spawn(function()
				saveProfile(player, true)
				pending -= 1
			end)
		end
	end

	local waited = 0
	while pending > 0 and waited < SHUTDOWN_TIMEOUT do
		waited += task.wait(0.5)
	end
end

local function autosaveLoop()
	while true do
		task.wait(AUTOSAVE_INTERVAL)

		for player, profile in profiles do
			if profile.persistent and not profile.releasing then
				task.spawn(saveProfile, player, false)
			end
		end
	end
end

function DataService.start()
	local ok, result = pcall(function()
		return DataStoreService:GetDataStore(STORE_NAME)
	end)

	if ok then
		store = result
	elseif IS_STUDIO then
		warn(
			"[DataService] DataStores aren't reachable from this Studio session, so progress won't be saved. "
				.. "Publish the place and turn on Game Settings > Security > Enable Studio Access to API Services "
				.. `to test saving. ({result})`
		)
	else
		warn(`[DataService] Couldn't open the DataStore: {result}`)
	end

	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)

	-- In Studio the local player can join before this script connects.
	for _, player in Players:GetPlayers() do
		task.spawn(onPlayerAdded, player)
	end

	game:BindToClose(onClose)
	task.spawn(autosaveLoop)
end

return DataService
