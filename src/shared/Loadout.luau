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
-- start room and pick one from the weapon stands, which is the first step of
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

function Loadout.getDef(weaponId: string): WeaponDefs.WeaponDef
	local def = WeaponDefs[weaponId]
	assert(def, `No weapon def for "{weaponId}"`)
	return def
end

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
