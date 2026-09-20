--!strict
-- Combat input. Sends presses to the server, which decides every outcome, and
-- plays the local player's side at once so the controls feel instant: the
-- animation, the lunge or dash, and the slowdowns while attacking, blocking
-- or stunned.
--
--   Left click / R2   attack (keep pressing for the combo)
--   R / R1            critical
--   Right click / X   feint (early in a swing)
--   F / L1            press to parry, hold to block
--   Q / B             dodge
--   Z / X / C         the abilities unlocked in the skill tree
--
-- The client mirrors the server's rules (combo steps, cooldowns, stuns) only to
-- decide what to animate. If the two disagree, the server's call stands and
-- the worst case is an animation that didn't land.

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local AbilityDefs = require(Shared.AbilityDefs)
local CombatConstants = require(Shared.CombatConstants)
local Loadout = require(Shared.Loadout)
local LocomotionMath = require(Shared.LocomotionMath)
local SkillTreeDefs = require(Shared.SkillTreeDefs)
local Remotes = require(Shared.Remotes)

local PlayerAnimation = require(script.Parent.PlayerAnimation)

local CombatClient = {}

-- Slot 1 is the leftmost branch of the skill tree, and so on, so a player who
-- knows the tree knows what their keys do before they press one.
local ABILITY_KEYS = {
	Enum.KeyCode.Z,
	Enum.KeyCode.X,
	Enum.KeyCode.C,
}

-- Number-key weapon swapping, for comparing weapons back to back while
-- tuning. Studio only, on both ends: in a live game the class altars are the
-- way to equip, and the server ignores this remote outside Studio anyway.
local SWAP_KEYS = {
	Enum.KeyCode.One,
	Enum.KeyCode.Two,
	Enum.KeyCode.Three,
}

-- A swing steps forward for this long.
local LUNGE_DURATION = 0.12
-- Walking stays slowed for this long past a swing's hit.
local ATTACK_SLOW_AFTER = 0.2

local localPlayer = Players.LocalPlayer

-- Everything below is in server time (Workspace:GetServerTimeNow()), so values
-- the server sends can be compared directly.
local weaponId: string? = nil
local dueling = false
local guarding = false
local stunnedUntil = 0
local attackReadyAt = 0
local attackSlowUntil = 0
local comboStep = 0
local comboExpiresAt = 0
local swingStartedAt = 0
local swingWindup = 0
local swingEndsAt = 0
local criticalReadyAt = 0
local feintReadyAt = 0
local dodgeReadyAt = 0
local abilityReadyAt = { 0, 0, 0 }
-- slot -> AbilityDefs id, from the skill tree. Empty until something is
-- unlocked, which is why an ability key does nothing at level 1.
local abilities: { [number]: string } = {}

local baseWalkSpeed = 16

-- The synchronised server clock. Every time value in this file is on it,
-- so a local prediction and the server's answer can be compared directly.
local function now(): number
	return Workspace:GetServerTimeNow()
end

-- The local character's Humanoid and HumanoidRootPart, or nils while it is
-- dead or still being built. Every caller has to handle the nils: a player
-- can press a key on the frame their character is replaced.
local function character(): (Humanoid?, BasePart?)
	local model = localPlayer.Character
	if not model then
		return nil, nil
	end
	return model:FindFirstChildOfClass("Humanoid"), model:FindFirstChild("HumanoidRootPart") :: BasePart?
end

-- Whether the local prediction thinks the player is stunned. Mirrors the
-- server's rule, and is only ever used to decide what to animate — if the
-- two disagree the server wins.
local function stunned(): boolean
	return now() < stunnedUntil
end

-- Whether a predicted swing is still in its windup.
local function swinging(): boolean
	return now() < swingEndsAt
end

-- A vector flattened to the ground plane and normalised, or nil if there
-- was no horizontal component worth using. Guards every direction this
-- file derives, so a straight-up look vector never becomes a NaN dash.
local function flat(vector: Vector3): Vector3?
	local horizontal = Vector3.new(vector.X, 0, vector.Z)
	if horizontal.Magnitude < 1e-3 then
		return nil
	end
	return horizontal.Unit
end

-- Drives the character along the ground at `speed` for `duration`. A velocity
-- constraint rather than an impulse, because a walking Humanoid cancels an
-- impulse almost immediately. Falls back to an impulse if the constraint
-- can't be made.
local function push(root: BasePart, direction: Vector3, speed: number, duration: number)
	local ok = pcall(function()
		local attachment = Instance.new("Attachment")
		attachment.Name = "CombatPush"
		attachment.Parent = root

		local velocity = Instance.new("LinearVelocity")
		velocity.Attachment0 = attachment
		velocity.RelativeTo = Enum.ActuatorRelativeTo.World
		velocity.ForceLimitMode = Enum.ForceLimitMode.PerAxis
		velocity.MaxAxesForce = Vector3.new(1e5, 0, 1e5)
		velocity.VectorVelocity = direction * speed
		velocity.Parent = attachment

		task.delay(duration, function()
			attachment:Destroy()
		end)
	end)

	if not ok then
		root:ApplyImpulse(direction * speed * root.AssemblyMass)
	end
end

-- Drops the local swing prediction and the combo, for a feint or a
-- dodge-cancel. Sends nothing; the caller tells the server separately.
local function cancelPredictedSwing()
	swingEndsAt = 0
	comboStep = 0
end

--[[ Attacking ]]

-- Whether a swing may start right now: armed, not stunned, not guarding,
-- not already mid-swing, and past the recovery of the last one.
-- The first thing to check when an attack press seems to do nothing.
local function canAttack(): boolean
	return weaponId ~= nil and not stunned() and not guarding and not swinging() and now() >= attackReadyAt
end

-- Records a swing as started, so `swinging`, the walk slowdown and the
-- feint window all know about it. Does not animate or send anything.
local function beginSwing(windup: number)
	local t = now()
	swingStartedAt = t
	swingWindup = windup
	swingEndsAt = t + windup
	attackSlowUntil = t + windup + ATTACK_SLOW_AFTER
end

-- The short forward step on a swing, along where the character faces.
-- Purely visual: the server resolves the hit from wherever the player
-- actually is when it runs.
local function lunge(speed: number)
	local _, root = character()
	local look = root and flat(root.CFrame.LookVector)
	if root and look then
		push(root, look, speed, LUNGE_DURATION)
	end
end

-- The attack press. Picks the next combo step (or the duel's single
-- telegraphed swing), plays it locally at once, steps the lunge, and tells
-- the server. Everything it sets is a prediction the server may override.
local function attack()
	if not canAttack() then
		return
	end

	local id = weaponId :: string
	local profile = Loadout.getDef(id).attack
	local t = now()

	if dueling then
		beginSwing(profile.pvpTelegraph)
		attackReadyAt = t + profile.pvpTelegraph + profile.recovery
		PlayerAnimation.playLocal("swing", id, profile.pvpTelegraph, 1)
	else
		local step = Loadout.nextComboStep(profile, comboStep, t, comboExpiresAt)
		local timing = Loadout.swingTiming(profile, step)
		comboStep = step
		comboExpiresAt = t + timing.comboExpiresAfter
		attackReadyAt = t + timing.readyAfter
		beginSwing(timing.windup)
		PlayerAnimation.playLocal("swing", id, timing.windup, step)
	end

	Remotes.get("AttackRequest"):FireServer()
	lunge(profile.lunge)
end

-- The heavy attack, on its own cooldown. Never in a duel — duels keep to
-- the opening swing.
local function critical()
	if dueling or not canAttack() or now() < criticalReadyAt then
		return
	end

	local id = weaponId :: string
	local profile = Loadout.getDef(id).attack
	local t = now()

	criticalReadyAt = t + profile.critical.cooldown
	attackReadyAt = t + profile.critical.windup + profile.finisherRecovery
	comboStep = 0
	beginSwing(profile.critical.windup)

	PlayerAnimation.playLocal("critical", id, profile.critical.windup)
	Remotes.get("CriticalRequest"):FireServer()
	lunge(profile.lunge * 1.4)
end

-- Only claims the input while a swing can still be feinted, so right-drag
-- camera control keeps working the rest of the time.
local function feint(): boolean
	local t = now()
	local cancellable = swinging() and t - swingStartedAt <= swingWindup * CombatConstants.CANCEL_WINDOW_FRACTION
	if not weaponId or not cancellable or t < feintReadyAt then
		return false
	end

	feintReadyAt = t + CombatConstants.FEINT_COOLDOWN
	attackReadyAt = t
	cancelPredictedSwing()

	PlayerAnimation.playLocal("feint", weaponId :: string)
	Remotes.get("FeintRequest"):FireServer()
	return true
end

--[[ Defending ]]

local function raiseGuard()
	if not weaponId or stunned() then
		return
	end

	-- The press is timestamped: whatever lands inside its parry frames is
	-- parried. GetServerTimeNow is synchronised to the server clock, so the
	-- server can check the claim directly.
	Remotes.get("ParryAttempt"):FireServer({ timestamp = now() })
	guarding = true
	PlayerAnimation.playLocal("parry", weaponId :: string)
end

-- The block key coming up: drops the guard and tells the server. Does
-- nothing if no guard was up, so a stray release can't clear a state the
-- server never opened.
local function lowerGuard()
	if not guarding then
		return
	end
	guarding = false
	Remotes.get("GuardReleased"):FireServer()
	PlayerAnimation.playLocal("guard_end", weaponId or "")
end

-- The dodge press. Rolls the way the character is travelling, pushes them
-- along it, and cancels a swing that is still early enough in its windup.
local function dodge()
	local t = now()
	if not weaponId or stunned() or t < dodgeReadyAt then
		return
	end

	-- A swing can only be dodge-cancelled early in its windup.
	if swinging() then
		if t - swingStartedAt > swingWindup * CombatConstants.CANCEL_WINDOW_FRACTION then
			return
		end
		cancelPredictedSwing()
		attackReadyAt = t
	end

	local humanoid, root = character()
	if not humanoid or not root then
		return
	end

	dodgeReadyAt = t + CombatConstants.DODGE_COOLDOWN
	guarding = false

	-- Whichever way the player is moving; straight back if standing still.
	local direction = flat(humanoid.MoveDirection) or flat(-root.CFrame.LookVector)
	if direction then
		push(root, direction, CombatConstants.DODGE_SPEED, CombatConstants.DODGE_DURATION)
	end

	-- Which roll to play: the same direction, measured against where the
	-- character is facing rather than where the camera is, so a roll to the
	-- left is a roll over the left shoulder whichever way the camera is
	-- pointing. Read from the movement input, not from the push, because with
	-- the camera locked the two are the same vector but only one of them is
	-- known before the physics runs.
	local facing = root.CFrame
	local rollDirection = if direction
		then LocomotionMath.rollDirection(facing.LookVector:Dot(direction), facing.RightVector:Dot(direction))
		else "back"

	Remotes.get("DodgeRequest"):FireServer({ timestamp = t, direction = rollDirection })
	PlayerAnimation.playLocal("dodge", weaponId :: string, nil, nil, rollDirection)
end

-- An ability, on the key its branch of the skill tree landed on. Predicted
-- locally like every other input: the animation plays on the press, and the
-- server decides whether anything actually happened.
local function castAbility(slot: number)
	local id = weaponId
	local abilityId = abilities[slot]
	if not id or not abilityId or dueling then
		return
	end

	local def = AbilityDefs.get(abilityId)
	if not def then
		return
	end

	local t = now()
	if t < stunnedUntil or t < (abilityReadyAt[slot] or 0) then
		return
	end

	-- Predicted at the base cooldown. The server's own figure arrives on the
	-- next CombatStateChanged and replaces it, so a tree that shortens the
	-- cooldown is never held back by this guess.
	abilityReadyAt[slot] = t + def.cooldown
	guarding = false

	Remotes.get("AbilityRequest"):FireServer({ slot = slot })
	PlayerAnimation.playLocal("ability", id, def.windup)
end

--[[ Setup ]]

local function bindDebugSwaps()
	local equipWeapon = Remotes.get("EquipWeapon")
	local weaponIds = Loadout.allWeaponIds()

	for index, keyCode in SWAP_KEYS do
		local id = weaponIds[index]
		if not id then
			break
		end

		ContextActionService:BindAction(`Equip_{id}`, function(_, inputState)
			if inputState == Enum.UserInputState.Begin then
				equipWeapon:FireServer({ weaponId = id })
			end
			return Enum.ContextActionResult.Sink
		end, false, keyCode)
	end
end

-- Binds a press-only action.
local function bindPress(name: string, title: string, touchButton: boolean, callback: () -> (), ...: Enum.KeyCode | Enum.UserInputType)
	ContextActionService:BindAction(name, function(_, inputState)
		if inputState ~= Enum.UserInputState.Begin then
			return Enum.ContextActionResult.Pass
		end
		callback()
		return Enum.ContextActionResult.Sink
	end, touchButton, ...)
	if touchButton then
		ContextActionService:SetTitle(name, title)
	end
end

function CombatClient.start()
	bindPress("Attack", "Attack", true, attack, Enum.UserInputType.MouseButton1, Enum.KeyCode.ButtonR2)
	bindPress("Critical", "Critical", true, critical, Enum.KeyCode.R, Enum.KeyCode.ButtonR1)
	bindPress("Dodge", "Dodge", true, dodge, Enum.KeyCode.Q, Enum.KeyCode.ButtonB)
	-- One key per branch of the tree, in the order the tree draws them.
	for slot, keyCode in ABILITY_KEYS do
		bindPress(`Ability{slot}`, `Ability {slot}`, true, function()
			castAbility(slot)
		end, keyCode)
	end

	ContextActionService:BindAction("Feint", function(_, inputState)
		if inputState == Enum.UserInputState.Begin and feint() then
			return Enum.ContextActionResult.Sink
		end
		return Enum.ContextActionResult.Pass
	end, false, Enum.UserInputType.MouseButton2, Enum.KeyCode.ButtonX)

	-- Press to parry, hold to block.
	ContextActionService:BindAction("Block", function(_, inputState)
		if inputState == Enum.UserInputState.Begin then
			raiseGuard()
			return Enum.ContextActionResult.Sink
		elseif inputState == Enum.UserInputState.End or inputState == Enum.UserInputState.Cancel then
			lowerGuard()
			return Enum.ContextActionResult.Sink
		end
		return Enum.ContextActionResult.Pass
	end, true, Enum.KeyCode.F, Enum.KeyCode.ButtonL1)
	ContextActionService:SetTitle("Block", "Block")

	if RunService:IsStudio() then
		bindDebugSwaps()
	end

	Remotes.get("WeaponEquipped").OnClientEvent:Connect(function(payload)
		if payload.weaponId ~= weaponId then
			comboStep = 0
		end
		weaponId = payload.weaponId
	end)

	Remotes.get("PvPStatusChanged").OnClientEvent:Connect(function(payload)
		dueling = payload.status == "dueling"
	end)

	-- The server's word on stun and cooldowns replaces the predictions.
	Remotes.get("CombatStateChanged").OnClientEvent:Connect(function(payload)
		stunnedUntil = payload.stunnedUntil
		dodgeReadyAt = payload.dodgeReadyAt
		criticalReadyAt = payload.criticalReadyAt
		abilityReadyAt = payload.abilityReadyAt or abilityReadyAt
	end)

	-- Which keys do anything comes from the tree, so a point spent on a
	-- capstone puts an ability under your hand without a respawn.
	Remotes.get("ProgressionChanged").OnClientEvent:Connect(function(payload)
		abilities = if payload.weaponId then SkillTreeDefs.abilities(payload.weaponId, payload.skills or {}) else {}
	end)

	Remotes.get("PlayerHit").OnClientEvent:Connect(function(payload)
		if payload.bleed or payload.dodged or payload.blocked then
			return
		end

		local t = now()
		if payload.guardBroken then
			guarding = false
			stunnedUntil = math.max(stunnedUntil, t + CombatConstants.GUARD_BREAK_STUN)
			cancelPredictedSwing()
			PlayerAnimation.playLocalGuardBreak()
		elseif payload.amount > 0 then
			stunnedUntil = math.max(stunnedUntil, t + CombatConstants.PLAYER_HIT_STUN)
			cancelPredictedSwing()
			PlayerAnimation.playLocalHurt()
		end
	end)

	localPlayer.CharacterAdded:Connect(function(newCharacter)
		guarding = false
		stunnedUntil = 0
		cancelPredictedSwing()
		local humanoid = newCharacter:WaitForChild("Humanoid", 10) :: Humanoid?
		if humanoid then
			baseWalkSpeed = humanoid.WalkSpeed
		end
	end)
	local humanoid = character()
	if humanoid then
		baseWalkSpeed = humanoid.WalkSpeed
	end

	-- Walking slows while attacking, blocking or stunned.
	RunService.RenderStepped:Connect(function()
		local current = character()
		if not current then
			return
		end

		local t = now()
		local fraction = 1
		if t < stunnedUntil then
			fraction = CombatConstants.STUN_WALK_FRACTION
		elseif t < attackSlowUntil then
			fraction = CombatConstants.ATTACK_WALK_FRACTION
		elseif guarding then
			fraction = CombatConstants.BLOCK_WALK_FRACTION
		end
		-- The skill tree can raise walk speed, and the server publishes the
		-- result as an attribute. Read every frame rather than cached at
		-- spawn, so spending a point takes effect without a respawn.
		local base = current:GetAttribute("BaseWalkSpeed")
		current.WalkSpeed = (if type(base) == "number" then base else baseWalkSpeed) * fraction
	end)
end

return CombatClient
