--!strict
-- Combat animations on players' avatars: each weapon's fighting stance under
-- walking and idling, its combo swings and critical, the guard held while
-- blocking, feints, the dodge roll, flinches and guard breaks.
--
-- Every player's stance comes from the weapon their character carries (an
-- attribute set by the server's WeaponVisuals). Other players' actions come
-- from the server's PlayerCombatAction broadcast. The local player's own are
-- played the instant they press, by CombatClient, without waiting a round
-- trip.
--
-- The animations are authored for R15 joints; an R6 avatar simply isn't
-- animated here.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage.Shared
local AnimationDefs = require(Shared.AnimationDefs)
local LocomotionMath = require(Shared.LocomotionMath)
local Remotes = require(Shared.Remotes)
local RigDefs = require(Shared.RigDefs)
local SoundDefs = require(Shared.SoundDefs)
local WeaponModelDefs = require(Shared.WeaponModelDefs)

local RigAnimation = require(script.Parent.RigAnimation)
local SoundFX = require(script.Parent.SoundFX)

local PlayerAnimation = {}

local R15_JOINTS = 15
local RIG_WAIT_LIMIT = 10

-- The whoosh sounds as the blade comes through, this far into the windup.
local WHOOSH_AT = 0.6

type Tracked = {
	controller: RigAnimation.Controller,
	character: Model,
	-- Where the hips and chest are turned to right now, eased toward the goal
	-- rather than snapped (LocomotionMath).
	hip: number,
	shoulder: number,
	-- Last frame's answer, which is what gives the reversal its hysteresis.
	reversed: boolean,
	-- Whether the feet are currently planted, likewise.
	planted: boolean,
}

local localPlayer = Players.LocalPlayer
local tracked: { [Player]: Tracked } = {}

-- Players whose guard is up, so it can resume once a swing or flinch ends.
local guardingPlayers: { [Player]: string } = {}

-- Motor6Ds or AnimationConstraints, whichever this avatar was built with.
local countJoints = RigAnimation.countJoints

-- A character's HumanoidRootPart, or nil while it is being assembled.
local function rootOf(character: Model): BasePart?
	return character:FindFirstChild("HumanoidRootPart") :: BasePart?
end

-- The base a character should be holding: the planted idle when they are
-- standing still, the walking stance when they are not.
--
-- Two animations rather than one because they are allowed different things. A
-- stance must leave the hips and legs to Roblox's walk cycle; a planted idle
-- owns the whole body, which is the only way the feet end up where a fighter
-- would actually put them. RigAnimation cross-fades between the two.
local function baseFor(entry: Tracked): string?
	local weaponId = entry.character:GetAttribute(WeaponModelDefs.WEAPON_ATTRIBUTE)
	if typeof(weaponId) ~= "string" then
		return nil
	end
	return if entry.planted then AnimationDefs.idle(weaponId) else AnimationDefs.stance(weaponId)
end

-- Puts the character on the base it should be holding right now, or takes
-- the base away entirely when they are carrying nothing — which hands the
-- arms back to Roblox's Animate script.
local function refreshStance(entry: Tracked)
	local wanted = baseFor(entry)
	if wanted then
		RigAnimation.setBase(entry.controller, wanted)
	elseif RigAnimation.currentBase(entry.controller) then
		RigAnimation.clearBase(entry.controller)
	end
end

-- Starts animating a player's new character, once it is whole.
--
-- Waits for the Humanoid and for all fifteen joints to replicate, then
-- checks the character is still the current one — a player can die and
-- respawn inside that wait. R6 avatars are skipped outright: every
-- animation in the game is authored for R15 joints.
local function onCharacterAdded(player: Player, character: Model)
	local previous = tracked[player]
	if previous then
		RigAnimation.destroy(previous.controller)
		tracked[player] = nil
	end
	guardingPlayers[player] = nil

	local humanoid = character:WaitForChild("Humanoid", RIG_WAIT_LIMIT) :: Humanoid?
	if not humanoid or humanoid.RigType ~= Enum.HumanoidRigType.R15 then
		return
	end

	local waited = 0
	while countJoints(character) < R15_JOINTS and character.Parent and waited < RIG_WAIT_LIMIT do
		waited += task.wait(0.2)
	end

	-- Still the current character?
	if player.Character ~= character or not character.Parent then
		return
	end

	local entry: Tracked = {
		controller = RigAnimation.new(character, RigDefs.PLAYER_RIG, true),
		character = character,
		hip = 0,
		shoulder = 0,
		reversed = false,
		planted = true,
	}
	tracked[player] = entry

	refreshStance(entry)
	character:GetAttributeChangedSignal(WeaponModelDefs.WEAPON_ATTRIBUTE):Connect(function()
		if tracked[player] == entry then
			refreshStance(entry)
		end
	end)
end

--[[ Strafing ]]

-- The four rolls all start "roll_".
local function isRoll(name: string?): boolean
	return name ~= nil and string.sub(name, 1, 5) == "roll_"
end

-- Roblox's Animate script names its tracks after the Animation instances it
-- loads: "WalkAnim", "RunAnim". Matching on the name is how we find the cycle
-- to run backwards without replacing the whole Animate script.
local function isWalkCycle(name: string): boolean
	local lower = string.lower(name)
	return string.find(lower, "walk", 1, true) ~= nil or string.find(lower, "run", 1, true) ~= nil
end

-- Backing up plays the walk cycle in reverse, so the feet stride the way the
-- body is travelling. Re-asserted every frame because the Animate script sets
-- its own speed whenever the character's velocity changes, and would undo it.
--
-- The local player only: another player's tracks are playing here by
-- replication, and a speed set on this client wouldn't survive the next update
-- from theirs. Their hips still turn, which is what reads at a distance.
local function setCycleDirection(humanoid: Humanoid, backwards: boolean)
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		return
	end

	for _, track in animator:GetPlayingAnimationTracks() do
		if not isWalkCycle(track.Name) then
			continue
		end

		-- The direction is asserted, never inferred. `AdjustSpeed(-n)` really
		-- does run a track backwards, but `Speed` does not report the sign
		-- back: it reads positive again the moment the Animate script re-sets
		-- the speed for the character's pace, which it does on every velocity
		-- change. Deciding "is it already reversed?" from that read is how
		-- backing up ended up playing forwards — the answer was always "yes,
		-- it's forwards", whatever we had just set.
		--
		-- So take the magnitude, which is the pace the Animate script picked
		-- and worth keeping, and put our own sign on it every frame.
		local pace = math.abs(track.Speed)
		if pace == 0 then
			continue
		end

		local wanted = if backwards then -pace else pace
		if track.Speed ~= wanted then
			track:AdjustSpeed(wanted)
		end
	end
end

-- The hips turn toward where the character is going and the chest turns back
-- against them, so a locked camera doesn't leave everyone moonwalking. Facing
-- and travel agree when the camera is unlocked, so this settles at zero on its
-- own rather than needing to know whether the lock is on.
local function updateStrafe(player: Player, entry: Tracked, deltaTime: number)
	local humanoid = entry.character:FindFirstChildOfClass("Humanoid")
	local root = rootOf(entry.character)

	-- Square, and unwinding: dead, not assembled yet, or rolling.
	--
	-- A roll turns the hips itself, and turns them a long way. The strafe twist
	-- is laid over the same joint, so leaving it on would swing the tumble off
	-- its axis — a forward roll going over one corner. At TURN_RATE the twist
	-- is gone well inside the plant, and the roll has the hips to itself.
	local alive = humanoid ~= nil and root ~= nil and humanoid.Health > 0
	local steering = alive and not isRoll(RigAnimation.currentAction(entry.controller))

	local motion: LocomotionMath.Motion = { angle = nil, moving = false, reversed = false }
	if steering then
		local move = (humanoid :: Humanoid).MoveDirection
		local facing = (root :: BasePart).CFrame
		motion = LocomotionMath.resolve(facing.LookVector:Dot(move), facing.RightVector:Dot(move), entry.reversed)
	end

	entry.reversed = motion.reversed

	local goal = LocomotionMath.twist(motion)
	entry.hip = LocomotionMath.approach(entry.hip, goal.hip, deltaTime)
	entry.shoulder = LocomotionMath.approach(entry.shoulder, goal.shoulder, deltaTime)
	RigAnimation.setTwist(entry.controller, entry.hip, entry.shoulder)

	-- The stance breathes at the pace the character is actually going. Read
	-- from the assembly's own velocity rather than from MoveDirection, which is
	-- a unit vector and says nothing about speed — and which is empty for a
	-- character being carried along by a dodge's push.
	if root then
		local velocity = root.AssemblyLinearVelocity
		local pace = Vector3.new(velocity.X, 0, velocity.Z).Magnitude
		entry.planted = LocomotionMath.planted(pace, entry.planted)

		local wanted = baseFor(entry)
		if wanted then
			-- A planted idle keeps its own tempo: it is a character standing
			-- still, and nothing about standing still should speed up.
			local tempo = if entry.planted then 1 else LocomotionMath.stanceTempo(pace)
			RigAnimation.setBase(entry.controller, wanted, tempo)
		end
	end

	if player == localPlayer and humanoid then
		setCycleDirection(humanoid, motion.moving and motion.reversed)
	end
end

-- Follows one player's characters from now on, including the one they
-- already have if this runs after they spawned.
local function watchPlayer(player: Player)
	player.CharacterAdded:Connect(function(character)
		onCharacterAdded(player, character)
	end)

	local character = player.Character
	if character then
		task.spawn(onCharacterAdded, player, character)
	end
end

-- Plays a weapon's guard and freezes on its last frame, so it stays up
-- until something stops it. `fromStart` false skips the snap, for a guard
-- settling back in after a flinch interrupted it.
local function holdGuard(entry: Tracked, weaponId: string, fromStart: boolean)
	RigAnimation.playAction(entry.controller, AnimationDefs.guard(weaponId), {
		hold = true,
		-- Resuming a guard after a flinch skips the snap and just settles in.
		elapsed = if fromStart then 0 else 0.1,
	})
end

-- Whether an action name is an attack of some kind: a combo swing, a move
-- off the combo, or a critical. These are the only actions a flinch is
-- allowed to interrupt, and the only ones a feint may cancel.
--
-- Moves have to be in here. They are attacks, so a hit should break one and a
-- feint should be able to call one off -- and because this is a name-prefix
-- test, a move left out would not error, it would just quietly become
-- uninterruptible. Which is the sort of thing nobody notices for a month.
local function isStrike(name: string?): boolean
	if name == nil then
		return false
	end
	return string.sub(name, 1, 6) == "swing_"
		or string.sub(name, 1, 5) == "move_"
		or string.sub(name, 1, 9) == "critical_"
end

-- Schedules the blade's whoosh for partway through the windup, where the
-- swing is actually travelling, rather than on the press. Checks the root
-- still exists when it fires: the character may be gone by then.
local function whooshLater(entry: Tracked, weaponId: string, windup: number)
	local root = rootOf(entry.character)
	task.delay(windup * WHOOSH_AT, function()
		if root and root.Parent then
			SoundFX.playAt(SoundDefs.swingSound(weaponId), root.Position)
		end
	end)
end

-- Plays one combat action on one player's avatar.
--
-- The single place every player action is turned into an animation, for
-- the local player (called on the press, before the server answers) and
-- for everyone else (called from the server's broadcast). Ignores the call
-- if the character has been replaced since it was tracked.
local function play(player: Player, action: string, weaponId: string, windup: number?, step: number?, direction: string?)
	local entry = tracked[player]
	if not entry or entry.character ~= player.Character then
		return
	end
	local controller = entry.controller

	if action == "swing" then
		local swingTime = windup or 0.25
		RigAnimation.playAction(controller, AnimationDefs.swing(weaponId, step or 1), { windup = swingTime })
		whooshLater(entry, weaponId, swingTime)
	elseif action == "critical" then
		local swingTime = windup or 0.5
		RigAnimation.playAction(controller, AnimationDefs.critical(weaponId), { windup = swingTime })
		local root = rootOf(entry.character)
		if root then
			SoundFX.playAt("critical_windup", root.Position)
		end
		whooshLater(entry, weaponId, swingTime)
	elseif action == "parry" then
		guardingPlayers[player] = weaponId
		holdGuard(entry, weaponId, true)
	elseif action == "guard_end" then
		guardingPlayers[player] = nil
		if RigAnimation.currentAction(controller) == AnimationDefs.guard(weaponId) then
			RigAnimation.stopAction(controller)
		end
	elseif action == "feint" then
		if isStrike(RigAnimation.currentAction(controller)) then
			RigAnimation.stopAction(controller)
		end
		local root = rootOf(entry.character)
		if root then
			SoundFX.playAt("feint", root.Position)
		end
	elseif action == "ability" then
		guardingPlayers[player] = nil
		RigAnimation.playAction(controller, AnimationDefs.ABILITY, { windup = windup })
		local root = rootOf(entry.character)
		if root then
			SoundFX.playAt("critical_windup", root.Position)
		end
	elseif action == "dodge" then
		guardingPlayers[player] = nil
		-- A roll in the direction the body is travelling. An unknown direction
		-- (an old client, or a dodge announced without one) rolls backwards,
		-- which is what a standing dodge does anyway.
		RigAnimation.playAction(controller, AnimationDefs.roll(direction or "back"))
		local root = rootOf(entry.character)
		if root then
			SoundFX.playAt("dodge", root.Position)
		end
	end
end

--[[ The local player, played on input by CombatClient ]]

function PlayerAnimation.playLocal(action: string, weaponId: string, windup: number?, step: number?, direction: string?)
	play(localPlayer, action, weaponId, windup, step, direction)
end

-- Freeze the local player's pose for a moment as their blow lands.
function PlayerAnimation.hitStopLocal(seconds: number)
	local entry = tracked[localPlayer]
	if entry then
		RigAnimation.hitStop(entry.controller, seconds)
	end
end

-- Being hit cancels a swing in progress (the server's hitstun does the same).
function PlayerAnimation.playLocalHurt()
	local entry = tracked[localPlayer]
	if not entry then
		return
	end
	local current = RigAnimation.currentAction(entry.controller)
	if current == nil or isStrike(current) then
		RigAnimation.playAction(entry.controller, AnimationDefs.HURT)
	end
end

-- The local player's guard shattering. Clears the held guard first, so it
-- doesn't settle straight back in when the break animation finishes.
function PlayerAnimation.playLocalGuardBreak()
	local entry = tracked[localPlayer]
	guardingPlayers[localPlayer] = nil
	if entry then
		RigAnimation.playAction(entry.controller, AnimationDefs.GUARD_BREAK)
	end
end

-- Starts animating every player, now and as they join, and begins the
-- per-frame step.
--
-- The frame step runs on PreSimulation: after Roblox's Animate script has
-- posed each avatar and before joints are applied, which is the point where
-- a script's pose wins.
function PlayerAnimation.start()
	Players.PlayerAdded:Connect(watchPlayer)
	for _, player in Players:GetPlayers() do
		watchPlayer(player)
	end

	Players.PlayerRemoving:Connect(function(player)
		local entry = tracked[player]
		if entry then
			RigAnimation.destroy(entry.controller)
			tracked[player] = nil
		end
		guardingPlayers[player] = nil
	end)

	Remotes.get("PlayerCombatAction").OnClientEvent:Connect(function(payload)
		local player = Players:GetPlayerByUserId(payload.userId)
		-- The local player's own actions were animated on input. (A guard the
		-- server breaks comes down through CombatClient, which hears about it
		-- from PlayerHit.)
		if not player or player == localPlayer then
			return
		end

		play(player, payload.action, payload.weaponId, payload.windup, payload.step, payload.direction)
	end)

	-- After Roblox's Animate script has posed each avatar for this frame.
	RunService.PreSimulation:Connect(function(deltaTime)
		for player, entry in tracked do
			-- A guard still held when a flinch or swing finishes settles back in.
			local guardWeapon = guardingPlayers[player]
			if guardWeapon and RigAnimation.currentAction(entry.controller) == nil then
				holdGuard(entry, guardWeapon, false)
			end
			updateStrafe(player, entry, deltaTime)
			RigAnimation.step(entry.controller, deltaTime)
		end
	end)
end

return PlayerAnimation
