--!strict
-- A bow's string and its arrows, on every character carrying one.
--
-- The bow model is welded parts, and a welded string cannot bend. So on each
-- client, for each character holding a bow:
--
--   * the built string is hidden and drawn instead as two segments, nock to
--     draw point to nock, where the draw point is the string hand whenever it
--     is behind the string and within an arrow's length of it — so drawing
--     the bow in the animation draws the string, with no animation data about
--     strings at all;
--   * while the string is drawn, the nocked arrow is drawn on it, lying back
--     from the string hand along the shelf;
--   * when the server says the shot went (Shots, via PlayerShot) the string
--     snaps straight, the arrow on it is gone, and an arrow flies from the
--     bow to where the shot landed. The string hand is still at the anchor at
--     that moment — the release is the impact frame — and moves off it after.
--
-- Purely a picture. The hit was resolved where the shot was taken; the arrow
-- is fast (WeaponDefs `shot.speed`) so that it reaches the target about when
-- the hit shows. Which characters get this is decided by their weapon model
-- having a string, not by what the weapon is called.

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local Palette = require(Shared.Palette)
local Remotes = require(Shared.Remotes)
local WeaponModelDefs = require(Shared.WeaponModelDefs)

local SoundFX = require(script.Parent.SoundFX)

local BowVFX = {}

local BOW = WeaponModelDefs.BOW
local STRING_PIECE = "BowString"
-- Built pieces the drawn string replaces.
local STRING_PIECES = { "BowString", "BowServing" }
-- Built pieces that are the arrow sitting on the string at rest.
local ARROW_PREFIX = "Arrow"

-- After a shot, how long the string stays straight and empty before the
-- next arrow is nocked. Long enough for the string hand to leave the draw.
local RELEASE_HOLD = 0.4
-- How far past the draw zone the string hand may go and still hold the
-- string, in studs, so a draw that is not quite on the string still draws it.
local REACH = 1.3

-- How long a missed arrow stays stuck where it landed.
local STUCK_FOR = 1.2
-- An arrow's drop over its flight, per stud travelled.
local DROP_PER_STUD = 0.02

local function rgb(values: { number }): Color3
	return Color3.fromRGB(values[1], values[2], values[3])
end

local SHAFT_COLOR = rgb(Palette.shade(Palette.OAK, 1.1))
local HEAD_COLOR = rgb(Palette.STEEL)
local FLETCH_COLOR = rgb(Palette.CRIMSON)
local STRING_COLOR = rgb(Palette.ROPE)

local folder: Folder? = nil

-- Where every client-side piece lives: out of the characters, so nothing
-- here can touch a body's physics or be mistaken for part of the rig.
local function effectFolder(): Folder
	if folder and folder.Parent then
		return folder
	end
	local created = Instance.new("Folder")
	created.Name = "BowVFX"
	created.Parent = Workspace
	folder = created
	return created
end

local function piece(name: string, size: Vector3, color: Color3, material: Enum.Material): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.Color = color
	part.Material = material
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	return part
end

-- An arrow: shaft, head and fletching, laid out along -Z from its nock.
type Arrow = { shaft: Part, head: Part, fletch: Part }

local function makeArrow(parent: Instance): Arrow
	local shaft = piece("ArrowShaft", Vector3.new(0.07, 0.07, BOW.arrowLength), SHAFT_COLOR, Enum.Material.Wood)
	local head = piece("ArrowHead", Vector3.new(0.1, 0.18, 0.4), HEAD_COLOR, Enum.Material.Metal)
	local fletch = piece("ArrowFletch", Vector3.new(0.04, 0.22, 0.5), FLETCH_COLOR, Enum.Material.Fabric)
	shaft.Parent = parent
	head.Parent = parent
	fletch.Parent = parent
	return { shaft = shaft, head = head, fletch = fletch }
end

-- Lays an arrow out with its nock at `nock`, pointing along `direction`.
local function placeArrow(arrow: Arrow, nock: Vector3, direction: Vector3)
	local frame = CFrame.lookAt(nock, nock + direction)
	local length = BOW.arrowLength
	arrow.shaft.CFrame = frame * CFrame.new(0, 0, -length / 2)
	arrow.head.CFrame = frame * CFrame.new(0, 0, -length - 0.1)
	arrow.fletch.CFrame = frame * CFrame.new(0, 0, -0.35)
end

local function showArrow(arrow: Arrow, visible: boolean)
	local transparency = if visible then 0 else 1
	arrow.shaft.Transparency = transparency
	arrow.head.Transparency = transparency
	arrow.fletch.Transparency = transparency
end

local function destroyArrow(arrow: Arrow)
	arrow.shaft:Destroy()
	arrow.head:Destroy()
	arrow.fletch:Destroy()
end

-- One bow being drawn on this client: its string segments and the arrow
-- that rides the string while it is drawn.
type Rig = {
	model: Model,
	upper: Part,
	lower: Part,
	arrow: Arrow,
	-- Where the drawn arrow was last frame, which is where a shot leaves from.
	nock: Vector3?,
	direction: Vector3?,
}

local rigs: { [Model]: Rig } = {}
local releasedUntil: { [Model]: number } = {}

local function destroyRig(character: Model)
	local rig = rigs[character]
	if not rig then
		return
	end
	rig.upper:Destroy()
	rig.lower:Destroy()
	destroyArrow(rig.arrow)
	rigs[character] = nil
end

local function newRig(model: Model): Rig
	local parent = effectFolder()
	local upper = piece("BowStringUpper", Vector3.new(0.05, 0.05, 1), STRING_COLOR, Enum.Material.Fabric)
	local lower = piece("BowStringLower", Vector3.new(0.05, 0.05, 1), STRING_COLOR, Enum.Material.Fabric)
	upper.Parent = parent
	lower.Parent = parent
	return { model = model, upper = upper, lower = lower, arrow = makeArrow(parent) }
end

-- A string segment from `a` to `b`.
local function span(part: Part, a: Vector3, b: Vector3)
	local length = (b - a).Magnitude
	part.Size = Vector3.new(0.05, 0.05, math.max(length, 0.05))
	part.CFrame = CFrame.lookAt((a + b) / 2, b)
end

-- The grip point of a hand: its grip attachment when the avatar has one,
-- which is where WeaponVisuals hung the bow, otherwise the hand's centre.
local function gripFrame(hand: BasePart, attachment: string): CFrame
	local grip = hand:FindFirstChild(attachment)
	if grip and grip:IsA("Attachment") then
		return hand.CFrame * CFrame.new(grip.Position)
	end
	return hand.CFrame
end

-- Sets a built piece's local visibility (this client only).
local function hideBuilt(model: Model, hidden: boolean, filter: (string) -> boolean)
	for _, child in model:GetChildren() do
		if child:IsA("BasePart") and filter(child.Name) then
			child.LocalTransparencyModifier = if hidden then 1 else 0
		end
	end
end

local function isStringPiece(name: string): boolean
	return table.find(STRING_PIECES, name) ~= nil
end

local function isRestArrow(name: string): boolean
	return string.sub(name, 1, #ARROW_PREFIX) == ARROW_PREFIX
end

-- One frame of one character's bow.
local function update(character: Model, model: Model, now: number)
	local bowHand = character:FindFirstChild("LeftHand")
	local stringHand = character:FindFirstChild("RightHand")
	if not (bowHand and bowHand:IsA("BasePart") and stringHand and stringHand:IsA("BasePart")) then
		destroyRig(character)
		return
	end

	local rig = rigs[character]
	if not rig or rig.model ~= model then
		destroyRig(character)
		rig = newRig(model)
		rigs[character] = rig
		hideBuilt(model, true, isStringPiece)
	end

	local bow = gripFrame(bowHand, "LeftGripAttachment")
	local upperNock = bow * Vector3.new(0, BOW.braceY, -BOW.nockZ)
	local lowerNock = bow * Vector3.new(0, BOW.braceY, BOW.nockZ)

	-- Where the string hand is, in the bow's own frame: +Y back toward the
	-- archer, the string at braceY, the arrow along -Y.
	local hand = bow:PointToObjectSpace(gripFrame(stringHand, "RightGripAttachment").Position)
	local released = now < (releasedUntil[character] or 0)
	local drawing = not released
		and hand.Y > BOW.braceY - 0.15
		and hand.Y < BOW.braceY + BOW.arrowLength + REACH
		and math.abs(hand.Z - BOW.arrowZ) < REACH
		and math.abs(hand.X) < REACH

	-- The draw point is the hand pulled onto the string's own plane: the
	-- string only moves back, never sideways off the bow, and never further
	-- than the arrow on it is long. That last matters in the gap between the
	-- shooter's own release and the server's word that the shot went: the
	-- hand is already flying back off the anchor, and the string should wait
	-- at full draw rather than follow it.
	local fullDraw = BOW.braceY + BOW.arrowLength - 0.2
	local drawnY = if drawing then math.clamp(hand.Y, BOW.braceY, fullDraw) else BOW.braceY
	local drawPoint = bow * Vector3.new(0, drawnY, BOW.arrowZ)
	span(rig.upper, upperNock, drawPoint)
	span(rig.lower, drawPoint, lowerNock)

	-- The built arrow is the one at rest on the string. Drawn, it is replaced
	-- by one riding the string back; just loosed, there is none at all.
	hideBuilt(model, drawing or released, isRestArrow)
	local direction = bow:VectorToWorldSpace(Vector3.new(0, -1, 0))
	if drawing then
		local nock = bow * Vector3.new(BOW.arrowX, drawnY, BOW.arrowZ)
		placeArrow(rig.arrow, nock, direction)
		rig.nock = nock
	else
		rig.nock = bow * Vector3.new(BOW.arrowX, BOW.braceY, BOW.arrowZ)
	end
	rig.direction = direction
	showArrow(rig.arrow, drawing)
end

-- Every character with a strung weapon, every frame.
local function step()
	local now = os.clock()
	local seen: { [Model]: boolean } = {}
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local model = character and character:FindFirstChild(WeaponModelDefs.MODEL_NAME)
		if character and model and model:IsA("Model") and model:FindFirstChild(STRING_PIECE) then
			seen[character] = true
			update(character, model, now)
		end
	end
	for character in rigs do
		if not seen[character] then
			destroyRig(character)
		end
	end
end

-- The spark where an arrow strikes.
local function strike(at: Vector3)
	local flash = piece("ArrowStrike", Vector3.new(0.4, 0.4, 0.4), HEAD_COLOR, Enum.Material.Neon)
	flash.Shape = Enum.PartType.Ball
	flash.CFrame = CFrame.new(at)
	flash.Transparency = 0.2
	flash.Parent = effectFolder()
	TweenService:Create(flash, TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = Vector3.new(2.4, 2.4, 2.4),
		Transparency = 1,
	}):Play()
	Debris:AddItem(flash, 0.25)
end

-- Flies one arrow from `origin` to `landing` at `speed`, dropping a little
-- over the distance and turning to follow its own path.
local function fly(origin: Vector3, landing: Vector3, speed: number, hit: boolean)
	local distance = (landing - origin).Magnitude
	if distance < 0.5 then
		return
	end
	local flight = distance / math.max(speed, 1)
	local drop = distance * DROP_PER_STUD
	local arrow = makeArrow(effectFolder())

	local trail = Instance.new("Trail")
	local tail = Instance.new("Attachment")
	local tip = Instance.new("Attachment")
	tail.Position = Vector3.new(0, 0, BOW.arrowLength / 2)
	tip.Position = Vector3.new(0, 0, -BOW.arrowLength / 2)
	tail.Parent = arrow.shaft
	tip.Parent = arrow.shaft
	trail.Attachment0 = tail
	trail.Attachment1 = tip
	trail.Color = ColorSequence.new(Color3.fromRGB(235, 230, 215))
	trail.Transparency = NumberSequence.new(0.55, 1)
	trail.Lifetime = 0.12
	trail.LightEmission = 0.4
	trail.FaceCamera = true
	trail.Parent = arrow.shaft

	local startedAt = os.clock()
	local previous = origin
	local connection: RBXScriptConnection? = nil
	connection = RunService.RenderStepped:Connect(function()
		local alpha = math.clamp((os.clock() - startedAt) / flight, 0, 1)
		-- Straight at the target, less a parabola that is zero at both ends:
		-- a flat shot, but not a laser.
		local sag = drop * 4 * alpha * (1 - alpha)
		local at = origin:Lerp(landing, alpha) - Vector3.new(0, sag, 0)
		local heading = at - previous
		if heading.Magnitude > 1e-4 then
			placeArrow(arrow, at - heading.Unit * BOW.arrowLength, heading.Unit)
		end
		previous = at

		if alpha >= 1 then
			if connection then
				connection:Disconnect()
			end
			if hit then
				strike(landing)
				SoundFX.playAt("arrow_hit", landing)
				destroyArrow(arrow)
			else
				-- A miss stays where it went in for a moment, then goes.
				task.delay(STUCK_FOR, destroyArrow, arrow)
			end
		end
	end)
end

-- The server's word that a shot went.
local function onShot(payload: { [string]: any })
	local landing = payload.landing
	local speed = payload.speed
	if typeof(landing) ~= "Vector3" or type(speed) ~= "number" then
		return
	end

	local shooter = Players:GetPlayerByUserId(payload.userId)
	local character = shooter and shooter.Character
	if not character then
		return
	end

	releasedUntil[character] = os.clock() + RELEASE_HOLD

	-- From the drawn arrow's head if this client has one on the string,
	-- otherwise from the shooter's chest.
	local rig = rigs[character]
	local origin: Vector3
	if rig and rig.nock and rig.direction then
		origin = rig.nock + rig.direction * BOW.arrowLength
	else
		local root = character:FindFirstChild("HumanoidRootPart")
		if not (root and root:IsA("BasePart")) then
			return
		end
		origin = root.Position + root.CFrame.LookVector * 2 + Vector3.new(0, 0.8, 0)
	end

	SoundFX.playAt("arrow_loose", origin)
	fly(origin, landing, speed, payload.hit == true)
end

function BowVFX.start()
	RunService.RenderStepped:Connect(step)
	Remotes.get("PlayerShot").OnClientEvent:Connect(onShot)
end

return BowVFX
