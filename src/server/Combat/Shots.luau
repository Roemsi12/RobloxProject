--!strict
-- Tells every client that a shot was loosed, and where it went, so they can
-- draw the arrow (BowVFX).
--
-- Only for weapons whose attack profile has a `shot` (WeaponDefs): a row, not
-- a branch, like everything else a class is. The hit itself is resolved by
-- the caller where the shot was taken, exactly as before; this is the picture
-- of it. It goes out at the moment of resolution, which is also the moment
-- the release plays in the shooter's animation, so the string lets go and the
-- arrow leaves together.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Loadout = require(Shared.Loadout)
local Remotes = require(Shared.Remotes)

local Shots = {}

-- How high on a body an arrow is aimed, above the root.
local CHEST_HEIGHT = 0.8

-- Announces a shot by `player` with `weaponId`, if that weapon shoots.
-- `target` is the root of whatever it hit, or nil for a miss, in which case
-- it flies straight out to `range` along the way the shooter faces.
function Shots.loose(player: Player, weaponId: string, root: BasePart, target: BasePart?, range: number)
	local shot = Loadout.getDef(weaponId).attack.shot
	if not shot then
		return
	end

	local landing = if target
		then target.Position + Vector3.new(0, CHEST_HEIGHT, 0)
		else root.Position + root.CFrame.LookVector * range + Vector3.new(0, CHEST_HEIGHT, 0)

	Remotes.get("PlayerShot"):FireAllClients({
		userId = player.UserId,
		kind = shot.kind,
		speed = shot.speed,
		landing = landing,
		hit = target ~= nil,
	})
end

return Shots
