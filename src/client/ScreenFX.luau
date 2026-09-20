--!strict
-- Effects on the whole screen: a coloured vignette for damage and healing, a
-- pulsing warning at low health, and the colour-grade flash and field-of-view
-- kick of a landed parry.
--
-- The vignette replaces the old full-screen flash. Tinting only the edges
-- says "you got hit" just as clearly without hiding the enemy you need to
-- watch for the next telegraph.

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local ScreenFX = {}

local DAMAGE_COLOR = Color3.fromRGB(190, 0, 0)
local HEAL_COLOR = Color3.fromRGB(40, 220, 110)
local LOW_HEALTH_COLOR = Color3.fromRGB(150, 0, 0)

-- How deep into the screen each edge's fade reaches, as a fraction.
local EDGE_DEPTH = 0.32
-- Below this fraction of max health, the warning vignette starts to pulse.
local LOW_HEALTH = 0.35

type Vignette = {
	frames: { Frame },
}

local grade: ColorCorrectionEffect
local damageVignette: Vignette
local healVignette: Vignette
local lowHealthVignette: Vignette
local baseFieldOfView = 70

-- Four edge strips, each fading from opaque at the edge to clear inward.
local function makeVignette(parent: Instance, color: Color3): Vignette
	local frames = {}

	local edges = {
		{ size = UDim2.fromScale(1, EDGE_DEPTH), position = UDim2.fromScale(0, 0), rotation = 90 },
		{ size = UDim2.fromScale(1, EDGE_DEPTH), position = UDim2.fromScale(0, 1 - EDGE_DEPTH), rotation = -90 },
		{ size = UDim2.fromScale(EDGE_DEPTH * 0.6, 1), position = UDim2.fromScale(0, 0), rotation = 0 },
		{ size = UDim2.fromScale(EDGE_DEPTH * 0.6, 1), position = UDim2.fromScale(1 - EDGE_DEPTH * 0.6, 0), rotation = 180 },
	}

	for _, edge in edges do
		local frame = Instance.new("Frame")
		frame.Size = edge.size
		frame.Position = edge.position
		frame.BackgroundColor3 = color
		frame.BackgroundTransparency = 1
		frame.BorderSizePixel = 0
		frame.Parent = parent

		local gradient = Instance.new("UIGradient")
		gradient.Rotation = edge.rotation
		gradient.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0),
			NumberSequenceKeypoint.new(1, 1),
		})
		gradient.Parent = frame

		table.insert(frames, frame)
	end

	return { frames = frames }
end

-- Sets a vignette's strength immediately, with no tween. 0 is invisible.
local function setVignette(vignette: Vignette, strength: number)
	for _, frame in vignette.frames do
		frame.BackgroundTransparency = 1 - math.clamp(strength, 0, 1)
	end
end

-- Flashes a vignette to `strength` and fades it out over `seconds`.
local function pulseVignette(vignette: Vignette, strength: number, seconds: number)
	for _, frame in vignette.frames do
		frame.BackgroundTransparency = 1 - math.clamp(strength, 0, 1)
		TweenService:Create(frame, TweenInfo.new(seconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			BackgroundTransparency = 1,
		}):Play()
	end
end

-- Snap the colour grade to a look, then ease back to neutral.
local function gradeFlash(brightness: number, contrast: number, saturation: number, tint: Color3, seconds: number)
	grade.Brightness = brightness
	grade.Contrast = contrast
	grade.Saturation = saturation
	grade.TintColor = tint

	TweenService:Create(grade, TweenInfo.new(seconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Brightness = 0,
		Contrast = 0,
		Saturation = 0,
		TintColor = Color3.new(1, 1, 1),
	}):Play()
end

-- Narrow the view for an instant and let it spring back.
function ScreenFX.fovKick(amount: number, seconds: number)
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end

	camera.FieldOfView = baseFieldOfView - amount
	TweenService:Create(camera, TweenInfo.new(seconds, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		FieldOfView = baseFieldOfView,
	}):Play()
end

-- The parry flash: a cold, bright grade and a short field-of-view kick.
-- Deliberately not a colour wash over the screen — DESIGN.md took those
-- out; a parry is felt through the clang, the sparks and the freeze.
function ScreenFX.parry()
	gradeFlash(0.22, 0.3, -0.55, Color3.fromRGB(235, 245, 255), 0.35)
	ScreenFX.fovKick(6, 0.4)
end

-- `strength` 0..1: a scratch to a heavy blow.
function ScreenFX.hurt(strength: number)
	pulseVignette(damageVignette, 0.35 + 0.5 * strength, 0.5)
	gradeFlash(0, 0.1 * strength, -0.25 * strength, Color3.fromRGB(255, 215, 215), 0.3)
end

-- The green pulse when healing lands on the local player.
function ScreenFX.heal()
	pulseVignette(healVignette, 0.45, 0.7)
end

-- Builds the vignettes and the colour-correction effect this module
-- drives. Its own grade, separate from the place file's art direction and
-- from AtmosphereFX's world grade: three reasons to tint the screen, none
-- overwriting the others.
function ScreenFX.start()
	local player = Players.LocalPlayer

	grade = Instance.new("ColorCorrectionEffect")
	grade.Name = "CombatGrade"
	-- Created by this client, so the flash is only on this player's screen.
	grade.Parent = Lighting

	local camera = Workspace.CurrentCamera
	if camera then
		baseFieldOfView = camera.FieldOfView
	end

	local gui = Instance.new("ScreenGui")
	gui.Name = "ScreenFX"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	-- Beneath every other interface.
	gui.DisplayOrder = -10
	gui.Parent = player:WaitForChild("PlayerGui")

	lowHealthVignette = makeVignette(gui, LOW_HEALTH_COLOR)
	damageVignette = makeVignette(gui, DAMAGE_COLOR)
	healVignette = makeVignette(gui, HEAL_COLOR)

	-- The warning breathes faster and harder the closer to death.
	RunService.RenderStepped:Connect(function()
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if not humanoid or humanoid.Health <= 0 or humanoid.MaxHealth <= 0 then
			setVignette(lowHealthVignette, 0)
			return
		end

		local fraction = humanoid.Health / humanoid.MaxHealth
		if fraction >= LOW_HEALTH then
			setVignette(lowHealthVignette, 0)
			return
		end

		local danger = 1 - fraction / LOW_HEALTH
		local beat = 0.5 + 0.5 * math.sin(os.clock() * (4 + 4 * danger))
		setVignette(lowHealthVignette, (0.25 + 0.3 * beat) * (0.4 + 0.6 * danger))
	end)
end

return ScreenFX
