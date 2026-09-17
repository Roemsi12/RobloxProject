--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local AbilityDefs = require(Shared.AbilityDefs)
local ProgressionDefs = require(Shared.ProgressionDefs)
local SkillTreeDefs = require(Shared.SkillTreeDefs)
local WeaponDefs = require(Shared.WeaponDefs)

local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local describe = JestGlobals.describe
local expect = JestGlobals.expect
local it = JestGlobals.it

-- Every node in a weapon's tree that hands out an ability.
local function capstones(weaponId: string): { any }
	local found = {}
	for _, node in (SkillTreeDefs.treeFor(weaponId) :: any).nodes do
		if node.ability then
			table.insert(found, node)
		end
	end
	return found
end

describe("the abilities themselves", function()
	it("has no duplicate ids", function()
		local seen: { [string]: boolean } = {}
		for _, id in AbilityDefs.ids() do
			expect(seen[id]).toBeNil()
			seen[id] = true
		end
	end)

	it("names every id it hands back", function()
		for _, id in AbilityDefs.ids() do
			expect((AbilityDefs.get(id) :: any).id).toBe(id)
		end
	end)

	-- An ability that lands on the frame you press it can't be read by anyone
	-- you are fighting, and everything else in this game can be.
	it("gives every ability a wind-up that can be seen", function()
		for _, id in AbilityDefs.ids() do
			expect((AbilityDefs.get(id) :: any).windup).toBeGreaterThanOrEqual(0.2)
		end
	end)

	-- A cooldown short enough to use every fight would make it the rotation
	-- rather than the moment it is meant to be.
	it("keeps every cooldown long enough to be a decision", function()
		for _, id in AbilityDefs.ids() do
			expect((AbilityDefs.get(id) :: any).cooldown).toBeGreaterThanOrEqual(10)
		end
	end)

	it("only uses kinds the server implements", function()
		local implemented = { burst = true, blink = true, mend = true, ward = true }
		for _, id in AbilityDefs.ids() do
			expect(implemented[(AbilityDefs.get(id) :: any).kind]).toBe(true)
		end
	end)

	it("staggers with everything that deals damage, and nothing that doesn't", function()
		for _, id in AbilityDefs.ids() do
			local def = AbilityDefs.get(id) :: any
			if def.kind == "burst" or def.kind == "blink" then
				expect(def.stagger).toBeGreaterThan(0)
			else
				expect(def.stagger).toBe(0)
			end
		end
	end)

	it("gives every ward a duration, and nothing else one", function()
		for _, id in AbilityDefs.ids() do
			local def = AbilityDefs.get(id) :: any
			if def.kind == "ward" then
				expect(def.duration).toBeGreaterThan(0)
				-- A reduction at or above 1 would be plain invulnerability.
				expect(def.power).toBeLessThan(0.75)
			else
				expect(def.duration).toBe(0)
			end
		end
	end)
end)

describe("abilities in the tree", function()
	-- The point of moving them there: an ability is something you spend
	-- points on, not something handed over with the weapon.
	it("grants every ability from a skill tree node", function()
		local granted: { [string]: boolean } = {}
		for _, weaponId in SkillTreeDefs.weaponIds() do
			for _, node in capstones(weaponId) do
				granted[node.ability] = true
			end
		end

		for _, id in AbilityDefs.ids() do
			expect({ id, granted[id] }).toEqual({ id, true })
		end
	end)

	it("only names abilities that exist", function()
		for _, weaponId in SkillTreeDefs.weaponIds() do
			for _, node in capstones(weaponId) do
				expect(AbilityDefs.get(node.ability)).never.toBeNil()
			end
		end
	end)

	-- One key per branch, and the branch decides the key.
	it("puts exactly one ability at the end of each branch", function()
		for _, weaponId in SkillTreeDefs.weaponIds() do
			local tree = SkillTreeDefs.treeFor(weaponId) :: any
			local perBranch: { [string]: number } = {}
			for _, node in capstones(weaponId) do
				perBranch[node.branch] = (perBranch[node.branch] or 0) + 1
				-- Always the deepest node of its branch: an ability halfway
				-- down would make the rest of the branch an afterthought.
				expect({ node.id, node.tier }).toEqual({ node.id, SkillTreeDefs.tiers(tree) })
			end
			for _, branch in tree.branches do
				expect({ weaponId, branch, perBranch[branch] }).toEqual({ weaponId, branch, 1 })
			end
		end
	end)

	it("unlocks nothing until a capstone is bought", function()
		for _, weaponId in SkillTreeDefs.weaponIds() do
			expect(SkillTreeDefs.abilities(weaponId, {})).toEqual({})
		end
	end)

	it("puts an unlocked ability on its own branch's key", function()
		local tree = SkillTreeDefs.treeFor("Daggers") :: any
		local slot = SkillTreeDefs.slotOf(tree, "Shadow") :: number
		expect(SkillTreeDefs.abilities("Daggers", { assassinate = 1 })[slot]).toBe("Shadowstep")
	end)

	-- Unlocking all three is possible at the cap, and costs more than half of
	-- everything you will ever earn — which leaves nowhere near enough for
	-- the ranks that make them hit hard. That is the trade the tree is for.
	it("costs over half a maxed player's points to unlock every ability", function()
		local budget = ProgressionDefs.pointsFor(ProgressionDefs.MAX_LEVEL)
		for _, weaponId in SkillTreeDefs.weaponIds() do
			local total = 0
			for _, node in capstones(weaponId) do
				local at: any = node
				while at do
					total += 1
					at = if at.requires then SkillTreeDefs.findNode(weaponId, at.requires) else nil
				end
			end
			-- The shared root is paid for once, not once per branch.
			total -= #capstones(weaponId) - 1
			expect({ weaponId, total > budget / 2, total <= budget }).toEqual({ weaponId, true, true })
		end
	end)

	-- ...but one has to be within reach well before the cap, or the early
	-- game has no abilities in it at all.
	it("puts the first ability within reach of a modest level", function()
		for _, weaponId in SkillTreeDefs.weaponIds() do
			local cheapest = math.huge
			for _, node in capstones(weaponId) do
				local at: any = node
				local cost = 0
				while at do
					cost += 1
					at = if at.requires then SkillTreeDefs.findNode(weaponId, at.requires) else nil
				end
				cheapest = math.min(cheapest, cost)
			end
			expect({ weaponId, cheapest <= ProgressionDefs.pointsFor(8) }).toEqual({ weaponId, true })
		end
	end)
end)

describe("AbilityDefs.resolve", function()
	local burst = AbilityDefs.get("ShieldBreak") :: any
	local ward = AbilityDefs.get("LastStand") :: any

	it("is the plain numbers with an empty tree", function()
		local resolved = AbilityDefs.resolve(burst, 0, 0)
		expect(resolved.cooldown).toBeCloseTo(burst.cooldown)
		expect(resolved.power).toBeCloseTo(burst.power)
	end)

	it("cuts the cooldown by the tree's reduction", function()
		expect(AbilityDefs.resolve(burst, 0.25, 0).cooldown).toBeCloseTo(burst.cooldown * 0.75)
	end)

	it("raises the power by the tree's bonus", function()
		expect(AbilityDefs.resolve(burst, 0, 0.5).power).toBeCloseTo(burst.power * 1.5)
	end)

	-- A ward's reduction never scales; power buys it seconds instead, so no
	-- combination of nodes can add up to being invulnerable.
	it("buys a ward seconds rather than more reduction", function()
		local resolved = AbilityDefs.resolve(ward, 0, 1)
		expect(resolved.power).toBeCloseTo(ward.power)
		expect(resolved.duration).toBeCloseTo(ward.duration * 2)
	end)

	it("never lets a cooldown go below a second", function()
		expect(AbilityDefs.resolve(burst, 5, 0).cooldown).toBe(1)
	end)

	-- What a maxed tree can actually do to a cooldown, which is the number
	-- that matters for balance.
	it("keeps a fully-specced cooldown respectable", function()
		for _, weaponId in SkillTreeDefs.weaponIds() do
			local best = 0
			for _, node in (SkillTreeDefs.treeFor(weaponId) :: any).nodes do
				if node.effects.abilityCooldown then
					best += node.effects.abilityCooldown * node.maxRank
				end
			end
			for _, node in capstones(weaponId) do
				local def = AbilityDefs.get(node.ability) :: any
				expect({ node.ability, AbilityDefs.resolve(def, best, 0).cooldown >= 5 }).toEqual({ node.ability, true })
			end
		end
	end)
end)

describe("abilities against the weapons that cast them", function()
	it("hits harder than a plain swing of the weapon", function()
		for _, weaponId in SkillTreeDefs.weaponIds() do
			for _, node in capstones(weaponId) do
				local def = AbilityDefs.get(node.ability) :: any
				if def.kind == "burst" or def.kind == "blink" then
					local harder = def.power > WeaponDefs[weaponId].attack.damage
					expect({ node.ability, harder }).toEqual({ node.ability, true })
				end
			end
		end
	end)

	it("reaches further than the weapon that casts it", function()
		for _, weaponId in SkillTreeDefs.weaponIds() do
			for _, node in capstones(weaponId) do
				local def = AbilityDefs.get(node.ability) :: any
				if def.radius > 0 then
					local further = def.radius > WeaponDefs[weaponId].attack.range
					expect({ node.ability, further }).toEqual({ node.ability, true })
				end
			end
		end
	end)
end)
