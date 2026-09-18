--!strict
-- Content checks for the character editor. The menu is generated from
-- AppearanceDefs.CATEGORIES and nothing else, so a category that names a field
-- the saved look doesn't have, or an option list with a duplicate id, shows up
-- as a row that silently does nothing rather than as an error.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local AppearanceDefs = require(Shared.AppearanceDefs)
local RigDefs = require(Shared.RigDefs)

local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local describe = JestGlobals.describe
local expect = JestGlobals.expect
local it = JestGlobals.it

local function check(label: string, value: boolean)
	expect({ label, value }).toEqual({ label, true })
end

local R15_PARTS = RigDefs.partNames()

local function isPart(name: string): boolean
	return table.find(R15_PARTS, name) ~= nil
end

local function eachPiece(callback: (label: string, piece: AppearanceDefs.Piece) -> ())
	for _, list in { AppearanceDefs.HAIR, AppearanceDefs.FACES, AppearanceDefs.MARKINGS, AppearanceDefs.GARB } do
		for _, option in list do
			for _, piece in option.pieces or {} do
				callback(`{option.id}/{piece.name}`, piece)
			end
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

describe("Appearance pieces", function()
	it("hangs every piece on a real R15 part", function()
		eachPiece(function(label, piece)
			check(`{label} attaches to {piece.attachTo}`, isPart(piece.attachTo))
		end)
	end)

	-- A piece that reaches a long way from the part it hangs on swings through
	-- the world when that part moves. Nothing here should be bigger than the
	-- body wearing it.
	it("keeps every piece a sane size, close to its part", function()
		eachPiece(function(label, piece)
			for axis = 1, 3 do
				check(`{label} size {axis}`, piece.size[axis] > 0 and piece.size[axis] <= 3)
				check(`{label} offset {axis}`, math.abs(piece.offset[axis]) <= 2.5)
			end
		end)
	end)

	it("gives every piece a name, unique within its option", function()
		for _, list in { AppearanceDefs.HAIR, AppearanceDefs.FACES, AppearanceDefs.MARKINGS, AppearanceDefs.GARB } do
			for _, option in list do
				local seen: { [string]: boolean } = {}
				for _, piece in option.pieces or {} do
					check(`{option.id}.{piece.name} unique`, piece.name ~= "" and not seen[piece.name])
					seen[piece.name] = true
				end
			end
		end
	end)

	-- Legs and hips are where a garb piece would clip through its own stride,
	-- and nothing in the editor is worth that.
	it("never dresses the legs", function()
		local legs = { "RightUpperLeg", "RightLowerLeg", "RightFoot", "LeftUpperLeg", "LeftLowerLeg", "LeftFoot" }
		eachPiece(function(label, piece)
			check(`{label} leaves the legs alone`, table.find(legs, piece.attachTo) == nil)
		end)
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
			trimColor = "nonsense",
		})

		expect(clean.build).toBe("heavy")
		expect(clean.hair).toBe("mohawk")
		expect(clean.face).toBe("grim")
		expect(clean.garb).toBe("robes")
		expect(clean.garbColor).toBe("crimson")

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

describe("AppearanceDefs.piecesFor", function()
	it("resolves every piece to a colour", function()
		local look = AppearanceDefs.default()
		local resolved = AppearanceDefs.piecesFor(look)
		check("builds something", #resolved > 0)
		for _, entry in resolved do
			local rgb = entry.color
			check(`{entry.piece.name} coloured`, typeof(rgb) == "table" and #rgb == 3)
		end
	end)

	it("tints a piece with the colour its look chose", function()
		local look = AppearanceDefs.default()
		look.hair = "long"
		look.hairColor = "white"

		local white = AppearanceDefs.colorOf(AppearanceDefs.HAIR_COLORS, "white")
		for _, entry in AppearanceDefs.piecesFor(look) do
			if entry.piece.tint == "hair" then
				expect(entry.color).toEqual(white)
			end
		end
	end)

	-- Every combination has to build, because every combination is reachable
	-- from the menu.
	it("builds every combination of hair, face, marking and garb", function()
		for _, hair in AppearanceDefs.HAIR do
			for _, face in AppearanceDefs.FACES do
				for _, marking in AppearanceDefs.MARKINGS do
					for _, garb in AppearanceDefs.GARB do
						local look = AppearanceDefs.default()
						look.hair, look.face, look.marking, look.garb = hair.id, face.id, marking.id, garb.id
						local ok = pcall(AppearanceDefs.piecesFor, look)
						check(`{hair.id}/{face.id}/{marking.id}/{garb.id}`, ok)
					end
				end
			end
		end
	end)

	-- Two pieces with the same name on the same part would weld on top of each
	-- other, and only one of them would ever be seen.
	it("never collides two piece names on one part", function()
		for _, hair in AppearanceDefs.HAIR do
			for _, face in AppearanceDefs.FACES do
				for _, marking in AppearanceDefs.MARKINGS do
					for _, garb in AppearanceDefs.GARB do
						local look = AppearanceDefs.default()
						look.hair, look.face, look.marking, look.garb = hair.id, face.id, marking.id, garb.id

						local seen: { [string]: boolean } = {}
						for _, entry in AppearanceDefs.piecesFor(look) do
							local key = `{entry.piece.attachTo}/{entry.piece.name}`
							check(`{hair.id}+{face.id}+{marking.id}+{garb.id}: {key}`, not seen[key])
							seen[key] = true
						end
					end
				end
			end
		end
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
