--!strict
-- Server bootstrap: combat authority, the hub and its stations, the dungeon
-- and the duel arena — then players, who only get a character once their saved
-- progress has loaded.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage.Shared.Remotes)

local AppearanceService = require(script.AppearanceService)
local CombatServer = require(script.Combat.CombatServer)
local DataService = require(script.DataService)
local DungeonService = require(script.Dungeon.DungeonService)
local QueueService = require(script.Dungeon.QueueService)
local ChestService = require(script.Dungeon.ChestService)
local BlacksmithService = require(script.Economy.BlacksmithService)
local ClassAltars = require(script.Lobby.ClassAltars)
local LobbyService = require(script.Lobby.LobbyService)
local LookingGlass = require(script.Lobby.LookingGlass)
local ArenaService = require(script.PvP.ArenaService)
local ProgressionService = require(script.Progression.ProgressionService)
local SpawnService = require(script.SpawnService)
local WeaponVisuals = require(script.WeaponVisuals)

-- How far north of the hub the dungeon is generated. The hub is a hundred and
-- ninety studs deep and every dungeon grows north from its entry hall, so a
-- gap this size means no run can ever reach the back of the hall, however
-- many rooms a seed asks for.
local DUNGEON_ORIGIN = CFrame.new(0, 0, 600)

-- Remotes must exist before any client starts waiting on them.
Remotes.init()

-- Before any profile loads, so a saved weapon is drawn in hand from the start.
WeaponVisuals.start()

-- Likewise: a character that appears before this is wearing whatever avatar
-- its player arrived in, which is the whole thing this replaces.
AppearanceService.start()

-- Combat has to be running before the dungeon spawns enemies into it.
CombatServer.start()

-- Before the dungeon, which registers XP on every enemy it spawns.
ProgressionService.start()

-- Before the dungeon, which starts building chests as soon as it generates.
ChestService.start()

-- The hub. It is built first because every station stands in it and takes the
-- frame it stands on from it: the hall owns where things are, the stations own
-- what they do. The gates' colours come from QueueService so the portal in the
-- wall and the prompt in front of it agree on which gate is which.
local lobby = LobbyService.start(CFrame.new(), QueueService.gateColors(), ClassAltars.count())

ClassAltars.start(lobby.altarAnchors)
LookingGlass.start(lobby.mirrorAnchor)
BlacksmithService.start(lobby.forgeAnchor)
ArenaService.start(lobby.centre, lobby.duelAnchor)

-- The dungeon, well north of the hub, and the three gates that send players
-- into it. The gates need the dungeon to exist before anyone can queue, so it
-- is generated first.
DungeonService.start(DUNGEON_ORIGIN)
QueueService.start(lobby.gateAnchors)

-- Players arrive on the dais at the south end of the hub, facing the length of
-- the hall to the gates. There's no SpawnLocation; SpawnService places every
-- character here, and puts them back here after a death or a dungeon reset.
SpawnService.start(LobbyService.spawnCFrame())

-- Last, so everything a loaded player can touch already exists. DataService
-- hands each player to SpawnService once their profile is ready.
DataService.start()
