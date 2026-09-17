--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CombatConstants = require(Shared.CombatConstants)
local ParryMath = require(Shared.ParryMath)
local WeaponDefs = require(Shared.WeaponDefs)

local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local describe = JestGlobals.describe
local expect = JestGlobals.expect
local it = JestGlobals.it

local TANK_PROFILE = WeaponDefs.SwordAndShield.parry

-- Fixed clock values keep these tests independent of wall time.
local IMPACT = 100.0
local NOW = 100.0

-- By default the message reached the server the instant it was sent, from a
-- zero-ping player. That isolates the timing verdict from the timestamp
-- authority checks, which get their own section below with explicit ping and
-- receipt times.
local function evaluateAt(attemptTime: number, overrides: { [string]: any }?): ParryMath.Evaluation
	local params = {
		attemptTime = attemptTime,
		serverNow = attemptTime,
		halfPing = 0,
		impactTime = IMPACT,
		parryProfile = TANK_PROFILE,
		attackParryable = true,
	}

	if overrides then
		for key, value in overrides do
			params[key] = value
		end
	end

	return ParryMath.evaluate(params :: any)
end

describe("ParryMath.evaluate timing", function()
	it("succeeds on a press exactly at impact", function()
		local result = evaluateAt(IMPACT)
		expect(result.verdict).toBe("parried")
		expect(result.success).toBe(true)
		expect(result.deltaMs).toBe(0)
	end)

	it("succeeds inside the early half of the window", function()
		expect(evaluateAt(IMPACT - TANK_PROFILE.earlyTolerance / 2).verdict).toBe("parried")
	end)

	it("succeeds inside the late half of the window", function()
		expect(evaluateAt(IMPACT + TANK_PROFILE.lateTolerance / 2).verdict).toBe("parried")
	end)

	-- The window is inclusive at both ends, so a press landing exactly on a
	-- boundary is a success. Worth pinning: an off-by-one here silently costs
	-- players parries they earned.
	it("treats both window boundaries as inclusive", function()
		expect(evaluateAt(IMPACT - TANK_PROFILE.earlyTolerance).verdict).toBe("parried")
		expect(evaluateAt(IMPACT + TANK_PROFILE.lateTolerance).verdict).toBe("parried")
	end)

	it("reports early just outside the early bound", function()
		local result = evaluateAt(IMPACT - TANK_PROFILE.earlyTolerance - 0.001)
		expect(result.verdict).toBe("early")
		expect(result.success).toBe(false)
		expect(result.deltaMs < 0).toBe(true)
	end)

	it("reports late just outside the late bound", function()
		local result = evaluateAt(IMPACT + TANK_PROFILE.lateTolerance + 0.001)
		expect(result.verdict).toBe("late")
		expect(result.success).toBe(false)
		expect(result.deltaMs > 0).toBe(true)
	end)

	it("reports the miss distance in signed milliseconds", function()
		expect(evaluateAt(IMPACT - 0.5).deltaMs).toBeCloseTo(-500, 6)
		expect(evaluateAt(IMPACT + 0.5).deltaMs).toBeCloseTo(500, 6)
	end)

	it("refuses a perfectly timed parry on an unparryable attack", function()
		local result = evaluateAt(IMPACT, { attackParryable = false })
		expect(result.verdict).toBe("unparryable")
		expect(result.success).toBe(false)
	end)
end)

describe("ParryMath.plausibleSendWindow", function()
	it("centres a zero-ping player's window on the receipt time", function()
		local earliest, latest = ParryMath.plausibleSendWindow(NOW, 0)
		expect(earliest).toBeCloseTo(NOW - CombatConstants.MIN_TIMESTAMP_TOLERANCE, 9)
		expect(latest).toBeCloseTo(NOW + CombatConstants.MIN_TIMESTAMP_TOLERANCE, 9)
	end)

	it("shifts back and widens with ping", function()
		local lowEarliest, lowLatest = ParryMath.plausibleSendWindow(NOW, 0)
		local highEarliest, highLatest = ParryMath.plausibleSendWindow(NOW, 0.1)

		expect(highLatest < lowLatest).toBe(true)
		expect(highLatest - highEarliest > lowLatest - lowEarliest).toBe(true)
	end)

	-- A spoofed or absurd ping must never widen the band past the hard limits.
	it("never extends past the hard limits, whatever the ping", function()
		for _, halfPing in { 0, 0.2, 0.4, 5, 1e9, -3 } do
			local earliest, latest = ParryMath.plausibleSendWindow(NOW, halfPing)
			expect(earliest >= NOW - CombatConstants.MAX_ACCEPTED_LATENCY - 1e-9).toBe(true)
			expect(latest <= NOW + CombatConstants.FUTURE_TOLERANCE + 1e-9).toBe(true)
			expect(earliest <= latest).toBe(true)
		end
	end)
end)

describe("ParryMath.evaluate timestamp authority", function()
	-- These hold the receipt time fixed and move the claimed press time around
	-- it. impactTime tracks the claim so the timing would always be perfect —
	-- proving any rejection comes from authority, not from the window.
	local function evaluateClaim(attemptTime: number, halfPing: number): ParryMath.Evaluation
		return evaluateAt(attemptTime, { serverNow = NOW, halfPing = halfPing, impactTime = attemptTime })
	end

	it("accepts an honest zero-ping claim", function()
		expect(evaluateClaim(NOW, 0).verdict).toBe("parried")
	end)

	it("accepts an honest high-ping claim sent half a round trip ago", function()
		expect(evaluateClaim(NOW - 0.15, 0.15).verdict).toBe("parried")
	end)

	it("rejects a claim later than the message could have been sent", function()
		local result = evaluateClaim(NOW + CombatConstants.FUTURE_TOLERANCE + 0.01, 0)
		expect(result.verdict).toBe("rejected_future")
		expect(result.success).toBe(false)
	end)

	it("rejects a claim older than the rewind bound", function()
		local result = evaluateClaim(NOW - CombatConstants.MAX_ACCEPTED_LATENCY - 0.01, 0.2)
		expect(result.verdict).toBe("rejected_stale")
		expect(result.success).toBe(false)
	end)

	-- The bot case. A client that knows impactTime can claim a press at exactly
	-- that moment. Bounded rewind alone would believe it anywhere in a 450ms
	-- span; checked against receipt time minus ping, a low-ping client can't
	-- backdate much at all.
	it("rejects a low-ping client backdating a claim", function()
		local result = evaluateClaim(NOW - 0.3, 0.01)
		expect(result.verdict).toBe("rejected_stale")
	end)

	it("rejects a high-ping claim that pretends to be instant", function()
		-- Half a round trip is 200ms, yet the claim says it was sent just now.
		local result = evaluateClaim(NOW, 0.2)
		expect(result.verdict).toBe("rejected_future")
	end)

	it("checks authority before the timing window", function()
		-- Perfect timing, untrustworthy claim: authority must win.
		expect(evaluateClaim(NOW + 5, 0).verdict).toBe("rejected_future")
		expect(evaluateClaim(NOW - 5, 0).verdict).toBe("rejected_stale")
	end)
end)

describe("ParryMath.catches", function()
	local profile = { earlyTolerance = 0.25, lateTolerance = 0.05 }

	it("catches a hit landing inside the frames a press opened", function()
		expect(ParryMath.catches(10, profile, 10.1)).toBe(true)
		expect(ParryMath.catches(10, profile, 10)).toBe(true)
	end)

	it("treats both ends as inclusive", function()
		expect(ParryMath.catches(10, profile, 10.25)).toBe(true)
		expect(ParryMath.catches(10, profile, 9.95)).toBe(true)
	end)

	it("misses a hit landing after the frames closed", function()
		expect(ParryMath.catches(10, profile, 10.3)).toBe(false)
	end)

	-- Pressing after being hit is not a parry, beyond a frame's slack.
	it("misses a hit that landed before the press", function()
		expect(ParryMath.catches(10, profile, 9.9)).toBe(false)
	end)
end)

describe("ParryMath.pressOpensFrames", function()
	local profile = { earlyTolerance = 0.25, lateTolerance = 0.05 }
	local cooldownEnds = 10 + 0.25 + CombatConstants.PARRY_COOLDOWN

	it("opens frames on a first press", function()
		expect(ParryMath.pressOpensFrames(nil, false, profile, 10)).toBe(true)
	end)

	it("opens frames again straight after a press that caught something", function()
		expect(ParryMath.pressOpensFrames(10, true, profile, 10.3)).toBe(true)
	end)

	-- The anti-mash rule: a miss puts parrying on cooldown; pressing again only blocks.
	it("refuses frames after a miss until the cooldown ends", function()
		expect(ParryMath.pressOpensFrames(10, false, profile, cooldownEnds - 0.01)).toBe(false)
		expect(ParryMath.pressOpensFrames(10, false, profile, cooldownEnds)).toBe(true)
	end)
end)

describe("ParryMath.withinWindow", function()
	it("covers the window and nothing outside it", function()
		expect(ParryMath.withinWindow(5, 0.3, 5)).toBe(true)
		expect(ParryMath.withinWindow(5, 0.3, 5.3)).toBe(true)
		expect(ParryMath.withinWindow(5, 0.3, 5.31)).toBe(false)
		expect(ParryMath.withinWindow(5, 0.3, 4.9)).toBe(false)
		expect(ParryMath.withinWindow(nil, 0.3, 5)).toBe(false)
	end)
end)

describe("ParryMath.validateTimestamp", function()
	it("accepts an honest press and rejects an impossible one", function()
		expect(ParryMath.validateTimestamp(100, 100, 0)).toBeNil()
		expect(ParryMath.validateTimestamp(101, 100, 0)).toBe("rejected_future")
	end)
end)

describe("ParryMath.widen", function()
	local profile = WeaponDefs.SwordAndShield.parry

	it("hands back the same profile when there's nothing to add", function()
		expect(ParryMath.widen(profile, 0)).toBe(profile)
	end)

	it("splits the bonus evenly across both halves", function()
		local widened = ParryMath.widen(profile, 0.06)
		expect(widened.earlyTolerance).toBeCloseTo(profile.earlyTolerance + 0.03)
		expect(widened.lateTolerance).toBeCloseTo(profile.lateTolerance + 0.03)
	end)

	it("leaves the weapon's own profile alone", function()
		ParryMath.widen(profile, 0.06)
		expect(WeaponDefs.SwordAndShield.parry.earlyTolerance).toBe(profile.earlyTolerance)
	end)

	it("catches a press that the unwidened window would have missed", function()
		local impact = 100
		local justLate = impact + profile.lateTolerance + 0.02
		expect(ParryMath.catches(justLate, profile, impact)).toBe(false)
		expect(ParryMath.catches(justLate, ParryMath.widen(profile, 0.06), impact)).toBe(true)
	end)

	it("never makes a tolerance negative", function()
		local narrowed = ParryMath.widen(profile, -10)
		expect(narrowed.earlyTolerance).toBe(0)
		expect(narrowed.lateTolerance).toBe(0)
	end)
end)
