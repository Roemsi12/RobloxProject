--!strict
-- Damage resolution and server-side hit-reg geometry. Pure Luau — the
-- positional checks take plain vectors rather than Roblox instances so they
-- stay testable outside the engine.

local CombatConstants = require(script.Parent.CombatConstants)
local PostureMath = require(script.Parent.PostureMath)

local DamageMath = {}

export type Vec2 = { x: number, z: number }

-- Damage a parried attack still deals. Zero for now: a clean parry fully
-- negates, which keeps feedback unambiguous while the windows are being
-- tuned. If chip damage on parry is introduced later, log it in DESIGN.md
-- first.
local PARRIED_DAMAGE_MULTIPLIER = 0

-- Damage after a parry is taken into account: a parried hit is scaled by
-- PARRIED_DAMAGE_MULTIPLIER, anything else passes through untouched.
-- Blocking is not handled here — see `resolveBlock`.
function DamageMath.resolveIncoming(baseDamage: number, wasParried: boolean): number
	if wasParried then
		return baseDamage * PARRIED_DAMAGE_MULTIPLIER
	end

	return baseDamage
end

export type BlockOutcome = "unguarded" | "blocked" | "broken"

export type BlockResult = {
	outcome: BlockOutcome,
	-- Health damage that lands.
	damage: number,
	-- The defender's posture afterwards.
	posture: number,
}

-- An incoming hit against a player who may be guarding. `facing` is whether
-- the attacker is inside the guard's arc. A guard only stops parryable
-- attacks from the front. A blocked hit costs no health but fills posture; one
-- that fills it breaks the guard and lands in full.
function DamageMath.resolveBlock(
	damage: number,
	guarding: boolean,
	parryable: boolean,
	facing: boolean,
	posture: number,
	maxPosture: number?
): BlockResult
	if not guarding or not parryable or not facing or damage <= 0 then
		return { outcome = "unguarded", damage = damage, posture = posture }
	end

	local block = PostureMath.block(posture, damage, maxPosture)
	if block.broken then
		return { outcome = "broken", damage = damage, posture = block.posture }
	end

	return { outcome = "blocked", damage = 0, posture = block.posture }
end

export type OutgoingContext = {
	-- The target is in its post-parry stagger: the universal punish window.
	targetStaggered: boolean,
	-- The attacker is inside their own riposte window: the Assassin's payoff.
	riposteActive: boolean,
	riposteMultiplier: number,
}

-- Damage a player deals, after upgrades have already been applied to
-- baseDamage.
--
-- The two bonuses take the larger rather than multiplying. Both reward the
-- same thing — a parry that just landed — so stacking them would double-count
-- one skill expression: an Assassin riposting into a staggered target would
-- hit for 5x, dwarfing every other number in the game. With max(), the
-- riposte's value is that it applies to targets that AREN'T staggered, and
-- that it outlasts the stagger.
function DamageMath.resolveOutgoing(baseDamage: number, context: OutgoingContext): number
	local multiplier = 1

	if context.targetStaggered then
		multiplier = math.max(multiplier, CombatConstants.STAGGER_DAMAGE_MULTIPLIER)
	end

	if context.riposteActive then
		multiplier = math.max(multiplier, context.riposteMultiplier)
	end

	return baseDamage * multiplier
end

-- Per-class scaling of the base stagger. The Tank's payoff is control: a
-- longer stagger is a longer punish window for everyone.
function DamageMath.staggerDuration(baseDuration: number, staggerMultiplier: number): number
	return baseDuration * staggerMultiplier
end

-- Health after healing, clamped so it can neither exceed the maximum nor
-- revive something already at zero.
function DamageMath.applyHealing(currentHealth: number, maxHealth: number, healing: number): number
	return math.clamp(currentHealth + healing, 0, maxHealth)
end

-- Flattened to the XZ plane: rooms are flat, and ignoring height avoids an
-- attack whiffing because a player hopped.
function DamageMath.horizontalDistance(from: Vec2, to: Vec2): number
	local dx = to.x - from.x
	local dz = to.z - from.z
	return math.sqrt(dx * dx + dz * dz)
end

-- Angle between the attacker's facing and the direction to the target, in
-- degrees, always 0-180.
local function angleToTarget(attackerPos: Vec2, attackerFacing: Vec2, targetPos: Vec2): number
	local dx = targetPos.x - attackerPos.x
	local dz = targetPos.z - attackerPos.z
	local distance = math.sqrt(dx * dx + dz * dz)

	-- Target is exactly on top of the attacker; treat as directly in front
	-- rather than dividing by zero.
	if distance == 0 then
		return 0
	end

	local facingLength = math.sqrt(attackerFacing.x * attackerFacing.x + attackerFacing.z * attackerFacing.z)
	if facingLength == 0 then
		return 0
	end

	local dot = (dx * attackerFacing.x + dz * attackerFacing.z) / (distance * facingLength)
	-- Guard against floating-point drift pushing the cosine outside [-1, 1],
	-- which would make math.acos return NaN.
	dot = math.clamp(dot, -1, 1)

	return math.deg(math.acos(dot))
end

-- Whether `targetPos` lies within `arcDegrees` (total, centred on `facing`) of
-- where someone at `position` is facing, at any distance. For guards.
function DamageMath.isFacing(position: Vec2, facing: Vec2, targetPos: Vec2, arcDegrees: number): boolean
	return angleToTarget(position, facing, targetPos) <= arcDegrees / 2 + 1e-9
end

export type HitTestParams = {
	attackerPos: Vec2,
	attackerFacing: Vec2,
	targetPos: Vec2,
	range: number,
	arcDegrees: number,
}

-- Evaluated on the server against server-side positions at the moment of
-- impact. The client is never asked whether it was hit. Used for enemy
-- strikes, player swings, and duel swings alike.
function DamageMath.isInHitVolume(params: HitTestParams): boolean
	if DamageMath.horizontalDistance(params.attackerPos, params.targetPos) > params.range then
		return false
	end

	-- arcDegrees is the full cone width, so a 360 arc means omnidirectional.
	local halfArc = params.arcDegrees / 2
	return angleToTarget(params.attackerPos, params.attackerFacing, params.targetPos) <= halfArc
end

return DamageMath
