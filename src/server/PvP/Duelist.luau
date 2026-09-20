--!strict
-- One side of a duel: a player's duel state machine
-- (idle -> telegraph -> staggered | recover -> idle) and their virtual health.
--
-- A duel swing plays the role an enemy attack plays in PvE: the swinging
-- player telegraphs, and the opponent is the one who tries to parry it. The
-- same impact-anchored timeline is used, so ParryMath judges a duel parry
-- exactly the way it judges a PvE one.
--
-- Health is a virtual pool, not the character's Humanoid: a duel never
-- actually damages or kills the player, so there is no respawn or ragdoll flow
-- to fight (DESIGN.md).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CombatConstants = require(ReplicatedStorage.Shared.CombatConstants)

local Duelist = {}

export type DuelState = "idle" | "telegraph" | "staggered" | "recover"

export type Swing = {
	weaponId: string,
	impactTime: number,
	-- Set the moment the opponent's parry validates. The swing still resolves
	-- on schedule, but deals nothing.
	parried: boolean,
}

export type Duelist = {
	player: Player,
	state: DuelState,
	health: number,
	swing: Swing?,
}

-- A fresh duelist record: full health, no swing, nothing parried yet.
function Duelist.new(player: Player): Duelist
	return {
		player = player,
		state = "idle",
		health = CombatConstants.PVP_STARTING_HEALTH,
		swing = nil,
	}
end

-- The weapon is captured at swing time, so a weapon swap mid-telegraph can't
-- change what lands.
function Duelist.beginSwing(duelist: Duelist, weaponId: string, impactTime: number): Swing
	local swing: Swing = {
		weaponId = weaponId,
		impactTime = impactTime,
		parried = false,
	}

	duelist.state = "telegraph"
	duelist.swing = swing
	return swing
end

-- Moves to `state`, then back to idle after `duration` — unless something else
-- has changed the state in the meantime, in which case that wins.
function Duelist.holdState(duelist: Duelist, state: DuelState, duration: number)
	duelist.state = state

	task.delay(duration, function()
		if duelist.state == state then
			duelist.state = "idle"
		end
	end)
end

-- Returns true if this damage ended the duel.
function Duelist.applyDamage(duelist: Duelist, amount: number): boolean
	duelist.health = math.max(0, duelist.health - amount)
	return duelist.health <= 0
end

return Duelist
