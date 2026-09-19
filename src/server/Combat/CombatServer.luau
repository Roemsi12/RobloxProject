--!strict
-- The authority. Owns every enemy's state machine, resolves every hit in both
-- directions, and is the only place PvE damage or healing is applied.
--
-- The client's inputs are presses: block (with a timestamp), release, attack,
-- critical, feint, dodge (with a timestamp), and (in Studio only) a weapon id.
-- All are untrusted: timestamps are checked against the server's own estimate
-- of when they could have been sent, hits are resolved against server-side
-- positions, and cooldowns and stuns are the server's. The client never names
-- what it is hitting, parrying or dodging — the server works it out when each
-- hit lands.
--
-- How an enemy's hit on a player resolves, in order (runChain drives
-- runStrike, which ends in resolveParried or resolveLanded):
--   1. Dodging, with the hit inside the dodge's invulnerability: nothing lands.
--   2. A parryable hit inside the frames of the player's last block press, from
--      the front: parried. The attack is cancelled for everyone and the enemy
--      staggers.
--   3. Guarding against a parryable hit from the front: blocked. No health
--      lost; posture fills, and a full posture breaks the guard and stuns.
--   4. Otherwise: the hit lands, and stuns briefly.
--
-- This module also owns the input listeners for duels, routing a dueling
-- player's attacks to PvPCombatServer, so one press can never be handled twice.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local AbilityDefs = require(Shared.AbilityDefs)
local AttackChain = require(Shared.AttackChain)
local AttackSelector = require(Shared.AttackSelector)
local CombatConstants = require(Shared.CombatConstants)
local DamageMath = require(Shared.DamageMath)
local EnemyDefs = require(Shared.EnemyDefs)
local Loadout = require(Shared.Loadout)
local ParryMath = require(Shared.ParryMath)
local PostureMath = require(Shared.PostureMath)
local Remotes = require(Shared.Remotes)

local Characters = require(script.Parent.Characters)
local EnemyAI = require(script.Parent.EnemyAI)
local PlayerCombatState = require(script.Parent.PlayerCombatState)
local EquipService = require(script.Parent.Parent.EquipService)
local ProgressionService = require(script.Parent.Parent.Progression.ProgressionService)
local PvPCombatServer = require(script.Parent.Parent.PvP.PvPCombatServer)

local CombatServer = {}

-- Thrown attacks leave the enemy around chest height rather than its feet.
local PROJECTILE_HEIGHT = 3

-- Even point-blank, something thrown takes a moment to arrive — otherwise a
-- cornered Spitter's spit would land on the same frame it was spat.
local MIN_FLIGHT = 0.12

-- How far behind a target Shadowstep puts you: outside their own hitbox, and
-- inside your own reach.
local BLINK_STANDOFF = 5

-- Pause after an ability resolves before a swing can follow it, so an ability
-- is a commitment rather than a free extra hit in the middle of a combo.
local ABILITY_RECOVERY = 0.4

-- One key per branch of the skill tree.
local ABILITY_SLOTS = 3

type ActiveAttack = {
	enemyId: string,
	attackId: string,
	def: EnemyDefs.AttackDef,
	impactTime: number,
	-- Set by a player's hit during the windup (unless the attack has hyper
	-- armour): the attack is cancelled and the enemy flinches.
	interrupted: boolean,
	-- Where a thrown attack is going to land. Set at launch; the hit is then
	-- resolved around this point rather than around the enemy, which is what
	-- makes stepping aside after the throw work.
	landing: Vector3?,
}

-- The profile a player's swing resolves with: a combo step or a critical.
type SwingProfile = {
	range: number,
	arcDegrees: number,
	damageMultiplier: number,
}

local enemies: { [string]: EnemyAI.Enemy } = {}
-- Enemies that stay dead once killed: a dungeon run's rooms stay cleared.
local staysDead: { [string]: boolean } = {}
-- Keyed by enemyId: at most one wind-up per enemy, but many across the dungeon.
local activeAttacks: { [string]: ActiveAttack } = {}
-- enemyId -> server time before which the enemy can't be flinched again.
local flinchImmuneUntil: { [string]: number } = {}
local running = false

local function broadcastEnemyHealth(enemy: EnemyAI.Enemy)
	Remotes.get("EnemyHealthChanged"):FireAllClients({
		enemyId = enemy.id,
		health = enemy.health,
		maxHealth = enemy.def.maxHealth,
		alive = enemy.alive,
	})
end

-- Nearest living player this enemy may act on: inside its room, out of the
-- duel arena. Used for targeting and for deciding whether to act at all.
local function getTarget(enemy: EnemyAI.Enemy): (Player?, number)
	local position = enemy.root.Position
	local nearest: Player? = nil
	local nearestDistance = math.huge

	for _, player in Players:GetPlayers() do
		local root = Characters.getRoot(player)
		if not root or not Characters.isAlive(player) or PvPCombatServer.isDueling(player) then
			continue
		end

		if not EnemyAI.canReach(enemy, root.Position) then
			continue
		end

		local distance = DamageMath.horizontalDistance(Characters.flat(position), Characters.flat(root.Position))
		if distance < nearestDistance then
			nearest = player
			nearestDistance = distance
		end
	end

	return nearest, nearestDistance
end

--[[ Enemy attacks ]]
--
-- The longest section in the file, so it is signposted. Reading order is also
-- dependency order: each part uses the ones above it.
--
--   What a hit does to a player      bleeds, heals -- the effects themselves
--   Who a strike reaches             server-side hit detection at impact
--   Resolving a strike               parried, or landed. One or the other
--   Timing and state helpers         waiting, staggering, throwing
--   Throwing an attack               runStrike, runChain, and the AI loop

--[[ What a hit does to a player ]]

-- The effects a resolved strike applies, kept separate from deciding whether
-- it resolved that way at all.

-- Keeps ticking independently of the enemy, which may die, respawn or start
-- another attack while the player is still bleeding. Stops early if the
-- player's character is gone.
local function applyBleed(player: Player, enemy: EnemyAI.Enemy, attackId: string, dot: EnemyDefs.DotDef)
	task.spawn(function()
		for _ = 1, dot.ticks do
			task.wait(dot.tickInterval)

			local humanoid = Characters.getHumanoid(player)
			if not humanoid or humanoid.Health <= 0 then
				return
			end

			humanoid:TakeDamage(dot.tickDamage)
			Remotes.get("PlayerHit"):FireClient(player, {
				amount = dot.tickDamage,
				sourceId = enemy.id,
				attackId = attackId,
				bleed = true,
			})
		end
	end)
end

-- Burst heal for the parrying player and every living player near them. A
-- payoff read from WeaponDefs rather than a check on class name, so any
-- future weapon can carry it.
local function applyBurstHeal(healer: Player, amount: number, radius: number)
	local healerRoot = Characters.getRoot(healer)
	if not healerRoot then
		return
	end

	local origin = Characters.flat(healerRoot.Position)

	for _, player in Players:GetPlayers() do
		local root = Characters.getRoot(player)
		local humanoid = Characters.getHumanoid(player)
		if not root or not humanoid or humanoid.Health <= 0 then
			continue
		end

		if player ~= healer and DamageMath.horizontalDistance(origin, Characters.flat(root.Position)) > radius then
			continue
		end

		local before = humanoid.Health
		humanoid.Health = DamageMath.applyHealing(before, humanoid.MaxHealth, amount)

		local healed = humanoid.Health - before
		if healed > 0 then
			Remotes.get("HealBurst"):FireClient(player, { amount = healed, healerName = healer.Name })
		end
	end
end

--[[ Who a strike reaches, and who answered it ]]

-- Hit detection is server-side and runs at the moment of impact, against
-- server positions. The client never names what it hit.

type Victim = {
	player: Player,
	root: BasePart,
	state: PlayerCombatState.State,
	facing: boolean,
}

-- Everyone this strike's volume covers, with their state brought up to now.
local function collectVictims(enemy: EnemyAI.Enemy, attack: ActiveAttack, now: number): { Victim }
	local attackerPos = Characters.flat(enemy.root.Position)
	local attackerFacing = Characters.flat(enemy.root.CFrame.LookVector)

	-- A thrown attack hits around where it landed, not around whoever threw
	-- it: by the time it arrives the enemy may have moved, and the player
	-- certainly may have.
	local range = attack.def.range
	local arcDegrees = attack.def.arcDegrees
	local landing = attack.landing
	local projectile = attack.def.projectile
	if landing and projectile then
		attackerPos = Characters.flat(landing)
		range = projectile.radius
		arcDegrees = 360
	end

	local victims = {}

	for _, player in Players:GetPlayers() do
		local root = Characters.getRoot(player)
		if not root or not Characters.isAlive(player) or PvPCombatServer.isDueling(player) then
			continue
		end

		-- Server-side positions only. A client that teleports its local view
		-- out of the cone changes nothing here.
		local inVolume = DamageMath.isInHitVolume({
			attackerPos = attackerPos,
			attackerFacing = attackerFacing,
			targetPos = Characters.flat(root.Position),
			range = range,
			arcDegrees = arcDegrees,
		})
		if not inVolume then
			continue
		end

		table.insert(victims, {
			player = player,
			root = root,
			state = PlayerCombatState.sync(player, now),
			facing = DamageMath.isFacing(
				Characters.flat(root.Position),
				Characters.flat(root.CFrame.LookVector),
				attackerPos,
				CombatConstants.BLOCK_ARC_DEGREES
			),
		})
	end

	return victims
end

local function parries(victim: Victim, attack: ActiveAttack): boolean
	local pressAt = victim.state.parryPressAt
	if not attack.def.parryable or not victim.facing or not victim.state.parryFramesOpen or not pressAt then
		return false
	end
	if PlayerCombatState.isStunned(victim.state, attack.impactTime) then
		return false
	end

	local weaponId = EquipService.getWeaponId(victim.player)
	if not weaponId then
		return false
	end
	local parry = ParryMath.widen(Loadout.getDef(weaponId).parry, ProgressionService.modifiers(victim.player).parryWindow)
	return ParryMath.catches(pressAt, parry, attack.impactTime)
end

-- A strike that at least one player parried: nobody takes it, every parrier
-- gets their class payoff, and the enemy staggers for the longest of them.
-- Returns the stagger duration.
--[[ Resolving a strike ]]

-- Exactly one of these runs per strike: parried, or landed. Both are the end
-- of the line for that attack -- the enemy state they leave behind is what the
-- attack loop reads to decide whether a chain continues.

local function resolveParried(enemy: EnemyAI.Enemy, attack: ActiveAttack, parriers: { Victim }, now: number): number
	local staggerFor = 0

	for _, victim in parriers do
		local player = victim.player
		local state = victim.state
		local weapon = Loadout.getDef(EquipService.getWeaponId(player) :: string)
		local payoff = weapon.payoff

		state.parryCaught = true
		local restore = PlayerCombatState.limits(player).parryRestore
		PlayerCombatState.setPosture(state, PostureMath.afterParry(state.posture, restore), now, false)

		staggerFor = math.max(staggerFor, DamageMath.staggerDuration(CombatConstants.STAGGER_DURATION, payoff.staggerMultiplier))

		if payoff.riposteDuration > 0 then
			state.riposteUntil = now + payoff.riposteDuration
		end
		if payoff.burstHeal > 0 then
			local healing = payoff.burstHeal * (1 + ProgressionService.modifiers(player).healPower)
			applyBurstHeal(player, healing, payoff.burstHealRadius)
		end

		Remotes.get("ParryResult"):FireClient(player, {
			verdict = "parried",
			success = true,
			deltaMs = ((state.parryPressAt :: number) - attack.impactTime) * 1000,
			riposteUntil = state.riposteUntil,
			enemyId = enemy.id,
		})
		PlayerCombatState.publish(player)
	end

	return staggerFor
end

-- A strike nobody parried: dodged, blocked, broken through, or taken.
local function resolveLanded(enemy: EnemyAI.Enemy, attack: ActiveAttack, victims: { Victim }, now: number)
	for _, victim in victims do
		local player = victim.player
		local state = victim.state

		local mods = ProgressionService.modifiers(player)
		local iframes = CombatConstants.DODGE_IFRAMES + mods.dodgeIframes
		if ParryMath.withinWindow(state.dodgeStartedAt, iframes, attack.impactTime) then
			Remotes.get("PlayerHit"):FireClient(player, {
				amount = 0,
				sourceId = enemy.id,
				attackId = attack.attackId,
				dodged = true,
			})
			continue
		end

		local warded = now < state.wardUntil
		local incoming = DamageMath.resolveIncoming(attack.def.damage, false)
		if warded then
			incoming *= 1 - state.wardReduction
		end
		-- Not mid-swing or stunned: attacking out of a guard opens it.
		local guarding = state.guarding and not state.swinging and not PlayerCombatState.isStunned(state, now)
		local block = DamageMath.resolveBlock(
			incoming,
			guarding,
			attack.def.parryable,
			victim.facing,
			state.posture,
			PlayerCombatState.limits(player).max
		)
		PlayerCombatState.setPosture(state, block.posture, now, block.outcome ~= "unguarded")

		-- A warded guard doesn't break: the posture still empties, but the
		-- stun and the full hit that normally come with it don't.
		if block.outcome == "broken" and warded then
			block = { outcome = "blocked", damage = 0, posture = 0 }
		end

		if block.outcome == "broken" then
			state.guarding = false
			PlayerCombatState.stun(state, CombatConstants.GUARD_BREAK_STUN, now)
			PlayerCombatState.announce(player, "guard_end", EquipService.getWeaponId(player) or "")
		elseif block.outcome == "unguarded" then
			PlayerCombatState.stun(state, CombatConstants.PLAYER_HIT_STUN, now)
		end

		if block.damage > 0 then
			local humanoid = Characters.getHumanoid(player)
			if humanoid then
				-- TakeDamage rather than subtracting Health directly, so a
				-- ForceField is respected.
				humanoid:TakeDamage(block.damage)
			end
		end

		Remotes.get("PlayerHit"):FireClient(player, {
			amount = block.damage,
			sourceId = enemy.id,
			attackId = attack.attackId,
			blocked = block.outcome == "blocked",
			guardBroken = block.outcome == "broken",
		})
		PlayerCombatState.publish(player)

		-- A blocked hit doesn't open a wound.
		local dot = attack.def.dot
		if dot and block.outcome ~= "blocked" then
			applyBleed(player, enemy, attack.attackId, dot)
		end
	end
end

-- Waits until `deadline`, returning early if the attack is interrupted or the
-- enemy dies. Polled on Heartbeat because the wait has to be interruptible.
--[[ Timing and state helpers ]]

-- Waiting, staggering and throwing things, shared by every path above.

local function waitUntilOrInterrupted(deadline: number, enemy: EnemyAI.Enemy, attack: ActiveAttack)
	while Workspace:GetServerTimeNow() < deadline do
		if attack.interrupted or not enemy.alive then
			return
		end
		RunService.Heartbeat:Wait()
	end
end

local function holdEnemyState(enemy: EnemyAI.Enemy, state: EnemyAI.EnemyState, kind: string, duration: number)
	enemy.state = state
	Remotes.get("EnemyStaggered"):FireAllClients({
		enemyId = enemy.id,
		duration = duration,
		kind = kind,
	})
	task.wait(duration)
	if enemy.alive and enemy.state == state then
		enemy.state = "idle"
	end
end

-- Sends a thrown attack on its way, aimed at where its target is standing
-- right now. Returns how long it will be in the air, or 0 if there was
-- nothing to throw it at.
--
-- The aim is fixed at launch and the flight time is the window to move: a
-- ranged enemy you can see winding up should be one you can step around,
-- rather than a damage tick that arrives wherever you are.
local function launchProjectile(enemy: EnemyAI.Enemy, attack: ActiveAttack, projectile: EnemyDefs.ProjectileDef): number
	local target = getTarget(enemy)
	local root = target and Characters.getRoot(target)
	if not root then
		return 0
	end

	local origin = enemy.root.Position + Vector3.new(0, PROJECTILE_HEIGHT, 0)
	local landing = root.Position
	local flight = math.max((landing - origin).Magnitude / projectile.speed, MIN_FLIGHT)

	attack.landing = landing

	Remotes.get("ProjectileLaunched"):FireAllClients({
		enemyId = enemy.id,
		attackId = attack.attackId,
		kind = projectile.kind,
		origin = origin,
		landing = landing,
		flight = flight,
		radius = projectile.radius,
	})

	return flight
end

--[[ Throwing an attack ]]

-- The loop itself: one strike, then however many links follow it. Everything
-- above is what a strike *does*; this is when it happens.

-- What a single strike did, so `runChain` can decide whether to keep going.
--
-- `impactTime` and `seed` are the two things a follow-up needs: the first
-- positions the link against the hitstun the player is in, the second is what
-- lets every client rebuild the carry pose this strike ended on, since
-- AttackChoreography is pure.
type StrikeOutcome = "landed" | "parried" | "interrupted" | "gone"

type StrikeResult = {
	outcome: StrikeOutcome,
	impactTime: number,
	seed: number,
}

-- Where in a chain a strike sits. The opener is index 1 with no `from`.
type StrikeContext = {
	index: number,
	-- Whether another link follows. Decided *before* the strike is thrown,
	-- because it is what makes the animation end held in its carry pose
	-- rather than standing back up -- and that unfinished silhouette is the
	-- only cue a player gets that the flurry is not over.
	carryOut: boolean,
	from: StrikeResult?,
	fromAttackId: string?,
}

-- One attack, from the start of its wind-up to the moment it resolves.
--
-- Deliberately does not handle recovery: a chain pays one recovery at the
-- end, not one per link, so that belongs to `runChain`.
local function runStrike(enemy: EnemyAI.Enemy, attackId: string, context: StrikeContext): StrikeResult
	local attackDef = enemy.def.attacks[attackId]
	local isLink = context.from ~= nil
	local seed = math.random(0, 65535)

	-- A link settles faster than an attack from neutral, because the rig
	-- starts already wound. Both sides derive this from the same lead time
	-- rather than one sending the other a duration.
	local telegraph = if isLink
		then AttackChain.telegraphOf(attackDef.leadTime)
		else attackDef.telegraphDuration

	if isLink then
		-- Hold the carry pose until the link is allowed to start. This is
		-- where the hitstun clamp is actually paid: the link cannot land
		-- before the player has had time to read it, and that is bought by
		-- waiting here rather than by hoping the tell is long enough.
		local timing = AttackChain.linkTiming(
			(context.from :: StrikeResult).impactTime,
			attackDef.leadTime,
			attackDef.parryable
		)
		-- "carry", not "telegraph". The only difference between the two is
		-- that an enemy may reposition during a carry: there is no tell on
		-- screen to make unreadable yet, and a Shambler rooted for a whole
		-- three-link flurry would make stepping back the answer to every
		-- chain. It also keeps `runEnemyLoop` out, since that only starts an
		-- attack on an idle enemy.
		enemy.state = "carry"

		local waitFor = timing.startsAt - Workspace:GetServerTimeNow()
		if waitFor > 0 then
			task.wait(waitFor)
		end

		-- Anything that moved the enemy off "carry" during the gap -- a flinch
		-- from a player hitting into the flurry, a stagger, death -- ends the
		-- chain here. That is what makes hitting into a chain break it.
		if not enemy.alive or enemy.state ~= "carry" then
			return { outcome = "gone", impactTime = 0, seed = seed }
		end
	end

	local now = Workspace:GetServerTimeNow()

	local attack: ActiveAttack = {
		enemyId = enemy.id,
		attackId = attackId,
		def = attackDef,
		impactTime = now + telegraph,
		interrupted = false,
		landing = nil,
	}

	activeAttacks[enemy.id] = attack
	enemy.state = "telegraph"
	EnemyAI.markAttackUsed(enemy, attackId, now)

	-- The client needs impactTime, not just the duration, so its animation
	-- stays in step even if this message is delayed in transit.
	--
	-- `seed` is the whole of the attack's shape. Every client builds the same
	-- swing from it (AttackChoreography is pure and its variation is a hash,
	-- not a sequence), so an attack that is different every time costs one
	-- number on the wire rather than a keyframe timeline. The tell it wears
	-- and how long that tell is held come from EnemyDefs, which every client
	-- already has.
	--
	-- The chain fields are the same idea one level up: `fromAttackId` and
	-- `fromSeed` are enough for a client to rebuild the exact carry pose the
	-- previous strike ended on, because `AttackChoreography.carryPose` is
	-- pure. Sending `chainIndex` rather than a computed duration means both
	-- sides call the same `linkTiming` -- one less number that can drift.
	Remotes.get("EnemyTelegraphStart"):FireAllClients({
		enemyId = enemy.id,
		attackId = attackId,
		duration = telegraph,
		impactTime = attack.impactTime,
		parryable = attackDef.parryable,
		seed = seed,
		chainIndex = context.index,
		chainLast = not context.carryOut,
		fromAttackId = context.fromAttackId,
		fromSeed = if context.from then (context.from :: StrikeResult).seed else nil,
	})

	-- Held open past impact so a block press made just before the hit, or a
	-- dodge, has time to arrive. See STRIKE_RESOLUTION_GRACE.
	waitUntilOrInterrupted(attack.impactTime + CombatConstants.STRIKE_RESOLUTION_GRACE, enemy, attack)

	if not enemy.alive then
		activeAttacks[enemy.id] = nil
		return { outcome = "gone", impactTime = attack.impactTime, seed = seed }
	end

	if attack.interrupted then
		activeAttacks[enemy.id] = nil
		holdEnemyState(enemy, "flinched", "flinch", CombatConstants.ENEMY_FLINCH_DURATION)
		return { outcome = "interrupted", impactTime = attack.impactTime, seed = seed }
	end

	-- A thrown attack leaves the enemy at the end of the telegraph and lands
	-- later. Once it is in the air it can't be interrupted — the enemy has
	-- already let go — so the flinch check above is the last one.
	local projectile = attackDef.projectile
	if projectile then
		local flight = launchProjectile(enemy, attack, projectile)
		if flight <= 0 then
			activeAttacks[enemy.id] = nil
			return { outcome = "gone", impactTime = attack.impactTime, seed = seed }
		end
		-- The parry is judged against the moment it arrives, not the throw.
		attack.impactTime += flight
		task.wait(flight)

		if not enemy.alive then
			activeAttacks[enemy.id] = nil
			return { outcome = "gone", impactTime = attack.impactTime, seed = seed }
		end
	end

	activeAttacks[enemy.id] = nil

	local resolvedAt = Workspace:GetServerTimeNow()
	local victims = collectVictims(enemy, attack, resolvedAt)

	local parriers = {}
	for _, victim in victims do
		if parries(victim, attack) then
			table.insert(parriers, victim)
		end
	end

	if #parriers > 0 then
		local staggerFor = resolveParried(enemy, attack, parriers, resolvedAt)
		holdEnemyState(enemy, "staggered", "stagger", staggerFor)
		return { outcome = "parried", impactTime = attack.impactTime, seed = seed }
	end

	resolveLanded(enemy, attack, victims, resolvedAt)
	return { outcome = "landed", impactTime = attack.impactTime, seed = seed }
end

-- An opener and however many links follow it.
--
-- The saving is structural: one RECOVER_DURATION and one attackInterval per
-- *chain* rather than per attack. Without this an enemy spends 1.4-2.0s
-- standing still between swings, which is where "slow and passive" came from.
--
-- The follow-up is chosen before the current strike is thrown, because that
-- decision changes how the current strike *ends* -- held in its carry pose,
-- or standing back up.
local function runChain(enemy: EnemyAI.Enemy, openerId: string)
	local maxLinks = AttackChain.maxLinks(enemy.def)
	local attackId: string? = openerId
	local previous: StrikeResult? = nil
	local previousId: string? = nil
	local index = 1

	while attackId do
		local _, distance = getTarget(enemy)
		local now = Workspace:GetServerTimeNow()

		-- Decide the follow-up first: `carryOut` depends on it.
		local nextId: string? = nil
		if index < maxLinks and AttackChain.wantsAnother(enemy.def) then
			nextId = EnemyAI.chooseChainLink(enemy, attackId, distance, now)
		end

		local result = runStrike(enemy, attackId, {
			index = index,
			carryOut = nextId ~= nil,
			from = previous,
			fromAttackId = previousId,
		})

		-- A parry, a flinch or a death ends the chain, and each of those has
		-- already put the enemy into the state it belongs in. Hitting into a
		-- flurry to break it is the aggressive answer to one, and it only
		-- works because this stops here.
		if result.outcome ~= "landed" then
			-- ...except "gone", which covers an attack abandoned rather than
			-- answered -- a thrown attack whose target walked out of reach
			-- before it let go. Nothing has moved the enemy out of
			-- "telegraph" in that case, and `runEnemyLoop` only ever acts on
			-- an idle enemy, so leaving it would freeze that enemy for good:
			-- no attacks, no movement, until something killed it. Guarded, so
			-- it cannot clobber a stagger or a flinch that did run.
			if enemy.alive and enemy.state == "telegraph" then
				enemy.state = "idle"
			end
			return
		end

		previous = result
		previousId = attackId
		attackId = nextId
		index += 1
	end

	-- One recovery for the whole chain, lengthened by each extra link. That
	-- bonus is what makes a chain a risk the enemy takes rather than a
	-- straight buff: a long flurry leaves it open for longer afterwards, so
	-- baiting one out is worth doing.
	local links = index - 1
	local recovery = CombatConstants.RECOVER_DURATION + math.max(0, links - 1) * AttackChain.RECOVER_BONUS
	task.wait(recovery)

	if enemy.alive and enemy.state == "telegraph" then
		enemy.state = "idle"
	end
end

-- One loop per enemy, so a staggered enemy doesn't hold up another. Each loop
-- only ever touches its own enemy's state.
local function runEnemyLoop(enemy: EnemyAI.Enemy)
	-- Ends when the enemy is despawned, not just when it dies: a dead enemy
	-- that will respawn keeps its loop.
	while running and enemies[enemy.id] == enemy do
		task.wait(enemy.def.attackInterval)

		if not running then
			break
		end

		if not enemy.alive or enemy.state ~= "idle" then
			continue
		end

		local target, distance = getTarget(enemy)
		if not target or distance > enemy.def.aggroRange then
			continue
		end

		local attackId = EnemyAI.chooseAttack(enemy, distance, Workspace:GetServerTimeNow())
		if attackId then
			runChain(enemy, attackId)
		end
	end
end

--[[ Kills ]]

local function onEnemyKilled(enemy: EnemyAI.Enemy, killer: Player)
	EnemyAI.markDead(enemy)
	-- Chest unlocks and payouts hang off this.
	EnemyAI.fireDeath(enemy, killer)

	if staysDead[enemy.id] then
		return
	end

	task.delay(CombatConstants.ENEMY_RESPAWN_DELAY, function()
		if running and enemies[enemy.id] == enemy then
			EnemyAI.revive(enemy)
			broadcastEnemyHealth(enemy)
		end
	end)
end

--[[ Player swings ]]

local function attackResult(player: Player, payload: { [string]: any })
	Remotes.get("AttackResult"):FireClient(player, payload)
end

-- A player's hit interrupts the enemy: a windup without hyper armour is
-- cancelled, and an idle enemy's next move is pushed back. Then it's immune
-- for a moment, so its next attack comes through.
local function flinch(enemy: EnemyAI.Enemy, now: number)
	if now < (flinchImmuneUntil[enemy.id] or 0) then
		return
	end

	if enemy.state == "telegraph" then
		local attack = activeAttacks[enemy.id]
		if attack then
			if attack.def.hyperArmor then
				return
			end
			attack.interrupted = true
		else
			-- Still flagged "telegraph", but the attack has already resolved
			-- and been cleared: the enemy is in its recovery. That is the
			-- punish window, and it used to be the one place a hit did
			-- nothing at all -- this branch read `activeAttacks`, found
			-- nothing, and returned without even setting flinch immunity, so
			-- enemies were unflinchable for RECOVER_DURATION after every
			-- single attack. Hitting a recovering enemy now staggers it,
			-- which is what makes baiting an attack out worth doing.
			task.spawn(holdEnemyState, enemy, "flinched", "flinch", CombatConstants.ENEMY_FLINCH_DURATION)
		end
	elseif enemy.state == "idle" or enemy.state == "carry" then
		-- "carry" is the gap between two links of a chain. Breaking one by
		-- hitting into it is the aggressive answer to a flurry, and it works
		-- because the flinch moves the enemy off "carry", which is the exact
		-- condition the next link checks before it fires.
		task.spawn(holdEnemyState, enemy, "flinched", "flinch", CombatConstants.ENEMY_FLINCH_DURATION)
	else
		return
	end

	flinchImmuneUntil[enemy.id] = now + CombatConstants.ENEMY_FLINCH_IMMUNITY
end

-- Nearest enemy inside the swing volume. Swings hit one target: cleave across
-- a group is a weapon property that doesn't exist yet, and giving it away free
-- would trivialise multi-enemy fights.
local function findSwingTarget(root: BasePart, profile: SwingProfile): EnemyAI.Enemy?
	local attackerPos = Characters.flat(root.Position)
	local attackerFacing = Characters.flat(root.CFrame.LookVector)

	local best: EnemyAI.Enemy? = nil
	local bestDistance = math.huge

	for _, enemy in enemies do
		if not enemy.alive then
			continue
		end

		local targetPos = Characters.flat(enemy.root.Position)
		local inVolume = DamageMath.isInHitVolume({
			attackerPos = attackerPos,
			attackerFacing = attackerFacing,
			targetPos = targetPos,
			range = profile.range,
			arcDegrees = profile.arcDegrees,
		})

		if not inVolume then
			continue
		end

		local distance = DamageMath.horizontalDistance(attackerPos, targetPos)
		if distance < bestDistance then
			best = enemy
			bestDistance = distance
		end
	end

	return best
end

local function resolveSwing(player: Player, weaponId: string, profile: SwingProfile, swingId: number)
	-- Left during the windup. Touching their state now would re-create a record
	-- that PlayerRemoving has already cleared.
	if not player.Parent then
		return
	end

	-- Cancelled by a feint, a dodge, or being hit.
	local state = PlayerCombatState.peek(player)
	if state.swingId ~= swingId then
		return
	end
	state.swinging = false

	local weapon = Loadout.getDef(weaponId)
	local root = Characters.getRoot(player)
	if not root then
		attackResult(player, { hit = false, reason = "no_target", damage = 0, riposte = false })
		return
	end

	local target = findSwingTarget(root, profile)
	if not target then
		local now = Workspace:GetServerTimeNow()
		state.attackReadyAt = math.max(state.attackReadyAt, now + CombatConstants.MISS_RECOVERY)
		state.comboStep = 0
		state.comboExpiresAt = 0
		attackResult(player, { hit = false, reason = "missed", damage = 0, riposte = false })
		PlayerCombatState.publish(player)
		return
	end

	local now = Workspace:GetServerTimeNow()
	local riposteActive = now < state.riposteUntil
	local mods = ProgressionService.modifiers(player)

	-- Struck from behind: the Assassin's payoff, and the one effect in the
	-- game that depends on where you are standing. Read off the enemy's own
	-- facing rather than the player's, using the same arc a block uses.
	local behind = not DamageMath.isFacing(
		Characters.flat(target.root.Position),
		Characters.flat(target.root.CFrame.LookVector),
		Characters.flat(root.Position),
		CombatConstants.BLOCK_ARC_DEGREES
	)
	local backstab = if behind then mods.backstab else 0

	local base = EquipService.getDamage(player, weaponId) * profile.damageMultiplier
	local damage = DamageMath.resolveOutgoing(base * (1 + mods.damage + backstab), {
		targetStaggered = target.state == "staggered",
		riposteActive = riposteActive,
		riposteMultiplier = weapon.payoff.riposteMultiplier + mods.riposte,
	})

	local killed = EnemyAI.applyDamage(target, damage)
	if not killed then
		flinch(target, now)
	end

	attackResult(player, {
		hit = true,
		reason = "hit",
		damage = damage,
		riposte = riposteActive,
		enemyId = target.id,
	})
	broadcastEnemyHealth(target)

	if killed then
		onEnemyKilled(target, player)
	end
end

-- Checks shared by every attack press. Returns the weapon id if the player
-- may attack now.
local function canAttack(player: Player, state: PlayerCombatState.State, now: number): string?
	local weaponId = EquipService.getWeaponId(player)
	if not weaponId then
		attackResult(player, { hit = false, reason = "unequipped", damage = 0, riposte = false })
		return nil
	end

	if PlayerCombatState.isStunned(state, now) then
		attackResult(player, { hit = false, reason = "stunned", damage = 0, riposte = false })
		return nil
	end

	-- Blocking and attacking are exclusive: let go of block to swing.
	if state.guarding then
		attackResult(player, { hit = false, reason = "guarding", damage = 0, riposte = false })
		return nil
	end

	if state.swinging or now < state.attackReadyAt then
		attackResult(player, { hit = false, reason = "cooldown", damage = 0, riposte = false })
		return nil
	end

	return weaponId
end

local function startSwing(player: Player, state: PlayerCombatState.State, weaponId: string, windup: number, profile: SwingProfile, now: number)
	state.swingId += 1
	state.swinging = true
	state.swingStartedAt = now
	state.swingWindup = windup

	-- The weapon and profile are captured now, so a swap landing mid-windup
	-- cannot change what this swing resolves as.
	task.delay(windup, resolveSwing, player, weaponId, profile, state.swingId)
end

local function onAttackRequest(player: Player)
	if PvPCombatServer.isDueling(player) then
		PvPCombatServer.handleAttack(player)
		return
	end

	local now = Workspace:GetServerTimeNow()
	local state = PlayerCombatState.sync(player, now)
	local weaponId = canAttack(player, state, now)
	if not weaponId then
		return
	end

	local attack = Loadout.getDef(weaponId).attack
	local step = Loadout.nextComboStep(attack, state.comboStep, now, state.comboExpiresAt)
	local timing = Loadout.swingTiming(attack, step)

	state.attackReadyAt = now + timing.readyAfter
	state.comboStep = step
	state.comboExpiresAt = now + timing.comboExpiresAfter

	PlayerCombatState.announce(player, "swing", weaponId, timing.windup, step)
	startSwing(player, state, weaponId, timing.windup, {
		range = attack.range,
		arcDegrees = attack.arcDegrees,
		damageMultiplier = timing.damageMultiplier,
	}, now)
end

local function onCriticalRequest(player: Player)
	-- Criticals are a dungeon move for now; duels keep to the opening swing.
	if PvPCombatServer.isDueling(player) then
		return
	end

	local now = Workspace:GetServerTimeNow()
	local state = PlayerCombatState.sync(player, now)
	local weaponId = canAttack(player, state, now)
	if not weaponId then
		return
	end

	if now < state.criticalReadyAt then
		attackResult(player, { hit = false, reason = "cooldown", damage = 0, riposte = false })
		return
	end

	local attack = Loadout.getDef(weaponId).attack
	local critical = attack.critical

	local mods = ProgressionService.modifiers(player)
	state.criticalReadyAt = now + critical.cooldown * (1 - mods.criticalCooldown)
	state.attackReadyAt = now + critical.windup + attack.finisherRecovery
	state.comboStep = 0

	PlayerCombatState.announce(player, "critical", weaponId, critical.windup)
	startSwing(player, state, weaponId, critical.windup, {
		range = critical.range,
		arcDegrees = critical.arcDegrees,
		damageMultiplier = critical.damageMultiplier * (1 + mods.criticalDamage),
	}, now)
	PlayerCombatState.publish(player)
end

-- Cancels a swing early in its windup: the tool for baiting a parry.
local function onFeintRequest(player: Player)
	local now = Workspace:GetServerTimeNow()
	local state = PlayerCombatState.peek(player)
	if now < state.feintReadyAt or not PlayerCombatState.inCancelWindow(state, now) then
		return
	end

	PlayerCombatState.cancelSwing(state)
	state.attackReadyAt = now
	state.feintReadyAt = now + CombatConstants.FEINT_COOLDOWN
	PlayerCombatState.announce(player, "feint", EquipService.getWeaponId(player) or "")
end

--[[ Defence ]]

-- Validates a timestamped press. Returns the claimed time if believable.
local function validatedTimestamp(player: Player, payload: unknown, now: number): number?
	if typeof(payload) ~= "table" then
		return nil
	end

	local attemptTime = (payload :: any).timestamp
	if typeof(attemptTime) ~= "number" or attemptTime ~= attemptTime then
		return nil
	end

	if ParryMath.validateTimestamp(attemptTime, now, Characters.halfPing(player)) then
		return nil
	end
	return attemptTime
end

-- The block key going down: raises the guard, and opens parry frames unless
-- the last press missed and parrying is still on cooldown.
local function onParryAttempt(player: Player, payload: unknown)
	local now = Workspace:GetServerTimeNow()
	local attemptTime = validatedTimestamp(player, payload, now)
	local weaponId = EquipService.getWeaponId(player)
	if not attemptTime or not weaponId then
		return
	end

	local state = PlayerCombatState.sync(player, now)
	if PlayerCombatState.isStunned(state, now) then
		return
	end

	state.guarding = true

	local profile = Loadout.getDef(weaponId).parry
	state.parryFramesOpen = ParryMath.pressOpensFrames(state.parryPressAt, state.parryCaught, profile, now)
	if state.parryFramesOpen then
		state.parryPressAt = attemptTime
		state.parryCaught = false
	end

	-- Nothing is judged now: whatever this press catches is decided when each
	-- hit lands, against enemies and duel opponents alike.
	PlayerCombatState.announce(player, "parry", weaponId)
end

local function onGuardReleased(player: Player)
	local state = PlayerCombatState.peek(player)
	if not state.guarding then
		return
	end

	state.guarding = false
	PlayerCombatState.announce(player, "guard_end", EquipService.getWeaponId(player) or "")
end

-- The dodge roll. Invulnerable from the press for DODGE_IFRAMES; cancels a
-- swing still early in its windup, and drops the guard.
local function onDodgeRequest(player: Player, payload: unknown)
	local now = Workspace:GetServerTimeNow()
	local attemptTime = validatedTimestamp(player, payload, now)
	if not attemptTime then
		return
	end

	local state = PlayerCombatState.sync(player, now)
	if PlayerCombatState.isStunned(state, now) or now < state.dodgeReadyAt then
		return
	end

	if state.swinging then
		if not PlayerCombatState.inCancelWindow(state, now) then
			return
		end
		PlayerCombatState.cancelSwing(state)
		state.attackReadyAt = now
	end

	state.guarding = false
	state.dodgeStartedAt = attemptTime
	local dodgeCooldown = CombatConstants.DODGE_COOLDOWN * (1 - ProgressionService.modifiers(player).dodgeCooldown)
	state.dodgeReadyAt = now + dodgeCooldown

	-- The direction is the client's to choose and nothing turns on it, so it
	-- is passed on once it has been checked against the four that exist.
	local direction = PlayerCombatState.rollDirection((payload :: any).direction)
	PlayerCombatState.announce(player, "dodge", EquipService.getWeaponId(player) or "", nil, nil, direction)
	PlayerCombatState.publish(player)
end

--[[ Abilities ]]

-- One signature move per weapon (AbilityDefs), on Z. Implemented here rather
-- than in a service of its own because everything it needs — the enemy table,
-- the stagger helper, the kill path, the burst heal — is already here, and a
-- second module would have to be handed all of it.

-- Everything alive inside a cone (or a full circle) around the caster.
local function enemiesAround(origin: Vector3, facing: Vector3, radius: number, arcDegrees: number): { EnemyAI.Enemy }
	local found = {}
	local flatOrigin = Characters.flat(origin)
	local flatFacing = Characters.flat(facing)

	for _, enemy in enemies do
		if not enemy.alive then
			continue
		end
		local inVolume = DamageMath.isInHitVolume({
			attackerPos = flatOrigin,
			attackerFacing = flatFacing,
			targetPos = Characters.flat(enemy.root.Position),
			range = radius,
			arcDegrees = arcDegrees,
		})
		if inVolume then
			table.insert(found, enemy)
		end
	end

	return found
end

local function hitWithAbility(player: Player, enemy: EnemyAI.Enemy, damage: number, stagger: number)
	local killed = EnemyAI.applyDamage(enemy, damage)
	broadcastEnemyHealth(enemy)

	if killed then
		onEnemyKilled(enemy, player)
		return
	end

	if stagger > 0 then
		-- Staggered rather than flinched: an ability you waited fourteen
		-- seconds for should open an enemy properly, not just interrupt it.
		local attack = activeAttacks[enemy.id]
		if attack then
			attack.interrupted = true
		end
		task.spawn(holdEnemyState, enemy, "staggered", "stagger", stagger)
	end
end

-- A burst: everything around the caster takes it, and all of it opens up.
local function castBurst(player: Player, root: BasePart, def: AbilityDefs.AbilityDef, power: number)
	for _, enemy in enemiesAround(root.Position, root.CFrame.LookVector, def.radius, def.arcDegrees) do
		hitWithAbility(player, enemy, power, def.stagger)
	end
end

-- A blink: behind the nearest enemy in front, then a strike from there. The
-- move is the ability; whatever the tree pays for hitting a back is the
-- branch's, and taking both is the point.
local function castBlink(player: Player, root: BasePart, def: AbilityDefs.AbilityDef, power: number)
	local candidates = enemiesAround(root.Position, root.CFrame.LookVector, def.radius, def.arcDegrees)

	local target: EnemyAI.Enemy? = nil
	local nearest = math.huge
	for _, enemy in candidates do
		local distance = DamageMath.horizontalDistance(Characters.flat(root.Position), Characters.flat(enemy.root.Position))
		if distance < nearest then
			target = enemy
			nearest = distance
		end
	end

	if not target then
		return
	end

	local enemy = target :: EnemyAI.Enemy
	local behind = enemy.root.Position - enemy.root.CFrame.LookVector * BLINK_STANDOFF
	-- Kept at the caster's own height: the enemy may be a different size, and
	-- landing inside the floor or above it would both be worse than landing
	-- next to them.
	local landing = Vector3.new(behind.X, root.Position.Y, behind.Z)
	root.CFrame = CFrame.lookAt(landing, Vector3.new(enemy.root.Position.X, landing.Y, enemy.root.Position.Z))

	hitWithAbility(player, enemy, power, def.stagger)
end

-- A mend: the Healer's rescue, which unlike the parry heal asks nothing of
-- you first.
local function castMend(player: Player, _root: BasePart, def: AbilityDefs.AbilityDef, power: number)
	applyBurstHeal(player, power, def.radius)
end

-- A ward: for a few seconds, less damage and a guard that holds.
local function castWard(player: Player, state: PlayerCombatState.State, resolved: AbilityDefs.Resolved, now: number)
	state.wardUntil = now + resolved.duration
	state.wardReduction = resolved.power
	PlayerCombatState.publish(player)
end

-- Which ability the player has on this key, if any. Read from the tree every
-- time rather than cached: a point spent mid-fight should work immediately,
-- and the tree is the only thing that decides this.
local function abilityInSlot(player: Player, slot: number): AbilityDefs.AbilityDef?
	local weaponId = EquipService.getWeaponId(player)
	if not weaponId then
		return nil
	end

	local abilityId = ProgressionService.abilities(player)[slot]
	return if abilityId then AbilityDefs.get(abilityId) else nil
end

local function onAbilityRequest(player: Player, payload: unknown)
	if type(payload) ~= "table" or PvPCombatServer.isDueling(player) then
		return
	end

	local slot = (payload :: { [string]: any }).slot
	if type(slot) ~= "number" or slot < 1 or slot > ABILITY_SLOTS or slot ~= math.floor(slot) then
		return
	end

	-- Unlocked in the tree, or there is nothing on this key.
	local def = abilityInSlot(player, slot)
	if not def then
		return
	end

	local now = Workspace:GetServerTimeNow()
	local state = PlayerCombatState.sync(player, now)
	local readyAt = state.abilityReadyAt[slot] or 0
	if PlayerCombatState.isStunned(state, now) or now < readyAt or not Characters.isAlive(player) then
		return
	end

	-- A swing in progress is given up for it, on the same terms a dodge is.
	if state.swinging then
		if not PlayerCombatState.inCancelWindow(state, now) then
			return
		end
		PlayerCombatState.cancelSwing(state)
	end

	local mods = ProgressionService.modifiers(player)
	local resolved = AbilityDefs.resolve(def, mods.abilityCooldown, mods.abilityPower)

	state.guarding = false
	state.abilityReadyAt[slot] = now + resolved.cooldown
	state.attackReadyAt = math.max(state.attackReadyAt, now + def.windup + ABILITY_RECOVERY)

	PlayerCombatState.announce(player, "ability", EquipService.getWeaponId(player) or "", def.windup)
	PlayerCombatState.publish(player)

	-- Resolved after the windup, so it can be seen coming like everything
	-- else in this game.
	task.delay(def.windup, function()
		local castRoot = Characters.getRoot(player)
		if not castRoot or not Characters.isAlive(player) then
			return
		end

		local castNow = Workspace:GetServerTimeNow()
		local castState = PlayerCombatState.sync(player, castNow)

		if def.kind == "burst" then
			castBurst(player, castRoot, def, resolved.power)
		elseif def.kind == "blink" then
			castBlink(player, castRoot, def, resolved.power)
		elseif def.kind == "ward" then
			castWard(player, castState, resolved, castNow)
		else
			castMend(player, castRoot, def, resolved.power)
		end
	end)
end

--[[ Debug equip ]]

-- Number-key weapon swapping, for comparing weapons back to back while
-- tuning. Studio only: in a live server the class altars are the one way to
-- equip, and this remote does nothing.
local function onEquipWeapon(player: Player, payload: unknown)
	if not RunService:IsStudio() or typeof(payload) ~= "table" then
		return
	end

	-- Swapping mid-swing would let a player start a cheap fast swing and land a
	-- heavy one.
	if PlayerCombatState.peek(player).swinging then
		return
	end

	EquipService.setWeapon(player, (payload :: any).weaponId)
end

--[[ Lifecycle ]]

export type SpawnOptions = {
	-- Respawn in place a few seconds after dying. On by default.
	respawns: boolean?,
}

-- Spawns an enemy and starts its loop. `bounds` leashes it to its room.
function CombatServer.spawnEnemy(
	defId: string,
	position: Vector3,
	facePosition: Vector3,
	bounds: AttackSelector.Bounds?,
	parent: Instance?,
	options: SpawnOptions?
): EnemyAI.Enemy
	assert(running, "CombatServer.start must be called before spawning enemies")

	local enemy = EnemyAI.spawn(defId, position, facePosition, bounds, parent)
	enemies[enemy.id] = enemy
	if options and options.respawns == false then
		staysDead[enemy.id] = true
	end
	broadcastEnemyHealth(enemy)
	task.spawn(runEnemyLoop, enemy)
	return enemy
end

-- Removes an enemy for good: stops its loop, cancels any windup in flight,
-- and destroys its model. For tearing down a finished dungeon.
function CombatServer.despawnEnemy(enemy: EnemyAI.Enemy)
	if enemies[enemy.id] ~= enemy then
		return
	end

	enemies[enemy.id] = nil
	staysDead[enemy.id] = nil
	activeAttacks[enemy.id] = nil
	flinchImmuneUntil[enemy.id] = nil
	enemy.alive = false
	enemy.state = "dead"
	enemy.model:Destroy()
end

function CombatServer.start()
	assert(not running, "CombatServer.start called twice")
	running = true

	Remotes.get("ParryAttempt").OnServerEvent:Connect(onParryAttempt)
	Remotes.get("GuardReleased").OnServerEvent:Connect(onGuardReleased)
	Remotes.get("AttackRequest").OnServerEvent:Connect(onAttackRequest)
	Remotes.get("CriticalRequest").OnServerEvent:Connect(onCriticalRequest)
	Remotes.get("FeintRequest").OnServerEvent:Connect(onFeintRequest)
	Remotes.get("DodgeRequest").OnServerEvent:Connect(onDodgeRequest)
	Remotes.get("AbilityRequest").OnServerEvent:Connect(onAbilityRequest)
	Remotes.get("EquipWeapon").OnServerEvent:Connect(onEquipWeapon)

	-- A joining player needs every enemy's current health for the HUD.
	Players.PlayerAdded:Connect(function(player)
		for _, enemy in enemies do
			Remotes.get("EnemyHealthChanged"):FireClient(player, {
				enemyId = enemy.id,
				health = enemy.health,
				maxHealth = enemy.def.maxHealth,
				alive = enemy.alive,
			})
		end
	end)

	-- Movement steps every enemy on one Heartbeat rather than inside each
	-- enemy's own loop, so they all move against the same frame delta.
	RunService.Heartbeat:Connect(function(deltaTime)
		for _, enemy in enemies do
			local target = getTarget(enemy)
			local root = if target then Characters.getRoot(target) else nil
			if root then
				EnemyAI.step(enemy, root.Position, deltaTime)
			end
		end
	end)
end

return CombatServer
