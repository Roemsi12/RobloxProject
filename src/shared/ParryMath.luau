--!strict
-- The parry decision, in full. Pure Luau: takes numbers, returns a verdict,
-- touches no Roblox API and holds no state. Every branch here is covered by
-- ParryMath.spec.luau, because this is the module where "server-authoritative"
-- either holds or quietly doesn't.
--
-- Used identically for PvE and PvP: a duel parry is the same decision with a
-- player's swing standing in for an enemy's attack.

local CombatConstants = require(script.Parent.CombatConstants)
local WeaponDefs = require(script.Parent.WeaponDefs)

local ParryMath = {}

local BOUNDARY_EPSILON = 1e-9

export type Verdict =
	-- Timestamp failed the authority checks; the attempt never reaches the window.
	"rejected_future" | "rejected_stale"
	-- Attack cannot be parried at all, whatever the timing.
	| "unparryable"
	-- Timing verdicts.
	| "early" | "late" | "parried"

export type Evaluation = {
	verdict: Verdict,
	success: boolean,
	-- Signed offset from impact in milliseconds: negative early, positive late.
	-- Surfaced to the debug HUD, because tuning windows by feel without the
	-- actual miss distance is guesswork.
	deltaMs: number,
}

export type EvaluateParams = {
	-- Server time the client claims it pressed parry.
	attemptTime: number,
	-- Server time right now, from the authoritative clock.
	serverNow: number,
	-- Half the player's round-trip ping, as measured by the server.
	halfPing: number,
	-- Server time this attack lands.
	impactTime: number,
	parryProfile: WeaponDefs.ParryProfile,
	attackParryable: boolean,
}

-- The span of claimed send times the server will believe, given when the
-- message arrived and how laggy this player is.
--
-- This combines two approaches. The client's own timestamp is precise, so an
-- honest player gets judged on exactly when they pressed. But the client also
-- knows when the attack lands — it has to, to draw the telegraph — so on its
-- own a timestamp could be set to impactTime and sent at leisure. Receipt time
-- minus half the ping is an estimate the client cannot choose, so the claim is
-- only believed when it sits close to that estimate.
function ParryMath.plausibleSendWindow(serverNow: number, halfPing: number): (number, number)
	-- Clamped so a spoofed or absurd ping reading can't drag the estimate
	-- outside the hard limits below.
	local clampedHalfPing = math.clamp(halfPing, 0, CombatConstants.MAX_ACCEPTED_LATENCY)

	local expectedSend = serverNow - clampedHalfPing
	local tolerance = CombatConstants.MIN_TIMESTAMP_TOLERANCE
		+ clampedHalfPing * CombatConstants.TIMESTAMP_TOLERANCE_PING_FRACTION

	local earliest = math.max(expectedSend - tolerance, serverNow - CombatConstants.MAX_ACCEPTED_LATENCY)
	local latest = math.min(expectedSend + tolerance, serverNow + CombatConstants.FUTURE_TOLERANCE)

	return earliest, latest
end

-- Whether the client's claimed press time is plausible, or the rejection
-- verdict saying why not.
--
-- The anti-cheat half of a parry. A client that knows impactTime — and it
-- must, to draw the telegraph — could otherwise claim a perfect press at
-- any moment; this bounds the claim to when it could honestly have been
-- sent, allowing for their ping.
local function checkTimestamp(attemptTime: number, serverNow: number, halfPing: number): Verdict?
	local earliest, latest = ParryMath.plausibleSendWindow(serverNow, halfPing)

	-- Claims a later press than could have produced a message arriving now.
	if attemptTime > latest then
		return "rejected_future"
	end

	-- Claims an earlier press than the connection accounts for.
	if attemptTime < earliest then
		return "rejected_stale"
	end

	return nil
end

-- Judges one parry press: whether it is trusted, whether it caught the
-- hit, and how far off it was in milliseconds.
--
-- The timestamp check runs first — a press that cannot be trusted is
-- rejected without ever being compared against the window, so a spoofed
-- time can never read as a perfect parry.
function ParryMath.evaluate(params: EvaluateParams): Evaluation
	local deltaSeconds = params.attemptTime - params.impactTime
	local deltaMs = deltaSeconds * 1000

	local rejection = checkTimestamp(params.attemptTime, params.serverNow, params.halfPing)
	if rejection then
		return { verdict = rejection, success = false, deltaMs = deltaMs }
	end

	if not params.attackParryable then
		return { verdict = "unparryable", success = false, deltaMs = deltaMs }
	end

	-- Window is anchored to impact, not to the start of the windup, so it stays
	-- correct regardless of how long a given attack telegraphs for.
	--
	-- BOUNDARY_EPSILON keeps the window genuinely inclusive at both ends: the
	-- timestamps being compared are accumulated floats, so a press landing on
	-- the boundary can come out a few ulps outside it and lose a parry the
	-- player earned. A nanosecond of slack is far below anything a human can
	-- express, so it costs nothing and makes the boundary deterministic.
	if deltaSeconds < -(params.parryProfile.earlyTolerance + BOUNDARY_EPSILON) then
		return { verdict = "early", success = false, deltaMs = deltaMs }
	end

	if deltaSeconds > params.parryProfile.lateTolerance + BOUNDARY_EPSILON then
		return { verdict = "late", success = false, deltaMs = deltaMs }
	end

	return { verdict = "parried", success = true, deltaMs = deltaMs }
end

-- Whether a claimed press time is believable, as the server judges it. nil
-- when it is; otherwise the rejection verdict. Used for parry and dodge
-- presses alike, since both are reactions timed against a telegraph.
function ParryMath.validateTimestamp(attemptTime: number, serverNow: number, halfPing: number): Verdict?
	return checkTimestamp(attemptTime, serverNow, halfPing)
end

-- Whether a parry press at `pressTime` catches a hit landing at `impactTime`:
-- the press opened its frames no more than earlyTolerance before the hit, and
-- no more than lateTolerance after it (the slack for a press and a hit that
-- land within a frame of each other).
function ParryMath.catches(pressTime: number, parryProfile: WeaponDefs.ParryProfile, impactTime: number): boolean
	local delta = pressTime - impactTime
	return delta >= -(parryProfile.earlyTolerance + BOUNDARY_EPSILON)
		and delta <= parryProfile.lateTolerance + BOUNDARY_EPSILON
end

-- A copy of `profile` with its window widened by `seconds` — what the skill
-- trees' parryWindow effect buys (SkillTreeDefs).
--
-- Split evenly across both halves rather than added to the late one. The
-- effect has to read as "a wider window": all of it on the late side would
-- quietly teach players to press after the hit, which is the opposite of
-- what a parry is.
function ParryMath.widen(profile: WeaponDefs.ParryProfile, seconds: number): WeaponDefs.ParryProfile
	if seconds == 0 then
		return profile
	end

	local half = seconds / 2
	local widened = table.clone(profile)
	widened.earlyTolerance = math.max(profile.earlyTolerance + half, 0)
	widened.lateTolerance = math.max(profile.lateTolerance + half, 0)
	return widened
end

-- Whether a new press gets parry frames. It doesn't if the previous press
-- caught nothing and its cooldown (from the end of its frames) hasn't run out:
-- such a press only blocks.
function ParryMath.pressOpensFrames(
	previousPressTime: number?,
	previousCaught: boolean,
	parryProfile: WeaponDefs.ParryProfile,
	now: number
): boolean
	if previousPressTime == nil or previousCaught then
		return true
	end
	return now >= previousPressTime + parryProfile.earlyTolerance + CombatConstants.PARRY_COOLDOWN
end

-- Whether `t` falls inside a window of `duration` starting at `startTime`
-- (a dodge's invulnerability).
function ParryMath.withinWindow(startTime: number?, duration: number, t: number): boolean
	if startTime == nil then
		return false
	end
	return t >= startTime - BOUNDARY_EPSILON and t <= startTime + duration + BOUNDARY_EPSILON
end


-- When a player hit by an attack landing at `impactTime` can act again.
--
-- Before this moment a parry press is not merely mistimed, it is *discarded*:
-- `CombatServer.onParryAttempt` returns early on a stunned victim and the
-- guard does not even rise. So an attack whose impact lands inside this window
-- is unanswerable by construction, however clean its tell is.
--
-- This came from the chain module and outlived it. Chaining was where the
-- problem was first noticed -- a follow-up landing too soon after the first
-- hit -- but the floor is a property of hitstun, not of chains, and any
-- decision about when an enemy may next commit has to respect it.
function ParryMath.agencyRegainedAt(impactTime: number): number
	return impactTime + CombatConstants.STRIKE_RESOLUTION_GRACE + CombatConstants.PLAYER_HIT_STUN
end

--[[ What a player can react to ]]

-- The span of reaction times the game is built to serve: from a quick player
-- to an ordinary one, measured from the tell landing to the key going down.
--
-- These two numbers are the whole basis of what a readable attack is, and they
-- give a *band*, not a floor. That distinction was got wrong once and it is
-- worth spelling out, because a floor alone reads as obviously sufficient and
-- is not:
--
--   The parry window is anchored to impact — [impact - early, impact + late],
--   which is `catches` above. Measured from the tell landing, it opens at
--   `leadTime - early`. So a tell that is on screen *too long* pushes the
--   window away from the moment the player reacted to it, and reacting to the
--   tell presses early, whiffs, and eats the parry cooldown.
--
--   A player is punished for doing exactly the thing the tell exists to make
--   them do. Too slow is as unreadable as too fast, and rather more insulting.
ParryMath.REACTION_FAST = 0.22
ParryMath.REACTION_SLOW = 0.32

-- The beat a rig takes to arrive in its tell. A wind-up that is still moving
-- is not yet readable, so this sits *before* the lead time rather than inside
-- it: an attack's full telegraph is SETTLE + leadTime.
ParryMath.SETTLE = 0.12

-- The band of lead times a player can actually answer by reacting to what they
-- saw. Returns the lowest and highest lead that works.
--
-- Both ends matter, and the upper one is the less obvious of the two:
--
--   too short   a slower player never arrives. The floor is REACTION_SLOW
--               minus the class's slack for a late press.
--   too long    a player who reacts to the tell presses *early*, before the
--               window has opened, whiffs, and eats the cooldown. The ceiling
--               is REACTION_FAST plus the class's slack for an early press.
--
-- The band is the intersection across every class, so no class is ever asked
-- to answer something it structurally cannot. Class identity lives in how
-- *wide* a window is, not in whether the attack can be read at all: a class
-- with tight frames has to be precise, and should never be the class that
-- simply cannot answer.
--
-- Which class is narrowest is deliberately not named here. It is a tuning
-- decision that has already moved once, and a comment naming one goes stale
-- silently. The loop finds it.
function ParryMath.readableLead(parryable: boolean): (number, number)
	if not parryable then
		-- Unparryable attacks are answered by moving. The i-frames cover the
		-- impact rather than opening a window around it, so the arithmetic is
		-- not the same shape.
		return ParryMath.REACTION_SLOW, ParryMath.REACTION_FAST + CombatConstants.DODGE_IFRAMES
	end

	local lowest, highest = 0, math.huge
	for _, weapon in WeaponDefs do
		lowest = math.max(lowest, ParryMath.REACTION_SLOW - weapon.parry.lateTolerance)
		highest = math.min(highest, ParryMath.REACTION_FAST + weapon.parry.earlyTolerance)
	end
	return lowest, highest
end
return ParryMath
