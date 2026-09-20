--!strict
-- Weapon equipping, and the derivation of class from weapon.
-- Pure Luau — no Roblox API, no player state held here.
--
-- Exists so "class = equipped weapon" has exactly one implementation. Anything
-- wanting a player's class asks for their weapon's classTag through here
-- rather than storing a class of its own, which is what stops the two from
-- ever drifting apart.

local WeaponDefs = require(script.Parent.WeaponDefs)

local Loadout = {}

-- There is deliberately no default weapon. Players start unequipped in the safe
-- hub and take one from a class altar, which is the first step of
-- DESIGN.md's core loop ("choose a weapon at start").

export type EquipResult = {
	ok: boolean,
	weaponId: string?,
	classTag: string?,
	reason: string?,
}

-- Equip requests can originate on the client (the Studio-only debug hotkeys),
-- so the id is treated as untrusted input and checked against the definition
-- table rather than assumed valid.
function Loadout.resolve(weaponId: unknown): EquipResult
	if type(weaponId) ~= "string" then
		return { ok = false, reason = "invalid_weapon" }
	end

	local def = WeaponDefs[weaponId]
	if not def then
		return { ok = false, reason = "unknown_weapon" }
	end

	return { ok = true, weaponId = weaponId, classTag = def.classTag }
end

-- A weapon's definition. Asserts rather than returning nil: every weapon
-- id in the game comes from WeaponDefs, so a miss is a typo or stale save
-- data reaching code that should have validated it first.
function Loadout.getDef(weaponId: string): WeaponDefs.WeaponDef
	local def = WeaponDefs[weaponId]
	assert(def, `No weapon def for "{weaponId}"`)
	return def
end

-- The class a weapon makes you. The only way class is ever derived —
-- nothing stores a class, which is what makes "switching weapon switches
-- class" true by construction.
function Loadout.classOf(weaponId: string): string
	return Loadout.getDef(weaponId).classTag
end

-- Which combo step a swing pressed at `now` is. `previousStep` is the step of
-- the last swing (0 if none), and `comboExpiresAt` when its window closes.
-- Continuing past the finisher starts over at 1. Shared by the server, which
-- decides, and the client, which predicts the animation.
function Loadout.nextComboStep(attack: WeaponDefs.AttackProfile, previousStep: number, now: number, comboExpiresAt: number): number
	if previousStep >= 1 and previousStep < #attack.combo and now <= comboExpiresAt then
		return previousStep + 1
	end
	return 1
end

export type SwingTiming = {
	windup: number,
	-- From the press until another swing may start.
	readyAfter: number,
	-- From the press until the combo window closes.
	comboExpiresAfter: number,
	damageMultiplier: number,
	finisher: boolean,
}

-- Every time this swing is worth knowing: its windup, how long the combo
-- stays open after it, and when the next press is allowed. The finisher
-- (the last step) pays the longer recovery.
function Loadout.swingTiming(attack: WeaponDefs.AttackProfile, step: number): SwingTiming
	local combo = attack.combo[step]
	assert(combo, `No combo step {step}`)
	local finisher = step == #attack.combo
	return {
		windup = combo.windup,
		readyAfter = combo.windup + (if finisher then attack.finisherRecovery else attack.recovery),
		comboExpiresAfter = combo.windup + attack.comboWindow,
		damageMultiplier = combo.damageMultiplier,
		finisher = finisher,
	}
end

-- Stable, sorted list so the debug keybinds and any future UI agree on order
-- regardless of table iteration order.
function Loadout.allWeaponIds(): { string }
	local ids = {}
	for weaponId in WeaponDefs do
		table.insert(ids, weaponId)
	end
	table.sort(ids)
	return ids
end

return Loadout
