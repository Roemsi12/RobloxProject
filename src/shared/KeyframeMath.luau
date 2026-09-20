--!strict
-- The maths of playing a rough keyframe animation: sampling a pose at a time,
-- easing, looping, blending, and stretching an attack's windup to fit its
-- telegraph. Pure Luau — poses are plain numbers here; turning them into
-- CFrames happens on the client.
--
-- Pose values are Euler angles in degrees and offsets in studs, because
-- they're meant to be read and nudged by hand. They become
-- `CFrame.new(px, py, pz) * CFrame.Angles(rx, ry, rz)` — the same formula the
-- animation workbench uses when it writes KeyframeSequences, so what plays in
-- game and what opens in the Animation Editor always match.

local KeyframeMath = {}

export type PoseValues = {
	rx: number,
	ry: number,
	rz: number,
	px: number,
	py: number,
	pz: number,
}

-- Any component left out is 0.
export type PoseSpec = {
	rx: number?,
	ry: number?,
	rz: number?,
	px: number?,
	py: number?,
	pz: number?,
}

-- How a keyframe moves to the next one. "Smooth" is cubic in-out, "Hold"
-- stays put until the next keyframe. "In" starts slow and accelerates (a blade
-- building into its hit); "Out" starts fast and settles (a follow-through, or
-- a body snapping into its windup). Cubic throughout.
export type Easing = "Linear" | "Smooth" | "Hold" | "In" | "Out"

export type Keyframe = {
	time: number,
	-- Part name (the part the joint moves, as in a Pose) -> pose. A part this
	-- animation animates but that a keyframe leaves out is at rest there.
	poses: { [string]: PoseSpec },
	easing: Easing?,
}

export type AnimationDef = {
	length: number,
	looped: boolean,
	priority: "Idle" | "Movement" | "Action",
	-- Attacks and swings only: the moment the hit lands. Playback stretches
	-- everything before it to fit the real windup, so the visible strike always
	-- lines up with the server's impact time.
	impact: number?,
	keyframes: { Keyframe },
}

export type PoseMap = { [string]: PoseValues }

KeyframeMath.REST = table.freeze({ rx = 0, ry = 0, rz = 0, px = 0, py = 0, pz = 0 })

local COMPONENTS = { "rx", "ry", "rz", "px", "py", "pz" }

-- A sparse pose filled out: every component the spec left out becomes 0.
-- `nil` gives a copy of REST, so a part an animation stopped posing reads
-- as at-rest rather than as missing.
function KeyframeMath.resolve(spec: PoseSpec?): PoseValues
	if not spec then
		return table.clone(KeyframeMath.REST) :: any
	end

	return {
		rx = spec.rx or 0,
		ry = spec.ry or 0,
		rz = spec.rz or 0,
		px = spec.px or 0,
		py = spec.py or 0,
		pz = spec.pz or 0,
	}
end

-- Where a keyframe's easing curve has got to at `alpha` (0 at this
-- keyframe, 1 at the next). Returns the blend factor to interpolate with,
-- clamped to 0..1. Smooth is the default when `easing` is nil.
function KeyframeMath.ease(easing: Easing?, alpha: number): number
	local a = math.clamp(alpha, 0, 1)

	if easing == "Linear" then
		return a
	elseif easing == "Hold" then
		return if a >= 1 then 1 else 0
	elseif easing == "In" then
		return a * a * a
	elseif easing == "Out" then
		local f = 1 - a
		return 1 - f * f * f
	end

	-- Smooth (the default): cubic in-out.
	if a < 0.5 then
		return 4 * a * a * a
	end
	local f = -2 * a + 2
	return 1 - f * f * f / 2
end

local partsCache: { [AnimationDef]: { string } } = setmetatable({}, { __mode = "k" }) :: any

-- Every part the animation poses anywhere, sorted.
function KeyframeMath.partsOf(anim: AnimationDef): { string }
	local cached = partsCache[anim]
	if cached then
		return cached
	end

	local seen = {}
	local parts = {}
	for _, keyframe in anim.keyframes do
		for part in keyframe.poses do
			if not seen[part] then
				seen[part] = true
				table.insert(parts, part)
			end
		end
	end
	table.sort(parts)

	partsCache[anim] = parts
	return parts
end

-- Where in the animation `t` falls: wrapped for a loop, clamped otherwise.
function KeyframeMath.localTime(anim: AnimationDef, t: number): number
	if anim.length <= 0 then
		return 0
	end

	if anim.looped then
		return t % anim.length
	end

	return math.clamp(t, 0, anim.length)
end

-- Straight linear interpolation between two numbers.
local function lerp(a: number, b: number, alpha: number): number
	return a + (b - a) * alpha
end

-- The pose of every animated part at time `t`.
--
-- Components are interpolated one by one. For the single-axis swings rough
-- animations are made of, that matches what the Animation Editor does; for
-- big turns on several axes at once it can differ slightly, which refining
-- the animation there resolves.
function KeyframeMath.sample(anim: AnimationDef, t: number): PoseMap
	local keyframes = anim.keyframes
	local result: PoseMap = {}
	local parts = KeyframeMath.partsOf(anim)

	if #keyframes == 0 then
		return result
	end

	local localT = KeyframeMath.localTime(anim, t)

	-- The last keyframe at or before localT.
	local fromIndex = 1
	for index, keyframe in keyframes do
		if keyframe.time <= localT then
			fromIndex = index
		else
			break
		end
	end

	local from = keyframes[fromIndex]
	local to = keyframes[fromIndex + 1]

	if not to or localT <= from.time then
		for _, part in parts do
			result[part] = KeyframeMath.resolve(from.poses[part])
		end
		return result
	end

	local span = to.time - from.time
	local alpha = if span > 0 then KeyframeMath.ease(from.easing, (localT - from.time) / span) else 1

	for _, part in parts do
		local a = KeyframeMath.resolve(from.poses[part])
		local b = KeyframeMath.resolve(to.poses[part])
		local blended: any = {}
		for _, component in COMPONENTS do
			blended[component] = lerp((a :: any)[component], (b :: any)[component], alpha)
		end
		result[part] = blended
	end

	return result
end

-- Real time since an attack started -> animation time. Everything up to
-- `impact` is stretched or squeezed to fill `windup`, so the strike lands when
-- the server resolves the hit; the follow-through then plays at normal speed.
function KeyframeMath.alignedTime(elapsed: number, impact: number, windup: number): number
	if windup <= 0 then
		return impact + math.max(elapsed, 0)
	end

	if elapsed <= windup then
		return math.max(elapsed, 0) * (impact / windup)
	end

	return impact + (elapsed - windup)
end

-- Cross-fade between two pose maps. A part only one side poses is taken to be
-- at rest on the other.
function KeyframeMath.blend(from: PoseMap, to: PoseMap, weight: number): PoseMap
	local w = math.clamp(weight, 0, 1)
	local result: PoseMap = {}
	local parts: { [string]: boolean } = {}

	for part in from do
		parts[part] = true
	end
	for part in to do
		parts[part] = true
	end

	for part in parts do
		local a: any = from[part] or KeyframeMath.REST
		local b: any = to[part] or KeyframeMath.REST
		local blended: any = {}
		for _, component in COMPONENTS do
			blended[component] = lerp(a[component], b[component], w)
		end
		result[part] = blended
	end

	return result
end

return KeyframeMath
