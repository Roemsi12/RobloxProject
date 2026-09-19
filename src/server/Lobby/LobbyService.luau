--!strict
-- Owns the hub: builds it once at startup, and is the one place that knows
-- where it is.
--
-- Everything that used to ask `DungeonService.isInCamp` asks `isInside` here
-- instead. The hub is no longer the dungeon's first room — it is its own
-- building, in its own part of the world — so "are you somewhere safe" is a
-- question about the hub, not about the dungeon.

local Workspace = game:GetService("Workspace")

local LobbyBuilder = require(script.Parent.LobbyBuilder)

local LobbyService = {}

local lobby: LobbyBuilder.Lobby? = nil

-- Builds the hall and returns its anchors, so the bootstrap can hand each
-- station the frame it stands on. `gateColors` is one accent per gate, in the
-- order they stand across the north wall, and `altarCount` how many class
-- altars the west aisle has to hold.
function LobbyService.start(origin: CFrame, gateColors: { Color3 }, altarCount: number): LobbyBuilder.Lobby
	assert(lobby == nil, "The lobby is built once")

	local built = LobbyBuilder.build(origin, gateColors, altarCount)
	built.model.Parent = Workspace
	lobby = built

	-- The client reads these off the model to know when the local player is
	-- inside the hub, so it can grade the picture for an interior lit by fire
	-- (AtmosphereFX). Attributes rather than a RemoteEvent: this is fixed for
	-- the life of the server, and a joining client gets it with the model
	-- instead of having to be told.
	built.model:SetAttribute("MinX", built.bounds.minX)
	built.model:SetAttribute("MaxX", built.bounds.maxX)
	built.model:SetAttribute("MinZ", built.bounds.minZ)
	built.model:SetAttribute("MaxZ", built.bounds.maxZ)
	built.model:SetAttribute("FloorY", built.centre.Position.Y)

	return built
end

-- Whether `position` is inside the hub. The class altars and the forge use
-- this: you change class or upgrade a weapon here or not at all.
function LobbyService.isInside(position: Vector3): boolean
	local built = lobby
	if not built then
		return false
	end

	local bounds = built.bounds
	return position.X >= bounds.minX
		and position.X <= bounds.maxX
		and position.Z >= bounds.minZ
		and position.Z <= bounds.maxZ
end

-- Where a character appears, on the dais at the south end facing the gates.
function LobbyService.spawnCFrame(): CFrame
	local built = lobby
	return if built then built.spawnCFrame else CFrame.new(0, 5, 0)
end

return LobbyService
