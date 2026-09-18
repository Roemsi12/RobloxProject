--!strict
-- Shift-lock style camera: the character always faces where the camera faces,
-- so movement becomes strafe-relative instead of turn-to-move.
--
-- Combat needs this. Parry timing is read off the enemy's telegraph, and with
-- free-look the player has to choose between watching the wind-up and steering
-- — which turns a timing test into a camera-wrangling test. Locked facing keeps
-- the enemy on screen while circling.
--
-- Toggled rather than held: a hold would fight the parry and attack binds
-- during the exact moments it matters most.
--
-- Rotation goes through an AlignOrientation constraint rather than writing
-- HumanoidRootPart.CFrame each frame. Overwriting the CFrame of a part the
-- physics solver also owns makes the two fight, and the correction is visible
-- as per-frame jitter. Setting a constraint's goal orientation instead lets the
-- solver do the rotating, so there is nothing to fight.

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Palette = require(ReplicatedStorage.Shared.Palette)

local CameraLock = {}

local TOGGLE_ACTION = "ToggleCameraLock"
local RENDER_STEP_NAME = "CameraLockFacing"

-- Nudges the character off-centre so the crosshair isn't buried in their head.
-- Matches the direction Roblox's built-in shift lock offsets to.
--
-- Deliberately smaller than Roblox's own 1.75. That much offset reads as
-- looking over someone's shoulder from a step to the left of them: the
-- character sits well off-centre and the crosshair ends up a long way from
-- where the body is pointing. One stud keeps the over-the-shoulder framing —
-- the head is still clear of the reticle — without the camera feeling like it
-- is standing somewhere the player isn't.
local SHOULDER_X = 1.0

-- How fast the shoulder offset eases in, out, and around walls, as a fraction
-- of the remaining distance per second. Snapping it is what made toggling the
-- lock feel like the camera teleporting.
local OFFSET_SMOOTHING = 14

-- The offset pushes the camera sideways *after* Roblox's camera has already
-- chosen somewhere clear to sit, so on the inside of a corner it can end up
-- looking through a wall. The offset is pulled in when there is something
-- solid that way, leaving this much clearance.
local WALL_MARGIN = 1.25

local player = Players.LocalPlayer
local locked = false

local attachment: Attachment? = nil
local alignOrientation: AlignOrientation? = nil

-- Eased toward the goal every frame rather than set.
local shoulderX = 0

-- A panel that needs the pointer (the skill tree) borrows it. The lock stays
-- on underneath, so closing the panel puts the camera straight back.
local cursorFree = false

local reticle: Frame? = nil

local function getHumanoid(): Humanoid?
	local character = player.Character
	if not character then
		return nil
	end
	return character:FindFirstChildOfClass("Humanoid")
end

local function getRoot(): BasePart?
	local character = player.Character
	if not character then
		return nil
	end
	return character:FindFirstChild("HumanoidRootPart") :: BasePart?
end

local function destroyConstraint()
	if alignOrientation then
		alignOrientation:Destroy()
		alignOrientation = nil
	end
	if attachment then
		attachment:Destroy()
		attachment = nil
	end
end

-- Rebuilt rather than reparented on respawn, since the old character's root is
-- gone and the constraint dies with it.
local function ensureConstraint(): AlignOrientation?
	local root = getRoot()
	if not root then
		return nil
	end

	if alignOrientation and alignOrientation.Parent == root then
		return alignOrientation
	end

	destroyConstraint()

	local newAttachment = Instance.new("Attachment")
	newAttachment.Name = "CameraLockAttachment"
	newAttachment.Parent = root

	local newAlign = Instance.new("AlignOrientation")
	newAlign.Name = "CameraLockOrientation"
	-- OneAttachment aligns the attachment to a world-space goal CFrame, which
	-- is what we want — there is no second part to align against.
	newAlign.Mode = Enum.OrientationAlignmentMode.OneAttachment
	newAlign.Attachment0 = newAttachment
	-- Rigid rather than springy: "always looks in the same direction" means the
	-- character should not lag behind the camera on a spring.
	newAlign.RigidityEnabled = true
	newAlign.Parent = root

	attachment = newAttachment
	alignOrientation = newAlign

	return newAlign
end

-- Applied on every toggle and again on respawn, since a new character comes
-- back with default AutoRotate and no camera offset.
local function applyToCharacter()
	local humanoid = getHumanoid()
	if not humanoid then
		return
	end

	-- AutoRotate turns the character toward its movement direction, which is
	-- exactly what the constraint is replacing. Leaving it on would be a third
	-- system competing for the same rotation.
	humanoid.AutoRotate = not locked

	if locked then
		ensureConstraint()
	else
		destroyConstraint()
		-- Eased back to centre by the render step while it still runs; if the
		-- lock went off, nothing is left to ease it, so it lands here.
		shoulderX = 0
		humanoid.CameraOffset = Vector3.zero
	end
end

-- How far the shoulder offset can go before it puts the camera through
-- something. Cast from the character, not the camera: the camera is behind
-- them, and it is the space beside *them* that the offset moves into.
local function clearOffset(root: BasePart, wanted: number): number
	local character = player.Character
	if not character or wanted <= 0 then
		return wanted
	end

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { character }
	params.IgnoreWater = true

	local direction = Workspace.CurrentCamera.CFrame.RightVector * (wanted + WALL_MARGIN)
	local hit = Workspace:Raycast(root.Position, direction, params)
	if not hit then
		return wanted
	end

	return math.max(hit.Distance - WALL_MARGIN, 0)
end

local function onRenderStep(deltaTime: number)
	if not locked then
		return
	end

	-- Other systems (and Roblox itself, on respawn or menu close) can reset
	-- this, so it's re-asserted rather than set once.
	if not cursorFree then
		UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
	end

	local humanoid = getHumanoid()
	local root = getRoot()
	if not humanoid or not root or humanoid.Health <= 0 then
		return
	end

	-- Exponential easing, framerate-independent: the same fraction of the way
	-- there per second whatever the frame rate.
	local goal = clearOffset(root, SHOULDER_X)
	shoulderX += (goal - shoulderX) * (1 - math.exp(-OFFSET_SMOOTHING * deltaTime))
	humanoid.CameraOffset = Vector3.new(shoulderX, 0, 0)

	local align = ensureConstraint()
	if not align then
		return
	end

	local look = Workspace.CurrentCamera.CFrame.LookVector
	-- Flattened to the XZ plane: looking up or down must not tip the character.
	local flat = Vector3.new(look.X, 0, look.Z)
	if flat.Magnitude < 1e-4 then
		return
	end

	-- Only the orientation of this CFrame is used, so the position stays at
	-- the origin. This is a goal for the solver, not a teleport.
	align.CFrame = CFrame.lookAt(Vector3.zero, flat.Unit)
end

--[[ The reticle ]]

-- A locked camera points somewhere, so it needs to show where. Four ticks
-- around a gap rather than a solid cross: the gap is where the enemy you are
-- reading is, and the game's whole combat is reading a wind-up.
--
-- Each tick carries a dark stroke, because a bone-white mark on torchlit
-- stone disappears exactly when a fight starts.
local RETICLE_TICK = 7
local RETICLE_THICKNESS = 2
local RETICLE_GAP = 5

local function buildTick(parent: Frame, position: UDim2, size: UDim2)
	local tick = Instance.new("Frame")
	tick.AnchorPoint = Vector2.new(0.5, 0.5)
	tick.Position = position
	tick.Size = size
	tick.BackgroundColor3 = Color3.fromRGB(table.unpack(Palette.BONE))
	tick.BackgroundTransparency = 0.15
	tick.BorderSizePixel = 0

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(table.unpack(Palette.VOID))
	stroke.Thickness = 1
	stroke.Transparency = 0.35
	stroke.Parent = tick

	tick.Parent = parent
end

local function buildReticle(): Frame
	local gui = Instance.new("ScreenGui")
	gui.Name = "CameraLockReticle"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = player:WaitForChild("PlayerGui")

	local frame = Instance.new("Frame")
	frame.Name = "Reticle"
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = UDim2.fromScale(0.5, 0.5)
	frame.Size = UDim2.fromOffset(1, 1)
	frame.BackgroundTransparency = 1
	frame.Visible = false
	frame.Parent = gui

	local offset = RETICLE_GAP + RETICLE_TICK / 2
	local across = UDim2.fromOffset(RETICLE_TICK, RETICLE_THICKNESS)
	local upright = UDim2.fromOffset(RETICLE_THICKNESS, RETICLE_TICK)

	buildTick(frame, UDim2.fromOffset(-offset, 0), across)
	buildTick(frame, UDim2.fromOffset(offset, 0), across)
	buildTick(frame, UDim2.fromOffset(0, -offset), upright)
	buildTick(frame, UDim2.fromOffset(0, offset), upright)

	return frame
end

function CameraLock.setLocked(value: boolean)
	locked = value
	applyToCharacter()

	if reticle then
		reticle.Visible = locked and not cursorFree
	end

	if locked then
		UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
		-- Runs after the camera has moved this frame, so the goal reflects
		-- where the camera actually ended up rather than lagging a frame.
		RunService:BindToRenderStep(RENDER_STEP_NAME, Enum.RenderPriority.Character.Value, onRenderStep)
	else
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		RunService:UnbindFromRenderStep(RENDER_STEP_NAME)
	end
end

function CameraLock.isLocked(): boolean
	return locked
end

-- Lends the pointer to a panel that needs clicking, and takes it back when
-- the panel closes. The reticle goes with it: a crosshair over a menu is
-- telling you to aim at a button.
function CameraLock.setCursorFree(value: boolean)
	cursorFree = value

	if cursorFree then
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	elseif locked then
		UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
	end

	if reticle then
		reticle.Visible = locked and not cursorFree
	end
end

function CameraLock.start()
	reticle = buildReticle()

	ContextActionService:BindAction(TOGGLE_ACTION, function(_, inputState)
		if inputState == Enum.UserInputState.Begin then
			CameraLock.setLocked(not locked)
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.KeyCode.LeftShift)

	player.CharacterAdded:Connect(function()
		-- The old constraint died with the old character.
		destroyConstraint()
		-- Wait for the Humanoid to exist before touching AutoRotate.
		task.defer(applyToCharacter)
	end)

	-- On by default: the combat slice is the reason this exists.
	CameraLock.setLocked(true)
end

return CameraLock
