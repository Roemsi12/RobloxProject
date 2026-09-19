--!strict
-- Chaining: a second attack thrown out of the first, without a trip back
-- through neutral.
--
-- Two complaints share a cause here. Enemies felt repetitive, and they felt
-- passive: `AnimationDefs.strike` ends every attack by returning to rest, and
-- the server then waits RECOVER_DURATION (0.8s) plus attackInterval
-- (0.6-1.2s) before even choosing the next one. That is 1.4-2.0s of standing
-- still between swings, most of it with the enemy frozen in place.
--
-- A chain spends that gap instead of waiting through it. The time comes out
-- of the *gap*, not out of the tell -- tells stay their full length, because
-- shortening them is the one lever that directly buys unreadability.
--
-- ## The finding that constrains all of this
--
-- There is a hitstun floor, and it is invisible from the animation layer.
-- `CombatServer.onParryAttempt` returns early when the victim is stunned: the
-- press is discarded and the guard does not even rise. After a hit lands,
--
--     resolve at   impact + STRIKE_RESOLUTION_GRACE   (0.15)
--     stunned to   + PLAYER_HIT_STUN                  (0.35)   = 0.50s
--
-- so **a link landing within 0.50s of the previous impact is unparryable by
-- construction**, whatever its tell looks like. Reaction time then starts on
-- top of that, because it only begins when the player regains agency.
--
-- That is why the link's start is *computed from its deadline* rather than
-- placed at a fixed gap after the last one. A fixed gap that looked fine on
-- the Shambler shipped a SkeletonWarrior chain with a 0.22s effective lead.
-- The clamp below is what makes the contract true by construction instead of
-- by tuning, which is the same reason `leadTime` is an input to
-- AttackChoreography rather than something it reports back.
--
-- ## The signpost
--
-- A chain announces itself by the *absence of a return to rest*. An attack
-- that ends held in its carry pose is visibly unfinished, and that is the
-- only cue. Nothing appears in the interface, because a chain that announces
-- itself there is one players stop reading the body for -- which is the whole
-- thing this combat system is trying to be about.

local AttackChoreography = require(script.Parent.AttackChoreography)
local AttackSelector = require(script.Parent.AttackSelector)
local CombatConstants = require(script.Parent.CombatConstants)

local AttackChain = {}

-- The shortest the carry pose is held before the next link starts moving.
--
-- This is a readability floor, not a pacing one: the unfinished silhouette is
-- the only signpost a chain gets, so it has to be on screen long enough to be
-- seen. It rarely binds -- the hitstun clamp below is almost always the later
-- of the two -- and it exists for the case where it would not.
AttackChain.CARRY_MIN = 0.1

-- Extra recovery for each link past the first, once the chain ends.
--
-- This is what makes a chain a *risk* the enemy takes rather than a straight
-- buff. A three-link flurry that gets parried should leave it open for longer
-- than a single swing would, or there is no reason for a player to ever want
-- to bait one.
AttackChain.RECOVER_BONUS = 0.25

-- Hard ceiling on links in one chain, including the opener. Past three the
-- player is mostly watching rather than playing, however readable each
-- individual link is.
AttackChain.MAX_LINKS = 3

-- When a player hit by an attack landing at `impactTime` can act again.
--
-- Before this moment a parry press is not merely mistimed, it is discarded --
-- so a link whose window opens earlier than this is unanswerable no matter
-- how clean its tell is.
function AttackChain.agencyRegainedAt(impactTime: number): number
	return impactTime + CombatConstants.STRIKE_RESOLUTION_GRACE + CombatConstants.PLAYER_HIT_STUN
end

-- How long a player actually has to answer a link, as opposed to how long its
-- tell is on screen.
--
-- The two differ whenever the player was hit by the previous link: the tell
-- may have landed while they were still in hitstun, and time spent stunned is
-- not time spent reading. Whichever of the two happens later is where their
-- reading actually starts.
function AttackChain.effectiveLead(previousImpact: number, tellLandsAt: number, linkImpact: number): number
	return linkImpact - math.max(tellLandsAt, AttackChain.agencyRegainedAt(previousImpact))
end

-- The lead a link has to clear to be answerable: the floor of the reactable
-- band for the answer it demands. Parryable links are held to the parry
-- floor, unparryable ones to the dodge floor.
--
-- An unparryable ender is deliberately held to a real floor rather than to
-- "anything above zero". Recognising the ender is supposed to be the skill
-- the chain tests; one that lands the instant agency returns is not a test of
-- anything.
function AttackChain.floorFor(parryable: boolean): number
	local lowest = AttackChoreography.readableLead(parryable)
	return lowest
end

-- When the next link's telegraph should start, so that the contract holds by
-- construction.
--
-- `resolveAt` is when the previous link finished resolving (its impact plus
-- the grace), and `linkTelegraph` is the link's full wind-up, LINK_SETTLE
-- plus its lead time.
--
-- Two constraints, and the later one wins:
--   * the carry pose has to be visible for CARRY_MIN
--   * the impact cannot arrive before the player has had `floor` seconds of
--     agency to read it
function AttackChain.linkStartsAt(
	previousImpact: number,
	resolveAt: number,
	linkTelegraph: number,
	parryable: boolean
): number
	local earliestImpact = AttackChain.agencyRegainedAt(previousImpact) + AttackChain.floorFor(parryable)
	return math.max(resolveAt + AttackChain.CARRY_MIN, earliestImpact - linkTelegraph)
end

-- The full wind-up of a link: its shortened arrival plus its lead time. A
-- link settles faster than a standalone attack because the rig starts already
-- wound rather than from rest.
function AttackChain.telegraphOf(leadTime: number): number
	return AttackChoreography.LINK_SETTLE + leadTime
end

-- Everything about a link's timing, from the previous link's impact.
export type LinkTiming = {
	startsAt: number,
	tellLandsAt: number,
	impactAt: number,
	effectiveLead: number,
}

-- Both sides of the wire compute this from the same inputs rather than one
-- sending the other a duration. One less number that can drift.
function AttackChain.linkTiming(previousImpact: number, leadTime: number, parryable: boolean): LinkTiming
	local resolveAt = previousImpact + CombatConstants.STRIKE_RESOLUTION_GRACE
	local telegraph = AttackChain.telegraphOf(leadTime)
	local startsAt = AttackChain.linkStartsAt(previousImpact, resolveAt, telegraph, parryable)
	local tellLandsAt = startsAt + AttackChoreography.LINK_SETTLE
	local impactAt = startsAt + telegraph

	return {
		startsAt = startsAt,
		tellLandsAt = tellLandsAt,
		impactAt = impactAt,
		effectiveLead = AttackChain.effectiveLead(previousImpact, tellLandsAt, impactAt),
	}
end

-- The attacks that could come next, in a stable sorted order.
--
-- An attack qualifies when it is legal at the current distance, off cooldown,
-- and wears an archetype that `follows` the one just thrown -- which in
-- practice means "not the same question twice running". Repeating a tell is
-- exactly the repetition that made enemies feel interchangeable.
function AttackChain.candidates(
	def: any,
	fromAttackId: string,
	distance: number,
	cooldowns: { [string]: number },
	now: number
): { string }
	local from = def.attacks[fromAttackId]
	if not from then
		return {}
	end

	local allowed = AttackChoreography.follows(from.archetype)
	local out: { string } = {}

	-- `includeChainOnly` -- links may use attacks that are not available as
	-- openers, which is how an enemy gets a move that only ever appears mid
	-- flurry.
	for _, attackId in AttackSelector.legalAttacks(def, distance, cooldowns, now, true) do
		if attackId == fromAttackId then
			continue
		end
		local attack = def.attacks[attackId]
		if table.find(allowed, attack.archetype) then
			table.insert(out, attackId)
		end
	end

	return out
end

-- Picks the next link, weighted the same way openers are. `roll` is injected
-- so tests are not at the mercy of the global RNG.
function AttackChain.chooseNext(
	def: any,
	fromAttackId: string,
	distance: number,
	cooldowns: { [string]: number },
	now: number,
	roll: (() -> number)?
): string?
	local candidates = AttackChain.candidates(def, fromAttackId, distance, cooldowns, now)
	return AttackSelector.pickWeighted(def, candidates, roll)
end

-- How many links this enemy is allowed to throw, and how often it wants to.
-- Both default to "no chaining", so chaining ships dark and is turned on one
-- enemy at a time.
function AttackChain.maxLinks(def: any): number
	return math.min(def.maxChain or 1, AttackChain.MAX_LINKS)
end

function AttackChain.wantsAnother(def: any, roll: (() -> number)?): boolean
	local chance = def.chainChance or 0
	if chance <= 0 then
		return false
	end
	local rng = roll or math.random
	return rng() < chance
end

return AttackChain
