--!strict
-- Levels: the XP curve, and what a level is worth. Pure — no Roblox API.
--
-- XP is the half of the loop coins never covered. Coins buy a weapon's
-- upgrade levels, which are per weapon and reset the moment you pick up a
-- different one; levels are yours, and what they buy is a skill point.
--
-- Per-enemy XP lives in EnemyDefs next to that enemy's other numbers, the
-- same split as coinReward — this module only knows the curve.
--
-- The curve is triangular: the step from level L to L+1 costs
-- STEP_XP * L. Linear steps, quadratic total. A flat cost would make level 20
-- as cheap as level 2, and an exponential one would make the back half of the
-- tree unreachable; triangular is the shape where a run is always worth
-- something and the last levels still cost.

local ProgressionDefs = {}

ProgressionDefs.MAX_LEVEL = 20

-- XP for the first level-up. Each later one costs a multiple of this.
--
-- Sized against a dungeon run: roughly twenty enemies and a boss pay about
-- 1000 XP, so a first run lands around level 4, level 10 takes about five
-- runs, and level 20 takes a few dozen. First guess like every other number
-- in the game — see DESIGN.md.
ProgressionDefs.STEP_XP = 120

ProgressionDefs.POINTS_PER_LEVEL = 1

export type Standing = {
	level: number,
	-- XP earned toward the next level, and what it costs. Both 0 at max level.
	into: number,
	toNext: number,
	-- Points this level entitles you to, spent or not.
	points: number,
}

-- XP to get from `level` to the next one. 0 at (or past) the cap.
function ProgressionDefs.stepCost(level: number): number
	if level >= ProgressionDefs.MAX_LEVEL then
		return 0
	end
	return ProgressionDefs.STEP_XP * math.max(level, 1)
end

-- Total XP needed to have reached `level`. Level 1 is where everyone starts,
-- so it costs nothing.
function ProgressionDefs.totalFor(level: number): number
	local capped = math.clamp(math.floor(level), 1, ProgressionDefs.MAX_LEVEL)
	-- Sum of STEP_XP * 1 .. STEP_XP * (capped - 1).
	return ProgressionDefs.STEP_XP * (capped - 1) * capped / 2
end

-- Points earned by reaching `level`. Level 1 grants none: the first point is
-- the reward for the first level-up, so it arrives having been earned.
function ProgressionDefs.pointsFor(level: number): number
	local capped = math.clamp(math.floor(level), 1, ProgressionDefs.MAX_LEVEL)
	return (capped - 1) * ProgressionDefs.POINTS_PER_LEVEL
end

-- Where a total XP figure puts you. Walked rather than solved: twenty steps
-- is nothing, and the loop stays correct if the curve is ever reshaped into
-- something without a closed form.
function ProgressionDefs.standing(xp: number): Standing
	local total = if type(xp) == "number" and xp == xp then math.max(math.floor(xp), 0) else 0

	local level = 1
	while level < ProgressionDefs.MAX_LEVEL do
		local cost = ProgressionDefs.stepCost(level)
		if total < cost then
			break
		end
		total -= cost
		level += 1
	end

	local toNext = ProgressionDefs.stepCost(level)
	return {
		level = level,
		into = if toNext > 0 then total else 0,
		toNext = toNext,
		points = ProgressionDefs.pointsFor(level),
	}
end

-- XP capped at the total the cap is worth, so a maxed player's saved XP
-- doesn't climb forever with nothing to show for it.
function ProgressionDefs.cap(xp: number): number
	return math.min(math.max(math.floor(xp), 0), ProgressionDefs.totalFor(ProgressionDefs.MAX_LEVEL))
end

return ProgressionDefs
