--!strict
-- Puts everyone in the same body, and then dresses it the way they chose.
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
--   The LOOK is given back, from AppearanceDefs.outfitFor: our own clothing
--   textures as a Shirt, Pants and chest ShirtGraphic, face and marking
--   decals on the head, and a Roblox-made hair accessory dyed the colour they
--   picked. Every texture is tinted through Color3, which multiplies.
--
-- Server-built, like WeaponVisuals and for the same reason: everyone has to
-- see the same character, not just its owner.
--
-- Nothing here adds a part except the hair accessory, which Roblox attaches
-- massless and non-colliding itself, so a look never changes how a character
-- moves or what hit-reg reads: combat resolves against the HumanoidRootPart.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local AppearanceDefs = require(Shared.AppearanceDefs)
local AvatarTextures = require(Shared.AvatarTextures)
local Remotes = require(Shared.Remotes)

local AppearanceService = {}

-- What every instance this service makes is named, so re-dressing a body
-- replaces exactly what it made.
local SHIRT = "LookShirt"
local PANTS = "LookPants"
local OVERLAY = "LookOverlay"
local DECAL_PREFIX = "LookDecal"

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

local looks: { [Player]: AppearanceDefs.Look } = {}
-- Called with a player once their character has been rebuilt and dressed.
local dressedListeners: { (Player) -> () } = {}
-- Characters already dressed, so a second CharacterAdded for the same body
-- (or a look change racing a respawn) can be told apart from a new body.
local dressed: { [Player]: Model } = {}

-- A palette colour ({0-255, 0-255, 0-255}) as a Color3. Every colour in the
-- data files is a plain table so those files stay Roblox-free.
local function rgb(values: { number }): Color3
	return Color3.fromRGB(values[1], values[2], values[3])
end

-- The content id of a named avatar texture, or nil if it hasn't been
-- uploaded yet (AvatarTextures holds 0). Each missing name is warned about
-- once, so a half-uploaded set says what's missing without flooding output.
local warnedMissing: { [string]: boolean } = {}
local function textureId(name: string): string?
	local id = AvatarTextures[name]
	if id and id > 0 then
		return `rbxassetid://{id}`
	end
	if not warnedMissing[name] then
		warnedMissing[name] = true
		warn(`[AppearanceService] Avatar texture "{name}" has no image id yet; run "lune run upload-avatar"`)
	end
	return nil
end

--[[ The shared body ]]

-- A description with nothing on it but the look's hair: no bundle, no
-- clothes, at the blocky proportions the animations were authored against.
--
-- Built fresh rather than edited from the character's current one. Editing
-- theirs means every field we forget to clear is a piece of catalogue avatar
-- that survives, and the list of things Roblox can put on an avatar only ever
-- grows.
local function describeBody(look: AppearanceDefs.Look, outfit: AppearanceDefs.Outfit): HumanoidDescription
	local description = Instance.new("HumanoidDescription")

	local build = AppearanceDefs.buildOf(look.build)
	description.WidthScale = build.width
	description.DepthScale = build.depth
	description.HeightScale = build.height
	description.HeadScale = AppearanceDefs.HEAD_SCALE
	description.BodyTypeScale = AppearanceDefs.BODY_TYPE_SCALE
	description.ProportionScale = AppearanceDefs.PROPORTION_SCALE

	local skin = rgb(outfit.skin)
	for _, field in SKIN_FIELDS do
		(description :: any)[field] = skin
	end

	-- The face is our own decals (dress), so the avatar's face has to go or
	-- it shows through underneath.
	description.Face = 0

	-- The one catalogue piece of a look. Roblox loads it and hangs it off the
	-- head; dress dyes it.
	description.HairAccessory = if outfit.hair then tostring(outfit.hair) else ""
	description.HatAccessory = if outfit.hat then tostring(outfit.hat) else ""

	return description
end

--[[ The look ]]

-- Takes the texture off a catalogue accessory and dyes it one colour
-- instead. A hair's texture is painted in its own colour, and no tint turns
-- painted-on yellow hair black; bare, the mesh takes any colour and its
-- shape still reads through the lighting.
local function dye(accessory: Accessory, color: Color3)
	local handle = accessory:FindFirstChild("Handle")
	if not handle or not handle:IsA("BasePart") then
		return
	end
	for _, child in handle:GetDescendants() do
		if child:IsA("SurfaceAppearance") then
			child:Destroy()
		elseif child:IsA("SpecialMesh") then
			child.TextureId = ""
			child.VertexColor = Vector3.one
		end
	end
	if handle:IsA("MeshPart") then
		handle.TextureID = ""
	end
	handle.Color = color
	handle.Material = Enum.Material.SmoothPlastic
end

-- One classic clothing item, tinted, replacing any this service made before.
-- An item whose texture isn't uploaded yet is left off.
local function wear(character: Model, className: string, name: string, layer: AppearanceDefs.Layer)
	local existing = character:FindFirstChild(name)
	if existing then
		existing:Destroy()
	end

	local id = textureId(layer.texture)
	if not id then
		return
	end

	local item = Instance.new(className) :: any
	item.Name = name
	if className == "Shirt" then
		item.ShirtTemplate = id
	elseif className == "Pants" then
		item.PantsTemplate = id
	else
		item.Graphic = id
	end
	item.Color3 = rgb(layer.color)
	item.Parent = character
end

-- Puts a look's clothes, face and hair colour on a character that already
-- has the look's body. Safe to call again on the same character: everything
-- it makes is found by name and replaced.
local function dress(character: Model, outfit: AppearanceDefs.Outfit)
	wear(character, "Pants", PANTS, outfit.pants)
	wear(character, "Shirt", SHIRT, outfit.shirt)
	wear(character, "ShirtGraphic", OVERLAY, outfit.overlay)

	local head = character:FindFirstChild("Head")
	if head and head:IsA("BasePart") then
		-- Every decal on the head goes, not just ours: the default head brings
		-- a face of its own.
		for _, child in head:GetChildren() do
			if child:IsA("Decal") then
				child:Destroy()
			end
		end
		-- Bottom first: marking, face, eyes. ZIndex keeps that order.
		for index, layer in outfit.decals do
			local id = textureId(layer.texture)
			if id then
				local decal = Instance.new("Decal")
				decal.Name = `{DECAL_PREFIX}{index}`
				decal.Face = Enum.NormalId.Front
				decal.Texture = id
				decal.Color3 = rgb(layer.color)
				decal.ZIndex = index
				decal.Parent = head
			end
		end
	end

	local hairColor = rgb(outfit.hairColor)
	for _, child in character:GetChildren() do
		if child:IsA("Accessory") then
			dye(child, hairColor)
		end
	end
end

-- Replace the body, then dress it.
--
-- ApplyDescription rebuilds the character's parts and removes clothing, so
-- the look has to go on after it rather than before: dressing first would
-- put a face on a head that is about to be replaced.
local function apply(player: Player, character: Model)
	local look = looks[player]
	if not look then
		return
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end

	local outfit = AppearanceDefs.outfitFor(look)

	-- Yields, and a player can leave or respawn while it does.
	local ok, err = pcall(function()
		humanoid:ApplyDescription(describeBody(look, outfit))
	end)
	if not ok then
		warn(`[AppearanceService] Couldn't apply {player.Name}'s body: {err}`)
	end

	if player.Character ~= character or not character.Parent then
		return
	end

	dress(character, outfit)
	dressed[player] = character

	for _, listener in dressedListeners do
		task.spawn(listener, player)
	end
end

-- Rebuilds the player's body and look on their current character, if they
-- have one. Spawned rather than called, because applying yields.
local function reapply(player: Player)
	local character = player.Character
	if character and character.Parent then
		task.spawn(apply, player, character)
	end
end

-- Tells one player their own look, so the editor shows what the server
-- actually stored rather than what the client last asked for.
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

-- Calls `listener(player)` every time a player's character has been rebuilt
-- and dressed. Rebuilding can replace body parts, so anything welded to the
-- body (WeaponVisuals) re-welds from here.
function AppearanceService.onDressed(listener: (Player) -> ())
	table.insert(dressedListeners, listener)
end

--[[ The DataService contract ]]

function AppearanceService.hydrate(player: Player, look: AppearanceDefs.Look?)
	looks[player] = AppearanceDefs.sanitize(look)
	publish(player)
	reapply(player)
end

-- The look to write to the profile. Sanitised on the way out as well as
-- in, so a look can never be saved in a shape the loader would reject.
function AppearanceService.snapshot(player: Player): AppearanceDefs.Look
	return AppearanceDefs.sanitize(looks[player])
end

-- Forgets a player, on leave. Their character goes with them, so there is
-- nothing to undress.
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

-- Listens for edits and for characters appearing. Called from the server
-- bootstrap before any profile loads, so no character can ever be seen in
-- the avatar its player arrived wearing.
function AppearanceService.start()
	Remotes.get("SetAppearance").OnServerEvent:Connect(onSetAppearance)

	-- Follows one player's characters, dressing each as it appears. Does
	-- nothing until their profile has loaded: until then there is no look to
	-- apply, and `hydrate` does it when there is.
	local function watch(player: Player)
		player.CharacterAdded:Connect(function(character)
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
