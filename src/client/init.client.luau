--!strict
-- Client bootstrap.

local AtmosphereFX = require(script.AtmosphereFX)
local CameraLock = require(script.CameraLock)
local CameraShake = require(script.CameraShake)
local CombatClient = require(script.CombatClient)
local CombatFeel = require(script.CombatFeel)
local DebugHUD = require(script.DebugHUD)
local EnemyAnimation = require(script.EnemyAnimation)
local GameUI = require(script.GameUI)
local PlayerAnimation = require(script.PlayerAnimation)
local ProjectileVFX = require(script.ProjectileVFX)
local ScreenFX = require(script.ScreenFX)
local SoundFX = require(script.SoundFX)
local TelegraphVFX = require(script.TelegraphVFX)
local WorldFeedback = require(script.WorldFeedback)

SoundFX.start()
CameraShake.start()
CameraLock.start()
PlayerAnimation.start()
CombatClient.start()
EnemyAnimation.start()
TelegraphVFX.start()
ProjectileVFX.start()
WorldFeedback.start()
ScreenFX.start()
-- After ScreenFX, so the combat grade is created before the world grade and
-- the two stack in a fixed order.
AtmosphereFX.start()
CombatFeel.start()
GameUI.start()
DebugHUD.start()
