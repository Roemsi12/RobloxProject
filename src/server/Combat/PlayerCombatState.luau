--!strict
-- Per-player combat state: posture, stun, the guard and parry presses, dodge
-- and critical cooldowns, feints, the riposte window, and swing timing.
--
-- One record per player, shared by PvE (CombatServer) and PvP
-- (PvPCombatServer). PvP reusing the same combat system (DESIGN.md) has to
-- include reusing the same state — a duel-only copy would let a player walk
-- into the arena with a fresh guard.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local CombatConstants = require(Shared.CombatConstants)
local PostureMath = require(Shared.PostureMath)
local Remotes = require(Shared.Remotes)

local ProgressionService = require(script.Parent.Parent.Progression.ProgressionService)

local PlayerCombatState = {}

-- What this player's posture is worth, after their skill tree. Every posture
-- number in combat goes through here rather than reading CombatConstants
-- directly, so a Tank who spent points into Deep Stance actually has the
-- deeper stance.
function PlayerCombatState.limits(player: Player): PostureMath.Limits
	local mods = ProgressionService.modifiers(player)
	return {
		max = CombatConstants.MAX_POSTURE + mods.maxPosture,
		regenPerSecond = CombatConstants.POSTURE_REGEN_PER_SECOND + mods.postureRegen,
		parryRestore = CombatConstants.PARRY_POSTURE_RESTORE + mods.parryRestore,
	}
end

-- "parry" is the block key going down (a parry attempt and a raised guard);
-- "guard_end" is it coming up. "critical" is the heavy attack; "feint" cancels
-- a swing; "dodge" is the roll.
export type CombatAction = "swing" | "critical" | "parry" | "guard_end" | "feint" | "dodge" | "ability"

-- Which way a dodge rolls. Cosmetic: the client picks it, the server passes it
-- on, and nothing is decided by it — so it is checked for being one of the
-- four rather than trusted, and a press that claims anything else simply rolls
-- backwards.
export type RollDirection = "forward" | "back" | "left" | "right"

local ROLL_DIRECTIONS: { [string]: boolean } = {
	forward = true,
	back = true,
	left = true,
	right = true,
}

function PlayerCombatState.rollDirection(claimed: unknown): RollDirection
	if typeof(claimed) == "string" and ROLL_DIRECTIONS[claimed] then
		return claimed :: RollDirection
	end
	return "back"
end

-- Tells every client a player has done something, so everyone can animate
-- it — not just the player doing it. Called once the server has accepted the
-- action, never on a rejected press. `windup` is how long a swing or critical
-- takes to land, `step` which swing of the combo it is, and `direction` which
-- way a dodge rolls.
function PlayerCombatState.announce(
	player: Player,
	action: CombatAction,
	weaponId: string,
	windup: number?,
	step: number?,
	direction: RollDirection?
)
	Remotes.get("PlayerCombatAction"):FireAllClients({
		userId = player.UserId,
		action = action,
		weaponId = weaponId,
		windup = windup,
		step = step,
		direction = direction,
	})
end

export type State = {
	-- Posture as last stored, and the times it was stored and last filled.
	-- Read it through `sync`, which drains it up to now.
	posture: number,
	postureUpdatedAt: number,
	postureDamagedAt: number,
	-- No attacking, blocking or dodging before this time.
	stunnedUntil: number,
	-- Holding the block key.
	guarding: boolean,
	-- The last press that opened parry frames, and whether they caught a hit.
	parryPressAt: number?,
	parryCaught: boolean,
	-- Whether the current guard came with parry frames at all.
	parryFramesOpen: boolean,
	-- Set by a successful parry; the Assassin's payoff window.
	riposteUntil: number,
	attackReadyAt: number,
	swinging: boolean,
	-- Bumped whenever a swing starts or is cancelled; a swing resolving with a
	-- stale id was cancelled and does nothing.
	swingId: number,
	swingStartedAt: number,
	swingWindup: number,
	-- The step of the last swing (0 before any), and when its combo window
	-- closes.
	comboStep: number,
	comboExpiresAt: number,
	criticalReadyAt: number,
	feintReadyAt: number,
	dodgeStartedAt: number?,
	dodgeReadyAt: number,
	-- One cooldown per ability slot (SkillTreeDefs.abilities). Slots a player
	-- hasn't unlocked simply never get used.
	abilityReadyAt: { number },
	-- A ward in effect: until when, and the fraction of incoming damage it
	-- turns away. A warded guard also cannot be broken.
	wardUntil: number,
	wardReduction: number,
}

local states: { [Player]: State } = {}

local function getOrCreate(player: Player): State
	local state = states[player]
	if state then
		return state
	end

	local now = Workspace:GetServerTimeNow()
	local created: State = {
		posture = 0,
		postureUpdatedAt = now,
		postureDamagedAt = -math.huge,
		stunnedUntil = 0,
		guarding = false,
		parryPressAt = nil,
		parryCaught = false,
		parryFramesOpen = false,
		riposteUntil = 0,
		attackReadyAt = 0,
		swinging = false,
		swingId = 0,
		swingStartedAt = 0,
		swingWindup = 0,
		comboStep = 0,
		comboExpiresAt = 0,
		criticalReadyAt = 0,
		feintReadyAt = 0,
		dodgeStartedAt = nil,
		dodgeReadyAt = 0,
		abilityReadyAt = { 0, 0, 0 },
		wardUntil = 0,
		wardReduction = 0,
	}
	states[player] = created
	return created
end

-- Returns the player's state with posture drained up to `now`.
--
-- Regen is applied lazily on read rather than on a tick, so it stays exact
-- regardless of server framerate and costs nothing while nobody is fighting.
function PlayerCombatState.sync(player: Player, now: number): State
	local state = getOrCreate(player)
	state.posture = PostureMath.regenerate(
		state.posture,
		state.postureUpdatedAt,
		state.postureDamagedAt,
		now,
		PlayerCombatState.limits(player).regenPerSecond
	)
	state.postureUpdatedAt = now
	return state
end

-- Read without draining posture, for callers that only need a flag.
function PlayerCombatState.peek(player: Player): State
	return getOrCreate(player)
end

function PlayerCombatState.isStunned(state: State, now: number): boolean
	return now < state.stunnedUntil
end

-- Sets posture after it took damage (or was restored), at `now`.
function PlayerCombatState.setPosture(state: State, posture: number, now: number, damaged: boolean)
	state.posture = posture
	state.postureUpdatedAt = now
	if damaged then
		state.postureDamagedAt = now
	end
end

-- Cancels a swing in progress, if any. Returns whether one was cancelled.
function PlayerCombatState.cancelSwing(state: State): boolean
	if not state.swinging then
		return false
	end
	state.swingId += 1
	state.swinging = false
	state.comboStep = 0
	return true
end

-- Whether a swing in progress is still early enough to cancel.
function PlayerCombatState.inCancelWindow(state: State, now: number): boolean
	return state.swinging and now - state.swingStartedAt <= state.swingWindup * CombatConstants.CANCEL_WINDOW_FRACTION
end

-- Stuns the player, cancelling any swing in progress.
function PlayerCombatState.stun(state: State, seconds: number, now: number)
	state.stunnedUntil = math.max(state.stunnedUntil, now + seconds)
	PlayerCombatState.cancelSwing(state)
end

-- Tells the player's own client their posture and cooldowns, so the HUD can
-- draw them. The client drains posture forward on its own clock between sends.
function PlayerCombatState.publish(player: Player)
	local state = states[player]
	if not state or not player.Parent then
		return
	end

	local limits = PlayerCombatState.limits(player)

	Remotes.get("CombatStateChanged"):FireClient(player, {
		posture = state.posture,
		postureUpdatedAt = state.postureUpdatedAt,
		postureDamagedAt = state.postureDamagedAt,
		-- Sent rather than assumed: the HUD's bar is drawn against the
		-- player's own maximum, which their skill tree may have raised.
		maxPosture = limits.max,
		postureRegen = limits.regenPerSecond,
		stunnedUntil = state.stunnedUntil,
		dodgeReadyAt = state.dodgeReadyAt,
		abilityReadyAt = table.clone(state.abilityReadyAt),
		wardUntil = state.wardUntil,
		criticalReadyAt = state.criticalReadyAt,
		riposteUntil = state.riposteUntil,
	})
end

Players.PlayerRemoving:Connect(function(player)
	states[player] = nil
end)

-- A new body starts fresh, whatever the old one was doing when it died.
local function watchCharacters(player: Player)
	player.CharacterAdded:Connect(function()
		local state = states[player]
		if state then
			state.guarding = false
			state.swinging = false
			state.swingId += 1
			state.comboStep = 0
			state.stunnedUntil = 0
			state.posture = 0
			state.postureUpdatedAt = Workspace:GetServerTimeNow()
			PlayerCombatState.publish(player)
		end
	end)
end

Players.PlayerAdded:Connect(watchCharacters)
for _, player in Players:GetPlayers() do
	watchCharacters(player)
end

return PlayerCombatState
