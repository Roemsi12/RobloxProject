--!strict
-- A tuning readout for combat: the equipped weapon's parry frames, posture,
-- stun and cooldowns, ping, and what the last parry, swing and hit did.
--
-- Hidden by default and only available in Studio (F2 toggles it): the game
-- itself shows none of this, as in Deepwoken. It exists so constants in
-- CombatConstants and WeaponDefs can be moved on evidence rather than feel.

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Stats = game:GetService("Stats")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local CombatConstants = require(Shared.CombatConstants)
local Loadout = require(Shared.Loadout)
local PostureMath = require(Shared.PostureMath)
local Remotes = require(Shared.Remotes)

local DebugHUD = {}

local TOGGLE_ACTION = "ToggleDebugHUD"

local GREY = Color3.fromRGB(150, 150, 150)
local WHITE = Color3.fromRGB(235, 235, 235)
local GOOD = Color3.fromRGB(120, 230, 140)
local BAD = Color3.fromRGB(255, 100, 90)

type State = {
	weaponId: string?,
	classTag: string?,
	posture: number,
	postureUpdatedAt: number,
	postureDamagedAt: number,
	stunnedUntil: number,
	dodgeReadyAt: number,
	criticalReadyAt: number,
	riposteUntil: number,
	lastParry: string?,
	lastSwing: string?,
	lastHit: string?,
	lastHitGood: boolean,
}

local state: State = {
	weaponId = nil,
	classTag = nil,
	posture = 0,
	postureUpdatedAt = 0,
	postureDamagedAt = -math.huge,
	stunnedUntil = 0,
	dodgeReadyAt = 0,
	criticalReadyAt = 0,
	riposteUntil = 0,
	lastParry = nil,
	lastSwing = nil,
	lastHit = nil,
	lastHitGood = false,
}

-- One monospaced line of the debug readout.
local function makeLabel(parent: Instance, order: number, size: number): TextLabel
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.Code
	label.TextSize = size
	label.TextColor3 = WHITE
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Size = UDim2.new(1, 0, 0, size + 6)
	label.LayoutOrder = order
	label.Parent = parent
	return label
end

-- A cooldown as text: "1.4s" while it is running, "ready" once it is not.
local function remaining(until_: number, now: number): string
	local left = until_ - now
	return if left > 0 then string.format("%.1fs", left) else "ready"
end

-- Builds the combat debug readout and binds F2 to it. Studio only:
-- returns immediately in a live game, so nothing is built at all.
function DebugHUD.start()
	if not RunService:IsStudio() then
		return
	end

	local player = Players.LocalPlayer

	local gui = Instance.new("ScreenGui")
	gui.Name = "CombatDebugHUD"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.Enabled = false
	gui.Parent = player:WaitForChild("PlayerGui")

	local frame = Instance.new("Frame")
	frame.Size = UDim2.fromOffset(380, 200)
	frame.Position = UDim2.fromOffset(16, 60)
	frame.BackgroundColor3 = Color3.fromRGB(18, 18, 22)
	frame.BackgroundTransparency = 0.25
	frame.BorderSizePixel = 0
	frame.Parent = gui

	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, 8)
	padding.PaddingLeft = UDim.new(0, 12)
	padding.Parent = frame

	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 2)
	layout.Parent = frame

	local weaponLabel = makeLabel(frame, 1, 14)
	local framesLabel = makeLabel(frame, 2, 13)
	local postureLabel = makeLabel(frame, 3, 13)
	local cooldownLabel = makeLabel(frame, 4, 13)
	local pingLabel = makeLabel(frame, 5, 13)
	local parryLabel = makeLabel(frame, 6, 14)
	local swingLabel = makeLabel(frame, 7, 14)
	local hitLabel = makeLabel(frame, 8, 14)

	ContextActionService:BindAction(TOGGLE_ACTION, function(_, inputState)
		if inputState == Enum.UserInputState.Begin then
			gui.Enabled = not gui.Enabled
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.KeyCode.F2)

	Remotes.get("WeaponEquipped").OnClientEvent:Connect(function(payload)
		state.weaponId = payload.weaponId
		state.classTag = payload.classTag
	end)

	Remotes.get("CombatStateChanged").OnClientEvent:Connect(function(payload)
		state.posture = payload.posture
		state.postureUpdatedAt = payload.postureUpdatedAt
		state.postureDamagedAt = payload.postureDamagedAt
		state.stunnedUntil = payload.stunnedUntil
		state.dodgeReadyAt = payload.dodgeReadyAt
		state.criticalReadyAt = payload.criticalReadyAt
		state.riposteUntil = payload.riposteUntil
	end)

	Remotes.get("ParryResult").OnClientEvent:Connect(function(payload)
		state.lastParry = string.format("PARRIED  %+.0f ms from impact  vs %s", payload.deltaMs, tostring(payload.enemyId))
	end)

	Remotes.get("AttackResult").OnClientEvent:Connect(function(payload)
		if payload.hit then
			state.lastSwing = string.format("hit %.1f%s", payload.damage, if payload.riposte then "  RIPOSTE" else "")
		else
			state.lastSwing = payload.reason
		end
	end)

	Remotes.get("PlayerHit").OnClientEvent:Connect(function(payload)
		if payload.dodged then
			state.lastHit, state.lastHitGood = "DODGED", true
		elseif payload.blocked then
			state.lastHit, state.lastHitGood = "BLOCKED", true
		elseif payload.guardBroken then
			state.lastHit, state.lastHitGood = string.format("GUARD BROKEN  -%.0f", payload.amount), false
		else
			state.lastHit, state.lastHitGood = string.format("%s  -%.0f", if payload.bleed then "BLEED" else "HIT", payload.amount), false
		end
	end)

	RunService.RenderStepped:Connect(function()
		if not gui.Enabled then
			return
		end

		local now = Workspace:GetServerTimeNow()
		local weaponId = state.weaponId
		local weapon = if weaponId then Loadout.getDef(weaponId) else nil

		if weapon then
			weaponLabel.Text = `weapon   {weapon.displayName} ({state.classTag})   [1/2/3]`
			framesLabel.Text = string.format(
				"parry    %.0f ms frames, %.0f ms late slack, %.1fs cooldown on a miss",
				weapon.parry.earlyTolerance * 1000,
				weapon.parry.lateTolerance * 1000,
				CombatConstants.PARRY_COOLDOWN
			)
		else
			weaponLabel.Text = "weapon   none — take up a class at an altar"
			framesLabel.Text = "parry    --"
		end

		local posture = PostureMath.regenerate(state.posture, state.postureUpdatedAt, state.postureDamagedAt, now)
		local stun = state.stunnedUntil - now
		postureLabel.Text = string.format(
			"posture  %d / %d%s",
			math.floor(posture),
			CombatConstants.MAX_POSTURE,
			if stun > 0 then string.format("   STUNNED %.1fs", stun) else ""
		)

		cooldownLabel.Text = `dodge    {remaining(state.dodgeReadyAt, now)}   critical {remaining(state.criticalReadyAt, now)}`
			.. (if now < state.riposteUntil then string.format("   RIPOSTE %.1fs", state.riposteUntil - now) else "")

		local ping = Stats.Network.ServerStatsItem["Data Ping"]:GetValue()
		pingLabel.Text = string.format("ping     %.0f ms", ping)

		parryLabel.Text = state.lastParry or "parry    --"
		parryLabel.TextColor3 = if state.lastParry then GOOD else GREY
		swingLabel.Text = `swing    {state.lastSwing or "--"}`
		hitLabel.Text = `taken    {state.lastHit or "--"}`
		hitLabel.TextColor3 = if state.lastHit == nil then GREY elseif state.lastHitGood then GOOD else BAD
	end)
end

return DebugHUD
