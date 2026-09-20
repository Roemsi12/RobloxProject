--!strict
-- Resolves swings inside the active duel.
--
-- PvP reuses the PvE combat system rather than a parallel rule set (DESIGN.md),
-- so a duel runs on the same pieces: parry frames from the last block press,
-- blocking into posture, dodge invulnerability, hitstun, the same late grace,
-- and DamageMath's range/arc hit test. A player's swing stands in for an
-- enemy attack, and their opponent is the one defending against it.
--
-- This module doesn't listen on any remote itself. CombatServer owns the
-- input listeners and routes a dueling player's attacks here, so a single
-- press can never be handled by both PvE and PvP at once.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local CombatConstants = require(Shared.CombatConstants)
local DamageMath = require(Shared.DamageMath)
local Loadout = require(Shared.Loadout)
local ParryMath = require(Shared.ParryMath)
local PostureMath = require(Shared.PostureMath)
local Remotes = require(Shared.Remotes)

local Characters = require(script.Parent.Parent.Combat.Characters)
local PlayerCombatState = require(script.Parent.Parent.Combat.PlayerCombatState)
local EquipService = require(script.Parent.Parent.EquipService)
local ProgressionService = require(script.Parent.Parent.Progression.ProgressionService)
local ArenaService = require(script.Parent.ArenaService)
local Duelist = require(script.Parent.Duelist)

local PvPCombatServer = {}

-- Whether this player is in a duel right now. The branch every combat
-- entry point takes first, since duels resolve on their own rules.
function PvPCombatServer.isDueling(player: Player): boolean
	return ArenaService.getDuelist(player) ~= nil
end

-- Reports a swing's outcome back to whoever threw it.
local function attackResult(player: Player, payload: { [string]: any })
	Remotes.get("AttackResult"):FireClient(player, payload)
end

-- Resolves a duel swing when its telegraph ends.
--
-- Guarded the same way PvE swings are: a newer swing, or a parry that
-- already staggered this one, owns the duelist's state, and this call
-- finds it is no longer the current swing and does nothing.
local function resolveSwing(attacker: Player, attackerDuelist: Duelist.Duelist, swing: Duelist.Swing, swingId: number)
	-- A newer swing, or a parry that already staggered this one, owns the
	-- duelist's state now.
	if attackerDuelist.swing ~= swing then
		return
	end
	attackerDuelist.swing = nil

	-- Cancelled by a feint, a dodge or a hit.
	local attackerState = PlayerCombatState.peek(attacker)
	if attackerState.swingId ~= swingId then
		Duelist.holdState(attackerDuelist, "recover", 0)
		return
	end
	attackerState.swinging = false

	-- Re-fetched rather than captured at swing time: the duel may have ended
	-- while the telegraph was in flight.
	local opponentDuelist, opponent = ArenaService.getOpponent(attacker)
	if not opponentDuelist or not opponent then
		return
	end

	local weapon = Loadout.getDef(swing.weaponId)
	local attackerRoot = Characters.getRoot(attacker)
	local opponentRoot = Characters.getRoot(opponent)
	if not attackerRoot or not opponentRoot then
		return
	end

	local inVolume = DamageMath.isInHitVolume({
		attackerPos = Characters.flat(attackerRoot.Position),
		attackerFacing = Characters.flat(attackerRoot.CFrame.LookVector),
		targetPos = Characters.flat(opponentRoot.Position),
		range = weapon.attack.range,
		arcDegrees = weapon.attack.arcDegrees,
	})

	Duelist.holdState(attackerDuelist, "recover", weapon.attack.recovery)

	if not inVolume then
		attackResult(attacker, { hit = false, reason = "missed", damage = 0, riposte = false })
		return
	end

	local now = Workspace:GetServerTimeNow()
	local defender = PlayerCombatState.sync(opponent, now)
	local facing = DamageMath.isFacing(
		Characters.flat(opponentRoot.Position),
		Characters.flat(opponentRoot.CFrame.LookVector),
		Characters.flat(attackerRoot.Position),
		CombatConstants.BLOCK_ARC_DEGREES
	)

	-- Dodged.
	local defenderMods = ProgressionService.modifiers(opponent)
	local iframes = CombatConstants.DODGE_IFRAMES + defenderMods.dodgeIframes
	if ParryMath.withinWindow(defender.dodgeStartedAt, iframes, swing.impactTime) then
		Remotes.get("PlayerHit"):FireClient(opponent, { amount = 0, sourceId = attacker.Name, attackId = swing.weaponId, dodged = true })
		attackResult(attacker, { hit = false, reason = "dodged", damage = 0, riposte = false })
		return
	end

	-- Parried: the attacker is opened up for as long as the defender's class
	-- decides, the same way an enemy is.
	local defenderWeaponId = EquipService.getWeaponId(opponent)
	local pressAt = defender.parryPressAt
	if
		defenderWeaponId
		and facing
		and defender.parryFramesOpen
		and pressAt
		and not PlayerCombatState.isStunned(defender, swing.impactTime)
		and ParryMath.catches(
			pressAt,
			ParryMath.widen(Loadout.getDef(defenderWeaponId).parry, defenderMods.parryWindow),
			swing.impactTime
		)
	then
		local defenderWeapon = Loadout.getDef(defenderWeaponId)
		defender.parryCaught = true
		local restore = PlayerCombatState.limits(opponent).parryRestore
		PlayerCombatState.setPosture(defender, PostureMath.afterParry(defender.posture, restore), now, false)

		local staggerFor = DamageMath.staggerDuration(CombatConstants.STAGGER_DURATION, defenderWeapon.payoff.staggerMultiplier)
		Duelist.holdState(attackerDuelist, "staggered", staggerFor)
		PlayerCombatState.stun(attackerState, staggerFor, now)

		if defenderWeapon.payoff.riposteDuration > 0 then
			defender.riposteUntil = now + defenderWeapon.payoff.riposteDuration
		end

		-- No burst heal in a duel: duel health is a virtual pool, so healing the
		-- real Humanoid would do nothing, and healing the pool would be a
		-- PvP-only rule this module exists to avoid.

		Remotes.get("ParryResult"):FireClient(opponent, {
			verdict = "parried",
			success = true,
			deltaMs = (pressAt - swing.impactTime) * 1000,
			riposteUntil = defender.riposteUntil,
			enemyId = attacker.Name,
		})
		local pvpParryResult = Remotes.get("PvPParryResult")
		pvpParryResult:FireClient(opponent, { success = true, message = "Parried!" })
		pvpParryResult:FireClient(attacker, { success = false, message = "Your attack was parried!" })
		PlayerCombatState.publish(opponent)
		PlayerCombatState.publish(attacker)
		return
	end

	local riposteActive = now < attackerState.riposteUntil
	local attackerMods = ProgressionService.modifiers(attacker)
	local base = EquipService.getDamage(attacker, swing.weaponId) * (1 + attackerMods.damage)
	local fullDamage = DamageMath.resolveOutgoing(base, {
		targetStaggered = opponentDuelist.state == "staggered",
		riposteActive = riposteActive,
		riposteMultiplier = weapon.payoff.riposteMultiplier + attackerMods.riposte,
	})

	-- The defender's guard works exactly as it does against an enemy.
	local guarding = defender.guarding and not defender.swinging and not PlayerCombatState.isStunned(defender, now)
	local block =
		DamageMath.resolveBlock(fullDamage, guarding, true, facing, defender.posture, PlayerCombatState.limits(opponent).max)
	PlayerCombatState.setPosture(defender, block.posture, now, block.outcome ~= "unguarded")

	if block.outcome == "broken" then
		defender.guarding = false
		PlayerCombatState.stun(defender, CombatConstants.GUARD_BREAK_STUN, now)
		PlayerCombatState.announce(opponent, "guard_end", defenderWeaponId or "")
	elseif block.outcome == "unguarded" then
		PlayerCombatState.stun(defender, CombatConstants.PLAYER_HIT_STUN, now)
	end

	local defeated = block.damage > 0 and Duelist.applyDamage(opponentDuelist, block.damage)

	Remotes.get("PlayerHit"):FireClient(opponent, {
		amount = block.damage,
		sourceId = attacker.Name,
		attackId = swing.weaponId,
		blocked = block.outcome == "blocked",
		guardBroken = block.outcome == "broken",
	})
	attackResult(attacker, {
		hit = block.outcome ~= "blocked",
		reason = if block.outcome == "blocked" then "blocked" else "hit",
		damage = block.damage,
		riposte = riposteActive,
	})
	PlayerCombatState.publish(opponent)
	ArenaService.publishHealth()

	if defeated then
		ArenaService.endDuel(opponent)
	end
end

-- A duelist's attack press. Duels use one telegraphed swing rather than
-- the combo, so there is no step to pick.
function PvPCombatServer.handleAttack(attacker: Player)
	local attackerDuelist = ArenaService.getDuelist(attacker)
	local _, opponent = ArenaService.getOpponent(attacker)
	if not attackerDuelist or not opponent then
		return
	end

	local weaponId = EquipService.getWeaponId(attacker)
	if not weaponId then
		attackResult(attacker, { hit = false, reason = "unequipped", damage = 0, riposte = false })
		return
	end

	local now = Workspace:GetServerTimeNow()
	local state = PlayerCombatState.sync(attacker, now)
	if PlayerCombatState.isStunned(state, now) or state.guarding then
		attackResult(attacker, { hit = false, reason = "stunned", damage = 0, riposte = false })
		return
	end

	-- The duel state machine is the cooldown: a swing can only start from idle.
	if attackerDuelist.state ~= "idle" then
		attackResult(attacker, { hit = false, reason = "cooldown", damage = 0, riposte = false })
		return
	end

	local attack = Loadout.getDef(weaponId).attack
	local swing = Duelist.beginSwing(attackerDuelist, weaponId, now + attack.pvpTelegraph)

	state.swingId += 1
	state.swinging = true
	state.swingStartedAt = now
	state.swingWindup = attack.pvpTelegraph
	local swingId = state.swingId

	-- Duels use each weapon's opening swing only: a combo's quick follow-ups
	-- would leave no time to read the swing, which is the duel.
	PlayerCombatState.announce(attacker, "swing", weaponId, attack.pvpTelegraph, 1)

	Remotes.get("PvPTelegraphStart"):FireClient(opponent, {
		attackerName = attacker.Name,
		duration = attack.pvpTelegraph,
		impactTime = swing.impactTime,
	})

	-- Held open past impact so a block press just before the hit can still
	-- arrive, exactly as for enemy attacks.
	task.delay(attack.pvpTelegraph + CombatConstants.STRIKE_RESOLUTION_GRACE, function()
		resolveSwing(attacker, attackerDuelist, swing, swingId)
	end)
end

return PvPCombatServer
