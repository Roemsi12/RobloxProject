--!strict
-- Decides what every enemy rig is doing, from what the server already reports:
-- idle or walking (from how fast its hitbox moves), an attack timed to the
-- telegraph, a stagger stretched over its real duration, and death.
--
-- Purely visual and per-client. RigAnimation does the playing.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local AnimationDefs = require(Shared.AnimationDefs)
local AttackChoreography = require(Shared.AttackChoreography)
local CombatConstants = require(Shared.CombatConstants)
local EnemyDefs = require(Shared.EnemyDefs)
local Remotes = require(Shared.Remotes)

local RigAnimation = require(script.Parent.RigAnimation)

local EnemyAnimation = {}

-- Server-side EnemyAI tags every enemy model with this.
local ENEMY_TAG = "Enemy"
local R15_JOINTS = 15
local RIG_WAIT_LIMIT = 10

-- Below this horizontal speed (studs per second) an enemy counts as standing.
local WALK_THRESHOLD = 0.5
-- Replicated positions arrive in steps rather than every frame, so speed is
-- smoothed before it picks between idle and walk.
local SPEED_SMOOTHING = 10

-- Long enough to land on the last frame of any death animation.
local SKIP_TO_END = 1e3

type Tracked = {
	controller: RigAnimation.Controller,
	root: BasePart,
	defId: string,
	lastPosition: Vector3,
	speed: number,
	dead: boolean,
}

local tracked: { [string]: Tracked } = {}

-- Latest alive/dead report per enemy, including ones whose rig hasn't
-- finished arriving yet — a player joining mid-fight can hear about a death
-- before they have the body to show it on.
local aliveById: { [string]: boolean } = {}
-- Last reported health, so a drop can be told apart from a respawn.
local healthById: { [string]: number } = {}

local countJoints = RigAnimation.countJoints

-- Starts animating an enemy rig, once the whole thing has replicated.
--
-- The model arrives before its joints do, so this waits for all fifteen
-- and for the PrimaryPart before building a controller. An enemy already
-- reported dead — a player joining mid-fight — is put straight onto the
-- last frame of its death rather than standing up first.
local function onEnemyAdded(instance: Instance)
	if not instance:IsA("Model") then
		return
	end

	local enemyId = instance:GetAttribute("EnemyId")
	local defId = instance:GetAttribute("EnemyDefId")
	if typeof(enemyId) ~= "string" or typeof(defId) ~= "string" or tracked[enemyId] then
		return
	end

	-- The joints replicate a moment after the model; wait for the whole rig.
	local waited = 0
	while
		(countJoints(instance) < R15_JOINTS or not instance.PrimaryPart)
		and instance.Parent
		and waited < RIG_WAIT_LIMIT
	do
		waited += task.wait(0.2)
	end

	local root = instance.PrimaryPart
	if not root or not instance.Parent or tracked[enemyId] then
		return
	end

	local controller = RigAnimation.new(instance, defId, false)
	RigAnimation.setBase(controller, "idle")

	local entry: Tracked = {
		controller = controller,
		root = root,
		defId = defId,
		lastPosition = root.Position,
		speed = 0,
		dead = aliveById[enemyId] == false,
	}
	tracked[enemyId] = entry

	if entry.dead then
		RigAnimation.playAction(controller, "death", { hold = true, elapsed = SKIP_TO_END })
	end
end

-- Stops tracking an enemy whose model has gone, releasing its controller
-- and any published tracks it loaded.
local function onEnemyRemoved(instance: Instance)
	local enemyId = instance:GetAttribute("EnemyId")
	if typeof(enemyId) ~= "string" then
		return
	end

	local entry = tracked[enemyId]
	if entry then
		RigAnimation.destroy(entry.controller)
		tracked[enemyId] = nil
	end
end

-- One frame for every tracked enemy: works out how fast it is actually
-- moving, picks idle or walk from that, and advances its animation.
--
-- Speed is measured from replicated positions, which arrive in steps
-- rather than every frame, so it is smoothed — without that an enemy
-- flickers between idle and walk between updates.
local function step(deltaTime: number)
	local dt = math.max(deltaTime, 1e-3)
	local smoothing = 1 - math.exp(-SPEED_SMOOTHING * dt)

	for _, entry in tracked do
		local position = entry.root.Position
		local moved = position - entry.lastPosition
		entry.lastPosition = position

		local instant = Vector3.new(moved.X, 0, moved.Z).Magnitude / dt
		entry.speed += (instant - entry.speed) * smoothing

		local controller = entry.controller
		if not entry.dead then
			local def = EnemyDefs[entry.defId]
			local moveSpeed = if def then def.moveSpeed else 0

			if moveSpeed > 0 and entry.speed > WALK_THRESHOLD then
				-- Stride tempo follows actual speed, within reason.
				RigAnimation.setBase(controller, "walk", math.clamp(entry.speed / moveSpeed, 0.5, 1.5))
			else
				RigAnimation.setBase(controller, "idle")
			end
		end

		RigAnimation.step(controller, dt)
	end
end

-- Freeze an enemy's pose for a moment as a blow lands. See RigAnimation.
function EnemyAnimation.hitStop(enemyId: string, seconds: number)
	local entry = tracked[enemyId]
	if entry and not entry.dead then
		RigAnimation.hitStop(entry.controller, seconds)
	end
end

-- Begins animating every tagged enemy, now and as they spawn, and wires
-- the server's combat events to what each rig should play. Runs its frame
-- step on PreSimulation, where a script's pose wins over the Animator's.
function EnemyAnimation.start()
	CollectionService:GetInstanceAddedSignal(ENEMY_TAG):Connect(onEnemyAdded)
	CollectionService:GetInstanceRemovedSignal(ENEMY_TAG):Connect(onEnemyRemoved)
	for _, instance in CollectionService:GetTagged(ENEMY_TAG) do
		task.spawn(onEnemyAdded, instance)
	end

	Remotes.get("EnemyTelegraphStart").OnClientEvent:Connect(function(payload)
		local entry = tracked[payload.enemyId]
		if not entry or entry.dead then
			return
		end

		-- Stretched so the strike lands on the server's impact time, and
		-- started part-way in if the message arrived late.
		local windupStarted = payload.impactTime - payload.duration

		-- Built here rather than looked up: the server sent a seed, and the
		-- same seed makes the same swing on every client and on the server's
		-- own reckoning of it. The tell inside it is fixed by the archetype,
		-- so the player reads something they already know however the rest of
		-- the arc happens to fall this time.
		local enemyDef = EnemyDefs[entry.defId]
		local attackDef = enemyDef and enemyDef.attacks[payload.attackId]
		local accent = if enemyDef then enemyDef.accent :: AttackChoreography.Accent? else nil
		local generated = nil

		if attackDef and typeof(payload.seed) == "number" then
			generated = AttackChoreography.generate({
				archetype = attackDef.archetype :: AttackChoreography.Archetype,
				leadTime = attackDef.leadTime,
				recovery = CombatConstants.RECOVER_DURATION,
				seed = payload.seed,
				accent = accent,
			})
		end

		RigAnimation.playAction(entry.controller, AnimationDefs.attack(payload.attackId), {
			windup = payload.duration,
			elapsed = Workspace:GetServerTimeNow() - windupStarted,
			def = generated,
		})
	end)

	Remotes.get("EnemyStaggered").OnClientEvent:Connect(function(payload)
		local entry = tracked[payload.enemyId]
		if not entry or entry.dead then
			return
		end

		-- A parry staggers; a player's hit only flinches.
		if payload.kind == "flinch" then
			RigAnimation.playAction(entry.controller, AnimationDefs.HURT)
		else
			RigAnimation.playAction(entry.controller, "stagger", { duration = payload.duration })
		end
	end)

	Remotes.get("EnemyHealthChanged").OnClientEvent:Connect(function(payload)
		aliveById[payload.enemyId] = payload.alive
		local previousHealth = healthById[payload.enemyId]
		healthById[payload.enemyId] = payload.health

		local entry = tracked[payload.enemyId]
		if not entry then
			return
		end

		local tookDamage = previousHealth ~= nil and payload.health < previousHealth
		if payload.alive and tookDamage and not entry.dead then
			-- A flinch only when nothing more important is playing: an attack
			-- must keep its timing, and a stagger or death says more than a
			-- flinch would.
			if RigAnimation.currentAction(entry.controller) == nil then
				RigAnimation.playAction(entry.controller, AnimationDefs.HURT)
			end
		elseif not payload.alive and not entry.dead then
			entry.dead = true
			RigAnimation.playAction(entry.controller, "death", { hold = true })
		elseif payload.alive and entry.dead then
			entry.dead = false
			RigAnimation.stopAction(entry.controller)
			RigAnimation.setBase(entry.controller, "idle")
		end
	end)

	-- After the Animator has run for this frame and before joints are applied.
	RunService.PreSimulation:Connect(step)
end

return EnemyAnimation
