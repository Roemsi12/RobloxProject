--!strict
-- The feel of combat: turns what the server reports into shake, hit-stop,
-- sound and screen effects, by calling the modules that draw each one.
--
-- One place decides how hard each moment hits, so the intensities can be
-- tuned against each other: a parry must always feel bigger than a hit, and a
-- slam you failed to dodge bigger than both.
--
-- Nothing here changes an outcome. Every effect follows a server report, with
-- one timed exception: an all-around slam's shockwave is scheduled for its
-- impact time, and cancelled if the enemy is staggered or dies first.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local EnemyDefs = require(Shared.EnemyDefs)
local Loadout = require(Shared.Loadout)
local Remotes = require(Shared.Remotes)

local CameraShake = require(script.Parent.CameraShake)
local EnemyAnimation = require(script.Parent.EnemyAnimation)
local PlayerAnimation = require(script.Parent.PlayerAnimation)
local ScreenFX = require(script.Parent.ScreenFX)
local SoundFX = require(script.Parent.SoundFX)
local WorldFeedback = require(script.Parent.WorldFeedback)

local CombatFeel = {}

-- Server-side EnemyAI tags every enemy model with this.
local ENEMY_TAG = "Enemy"

-- Hit-stop lengths, in seconds.
local HIT_STOP = 0.06
local RIPOSTE_HIT_STOP = 0.1
local PARRY_HIT_STOP = 0.12

local SLAM_COLOR = Color3.fromRGB(255, 120, 0)
-- A slam shakes the camera out to this multiple of its hit radius.
local SLAM_SHAKE_REACH = 3

local localPlayer = Players.LocalPlayer

-- enemyId -> the slam currently scheduled, so a stagger or death can cancel it.
local pendingSlams: { [string]: thread } = {}
-- Last reported alive state per enemy, to tell a death from old news.
local aliveById: { [string]: boolean } = {}

local lastWeaponId: string? = nil
local profileReady = false
local lastCoins: number? = nil

local function findEnemyModel(enemyId: string): Model?
	for _, tagged in CollectionService:GetTagged(ENEMY_TAG) do
		if tagged:IsA("Model") and tagged:GetAttribute("EnemyId") == enemyId then
			return tagged
		end
	end
	return nil
end

local function enemyRoot(enemyId: string): BasePart?
	local model = findEnemyModel(enemyId)
	return model and model.PrimaryPart
end

local function localRoot(): BasePart?
	local character = localPlayer.Character
	return character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
end

local function cancelSlam(enemyId: string)
	local pending = pendingSlams[enemyId]
	if pending then
		pendingSlams[enemyId] = nil
		pcall(task.cancel, pending)
	end
end

local function scheduleSlam(enemyId: string, root: BasePart, radius: number, impactTime: number)
	cancelSlam(enemyId)

	local delaySeconds = math.max(impactTime - Workspace:GetServerTimeNow(), 0)
	pendingSlams[enemyId] = task.delay(delaySeconds, function()
		pendingSlams[enemyId] = nil
		if not root.Parent then
			return
		end

		local floor = root.Position - Vector3.new(0, root.Size.Y / 2, 0)
		WorldFeedback.shockwave(floor, radius, SLAM_COLOR)
		SoundFX.playAt("enemy_slam", floor)
		CameraShake.addAt(0.55, floor, radius, radius * SLAM_SHAKE_REACH)
	end)
end

function CombatFeel.start()
	-- Your blow landing.
	Remotes.get("AttackResult").OnClientEvent:Connect(function(payload)
		if not payload.hit then
			return
		end

		local stop = if payload.riposte then RIPOSTE_HIT_STOP else HIT_STOP
		PlayerAnimation.hitStopLocal(stop)
		CameraShake.add(if payload.riposte then 0.32 else 0.16)

		local enemyId = payload.enemyId
		if typeof(enemyId) == "string" then
			EnemyAnimation.hitStop(enemyId, stop)
			local root = enemyRoot(enemyId)
			if root then
				SoundFX.playAt(if payload.riposte then "hit_riposte" else "hit", root.Position)
			end
		else
			-- A duel hit: the opponent is a player, so there's no enemy to find.
			SoundFX.play(if payload.riposte then "hit_riposte" else "hit")
		end
	end)

	-- A landed parry: the biggest moment in the game.
	Remotes.get("ParryResult").OnClientEvent:Connect(function(payload)
		if not payload.success then
			return
		end

		-- Felt through the clang, the sparks and the freeze; nothing drawn over
		-- the screen.
		CameraShake.add(0.28)
		PlayerAnimation.hitStopLocal(PARRY_HIT_STOP)
		SoundFX.play("parry")
		SoundFX.play("parry_crack")

		local enemyId = payload.enemyId
		if typeof(enemyId) == "string" then
			EnemyAnimation.hitStop(enemyId, PARRY_HIT_STOP)
			cancelSlam(enemyId)
		end
	end)

	Remotes.get("PvPParryResult").OnClientEvent:Connect(function(payload)
		-- The defender's own ParryResult already covers their side.
		if not payload.success then
			CameraShake.add(0.2)
		end
	end)

	-- Being hit.
	Remotes.get("PlayerHit").OnClientEvent:Connect(function(payload)
		local humanoid = localPlayer.Character and localPlayer.Character:FindFirstChildOfClass("Humanoid")
		local maxHealth = if humanoid then humanoid.MaxHealth else 100
		local strength = math.clamp(payload.amount / (maxHealth * 0.35), 0.15, 1)

		if payload.bleed then
			ScreenFX.hurt(0.1)
			CameraShake.add(0.05)
			return
		end

		-- Slipped it: the dash already made its sound.
		if payload.dodged then
			return
		end

		local root = localRoot()

		-- A guard taking the hit: sparks and a clink, no health lost.
		if payload.blocked then
			CameraShake.add(0.12)
			SoundFX.play("block")
			if root then
				WorldFeedback.guardSparks(root, Color3.fromRGB(255, 230, 160))
			end
			return
		end

		if payload.guardBroken then
			SoundFX.play("guard_break")
			CameraShake.add(0.25)
		end

		-- (The flinch itself is played by CombatClient, which also cancels any
		-- swing the hit interrupted.)
		ScreenFX.hurt(strength)
		CameraShake.add(0.2 + 0.4 * strength)
		SoundFX.play("player_hurt")
	end)

	Remotes.get("EnemyTelegraphStart").OnClientEvent:Connect(function(payload)
		local model = findEnemyModel(payload.enemyId)
		local root = model and model.PrimaryPart
		if not model or not root then
			return
		end

		-- Once per link, not once per chain, and deliberately: each link is a
		-- real wind-up and the sound is one of the cues a player reads. Going
		-- quiet on follow-ups would make the fastest part of a fight the part
		-- with the least information in it.
		SoundFX.playAt("enemy_windup", root.Position)

		local defId = model:GetAttribute("EnemyDefId")
		local def = if typeof(defId) == "string" then EnemyDefs[defId] else nil
		local attack = def and def.attacks[payload.attackId]
		if attack and attack.arcDegrees >= 360 then
			scheduleSlam(payload.enemyId, root, attack.range, payload.impactTime)
		end
	end)

	-- The boss noticing you.
	Remotes.get("BossEncounter").OnClientEvent:Connect(function(payload)
		if payload.active then
			SoundFX.play("boss_awakens")
			CameraShake.add(0.3)
		elseif payload.defeated then
			SoundFX.play("dungeon_cleared")
			CameraShake.add(0.5)
			ScreenFX.parry()
		end
	end)

	Remotes.get("DungeonNotice").OnClientEvent:Connect(function(payload)
		if payload.tone == "good" then
			SoundFX.play("room_cleared")
		elseif payload.tone == "danger" then
			-- An ambush springing or a new wave arriving.
			SoundFX.play("ambush")
			CameraShake.add(0.2)
		end
	end)

	Remotes.get("EnemyStaggered").OnClientEvent:Connect(function(payload)
		cancelSlam(payload.enemyId)
	end)

	Remotes.get("EnemyHealthChanged").OnClientEvent:Connect(function(payload)
		local wasAlive = aliveById[payload.enemyId]
		aliveById[payload.enemyId] = payload.alive
		if payload.alive then
			return
		end

		cancelSlam(payload.enemyId)

		-- Only at the moment of death: a player who joins hears about enemies
		-- that died a while ago, and those shouldn't explode on arrival.
		local root = enemyRoot(payload.enemyId)
		if wasAlive and root then
			WorldFeedback.deathBurst(root)
			SoundFX.playAt("enemy_death", root.Position)
			CameraShake.addAt(0.18, root.Position, 12, 40)
		end
	end)

	Remotes.get("HealBurst").OnClientEvent:Connect(function()
		ScreenFX.heal()
		SoundFX.play("heal")
		local root = localRoot()
		if root then
			WorldFeedback.healMotes(root)
		end
	end)

	-- Everything before the profile loads is the saved state arriving, not
	-- something the player just did, so it makes no sound.
	Remotes.get("ProfileLoaded").OnClientEvent:Connect(function()
		profileReady = true
	end)

	Remotes.get("WeaponEquipped").OnClientEvent:Connect(function(payload)
		local changed = payload.weaponId ~= lastWeaponId
		lastWeaponId = payload.weaponId
		if profileReady and changed and Loadout.resolve(payload.weaponId).ok then
			SoundFX.play("equip")
		end
	end)

	Remotes.get("UpgradeResult").OnClientEvent:Connect(function(payload)
		if payload.success then
			SoundFX.play("upgrade")
			CameraShake.add(0.15)
		else
			SoundFX.play("refused")
		end
	end)

	Remotes.get("ChestOpened").OnClientEvent:Connect(function(payload)
		if payload.inventoryFull then
			SoundFX.play("refused")
		else
			SoundFX.play("chest_open")
		end
	end)

	Remotes.get("CurrencyUpdated").OnClientEvent:Connect(function(payload)
		if profileReady and lastCoins and payload.coins > lastCoins then
			SoundFX.play("coins")
		end
		lastCoins = payload.coins
	end)
end

return CombatFeel
