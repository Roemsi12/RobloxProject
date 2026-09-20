--!strict
-- Content checks for weapon models and sounds. Both are data read by code that
-- turns names into Roblox enums and asset IDs at runtime, where a typo only
-- shows up as an error in a live server — so the names are checked here.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local SoundDefs = require(Shared.SoundDefs)
local WeaponDefs = require(Shared.WeaponDefs)
local WeaponModelDefs = require(Shared.WeaponModelDefs)

local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local describe = JestGlobals.describe
local expect = JestGlobals.expect
local it = JestGlobals.it

-- Every body part a weapon piece may hang from: the R15 parts WeaponVisuals
-- knows how to find (with an R6 fallback). The torso is on the list for the
-- things a weapon carries rather than holds — a quiver, a sheath — which do
-- not belong on an arm.
local ATTACHABLE_PARTS = { "RightHand", "LeftHand", "RightLowerArm", "LeftLowerArm", "UpperTorso", "LowerTorso" }

-- Enum.Material and Enum.PartType names the models use. Pure modules can't
-- read Enum, so the valid names are listed here; add to this list only after
-- checking the name exists in Roblox.
local MATERIALS = {
	"SmoothPlastic", "Plastic", "Metal", "Wood", "WoodPlanks", "Fabric", "Glass",
	"Neon", "Slate", "Granite", "Marble", "Brick", "Cobblestone",
}
local SHAPES = { "Block", "Ball", "Cylinder" }

-- expect() on a { label, value } pair, so a failure names what failed
-- rather than just saying false was not true.
local function check(label: string, value: boolean)
	expect({ label, value }).toEqual({ label, true })
end

-- Whether a colour is three channels, each in 0-255.
local function validColor(rgb: { number }): boolean
	if #rgb ~= 3 then
		return false
	end
	for _, channel in rgb do
		if channel < 0 or channel > 255 then
			return false
		end
	end
	return true
end

describe("WeaponModelDefs", function()
	it("has a model for every weapon, and none for weapons that don't exist", function()
		for weaponId in WeaponDefs do
			check(`model for {weaponId}`, WeaponModelDefs.MODELS[weaponId] ~= nil)
		end
		for weaponId in WeaponModelDefs.MODELS do
			check(`weapon for model {weaponId}`, WeaponDefs[weaponId] ~= nil)
		end
	end)

	it("builds every piece from valid names, sizes and colours", function()
		for weaponId, model in WeaponModelDefs.MODELS do
			check(`{weaponId} glow colour`, validColor(model.glowColor))

			local names = {}
			for _, piece in model.pieces do
				local label = `{weaponId}.{piece.name}`
				check(`{label} unique name`, names[piece.name] == nil)
				names[piece.name] = true

				check(`{label} attaches to a known part`, table.find(ATTACHABLE_PARTS, piece.attachTo) ~= nil)
				check(`{label} colour`, validColor(piece.color))
				check(`{label} material`, table.find(MATERIALS, piece.material or "SmoothPlastic") ~= nil)
				check(`{label} shape`, table.find(SHAPES, piece.shape or "Block") ~= nil)

				expect(#piece.size).toBe(3)
				expect(#piece.offset).toBe(3)
				for _, extent in piece.size do
					check(`{label} positive size`, extent > 0)
				end
			end
		end
	end)

	it("shows nothing extra on an unupgraded weapon", function()
		local look = WeaponModelDefs.upgradeLook(0)
		expect(look.lightBrightness).toBe(0)
		expect(look.sparkleRate).toBe(0)
		expect(look.neon).toBe(false)
	end)

	-- Upgrades are visible progress: each tier must look at least as strong as
	-- the one before it.
	it("never looks weaker at a higher upgrade level", function()
		local previous = WeaponModelDefs.upgradeLook(0)
		for level = 1, 5 do
			local look = WeaponModelDefs.upgradeLook(level)
			check(`level {level} light`, look.lightBrightness >= previous.lightBrightness)
			check(`level {level} sparkles`, look.sparkleRate >= previous.sparkleRate)
			check(`level {level} neon`, look.neon or not previous.neon)
			previous = look
		end
		expect(WeaponModelDefs.upgradeLook(5).neon).toBe(true)
	end)
end)

describe("SoundDefs", function()
	it("has a swing sound for every weapon", function()
		for weaponId in WeaponDefs do
			check(`swing sound for {weaponId}`, SoundDefs.get(SoundDefs.swingSound(weaponId)) ~= nil)
		end
	end)

	it("points every sound at a real kind of asset, with sane levels", function()
		for name, def in SoundDefs.SOUNDS do
			local isAsset = string.match(def.id, "^rbxassetid://%d+$") ~= nil
			local isBuiltIn = string.match(def.id, "^rbxasset://sounds/[%w_]+%.%w+$") ~= nil
			check(`{name} id`, isAsset or isBuiltIn)
			check(`{name} volume`, def.volume > 0 and def.volume <= 2)
			check(`{name} pitch range`, def.pitchMin > 0 and def.pitchMin <= def.pitchMax)
		end
	end)

	it("picks pitches inside the range", function()
		local def = { id = "rbxassetid://1", volume = 1, pitchMin = 0.8, pitchMax = 1.2 }
		expect(SoundDefs.pitchFor(def, 0)).toBeCloseTo(0.8)
		expect(SoundDefs.pitchFor(def, 0.5)).toBeCloseTo(1.0)
		expect(SoundDefs.pitchFor(def, 1)).toBeCloseTo(1.2)
		expect(SoundDefs.pitchFor(def, 7)).toBeCloseTo(1.2)
	end)
end)
