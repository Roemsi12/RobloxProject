--!strict
-- Plays AnimationDefs animations on one rig, by writing its joint
-- (Motor6D or AnimationConstraint) Transforms every frame — and hands any animation with a published version
-- (AnimationIds) to Roblox's Animator instead.
--
-- Two layers, like Roblox animation priorities: a looping base (idle, walk)
-- and a one-shot action (an attack, a stagger, death). An action poses only
-- the parts it animates; the base keeps moving the rest.
--
-- A rig whose base belongs to someone else — a player's avatar, whose walk
-- and idle come from Roblox's Animate script — is "external". There, an
-- action is blended over whatever the joints already hold, and nothing else
-- is touched.
--
-- Runs on each client, for that client's view only. Transforms are written in
-- PreSimulation: after the Animator has posed the rig for this frame, and
-- before joints are applied — the point where a script's pose wins.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local AnimationDefs = require(Shared.AnimationDefs)
local AnimationIds = require(Shared.AnimationIds)
local KeyframeMath = require(Shared.KeyframeMath)
local RigDefs = require(Shared.RigDefs)

local RigAnimation = {}

-- How long a switch between animations blends.
local CROSSFADE = 0.15

-- External rigs: how quickly an action takes over, and lets go at the end.
local OVERLAY_FADE_IN = 0.06
local OVERLAY_FADE_OUT = 0.12

-- The keyframe a refined strike must keep, so its timing survives publishing.
local IMPACT_KEYFRAME = "Impact"

type AnimationDef = KeyframeMath.AnimationDef
type PoseMap = KeyframeMath.PoseMap

-- A Motor6D or an AnimationConstraint: anything with a Transform the Animator
-- writes each frame.
type Joint = any

export type ActionOptions = {
	-- Strikes: real seconds from the start of the windup to impact. Everything
	-- before the animation's impact keyframe is stretched to fit.
	windup: number?,
	-- Seconds of the action already over before it started playing here, e.g.
	-- a telegraph message that arrived late.
	elapsed: number?,
	-- Anything else: stretch the whole animation over this many seconds.
	duration: number?,
	-- Stay on the last frame when finished (death), until stopped.
	hold: boolean?,
	-- A generated attack (AttackChoreography), played instead of looking `name`
	-- up. Generated attacks are keyframe-played only: there is no published
	-- version of an animation that did not exist until this swing.
	def: AnimationDef?,
}

type Layer = {
	name: string,
	anim: AnimationDef,
	startedAt: number,
	windup: number?,
	timeScale: number,
	hold: boolean,
	-- Loops advance by accumulated phase, so a change of speed doesn't jump.
	phase: number,
	track: AnimationTrack?,
}

export type Controller = {
	model: Model,
	rigId: string,
	joints: { [string]: Joint },
	animator: Animator?,
	external: boolean,
	base: Layer?,
	baseSpeed: number,
	action: Layer?,
	fadeFrom: PoseMap?,
	fadeStart: number,
	lastPose: PoseMap,
	-- An overlay rig's base (a player's stance or idle) as it looked when the
	-- base last changed, and when that change started. Overlay rigs get no
	-- `fadeFrom`: that one blends a pose the rig owns outright, and here the
	-- Animator owns most of the joints. Without this, walking out of a planted
	-- idle snaps the legs from the idle's stance to the walk in one frame.
	baseFadeFrom: PoseMap?,
	baseFadeStart: number,
	lastBasePose: PoseMap,
	written: { [string]: boolean },
	tracks: { [string]: AnimationTrack },
	-- Hit-stop: the rig holds its pose until this clock time.
	frozenUntil: number,
	-- The rig's size (RigDefs.scaleOf). Animations are authored at size 1, so
	-- their offsets in studs are multiplied by this.
	scale: number,
	-- Hip and chest turn, in degrees, laid over whatever is playing
	-- (LocomotionMath). Zero on anything that isn't strafing.
	twistHip: number,
	twistShoulder: number,
}

-- The clock every layer's timing is measured on. `os.clock` rather than the
-- server clock: this is playback on one machine, and it must not jump when
-- the server time sync corrects itself mid-animation.
local function clock(): number
	return os.clock()
end

-- Every animatable joint in a model, keyed by the name of the part it moves.
--
-- Two kinds exist. Enemy rigs are built here with Motor6Ds. Player avatars
-- now spawn with AnimationConstraints instead (Roblox's Avatar Joint Upgrade,
-- the default for new experiences), where the moved part is Attachment1's
-- parent. Both expose Transform the same way, so everything past this
-- function treats them alike. Only looking for Motor6Ds is what used to leave
-- players' swings and parries unanimated.
local function findJoints(model: Model): { [string]: Joint }
	local joints: { [string]: Joint } = {}
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("Motor6D") then
			local part1 = descendant.Part1
			if part1 then
				joints[part1.Name] = descendant
			end
		elseif descendant:IsA("AnimationConstraint") then
			local attachment = (descendant :: any).Attachment1 :: Attachment?
			local part = attachment and attachment.Parent
			if part and part:IsA("BasePart") then
				joints[part.Name] = descendant
			end
		end
	end
	return joints
end

-- How many animatable joints a model has, whichever kind. Callers wait for a
-- replicating rig to be whole before animating it.
function RigAnimation.countJoints(model: Model): number
	local count = 0
	for _ in findJoints(model) do
		count += 1
	end
	return count
end

-- A controller for one rig. `external` means someone else owns the base
-- pose — a player's avatar, driven by Roblox's Animate script — in which
-- case everything here is blended over the joints rather than replacing
-- them. Enemy rigs built by RigAssembly pass false.
--
-- Finds the joints once, here. A rig whose joints arrive late (replication)
-- gives a controller that animates nothing, which is what `jointCount` is
-- for: callers wait for the rig to be whole before constructing.
function RigAnimation.new(model: Model, rigId: string, external: boolean): Controller
	return {
		model = model,
		rigId = rigId,
		joints = findJoints(model),
		animator = model:FindFirstChildWhichIsA("Animator", true),
		external = external,
		base = nil,
		baseSpeed = 1,
		action = nil,
		fadeFrom = nil,
		fadeStart = 0,
		lastPose = {},
		baseFadeFrom = nil,
		baseFadeStart = 0,
		lastBasePose = {},
		written = {},
		tracks = {},
		frozenUntil = 0,
		-- A player's avatar is whatever size Roblox built it; only our own rigs
		-- carry a scale.
		scale = if external then 1 else RigDefs.scaleOf(rigId),
		twistHip = 0,
		twistShoulder = 0,
	}
end

-- How many joints were found: callers wait for a replicating rig to be whole.
function RigAnimation.jointCount(controller: Controller): number
	local count = 0
	for _ in controller.joints do
		count += 1
	end
	return count
end

-- The published version of an animation, loaded once, if it has one.
local function publishedTrack(controller: Controller, name: string): AnimationTrack?
	local id = AnimationIds.get(controller.rigId, name)
	local animator = controller.animator
	if not id or not animator then
		return nil
	end

	local cached = controller.tracks[name]
	if cached then
		return cached
	end

	local animation = Instance.new("Animation")
	animation.AnimationId = id

	local ok, result = pcall(function()
		return animator:LoadAnimation(animation)
	end)

	if not ok then
		warn(`[RigAnimation] Couldn't load {controller.rigId}/{name} ({id}); using the rough version. {result}`)
		return nil
	end

	controller.tracks[name] = result
	return result
end

-- Whether this frame's rough poses go on top of something else writing the
-- joints: a player's Animate script, or this rig's own published base
-- animation. Either way, blend over the joints instead of replacing them.
local function overlaysAnimator(controller: Controller): boolean
	local base = controller.base
	return controller.external or (base ~= nil and base.track ~= nil)
end

-- Start blending from whatever the rig showed last frame.
local function beginFade(controller: Controller)
	if overlaysAnimator(controller) then
		return
	end
	controller.fadeFrom = controller.lastPose
	controller.fadeStart = clock()
end

-- How far into its animation the current action is, in animation time.
--
-- For a strike this is not simply elapsed seconds: everything before the
-- impact keyframe is stretched to fit the server's real windup, so the
-- visible hit lands when the server says it did. Anything else just runs
-- at `timeScale`.
local function actionTime(layer: Layer, now: number): number
	local elapsed = now - layer.startedAt
	local impact = layer.anim.impact
	if layer.windup and impact then
		return KeyframeMath.alignedTime(elapsed, impact, layer.windup)
	end
	return elapsed * layer.timeScale
end

-- Sets the looping base layer (an idle, a walk, a player's stance), at
-- `speed` times its authored tempo.
--
-- Safe to call every frame: naming the base that is already playing only
-- updates its speed, and does not restart it. Changing to a different
-- animation cross-fades. Does nothing at all if the rig has no animation
-- under that name, which is what a typo'd name looks like — the rig keeps
-- whatever it was doing.
function RigAnimation.setBase(controller: Controller, name: string, speed: number?)
	controller.baseSpeed = speed or 1

	local current = controller.base
	if current and current.name == name then
		if current.track then
			current.track:AdjustSpeed(controller.baseSpeed)
		end
		return
	end

	local anim = AnimationDefs.get(controller.rigId, name)
	if not anim then
		return
	end

	if current and current.track then
		current.track:Stop(CROSSFADE)
	end

	local track = publishedTrack(controller, name)
	if track then
		track.Looped = true
		track:Play(CROSSFADE, 1, controller.baseSpeed)
	end

	if not controller.action then
		beginFade(controller)
	end

	-- Overlay rigs blend from wherever the outgoing base had got to.
	if overlaysAnimator(controller) and current then
		controller.baseFadeFrom = controller.lastBasePose
		controller.baseFadeStart = clock()
	end

	controller.base = {
		name = name,
		anim = anim,
		startedAt = clock(),
		windup = nil,
		timeScale = 1,
		hold = false,
		phase = 0,
		track = track,
	}
end

-- Stops the looping base. On a player's avatar that hands the parts back to
-- Roblox's Animate script.
function RigAnimation.clearBase(controller: Controller)
	local current = controller.base
	if current and current.track then
		current.track:Stop(CROSSFADE)
	end
	if overlaysAnimator(controller) and current then
		controller.baseFadeFrom = controller.lastBasePose
		controller.baseFadeStart = clock()
	end
	controller.base = nil
end

-- The name of the looping base playing, if any.
function RigAnimation.currentBase(controller: Controller): string?
	local base = controller.base
	return base and base.name
end

-- Plays a one-shot action over the base: an attack, a stagger, a roll, a
-- death. Replaces whatever action was playing.
--
-- `options.windup` stretches a strike to the server's timing,
-- `options.elapsed` starts it part-way in (a telegraph that arrived late),
-- `options.duration` stretches anything else, `options.hold` freezes the
-- last frame, and `options.def` plays a generated animation instead of
-- looking the name up. Hands off to Roblox's Animator instead if the
-- animation has a published id — unless `def` is set, since a generated
-- attack has no published version by definition.
function RigAnimation.playAction(controller: Controller, name: string, options: ActionOptions?)
	local opts: ActionOptions = options or {}
	local anim = opts.def or AnimationDefs.get(controller.rigId, name)
	if not anim then
		return
	end
	local previous = controller.action
	if previous and previous.track then
		previous.track:Stop(CROSSFADE)
	end

	local elapsed = math.max(opts.elapsed or 0, 0)
	local duration = opts.duration
	local layer: Layer = {
		name = name,
		anim = anim,
		startedAt = clock() - elapsed,
		windup = opts.windup,
		timeScale = if duration and duration > 0 then anim.length / duration else 1,
		hold = opts.hold == true,
		phase = 0,
		track = nil,
	}

	local track = if opts.def then nil else publishedTrack(controller, name)
	if track then
		track.Looped = false
		track.Priority = Enum.AnimationPriority.Action

		local speed = layer.timeScale
		local windup = opts.windup
		if windup and windup > 0 then
			-- Needs the animation loaded; if it isn't yet, play at normal speed
			-- rather than guess.
			local ok, impactAt = pcall(function()
				return track:GetTimeOfKeyframe(IMPACT_KEYFRAME)
			end)
			if ok and impactAt > 0 then
				speed = impactAt / windup
				task.delay(math.max(windup - elapsed, 0), function()
					if controller.action == layer and track.IsPlaying then
						track:AdjustSpeed(1)
					end
				end)
			end
		end

		track:Play(CROSSFADE, 1, speed)
		layer.track = track
	else
		beginFade(controller)
	end

	controller.action = layer
end

-- Ends the current action early and fades back to the base. Used to drop a
-- held pose (a guard being released, a death being undone by a respawn).
function RigAnimation.stopAction(controller: Controller)
	local action = controller.action
	if not action then
		return
	end

	if action.track then
		action.track:Stop(CROSSFADE)
	end

	controller.action = nil
	beginFade(controller)
end

-- The name of the action playing, or nil if only the base is. Callers use
-- it to avoid interrupting something more important than what they want to
-- play — a flinch never cuts off an attack's timing.
function RigAnimation.currentAction(controller: Controller): string?
	local action = controller.action
	return action and action.name
end

-- Hold the rig's pose for a moment when a blow lands — a few frames of
-- stillness is what makes a hit read as heavy. Purely visual and per client.
function RigAnimation.hitStop(controller: Controller, seconds: number)
	controller.frozenUntil = math.max(controller.frozenUntil, clock() + seconds)
end

-- A strike still winding up is never held: that would push the visible hit
-- past the server's impact time, which is exactly what the parry reads.
local function canHold(layer: Layer, now: number): boolean
	local windup = layer.windup
	return not (windup and layer.anim.impact and now - layer.startedAt < windup)
end

-- One pose as a CFrame: offsets in studs scaled to the rig's size, then
-- rotations in degrees. Exactly the formula the workbench uses when it
-- writes KeyframeSequences, so what plays here and what opens in the
-- Animation Editor are the same pose.
local function toCFrame(values: KeyframeMath.PoseValues, scale: number): CFrame
	return CFrame.new(values.px * scale, values.py * scale, values.pz * scale)
		* CFrame.Angles(math.rad(values.rx), math.rad(values.ry), math.rad(values.rz))
end

-- Turning the hips toward where a strafing character is going, and the chest
-- back against them. Both are laid over whatever the joint already holds, so
-- the walk cycle underneath keeps playing — the legs it moves simply point
-- somewhere else now.
--
-- Pre-multiplied: that turns the joint about its own origin in the parent's
-- frame, which is a hip turning. Post-multiplying would swing the part around
-- its far end instead.
local HIP_JOINT = "LowerTorso"
local CHEST_JOINT = "UpperTorso"

-- The strafe twist for one joint, or nil if this joint doesn't take one.
-- Only the hips and the chest do; everything else gets nil and is left
-- alone.
local function twistOf(controller: Controller, part: string): CFrame?
	local degrees = if part == HIP_JOINT
		then controller.twistHip
		elseif part == CHEST_JOINT then controller.twistShoulder
		else 0
	if degrees == 0 then
		return nil
	end
	-- Negated. LocomotionMath measures the turn the way a person would — to
	-- the right is positive — while a positive rotation about Y in Roblox
	-- turns left. Without this, walking right turned the body left.
	return CFrame.Angles(0, -math.rad(degrees), 0)
end

-- Degrees, from LocomotionMath. Set every frame on player avatars; nothing
-- else in the game strafes.
function RigAnimation.setTwist(controller: Controller, hip: number, shoulder: number)
	controller.twistHip = hip
	controller.twistShoulder = shoulder
end

-- Advance one frame and pose the rig. Call from PreSimulation.
function RigAnimation.step(controller: Controller, deltaTime: number)
	local now = clock()
	local action = controller.action

	-- A published action is the Animator's to play; stay off its joints.
	if action and action.track then
		local track = action.track
		if action.hold then
			-- A finished track lets go of the rig, and it would stand back up.
			-- Freeze just short of the end instead.
			if track.IsPlaying and track.Length > 0 and track.TimePosition >= track.Length - 0.05 then
				track:AdjustSpeed(0)
			end
		elseif not track.IsPlaying then
			controller.action = nil
		end
		return
	end

	local pose: PoseMap = {}
	local overlayWeight = 1
	local overlay = overlaysAnimator(controller)

	-- During a hit-stop, time stands still for this rig: the action's start
	-- slides forward with the clock, and the base loop doesn't advance.
	local baseDelta = deltaTime
	if now < controller.frozenUntil then
		baseDelta = 0
		if action and canHold(action, now) then
			action.startedAt += deltaTime
		end
	end

	-- On an external rig (a player's avatar) the base is a stance layered over
	-- whatever Roblox's Animate script is doing, kept apart from the action so
	-- each can be blended on its own.
	local overlayBase: PoseMap = {}
	local base = controller.base
	if base and not base.track then
		base.phase += baseDelta * controller.baseSpeed
		if controller.external then
			overlayBase = KeyframeMath.sample(base.anim, base.phase)
		else
			pose = KeyframeMath.sample(base.anim, base.phase)
		end
	end

	local baseFadeFrom = controller.baseFadeFrom
	if baseFadeFrom then
		local progress = (now - controller.baseFadeStart) / CROSSFADE
		if progress >= 1 then
			controller.baseFadeFrom = nil
		else
			overlayBase = KeyframeMath.blend(baseFadeFrom, overlayBase, progress)
		end
	end
	controller.lastBasePose = overlayBase

	if action then
		local t = actionTime(action, now)
		local actionPose = KeyframeMath.sample(action.anim, t)

		-- The action takes over the parts it animates; the base keeps the rest.
		for part, values in actionPose do
			pose[part] = values
		end

		local finished = not action.anim.looped and t >= action.anim.length
		if overlay then
			local sinceStart = now - action.startedAt
			local untilEnd = (action.anim.length - t) / math.max(action.timeScale, 1e-3)
			overlayWeight = math.min(sinceStart / OVERLAY_FADE_IN, 1)
			if not action.hold then
				overlayWeight = math.min(overlayWeight, math.max(untilEnd / OVERLAY_FADE_OUT, 0))
			end
		end

		if finished and not action.hold then
			controller.action = nil
			beginFade(controller)
		end
	end

	local fadeFrom = controller.fadeFrom
	if fadeFrom then
		local progress = (now - controller.fadeStart) / CROSSFADE
		if progress >= 1 then
			controller.fadeFrom = nil
		else
			pose = KeyframeMath.blend(fadeFrom, pose, progress)
		end
	end

	controller.lastPose = pose

	if overlay then
		-- The stance replaces the Animator's pose on the parts it covers (arms
		-- and torso, while the legs keep walking), and the action blends in over
		-- the result.
		for part, joint in controller.joints do
			local stanceValues = overlayBase[part]
			local actionValues = pose[part]
			local twist = twistOf(controller, part)
			if stanceValues or actionValues or twist then
				local transform = if stanceValues then toCFrame(stanceValues, controller.scale) else joint.Transform
				if actionValues then
					transform = transform:Lerp(toCFrame(actionValues, controller.scale), overlayWeight)
				end
				joint.Transform = if twist then twist * transform else transform
			end
		end
	else
		for part, values in pose do
			local joint = controller.joints[part]
			if joint then
				joint.Transform = toCFrame(values, controller.scale)
				controller.written[part] = true
			end
		end
	end

	-- A part this rig stopped animating goes back to rest rather than
	-- freezing wherever it was last left. Overlays leave that to the Animator.
	if not overlay then
		for part in controller.written do
			if not pose[part] then
				local joint = controller.joints[part]
				if joint then
					joint.Transform = CFrame.identity
				end
				controller.written[part] = nil
			end
		end
	end
end

-- Releases every published track this controller loaded and forgets its
-- layers. Call when the rig goes, or the Animator keeps the tracks alive.
function RigAnimation.destroy(controller: Controller)
	for _, track in controller.tracks do
		track:Stop(0)
		track:Destroy()
	end
	table.clear(controller.tracks)
	controller.action = nil
	controller.base = nil
end

return RigAnimation
