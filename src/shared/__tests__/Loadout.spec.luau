--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CombatConstants = require(Shared.CombatConstants)
local Loadout = require(Shared.Loadout)
local WeaponDefs = require(Shared.WeaponDefs)

local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local describe = JestGlobals.describe
local expect = JestGlobals.expect
local it = JestGlobals.it

describe("Loadout.resolve", function()
	it("accepts a known weapon and returns its class", function()
		local result = Loadout.resolve("Daggers")
		expect(result.ok).toBe(true)
		expect(result.weaponId).toBe("Daggers")
		expect(result.classTag).toBe("Assassin")
	end)

	-- Weapon ids arrive from the client, so these are the anti-tamper cases.
	it("rejects an unknown weapon id", function()
		local result = Loadout.resolve("Excalibur")
		expect(result.ok).toBe(false)
		expect(result.reason).toBe("unknown_weapon")
	end)

	it("rejects a non-string payload", function()
		expect(Loadout.resolve(42).reason).toBe("invalid_weapon")
		expect(Loadout.resolve(nil).reason).toBe("invalid_weapon")
		expect(Loadout.resolve({}).reason).toBe("invalid_weapon")
	end)
end)

describe("Loadout class derivation", function()
	it("derives class from the weapon, never stored separately", function()
		expect(Loadout.classOf("SwordAndShield")).toBe("Tank")
		expect(Loadout.classOf("Daggers")).toBe("Assassin")
		expect(Loadout.classOf("Staff")).toBe("Healer")
	end)

	it("lists every defined weapon in stable order", function()
		local ids = Loadout.allWeaponIds()
		local count = 0
		for _ in WeaponDefs do
			count += 1
		end

		expect(#ids).toBe(count)
		-- Sorted, so debug keybinds map to the same weapon every session.
		expect(ids).toEqual({ "Bow", "Daggers", "Focus", "Greataxe", "Rapier", "Staff", "SwordAndShield" })
	end)
end)

describe("WeaponDefs invariants", function()
	-- These guard the design rather than the code: DESIGN.md ties class
	-- identity and skill expression to these fields, so a weapon missing one
	-- is a design bug, not just a nil index.
	it("gives every weapon a class, a parry profile and an attack profile", function()
		for weaponId, def in WeaponDefs do
			expect(def.classTag).never.toBeNil()
			expect(def.parry.earlyTolerance > 0).toBe(true)
			expect(def.parry.lateTolerance > 0).toBe(true)
			expect(def.attack.damage > 0).toBe(true)
			expect(def.attack.critical.cooldown > 0).toBe(true)
			expect(def.attack.critical.damageMultiplier > def.attack.combo[#def.attack.combo].damageMultiplier).toBe(true)
			expect(def.attack.pvpTelegraph > 0).toBe(true)
			expect(typeof(weaponId)).toBe("string")
		end
	end)

	it("keeps the early half of every window wider than the late half", function()
		-- Players anticipate the hit, so pressing early is the common honest
		-- mistake; this asymmetry is deliberate and applies to every class.
		for _, def in WeaponDefs do
			expect(def.parry.earlyTolerance > def.parry.lateTolerance).toBe(true)
		end
	end)

	it("gives the Assassin a tighter window than the Tank", function()
		local tank = WeaponDefs.SwordAndShield.parry
		local assassin = WeaponDefs.Daggers.parry
		local tankWidth = tank.earlyTolerance + tank.lateTolerance
		local assassinWidth = assassin.earlyTolerance + assassin.lateTolerance

		expect(assassinWidth < tankWidth).toBe(true)
	end)

	-- "Skill must count as much as level/gear": every class needs its parry to
	-- buy something, or parrying becomes optional for that class.
	it("gives every class a non-trivial parry payoff", function()
		for _, def in WeaponDefs do
			local payoff = def.payoff
			local hasPayoff = payoff.staggerMultiplier > 1
				or payoff.burstHeal > 0
				or payoff.riposteDuration > 0
			expect(hasPayoff).toBe(true)
		end
	end)

	-- The Healer pillar: healing reaches allies, so a burst heal with no
	-- radius would quietly turn back into a self-heal.
	it("gives every burst heal a radius that reaches allies", function()
		for _, def in WeaponDefs do
			if def.payoff.burstHeal > 0 then
				expect(def.payoff.burstHealRadius > 0).toBe(true)
			end
		end
	end)

	-- Riposte and the stagger bonus take the larger rather than stacking, so a
	-- riposte multiplier at or below the stagger bonus would add nothing
	-- against a staggered target and very little anywhere else.
	it("keeps every riposte above the universal stagger bonus", function()
		for _, def in WeaponDefs do
			if def.payoff.riposteDuration > 0 then
				expect(def.payoff.riposteMultiplier > CombatConstants.STAGGER_DAMAGE_MULTIPLIER).toBe(true)
			end
		end
	end)
end)

describe("Loadout combos", function()
	local attack = WeaponDefs.SwordAndShield.attack

	it("starts a combo at the first swing", function()
		expect(Loadout.nextComboStep(attack, 0, 10, 0)).toBe(1)
	end)

	it("continues inside the window and starts over outside it", function()
		expect(Loadout.nextComboStep(attack, 1, 10, 10.5)).toBe(2)
		expect(Loadout.nextComboStep(attack, 2, 10, 10.5)).toBe(3)
		expect(Loadout.nextComboStep(attack, 1, 11, 10.5)).toBe(1)
	end)

	it("starts over after the finisher", function()
		expect(Loadout.nextComboStep(attack, #attack.combo, 10, 99)).toBe(1)
	end)

	it("recovers longer from the finisher than from any other swing", function()
		for weaponId, def in WeaponDefs do
			local last = #def.attack.combo
			local finisher = Loadout.swingTiming(def.attack, last)
			expect({ weaponId, finisher.finisher }).toEqual({ weaponId, true })
			for step = 1, last - 1 do
				local timing = Loadout.swingTiming(def.attack, step)
				expect({ weaponId, step, timing.finisher }).toEqual({ weaponId, step, false })
				expect({ weaponId, step, finisher.readyAfter - finisher.windup > timing.readyAfter - timing.windup })
					.toEqual({ weaponId, step, true })
			end
		end
	end)

	-- A combo you can never continue isn't a combo: the window has to stay
	-- open past the moment the next swing is allowed.
	it("keeps every combo window open past the swing cooldown", function()
		for weaponId, def in WeaponDefs do
			for step = 1, #def.attack.combo - 1 do
				local timing = Loadout.swingTiming(def.attack, step)
				expect({ weaponId, step, timing.comboExpiresAfter > timing.readyAfter }).toEqual({ weaponId, step, true })
			end
		end
	end)

	it("gives every weapon a combo that ends in its hardest hit", function()
		for weaponId, def in WeaponDefs do
			local combo = def.attack.combo
			expect({ weaponId, #combo >= 2 }).toEqual({ weaponId, true })
			for step = 1, #combo - 1 do
				expect({ weaponId, combo[#combo].damageMultiplier > combo[step].damageMultiplier }).toEqual({ weaponId, true })
			end
		end
	end)
end)

-- The first playtest verdict on melee was "too fast, you can pretty much
-- spam". These are the floors that keeps it honest: a swing has to cost real
-- time, so the answer to a fight is never to hold the button down.
describe("melee pacing", function()
	local MIN_SWING_CYCLE = 0.3
	local MIN_FINISHER_CYCLE = 0.6

	it("never lets a swing come round faster than the floor", function()
		for weaponId, def in WeaponDefs do
			for step = 1, #def.attack.combo do
				local timing = Loadout.swingTiming(def.attack, step)
				local floor = if timing.finisher then MIN_FINISHER_CYCLE else MIN_SWING_CYCLE
				expect({ weaponId, step, timing.readyAfter >= floor }).toEqual({ weaponId, step, true })
			end
		end
	end)

	it("makes the finisher the slowest swing to recover from", function()
		for weaponId, def in WeaponDefs do
			local combo = def.attack.combo
			local finisher = Loadout.swingTiming(def.attack, #combo)
			for step = 1, #combo - 1 do
				local timing = Loadout.swingTiming(def.attack, step)
				expect({ weaponId, step, finisher.readyAfter > timing.readyAfter }).toEqual({ weaponId, step, true })
			end
		end
	end)

	-- A pause you can't see is a pause that reads as lag, not as commitment.
	it("gives every weapon a real pause between swings", function()
		for weaponId, def in WeaponDefs do
			expect({ weaponId, def.attack.recovery >= 0.12 }).toEqual({ weaponId, true })
		end
	end)

	-- Missing has to cost more than connecting, or mashing stays free.
	it("punishes a whiff harder than any weapon's own recovery", function()
		for weaponId, def in WeaponDefs do
			expect({ weaponId, CombatConstants.MISS_RECOVERY > def.attack.recovery }).toEqual({ weaponId, true })
		end
	end)

	-- The class pass added weapons at both ends of this: the Berserker is
	-- slower than the Tank now, and nothing is faster than the Assassin.
	it("keeps the Assassin the fastest and the Berserker the slowest", function()
		local function cycle(weaponId: string): number
			return Loadout.swingTiming(WeaponDefs[weaponId].attack, 1).readyAfter
		end
		expect(cycle("Daggers")).toBeLessThan(cycle("Staff"))
		expect(cycle("Staff")).toBeLessThan(cycle("SwordAndShield"))
		expect(cycle("SwordAndShield")).toBeLessThan(cycle("Greataxe"))

		local fastest, slowest = "Daggers", "Greataxe"
		for weaponId in WeaponDefs do
			expect({ weaponId, cycle(weaponId) >= cycle(fastest) }).toEqual({ weaponId, true })
			expect({ weaponId, cycle(weaponId) <= cycle(slowest) }).toEqual({ weaponId, true })
		end
	end)
end)
