--!strict
-- Content checks for the character editor. The menu is generated from
-- AppearanceDefs.CATEGORIES and nothing else, so a category that names a field
-- the saved look doesn't have, or an option list with a duplicate id, shows up
-- as a row that silently does nothing rather than as an error.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local AppearanceDefs = require(Shared.AppearanceDefs)
local AvatarTextures = require(Shared.AvatarTextures)

local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local describe = JestGlobals.describe
local expect = JestGlobals.expect
local it = JestGlobals.it

-- expect() on a { label, value } pair, so a failure names what failed
-- rather than just saying false was not true.
local function check(label: string, value: boolean)
	expect({ label, value }).toEqual({ label, true })
end

-- Every texture name a look can ask for, labelled by the choice that asks.
local function eachTexture(callback: (label: string, name: string) -> ())
	for _, garb in AppearanceDefs.GARB do
		callback(`garb {garb.id} shirt`, garb.shirt)
		callback(`garb {garb.id} pants`, garb.pants)
		callback(`garb {garb.id} overlay`, garb.overlay)
	end
	for _, face in AppearanceDefs.FACES do
		callback(`face {face.id}`, face.face)
		callback(`face {face.id} eyes`, face.eyes)
	end
	for _, marking in AppearanceDefs.MARKINGS do
		if marking.texture then
			callback(`marking {marking.id}`, marking.texture)
		end
	end
end

describe("Appearance categories", function()
	it("names a field the saved look actually has", function()
		local look = AppearanceDefs.default() :: any
		for _, category in AppearanceDefs.CATEGORIES do
			check(`{category.id} is a field`, look[category.id] ~= nil)
		end
	end)

	it("covers every field of the look", function()
		for field in AppearanceDefs.default() :: any do
			local covered = false
			for _, category in AppearanceDefs.CATEGORIES do
				covered = covered or category.id == field
			end
			check(`{field} has a category`, covered)
		end
	end)

	it("gives every category something to pick from", function()
		for _, category in AppearanceDefs.CATEGORIES do
			local choices = AppearanceDefs.choicesFor(category)
			check(`{category.id} has choices`, choices ~= nil and #choices > 0)
			check(`{category.id} has a label`, category.label ~= "")
		end
	end)

	it("keeps ids unique within a category, and labels non-empty", function()
		for _, category in AppearanceDefs.CATEGORIES do
			local seen: { [string]: boolean } = {}
			for _, choice in AppearanceDefs.choicesFor(category) do
				check(`{category.id}.{choice.id} unique`, not seen[choice.id])
				check(`{category.id}.{choice.id} labelled`, choice.label ~= nil and choice.label ~= "")
				seen[choice.id] = true
			end
		end
	end)

	-- The default has to be a real choice in every category, or a new player
	-- gets a look the editor can't show as selected.
	it("defaults to a choice that exists", function()
		local look = AppearanceDefs.default() :: any
		for _, category in AppearanceDefs.CATEGORIES do
			local found = AppearanceDefs.findById(AppearanceDefs.choicesFor(category), look[category.id])
			check(`{category.id} default exists`, found ~= nil)
		end
	end)

	it("gives every colour three channels in range", function()
		for _, category in AppearanceDefs.CATEGORIES do
			if category.kind ~= "color" then
				continue
			end
			for _, choice in AppearanceDefs.choicesFor(category) do
				local rgb = choice.rgb
				check(`{category.id}.{choice.id} has 3 channels`, typeof(rgb) == "table" and #rgb == 3)
				for index, channel in rgb do
					check(`{category.id}.{choice.id}[{index}] in range`, channel >= 0 and channel <= 255)
				end
			end
		end
	end)
end)

describe("Appearance textures and hair", function()
	-- A texture name AvatarTextures has never heard of is a layer that is
	-- silently never worn, whatever gets uploaded.
	it("names only textures AvatarTextures knows", function()
		eachTexture(function(label, name)
			check(`{label}: {name}`, AvatarTextures[name] ~= nil)
		end)
	end)

	it("gives every hairstyle at most one catalogue item, and a real id", function()
		for _, hair in AppearanceDefs.HAIR do
			check(`{hair.id} not both hair and hat`, not (hair.hair and hair.hat))
			for _, id in { hair.hair, hair.hat } do
				check(`{hair.id} id is a positive whole number`, math.floor(id) == id and id > 0)
			end
		end
	end)

	-- The first entry is the fallback for an unknown id, and a fallback
	-- should never put something on a head the player didn't pick.
	it("falls back to no hair and no marking", function()
		check("first hair is bare", AppearanceDefs.HAIR[1].hair == nil and AppearanceDefs.HAIR[1].hat == nil)
		check("first marking is bare", AppearanceDefs.MARKINGS[1].texture == nil)
	end)
end)

describe("AppearanceDefs.sanitize", function()
	it("passes a valid look through unchanged", function()
		local look = AppearanceDefs.default()
		expect(AppearanceDefs.sanitize(look)).toEqual(look)
	end)

	it("falls back field by field, never wholesale", function()
		local clean = AppearanceDefs.sanitize({
			build = "heavy",
			skin = "nonsense",
			hair = "mohawk",
			hairColor = "nonsense",
			face = "grim",
			marking = "nonsense",
			garb = "robes",
			garbColor = "crimson",
			legwearColor = "moss",
			trimColor = "nonsense",
		})

		expect(clean.build).toBe("heavy")
		expect(clean.hair).toBe("mohawk")
		expect(clean.face).toBe("grim")
		expect(clean.garb).toBe("robes")
		expect(clean.garbColor).toBe("crimson")
		expect(clean.legwearColor).toBe("moss")

		local fallback = AppearanceDefs.default()
		expect(clean.skin).toBe(fallback.skin)
		expect(clean.marking).toBe(fallback.marking)
		expect(clean.trimColor).toBe(fallback.trimColor)
	end)

	it("makes a look out of anything, including nothing", function()
		expect(AppearanceDefs.sanitize(nil)).toEqual(AppearanceDefs.default())
		expect(AppearanceDefs.sanitize(42)).toEqual(AppearanceDefs.default())
		expect(AppearanceDefs.sanitize({})).toEqual(AppearanceDefs.default())
	end)

	it("returns a fresh table rather than the one it was given", function()
		local source = AppearanceDefs.default()
		local clean = AppearanceDefs.sanitize(source)
		clean.skin = "corpse"
		expect(source.skin).never.toBe("corpse")
	end)
end)

describe("AppearanceDefs.outfitFor", function()
	-- Every combination has to build, because every combination is reachable
	-- from the menu.
	it("builds every combination of hair, face, marking and garb", function()
		for _, hair in AppearanceDefs.HAIR do
			for _, face in AppearanceDefs.FACES do
				for _, marking in AppearanceDefs.MARKINGS do
					for _, garb in AppearanceDefs.GARB do
						local look = AppearanceDefs.default()
						look.hair, look.face, look.marking, look.garb = hair.id, face.id, marking.id, garb.id
						local ok, outfit = pcall(AppearanceDefs.outfitFor, look)
						local label = `{hair.id}/{face.id}/{marking.id}/{garb.id}`
						check(label, ok)
						if ok then
							check(`{label} has a face and eyes`, #outfit.decals >= 2)
							for _, layer in outfit.decals do
								check(`{label} {layer.texture} coloured`, #layer.color == 3)
							end
						end
					end
				end
			end
		end
	end)

	it("tints each garment with its own colour", function()
		local look = AppearanceDefs.default()
		look.garbColor, look.legwearColor, look.trimColor = "crimson", "moss", "gold"
		local outfit = AppearanceDefs.outfitFor(look)

		expect(outfit.shirt.color).toEqual(AppearanceDefs.colorOf(AppearanceDefs.GARB_COLORS, "crimson"))
		expect(outfit.pants.color).toEqual(AppearanceDefs.colorOf(AppearanceDefs.GARB_COLORS, "moss"))
		expect(outfit.overlay.color).toEqual(AppearanceDefs.colorOf(AppearanceDefs.TRIM_COLORS, "gold"))
	end)

	it("dyes hair the hair colour and a hood the garb colour", function()
		local look = AppearanceDefs.default()
		look.hairColor, look.garbColor = "white", "moss"

		look.hair = "long"
		expect(AppearanceDefs.outfitFor(look).hairColor).toEqual(AppearanceDefs.colorOf(AppearanceDefs.HAIR_COLORS, "white"))

		look.hair = "hooded"
		local hooded = AppearanceDefs.outfitFor(look)
		check("a hood is a hat", hooded.hat ~= nil and hooded.hair == nil)
		expect(hooded.hairColor).toEqual(AppearanceDefs.colorOf(AppearanceDefs.GARB_COLORS, "moss"))
	end)

	-- Marking under the face, eyes on top of both: a mask has to cover a
	-- scar, and eyes have to show through a mask's slits.
	it("stacks marking, face, then eyes", function()
		local look = AppearanceDefs.default()
		look.marking, look.face = "scar", "masked"
		local decals = AppearanceDefs.outfitFor(look).decals
		expect(#decals).toBe(3)
		expect(decals[1].texture).toBe("mark_scar")
		expect(decals[2].texture).toBe("face_mask")
		expect(decals[3].texture).toBe("eyes_slits")
	end)
end)

describe("AppearanceDefs.BUILDS", function()
	-- The parry read depends on silhouettes staying comparable: a body twice
	-- as wide as another holding the same guard is a different pose.
	it("keeps every build close to standard", function()
		for _, build in AppearanceDefs.BUILDS do
			for _, axis in { "width", "depth", "height" } do
				local scale = (build :: any)[axis]
				check(`{build.id}.{axis}`, scale >= 0.85 and scale <= 1.2)
			end
		end
	end)

	it("has a standard build at exactly one", function()
		local standard = AppearanceDefs.buildOf("standard")
		expect(standard.width).toBe(1)
		expect(standard.depth).toBe(1)
		expect(standard.height).toBe(1)
	end)

	it("falls an unknown build back to standard", function()
		expect(AppearanceDefs.buildOf("colossal").id).toBe("standard")
		expect(AppearanceDefs.buildOf(nil).id).toBe("standard")
	end)
end)
