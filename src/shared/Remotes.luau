--!strict
-- Every RemoteEvent in the game is created here and nowhere else
-- (ARCHITECTURE.md). Anything added must also get a row in that file's remote
-- registry table.
--
-- The server creates the instances; the client waits for them. Both sides call
-- Remotes.get(name) and neither needs to know which case it is in.
--
-- The list is fixed rather than created on first request, so a mistyped name
-- fails loudly instead of quietly creating a remote nobody listens to.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Remotes = {}

local FOLDER_NAME = "Remotes"

local REMOTE_EVENTS = {
	-- Client -> Server
	"ParryAttempt",
	"GuardReleased",
	"AttackRequest",
	"CriticalRequest",
	"FeintRequest",
	"DodgeRequest",
	"AbilityRequest",
	"EquipWeapon",
	"SpendSkillPoint",
	"ChestTakeItem",
	"SetAppearance",

	-- Server -> Client: combat
	"EnemyTelegraphStart",
	"ProjectileLaunched",
	"EnemyStaggered",
	"EnemyHealthChanged",
	"PlayerHit",
	"ParryResult",
	"AttackResult",
	"HealBurst",
	"PlayerCombatAction",
	"CombatStateChanged",

	-- Server -> Client: profile, equipment and economy
	"ProfileLoaded",
	"WeaponEquipped",
	"ChestOpened",
	"ChestContentsChanged",
	"InventoryUpdated",
	"CurrencyUpdated",
	"UpgradeResult",
	"ProgressionChanged",
	"LevelGained",
	"AppearanceChanged",
	"OpenAppearanceEditor",

	-- Server -> Client: the dungeon run
	"DungeonUpdated",
	"DungeonNotice",
	"BossEncounter",
	"DungeonQueueChanged",

	-- Server -> Client: PvP
	"PvPStatusChanged",
	"PvPTelegraphStart",
	"PvPParryResult",
	"PvPHealthChanged",
}

local folder: Folder? = nil

local function buildOnServer(): Folder
	local existing = ReplicatedStorage:FindFirstChild(FOLDER_NAME)
	if existing then
		return existing :: Folder
	end

	local created = Instance.new("Folder")
	created.Name = FOLDER_NAME

	for _, remoteName in REMOTE_EVENTS do
		local remote = Instance.new("RemoteEvent")
		remote.Name = remoteName
		remote.Parent = created
	end

	created.Parent = ReplicatedStorage
	return created
end

local function resolveFolder(): Folder
	if folder then
		return folder
	end

	if RunService:IsServer() then
		folder = buildOnServer()
	else
		folder = ReplicatedStorage:WaitForChild(FOLDER_NAME) :: Folder
	end

	return folder :: Folder
end

-- Call once from the server bootstrap, before anything tries to connect, so
-- the folder exists by the time clients start waiting on it.
function Remotes.init()
	assert(RunService:IsServer(), "Remotes.init must be called from the server")
	resolveFolder()
end

function Remotes.get(name: string): RemoteEvent
	local resolved = resolveFolder()

	-- The server built every remote up front, so anything missing there is a
	-- name that was never registered: fail immediately rather than waiting.
	if RunService:IsServer() then
		local remote = resolved:FindFirstChild(name)
		assert(remote, `Remote "{name}" is not registered — add it to REMOTE_EVENTS`)
		return remote :: RemoteEvent
	end

	local remote = resolved:WaitForChild(name, 10)
	assert(remote, `Remote "{name}" was never created — add it to REMOTE_EVENTS`)
	return remote :: RemoteEvent
end

return Remotes
