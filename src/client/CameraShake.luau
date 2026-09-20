--!strict
-- Screen shake, driven by "trauma": each event adds some, it drains over time,
-- and the shake felt is trauma squared, so small bumps stay subtle while big
-- hits kick hard. Noise rather than random jitter, so it rumbles instead of
-- buzzing.
--
-- The shake is applied just after Roblox's camera script positions the camera,
-- and taken off again just before it runs next frame. The camera script reads
-- the camera's own CFrame to work out where to look, so a shake left on would
-- accumulate into a permanent drift.

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local CameraShake = {}

local UNDO_STEP = "CameraShakeUndo"
local APPLY_STEP = "CameraShakeApply"

-- Trauma lost per second.
local DECAY = 1.8
-- Noise samples per second: higher is a faster rumble.
local FREQUENCY = 18

-- At full trauma.
local MAX_OFFSET = 0.45
local MAX_PITCH = math.rad(1.4)
-- Kept smaller than pitch: CameraLock turns the character to face the camera,
-- so yaw shake would twitch the character too.
local MAX_YAW = math.rad(0.6)
local MAX_ROLL = math.rad(2.5)

local trauma = 0
local applied = CFrame.identity
local seed = math.random() * 1000

-- Add shake. 0.1 is a nudge, 0.3 a solid hit, 0.6 and up a heavy slam.
function CameraShake.add(amount: number)
	trauma = math.clamp(trauma + amount, 0, 1)
end

-- Shake that falls off with distance from the camera: full within `near`
-- studs, none beyond `far`.
function CameraShake.addAt(amount: number, position: Vector3, near: number, far: number)
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end

	local distance = (camera.Focus.Position - position).Magnitude
	local falloff = 1 - math.clamp((distance - near) / math.max(far - near, 1e-3), 0, 1)
	if falloff > 0 then
		CameraShake.add(amount * falloff)
	end
end

-- A smooth -1..1 wobble on its own channel, so the shake's axes never
-- move together and it reads as shake rather than as a slide.
local function noise(channel: number, t: number): number
	-- math.noise stays roughly within ±0.5; doubled to use the full range.
	return math.noise(seed + channel * 17.3, t) * 2
end

-- Begins the shake, and the step that undoes it.
--
-- Bound just before the camera's own render step so the offset is applied
-- and then removed every frame — the camera is never left displaced, which
-- is what stops repeated shakes drifting the view.
function CameraShake.start()
	RunService:BindToRenderStep(UNDO_STEP, Enum.RenderPriority.Camera.Value - 1, function()
		local camera = Workspace.CurrentCamera
		if camera and applied ~= CFrame.identity then
			camera.CFrame = camera.CFrame * applied:Inverse()
		end
		applied = CFrame.identity
	end)

	RunService:BindToRenderStep(APPLY_STEP, Enum.RenderPriority.Camera.Value + 1, function(deltaTime)
		if trauma <= 0 then
			return
		end

		trauma = math.max(trauma - DECAY * deltaTime, 0)

		local camera = Workspace.CurrentCamera
		if not camera then
			return
		end

		local shake = trauma * trauma
		local t = os.clock() * FREQUENCY
		applied = CFrame.new(noise(1, t) * MAX_OFFSET * shake, noise(2, t) * MAX_OFFSET * shake, 0)
			* CFrame.Angles(noise(3, t) * MAX_PITCH * shake, noise(4, t) * MAX_YAW * shake, noise(5, t) * MAX_ROLL * shake)

		camera.CFrame = camera.CFrame * applied
	end)
end

return CameraShake
