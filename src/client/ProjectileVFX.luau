--!strict
-- Draws the things ranged enemies throw, and marks where they are going to
-- land.
--
-- Purely a picture. The server decided at launch where the projectile lands
-- and resolves the hit there when it arrives; nothing here touches that. What
-- this does is make the decision *readable*: something leaves the enemy, you
-- can see where it is headed, and you have its flight time to not be there.
--
-- A ranged attack without this is a number that arrives from off screen. The
-- flight time was always in the rules — this is what lets a player use it.

local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local Palette = require(Shared.Palette)
local Remotes = require(Shared.Remotes)

local ProjectileVFX = {}

type Look = {
	color: { number },
	size: Vector3,
	material: Enum.Material,
	-- How far the shot arcs above the straight line, in studs. A spat blob
	-- lobs; a thrown spear does not.
	arc: number,
	trail: boolean,
}

local LOOKS: { [string]: Look } = {
	acid = {
		color = Palette.ACID,
		size = Vector3.new(1.4, 1.4, 1.4),
		material = Enum.Material.Neon,
		arc = 4,
		trail = true,
	},
	bone = {
		color = Palette.OLD_BONE,
		size = Vector3.new(0.35, 0.35, 4.5),
		material = Enum.Material.SmoothPlastic,
		arc = 0,
		trail = false,
	},
}

local FALLBACK: Look = LOOKS.bone

-- How long the mark where it will land stays after the hit.
local MARK_LINGER = 0.15

local function rgb(values: { number }): Color3
	return Color3.fromRGB(values[1], values[2], values[3])
end

local function effectFolder(): Instance
	local existing = Workspace:FindFirstChild("ProjectileVFX")
	if existing then
		return existing
	end

	local folder = Instance.new("Folder")
	folder.Name = "ProjectileVFX"
	folder.Parent = Workspace
	return folder
end

-- The circle on the floor where it is going to land, sized to the radius the
-- server will actually check. Anyone standing on it when the shot arrives is
-- hit, so it is worth drawing honestly.
local function markLanding(parent: Instance, landing: Vector3, radius: number, look: Look, flight: number)
	local mark = Instance.new("Part")
	mark.Name = "LandingMark"
	mark.Anchored = true
	mark.CanCollide = false
	mark.CanQuery = false
	mark.CanTouch = false
	mark.Size = Vector3.new(radius * 2, 0.08, radius * 2)
	mark.Shape = Enum.PartType.Cylinder
	-- A cylinder's flat faces point along X, so it needs laying down.
	mark.CFrame = CFrame.new(landing.X, landing.Y - 2.6, landing.Z) * CFrame.Angles(0, 0, math.rad(90))
	mark.Color = rgb(look.color)
	mark.Material = Enum.Material.Neon
	mark.Transparency = 0.85
	mark.Parent = parent

	-- Fills in as the shot closes, so the mark itself is the timer.
	TweenService:Create(mark, TweenInfo.new(flight, Enum.EasingStyle.Linear), { Transparency = 0.55 }):Play()
	Debris:AddItem(mark, flight + MARK_LINGER)
end

local function burst(parent: Instance, at: Vector3, look: Look)
	local flash = Instance.new("Part")
	flash.Name = "Impact"
	flash.Anchored = true
	flash.CanCollide = false
	flash.CanQuery = false
	flash.CanTouch = false
	flash.Shape = Enum.PartType.Ball
	flash.Size = Vector3.new(1, 1, 1)
	flash.CFrame = CFrame.new(at)
	flash.Color = rgb(look.color)
	flash.Material = Enum.Material.Neon
	flash.Transparency = 0.2
	flash.Parent = parent

	TweenService:Create(flash, TweenInfo.new(0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = Vector3.new(7, 7, 7),
		Transparency = 1,
	}):Play()
	Debris:AddItem(flash, 0.35)
end

local function launch(payload: { [string]: any })
	local origin = payload.origin
	local landing = payload.landing
	local flight = payload.flight
	if typeof(origin) ~= "Vector3" or typeof(landing) ~= "Vector3" or type(flight) ~= "number" or flight <= 0 then
		return
	end

	local look = LOOKS[payload.kind] or FALLBACK
	local parent = effectFolder()
	local radius = if type(payload.radius) == "number" then payload.radius else 4

	markLanding(parent, landing, radius, look, flight)

	local shot = Instance.new("Part")
	shot.Name = "Projectile"
	shot.Anchored = true
	shot.CanCollide = false
	shot.CanQuery = false
	shot.CanTouch = false
	shot.Size = look.size
	shot.Color = rgb(look.color)
	shot.Material = look.material
	shot.CFrame = CFrame.lookAt(origin, landing)
	shot.Parent = parent

	if look.trail then
		local light = Instance.new("PointLight")
		light.Color = rgb(look.color)
		light.Brightness = 2
		light.Range = 10
		light.Parent = shot
	end

	-- Stepped rather than tweened, because a lobbed shot follows an arc and a
	-- tween only knows about straight lines. Each step also re-aims the part,
	-- so a spear points the way it is travelling all the way down.
	local startedAt = os.clock()

	task.spawn(function()
		local previous = origin
		while true do
			local alpha = math.clamp((os.clock() - startedAt) / flight, 0, 1)
			-- A parabola that is zero at both ends and `arc` high in the middle.
			local lift = look.arc * 4 * alpha * (1 - alpha)
			local at = origin:Lerp(landing, alpha) + Vector3.new(0, lift, 0)

			if (at - previous).Magnitude > 1e-3 then
				shot.CFrame = CFrame.lookAt(at, at + (at - previous))
			else
				shot.Position = at
			end
			previous = at

			if alpha >= 1 then
				break
			end
			task.wait()
		end

		burst(parent, landing, look)
		shot:Destroy()
	end)

	Debris:AddItem(shot, flight + 1)
end

function ProjectileVFX.start()
	Remotes.get("ProjectileLaunched").OnClientEvent:Connect(launch)
end

return ProjectileVFX
