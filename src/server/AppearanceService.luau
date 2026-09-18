--!strict
-- Puts everyone in the same body, and then puts their own face on it.
--
-- Two halves, and they do different jobs:
--
--   The BODY is taken away from the player. A HumanoidDescription with no
--   bundle, no clothing and no accessories, at fixed proportions, replaces
--   whatever avatar they arrived wearing. That is what stops one player being
--   a penguin in a dungeon built out of one grim palette — and, less
--   obviously, it is what keeps combat readable: every stance, guard and tell
--   in the game is authored against R15's proportions, and a bundle that
--   moves the shoulders somewhere else makes a parry tell harder to read
--   through no fault of the person trying to read it.
--
--   The LOOK is given back. Hair, face, markings and garb are welded on top
--   from AppearanceDefs, tinted with the colours they chose.
--
-- Server-built, like WeaponVisuals and for the same reason: everyone has to
-- see the same character, not just its owner.
--
-- Pieces are massless, non-colliding and non-querying, so nothing here changes
-- how a character moves or what hit-reg reads — combat resolves against the
-- HumanoidRootPart alone, which this never touches.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local AppearanceDefs = require(Shared.AppearanceDefs)
local Remotes = require(Shared.Remotes)

local AppearanceService = {}

-- The model holding everything a look welds on, so re-applying is a destroy
-- and a rebuild rather than a diff.
local LOOK_MODEL = "CharacterLook"

-- The R15 parts a body colour applies to, and which HumanoidDescription field
-- carries each one.
local SKIN_FIELDS = {
	"HeadColor",
	"TorsoColor",
	"LeftArmColor",
	"RightArmColor",
	"LeftLegColor",
	"RightLegColor",
}

-- Where a piece on a hand is held from, if the avatar says.
local GRIP_ATTACHMENT: { [string]: string } = {
	RightHand = "RightGripAttachment",
	LeftHand = "LeftGripAttachment",
}

local looks: { [Player]: AppearanceDefs.Look } = {}
-- Characters already dressed, so a second CharacterAdded for the same body
-- (or a look change racing a respawn) doesn't build the pieces twice.
local dressed: { [Player]: Model } = {}

local function rgb(values: { number }): Color3
	return Color3.fromRGB(values[1], values[2], values[3])
end

local function vec(values: { number }): Vector3
	return Vector3.new(values[1], values[2], values[3])
end

local function pieceOffset(piece: AppearanceDefs.Piece): CFrame
	local rotation = piece.rotation or { 0, 0, 0 }
	return CFrame.new(vec(piece.offset))
		* CFrame.Angles(math.rad(rotation[1]), math.rad(rotation[2]), math.rad(rotation[3]))
end

--[[ The shared body ]]

-- A description with nothing on it: no bundle, no clothes, no hat, at the
-- blocky proportions the animations were authored against.
--
-- Built fresh rather than edited from the character's current one. Editing
-- theirs means every field we forget to clear is a piece of catalogue avatar
-- that survives, and the list of things Roblox can put on an avatar only ever
-- grows.
local function describeBody(look: AppearanceDefs.Look): HumanoidDescription
	local description = Instance.new("HumanoidDescription")

	local build = AppearanceDefs.buildOf(look.build)
	description.WidthScale = build.width
	description.DepthScale = build.depth
	description.HeightScale = build.height
	description.HeadScale = AppearanceDefs.HEAD_SCALE
	description.BodyTypeScale = AppearanceDefs.BODY_TYPE_SCALE
	description.ProportionScale = AppearanceDefs.PROPORTION_SCALE

	local skin = rgb(AppearanceDefs.colorOf(AppearanceDefs.SKIN_TONES, look.skin))
	for _, field in SKIN_FIELDS do
		(description :: any)[field] = skin
	end

	-- The face is built out of parts (AppearanceDefs), so the avatar's own
	-- face decal has to go or it shows through underneath.
	description.Face = 0

	return description
end

--[[ The look ]]

local function stripLook(character: Model)
	local existing = character:FindFirstChild(LOOK_MODEL)
	if existing then
		existing:Destroy()
	end
end

local function dress(character: Model, look: AppearanceDefs.Look)
	stripLook(character)

	local model = Instance.new("Model")
	model.Name = LOOK_MODEL

	for _, entry in AppearanceDefs.piecesFor(look) do
		local piece = entry.piece
		local host = character:FindFirstChild(piece.attachTo)
		if not host or not host:IsA("BasePart") then
			continue
		end

		local part = Instance.new("Part")
		part.Name = piece.name
		part.Size = vec(piece.size)
		part.Color = rgb(entry.color)
		part.Material = (Enum.Material :: any)[piece.material or "SmoothPlastic"]
		part.Shape = (Enum.PartType :: any)[piece.shape or "Block"]
		part.Transparency = piece.transparency or 0
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.Massless = true
		part.CastShadow = true
		part.TopSurface = Enum.SurfaceType.Smooth
		part.BottomSurface = Enum.SurfaceType.Smooth

		local anchor = CFrame.identity
		local gripName = GRIP_ATTACHMENT[piece.attachTo]
		local grip = gripName and host:FindFirstChild(gripName)
		if grip and grip:IsA("Attachment") then
			anchor = CFrame.new(grip.Position)
		end

		local c0 = anchor * pieceOffset(piece)
		part.CFrame = host.CFrame * c0
		part.Parent = model

		local weld = Instance.new("Weld")
		weld.Part0 = host
		weld.Part1 = part
		weld.C0 = c0
		weld.Parent = part
	end

	model.Parent = character
end

-- Replace the body, then dress it.
--
-- ApplyDescription rebuilds the character's parts, so the pieces have to be
-- welded after it rather than before: welding first would hang a haircut off
-- a head that is about to be replaced.
local function apply(player: Player, character: Model)
	local look = looks[player]
	if not look then
		return
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end

	-- Yields, and a player can leave or respawn while it does.
	local ok, err = pcall(function()
		humanoid:ApplyDescription(describeBody(look))
	end)
	if not ok then
		warn(`[AppearanceService] Couldn't apply {player.Name}'s body: {err}`)
	end

	if player.Character ~= character or not character.Parent then
		return
	end

	dress(character, look)
	dressed[player] = character
end

local function reapply(player: Player)
	local character = player.Character
	if character and character.Parent then
		task.spawn(apply, player, character)
	end
end

local function publish(player: Player)
	local look = looks[player]
	if look then
		Remotes.get("AppearanceChanged"):FireClient(player, { appearance = look })
	end
end

--[[ Editing ]]

-- A look the client asked for. Every field is checked against what this server
-- knows before it is stored (AppearanceDefs.sanitize), so the worst a client
-- can do by lying is give itself a look that already exists in the menu.
local function onSetAppearance(player: Player, payload: unknown)
	if not looks[player] then
		return
	end

	local requested = if typeof(payload) == "table" then (payload :: any).appearance else nil
	local clean = AppearanceDefs.sanitize(requested)

	looks[player] = clean
	publish(player)
	reapply(player)
end

--[[ The DataService contract ]]

function AppearanceService.hydrate(player: Player, look: AppearanceDefs.Look?)
	looks[player] = AppearanceDefs.sanitize(look)
	publish(player)
	reapply(player)
end

function AppearanceService.snapshot(player: Player): AppearanceDefs.Look
	return AppearanceDefs.sanitize(looks[player])
end

function AppearanceService.release(player: Player)
	looks[player] = nil
	dressed[player] = nil
end

-- What the hub's mirror calls. Diegetic, like the altars: the prompt fires
-- server-side with the player attached, so opening the editor needs no
-- client-callable remote of its own.
function AppearanceService.openEditor(player: Player)
	if looks[player] then
		Remotes.get("OpenAppearanceEditor"):FireClient(player, { appearance = looks[player] })
	end
end

function AppearanceService.start()
	Remotes.get("SetAppearance").OnServerEvent:Connect(onSetAppearance)

	local function watch(player: Player)
		player.CharacterAdded:Connect(function(character)
			-- Only once the profile has loaded. Until then there is no look to
			-- apply, and hydrate will do it when there is.
			if looks[player] then
				task.spawn(apply, player, character)
			end
		end)
	end

	Players.PlayerAdded:Connect(watch)
	for _, player in Players:GetPlayers() do
		watch(player)
	end

	Players.PlayerRemoving:Connect(AppearanceService.release)
end

return AppearanceService
