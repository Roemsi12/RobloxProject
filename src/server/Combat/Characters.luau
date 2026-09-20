--!strict
-- Small lookups on a player's character, shared by every server module that
-- resolves combat against real positions.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DamageMath = require(ReplicatedStorage.Shared.DamageMath)

local Characters = {}

-- A player's HumanoidRootPart, or nil if they have no character right
-- now. The position all combat reasons about: hit-reg reads this part and
-- nothing else.
function Characters.getRoot(player: Player): BasePart?
	local character = player.Character
	if not character then
		return nil
	end

	return character:FindFirstChild("HumanoidRootPart") :: BasePart?
end

-- A player's Humanoid, or nil if they have no character right now.
function Characters.getHumanoid(player: Player): Humanoid?
	local character = player.Character
	if not character then
		return nil
	end

	return character:FindFirstChildOfClass("Humanoid")
end

-- Whether the player has a character with health left. Checked before
-- anything is done to them: a player can die between a swing starting and
-- it landing.
function Characters.isAlive(player: Player): boolean
	local humanoid = Characters.getHumanoid(player)
	return humanoid ~= nil and humanoid.Health > 0
end

-- The XZ projection the pure combat math works in.
function Characters.flat(position: Vector3): DamageMath.Vec2
	return { x = position.X, z = position.Z }
end

-- GetNetworkPing is the round trip; parry authority needs the one-way half.
function Characters.halfPing(player: Player): number
	return player:GetNetworkPing() / 2
end

return Characters
