--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Loadout = require(Shared.Loadout)
local ProgressionDefs = require(Shared.ProgressionDefs)
local SkillTreeDefs = require(Shared.SkillTreeDefs)

local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local describe = JestGlobals.describe
local expect = JestGlobals.expect
local it = JestGlobals.it

local SWORD = "SwordAndShield"
local PLENTY = 99

describe("the trees themselves", function()
	it("gives every weapon a tree", function()
		for _, weaponId in Loadout.allWeaponIds() do
			expect(SkillTreeDefs.treeFor(weaponId)).never.toBeNil()
		end
	end)

	it("has no duplicate node ids inside a tree", function()
		for _, weaponId in SkillTreeDefs.weaponIds() do
			local seen = {}
			for _, node in (SkillTreeDefs.treeFor(weaponId) :: any).nodes do
				expect(seen[node.id]).toBeNil()
				seen[node.id] = true
			end
		end
	end)

	-- A node that requires something missing, or in another branch, is a node
	-- nobody can ever buy.
	it("only requires nodes that exist, higher up the tree", function()
		for _, weaponId in SkillTreeDefs.weaponIds() do
			local tree = SkillTreeDefs.treeFor(weaponId) :: any
			for _, node in tree.nodes do
				if node.requires then
					local parent = SkillTreeDefs.findNode(weaponId, node.requires)
					expect(parent).never.toBeNil()
					expect((parent :: any).tier).toBeLessThan(node.tier)
					-- Same branch, or the shared root every branch hangs off.
					local sameBranch = (parent :: any).branch == node.branch
					expect({ node.id, sameBranch or node.requires == tree.root }).toEqual({ node.id, true })
				end
			end
		end
	end)

	it("has exactly one node with no prerequisite, and names it as the root", function()
		for _, weaponId in SkillTreeDefs.weaponIds() do
			local tree = SkillTreeDefs.treeFor(weaponId) :: any
			local free = {}
			for _, node in tree.nodes do
				if not node.requires then
					table.insert(free, node.id)
				end
			end
			expect(free).toEqual({ tree.root })
		end
	end)

	-- Every node has to hang off the root, or it is drawn floating.
	it("connects every node back to the root", function()
		for _, weaponId in SkillTreeDefs.weaponIds() do
			local tree = SkillTreeDefs.treeFor(weaponId) :: any
			for _, node in tree.nodes do
				local at: any = node
				local steps = 0
				while at.requires and steps < #tree.nodes do
					at = SkillTreeDefs.findNode(weaponId, at.requires)
					steps += 1
				end
				expect({ node.id, (at :: any).id }).toEqual({ node.id, tree.root })
			end
		end
	end)

	-- A branch that forks is what makes it a tree rather than three columns.
	it("forks every branch at least once", function()
		for _, weaponId in SkillTreeDefs.weaponIds() do
			local tree = SkillTreeDefs.treeFor(weaponId) :: any
			for _, branch in tree.branches do
				local children: { [string]: number } = {}
				for _, node in tree.nodes do
					if node.branch == branch and node.requires then
						children[node.requires] = (children[node.requires] or 0) + 1
					end
				end
				local forked = false
				for _, count in children do
					if count > 1 then
						forked = true
					end
				end
				expect({ weaponId, branch, forked }).toEqual({ weaponId, branch, true })
			end
		end
	end)

	-- Two nodes in the same place would draw on top of each other.
	it("gives every node its own square of the grid", function()
		for _, weaponId in SkillTreeDefs.weaponIds() do
			local tree = SkillTreeDefs.treeFor(weaponId) :: any
			local taken: { [string]: boolean } = {}
			for _, node in tree.nodes do
				local key = `{node.tier}:{node.column}`
				expect({ weaponId, key, taken[key] }).toEqual({ weaponId, key, nil })
				taken[key] = true
				expect(node.column).toBeLessThan(SkillTreeDefs.columns(tree))
			end
		end
	end)

	it("only uses effect keys combat knows", function()
		local known = SkillTreeDefs.noModifiers()
		for _, weaponId in SkillTreeDefs.weaponIds() do
			for _, node in (SkillTreeDefs.treeFor(weaponId) :: any).nodes do
				for key in node.effects do
					expect(known[key]).never.toBeNil()
				end
			end
		end
	end)

	-- The whole point of a tree: at max level you still cannot have it all.
	it("costs more than a maxed player can ever spend", function()
		local budget = ProgressionDefs.pointsFor(ProgressionDefs.MAX_LEVEL)
		for _, weaponId in SkillTreeDefs.weaponIds() do
			local total = 0
			for _, node in (SkillTreeDefs.treeFor(weaponId) :: any).nodes do
				total += node.maxRank
			end
			expect(total).toBeGreaterThan(budget)
		end
	end)

	-- Every capstone has to be reachable on its own, or it is decoration.
	-- The cheapest route is one rank in each node on the way down to it.
	it("lets a maxed player reach every capstone", function()
		local budget = ProgressionDefs.pointsFor(ProgressionDefs.MAX_LEVEL)
		for _, weaponId in SkillTreeDefs.weaponIds() do
			local tree = SkillTreeDefs.treeFor(weaponId) :: any
			for _, node in tree.nodes do
				local at: any = node
				local cost = 0
				while at do
					cost += 1
					at = if at.requires then SkillTreeDefs.findNode(weaponId, at.requires) else nil
				end
				expect({ node.id, cost <= budget }).toEqual({ node.id, true })
			end
		end
	end)
end)

describe("SkillTreeDefs.canSpend", function()
	it("allows the root straight away", function()
		expect(SkillTreeDefs.canSpend(SWORD, {}, "oathbound", PLENTY).ok).toBe(true)
	end)

	-- Every branch hangs off the root, so the first point is never a choice.
	it("refuses a branch head until the root is bought", function()
		expect(SkillTreeDefs.canSpend(SWORD, {}, "iron_frame", PLENTY).reason).toBe("locked")
		expect(SkillTreeDefs.canSpend(SWORD, { oathbound = 1 }, "iron_frame", PLENTY).ok).toBe(true)
	end)

	it("refuses a node whose prerequisite is unbought", function()
		expect(SkillTreeDefs.canSpend(SWORD, {}, "deep_stance", PLENTY)).toEqual({ ok = false, reason = "locked" })
	end)

	it("allows it once one rank of the prerequisite is in", function()
		local allocation = { oathbound = 1, iron_frame = 1 }
		expect(SkillTreeDefs.canSpend(SWORD, allocation, "deep_stance", PLENTY).ok).toBe(true)
	end)

	it("refuses a node already at max rank", function()
		local node = SkillTreeDefs.findNode(SWORD, "iron_frame") :: any
		local allocation = { oathbound = 1, iron_frame = node.maxRank }
		expect(SkillTreeDefs.canSpend(SWORD, allocation, "iron_frame", PLENTY)).toEqual({
			ok = false,
			reason = "max_rank",
		})
	end)

	it("refuses when every point is already spent", function()
		expect(SkillTreeDefs.canSpend(SWORD, { oathbound = 1, iron_frame = 1 }, "iron_frame", 2)).toEqual({
			ok = false,
			reason = "no_points",
		})
	end)

	it("refuses ids it doesn't know", function()
		expect(SkillTreeDefs.canSpend(SWORD, {}, "free_wins", PLENTY).reason).toBe("unknown_node")
		expect(SkillTreeDefs.canSpend("Longbow", {}, "iron_frame", PLENTY).reason).toBe("unknown_weapon")
	end)

	-- A save may name nodes this server has never heard of. Counting them
	-- would spend points the player can't see on nodes it can't show them.
	it("ignores unknown nodes when counting what's spent", function()
		expect(SkillTreeDefs.spent(SWORD, { iron_frame = 1, from_the_future = 5 })).toBe(1)
	end)

	it("refuses a node whose weapon isn't the one asked about", function()
		expect(SkillTreeDefs.canSpend(SWORD, {}, "lightfoot", PLENTY).reason).toBe("unknown_node")
	end)

	it("counts a rank past a node's cap only once", function()
		local node = SkillTreeDefs.findNode(SWORD, "iron_frame") :: any
		expect(SkillTreeDefs.spent(SWORD, { iron_frame = 999 })).toBe(node.maxRank)
	end)
end)

describe("SkillTreeDefs.modifiers", function()
	it("is all zeros with nothing spent", function()
		local mods = SkillTreeDefs.modifiers(SWORD, {})
		for key, value in mods do
			expect(value).toBe(0)
			expect(SkillTreeDefs.EFFECTS[key]).never.toBeNil()
		end
	end)

	it("multiplies a node's effect by its ranks", function()
		local node = SkillTreeDefs.findNode(SWORD, "iron_frame") :: any
		expect(SkillTreeDefs.modifiers(SWORD, { iron_frame = 3 }).maxHealth).toBeCloseTo(node.effects.maxHealth * 3)
	end)

	it("adds up nodes that share an effect", function()
		local mods = SkillTreeDefs.modifiers(SWORD, { read_the_blade = 3, perfect_guard = 1 })
		local perRank = (SkillTreeDefs.findNode(SWORD, "read_the_blade") :: any).effects.parryWindow
		local capstone = (SkillTreeDefs.findNode(SWORD, "perfect_guard") :: any).effects.parryWindow
		expect(mods.parryWindow).toBeCloseTo(perRank * 3 + capstone)
	end)

	it("never counts more than a node's max rank", function()
		local node = SkillTreeDefs.findNode(SWORD, "unbroken") :: any
		expect(SkillTreeDefs.modifiers(SWORD, { unbroken = 50 }).maxHealth).toBeCloseTo(node.effects.maxHealth)
	end)

	it("ignores a tree's nodes when reading another tree", function()
		expect(SkillTreeDefs.modifiers("Daggers", { iron_frame = 3 }).maxHealth).toBe(0)
	end)

	it("survives junk in a saved allocation", function()
		local mods = SkillTreeDefs.modifiers(SWORD, { iron_frame = 0 / 0, deep_stance = -4 } :: any)
		expect(mods.maxHealth).toBe(0)
		expect(mods.maxPosture).toBe(0)
	end)

	-- The Assassin's backstab, promised in DESIGN.md since step 2.
	it("puts a real backstab at the end of the Assassin's Shadow branch", function()
		local full = SkillTreeDefs.modifiers("Daggers", { opening = 3, assassinate = 1 })
		expect(full.backstab).toBeGreaterThan(0.5)
	end)

	-- Every weapon needs a way to improve the ability it carries, or the
	-- ability is a flat number that never changes for twenty levels.
	it("lets every tree improve its weapon's ability", function()
		for _, weaponId in SkillTreeDefs.weaponIds() do
			local reachable = false
			for _, node in (SkillTreeDefs.treeFor(weaponId) :: any).nodes do
				if node.effects.abilityCooldown or node.effects.abilityPower then
					reachable = true
				end
			end
			expect({ weaponId, reachable }).toEqual({ weaponId, true })
		end
	end)
end)

describe("SkillTreeDefs.describe", function()
	it("writes a flat effect as a count", function()
		expect(SkillTreeDefs.describe({ maxHealth = 12 }, 1)).toEqual({ "+12 Max health" })
	end)

	it("scales the wording by the ranks asked for", function()
		expect(SkillTreeDefs.describe({ maxHealth = 12 }, 3)).toEqual({ "+36 Max health" })
	end)

	it("writes a fraction as a percentage", function()
		expect(SkillTreeDefs.describe({ damage = 0.05 }, 1)).toEqual({ "+5% Damage" })
	end)

	it("writes a reduction as a percentage off", function()
		expect(SkillTreeDefs.describe({ criticalCooldown = 0.15 }, 1)).toEqual({ "-15% Critical cooldown" })
	end)

	it("writes a duration in seconds", function()
		expect(SkillTreeDefs.describe({ parryWindow = 0.02 }, 1)).toEqual({ "+0.02s Parry window" })
	end)

	it("says nothing about an effect it has no wording for", function()
		expect(SkillTreeDefs.describe({ mystery = 1 }, 1)).toEqual({})
	end)

	-- Every node in the game has to be explainable in the panel.
	it("has wording for every node in every tree", function()
		for _, weaponId in SkillTreeDefs.weaponIds() do
			for _, node in (SkillTreeDefs.treeFor(weaponId) :: any).nodes do
				expect(#SkillTreeDefs.describe(node.effects, 1)).toBeGreaterThan(0)
			end
		end
	end)
end)
