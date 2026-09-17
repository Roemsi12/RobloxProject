--!strict
-- Server bootstrap: combat authority, the dungeon, the start-room stations and
-- the duel arena — then players, who only get a character once their saved
-- progress has loaded.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local DungeonDefs = require(Shared.DungeonDefs)
local Remotes = require(Shared.Remotes)

local CombatServer = require(script.Combat.CombatServer)
local DataService = require(script.DataService)
local ChestService = require(script.Dungeon.ChestService)
local DungeonService = require(script.Dungeon.DungeonService)
local QueueService = require(script.Dungeon.QueueService)
local BlacksmithService = require(script.Economy.BlacksmithService)
local ArenaService = require(script.PvP.ArenaService)
local ProgressionService = require(script.Progression.ProgressionService)
local SpawnService = require(script.SpawnService)
local WeaponPickups = require(script.WeaponPickups)
local WeaponVisuals = require(script.WeaponVisuals)

-- Remotes must exist before any client starts waiting on them.
Remotes.init()

-- Before any profile loads, so a saved weapon is drawn in hand from the start.
WeaponVisuals.start()

-- Combat has to be running before the dungeon spawns enemies into it.
CombatServer.start()

-- Before the dungeon, which registers XP on every enemy it spawns.
ProgressionService.start()

-- Before the dungeon, which starts building chests as soon as it generates.
ChestService.start()

-- The start room sits at the origin; every dungeon grows north from its door.
local startCFrame = DungeonService.start(CFrame.new())

WeaponPickups.start(startCFrame)
BlacksmithService.start(startCFrame)
ArenaService.start(startCFrame)

-- The gate into the dungeon, and the portcullis that makes it the way in.
-- After the stations, so it can sit past them on the walk toward the door.
QueueService.start(startCFrame, DungeonDefs.SIZES[DungeonDefs.PURPOSES.Start.sizes[1]])

-- Players start in the safe start room, facing the door to the dungeon, with
-- the weapon stands in front of them. There's no SpawnLocation; SpawnService
-- places every character here.
SpawnService.start(CFrame.lookAt(
	startCFrame.Position + Vector3.new(0, 4, 0),
	startCFrame.Position + Vector3.new(0, 4, 20)
))

-- Last, so everything a loaded player can touch already exists. DataService
-- hands each player to SpawnService once their profile is ready.
DataService.start()
