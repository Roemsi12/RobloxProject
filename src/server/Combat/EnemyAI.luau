--!strict
-- Enemy instances: rig construction, movement, death hooks, and per-enemy
-- state.
--
-- Decision-making lives in the pure AttackSelector; this module is the Roblox
-- half — spawning parts, moving them, and holding the mutable state the
-- selector is fed. Keeping the split means enemy behaviour stays testable
-- without a running game.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local AttackChain = require(Shared.AttackChain)
local AttackSelector = require(Shared.AttackSelector)
local EnemyDefs = require(Shared.EnemyDefs)
local RigAssembly = require(Shared.RigAssembly)
local RigDefs = require(Shared.RigDefs)

local EnemyAI = {}

-- CollectionService tag on every enemy model. Clients look enemies up by it.
EnemyAI.TAG = "Enemy"

-- The Roblox API, handed to RigAssembly — which the Lune workbench also runs,
-- with its own implementation of the same API.
local ROBLOX_API: RigAssembly.Api = {
	Instance = Instance,
	CFrame = CFrame,
	Vector3 = Vector3,
	Color3 = Color3,
	Enum = Enum,
}

-- "carry" is the gap between two links of a chain: the previous attack has
-- resolved and the next tell has not started. It is deliberately distinct from
-- "telegraph", because the two differ in exactly one way that matters -- an
-- enemy may reposition during a carry and may not during a wind-up.
export type EnemyState = "idle" | "telegraph" | "carry" | "staggered" | "flinched" | "dead"

-- Receives the player who landed the killing blow, or nil.
export type DeathCallback = (killer: Player?) -> ()

export type Enemy = {
	id: string,
	defId: string,
	def: EnemyDefs.EnemyDef,
	model: Model,
	root: BasePart,
	health: number,
	alive: boolean,
	state: EnemyState,
	-- attackId -> server time the attack becomes usable again.
	cooldowns: AttackSelector.CooldownMap,
	homeCFrame: CFrame,
	-- The room this enemy belongs to. nil means unleashed.
	bounds: AttackSelector.Bounds?,
	deathCallbacks: { DeathCallback },
}

local nextInstanceId = 0

function EnemyAI.spawn(
	defId: string,
	position: Vector3,
	facePosition: Vector3,
	bounds: AttackSelector.Bounds?,
	parent: Instance?
): Enemy
	local def = EnemyDefs[defId]
	assert(def, `Unknown enemy def "{defId}"`)

	nextInstanceId += 1
	local enemyId = `{defId}_{nextInstanceId}`

	local model = Instance.new("Model")
	model.Name = enemyId

	-- Flattened so the rig never tips.
	local homeCFrame = CFrame.lookAt(position, Vector3.new(facePosition.X, position.Y, facePosition.Z))

	-- The hitbox: invisible, anchored, and the only part that collides. Every
	-- position the combat code reasons about is this part's. Named like an R15
	-- root so the rig and its animations recognise it.
	local rootSize = RigDefs.rootSize(defId)
	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = Vector3.new(rootSize[1], rootSize[2], rootSize[3])
	root.Anchored = true
	root.Transparency = 1
	root.CFrame = homeCFrame
	root.Parent = model

	model.PrimaryPart = root

	-- The visible body hangs off the hitbox on Motor6D joints, so moving the
	-- root moves it all. Clients animate those joints; the server never does.
	RigAssembly.attach(ROBLOX_API, root, defId, model)
	RigAssembly.addAnimator(ROBLOX_API, model)

	-- Read by the client for telegraph VFX, so the client never needs its own
	-- registry of which model is which enemy. The tag lets clients find enemies
	-- wherever they're parented — the dungeon nests them inside a folder.
	model:SetAttribute("EnemyId", enemyId)
	model:SetAttribute("EnemyDefId", defId)
	CollectionService:AddTag(model, EnemyAI.TAG)

	model.Parent = parent or Workspace

	return {
		id = enemyId,
		defId = defId,
		def = def,
		model = model,
		root = root,
		health = def.maxHealth,
		alive = true,
		state = "idle",
		cooldowns = {},
		homeCFrame = homeCFrame,
		bounds = bounds,
		deathCallbacks = {},
	}
end

--[[ Death hooks ]]

-- Runs on every death, in registration order. A list rather than a single
-- slot because the listeners are genuinely independent: a guarded chest
-- unlocking and a kill payout both care about the same death.
function EnemyAI.onDeath(enemy: Enemy, callback: DeathCallback)
	table.insert(enemy.deathCallbacks, callback)
end

function EnemyAI.fireDeath(enemy: Enemy, killer: Player?)
	for _, callback in enemy.deathCallbacks do
		-- One misbehaving listener must not stop the others (a chest failing to
		-- unlock shouldn't also cost the killer their coins).
		local ok, err = pcall(callback, killer)
		if not ok then
			warn(`Death callback for {enemy.id} failed: {err}`)
		end
	end
end

--[[ Targeting ]]

-- Whether this enemy may act on something standing at `position`. A leashed
-- enemy only ever considers its own room.
function EnemyAI.canReach(enemy: Enemy, position: Vector3): boolean
	local bounds = enemy.bounds
	if not bounds then
		return true
	end

	return AttackSelector.isWithinBounds(bounds, position.X, position.Z)
end

--[[ Movement ]]

-- Anchored parts moved by CFrame rather than a Humanoid: the rigs are single
-- parts, and stepping them directly keeps server-side hit-reg reading the same
-- positions the AI reasoned about. Because that ignores walls, movement is
-- clamped to the enemy's room.
function EnemyAI.step(enemy: Enemy, targetPosition: Vector3, deltaTime: number)
	if not enemy.alive then
		return
	end

	local currentPosition = enemy.root.Position
	local toTarget = Vector3.new(
		targetPosition.X - currentPosition.X,
		0,
		targetPosition.Z - currentPosition.Z
	)

	local distance = toTarget.Magnitude
	-- Always face the player, even while stationary or staggered, so the
	-- telegraph is readable and hit-reg arcs mean what they look like.
	if distance > 1e-3 then
		enemy.root.CFrame = CFrame.lookAt(currentPosition, currentPosition + toTarget.Unit)
	end

	-- An enemy mid-windup is committed: letting it reposition during the
	-- telegraph would make the parry beat unreadable, since the hit would
	-- land somewhere other than where the tell said it would.
	--
	-- A carry is the other half of that argument rather than an exception to
	-- it. Between two links of a chain there is no tell on screen yet, so
	-- there is no beat to make unreadable -- and an enemy rooted for the whole
	-- of a three-link flurry would make "step back after the first hit" the
	-- answer to every chain in the game.
	if enemy.state ~= "idle" and enemy.state ~= "carry" then
		return
	end

	local intent = AttackSelector.movementIntent(enemy.def, distance)
	if intent == "hold" or intent == "idle" then
		return
	end

	local direction = if intent == "approach" then toTarget.Unit else -toTarget.Unit
	local travel = enemy.def.moveSpeed * deltaTime
	-- Never overshoot past the player on a long frame.
	travel = math.min(travel, math.max(distance - 1, 0))
	if travel <= 0 then
		return
	end

	local moved = currentPosition + direction * travel

	local bounds = enemy.bounds
	if bounds then
		local x, z = AttackSelector.clampToBounds(bounds, moved.X, moved.Z)
		moved = Vector3.new(x, moved.Y, z)
	end

	enemy.root.CFrame = CFrame.lookAt(moved, moved + toTarget.Unit)
end

--[[ Combat state ]]

function EnemyAI.chooseAttack(enemy: Enemy, distance: number, now: number): string?
	return AttackSelector.chooseAttack(enemy.def, distance, enemy.cooldowns, now)
end

-- The attack to throw out of `fromAttackId` without returning to neutral,
-- or nil when nothing legal follows it. Chain links may reach for attacks an
-- opener cannot (`chainOnly`), which is how an enemy gets a move that only
-- ever appears part way through a flurry.
function EnemyAI.chooseChainLink(enemy: Enemy, fromAttackId: string, distance: number, now: number): string?
	return AttackChain.chooseNext(enemy.def, fromAttackId, distance, enemy.cooldowns, now)
end

function EnemyAI.markAttackUsed(enemy: Enemy, attackId: string, now: number)
	local attack = enemy.def.attacks[attackId]
	enemy.cooldowns[attackId] = now + attack.cooldown
end

-- Returns true if this damage killed the enemy. Death hooks are fired by the
-- caller, which knows who landed the blow.
function EnemyAI.applyDamage(enemy: Enemy, amount: number): boolean
	if not enemy.alive then
		return false
	end

	enemy.health = math.max(enemy.health - amount, 0)
	if enemy.health > 0 then
		return false
	end

	enemy.alive = false
	enemy.state = "dead"
	return true
end

-- Respawning in place keeps the dungeon practicable: a guard comes back for
-- another go, though its chest stays unlocked.
function EnemyAI.revive(enemy: Enemy)
	enemy.health = enemy.def.maxHealth
	enemy.alive = true
	enemy.state = "idle"
	enemy.cooldowns = {}
	enemy.root.CanCollide = true
	enemy.root.CFrame = enemy.homeCFrame
end

-- Death is drawn on clients (a death animation, then a grey tint). The server
-- only lets players walk through the body.
function EnemyAI.markDead(enemy: Enemy)
	enemy.root.CanCollide = false
end

return EnemyAI
