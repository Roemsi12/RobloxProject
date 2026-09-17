--!strict
-- Tunable combat values. Pure data — no Roblox API, so it can be required from
-- anywhere including headless tests.
--
-- Per-weapon numbers live in WeaponDefs and per-attack numbers in EnemyDefs;
-- this file holds only what is shared across all of them.
--
-- Nothing here has had a real tuning pass. If a value changes meaningfully,
-- log why in DESIGN.md's decision log.

local CombatConstants = {}

--[[ Parry timestamp authority ]]

-- The client stamps its parry with the synchronised server clock, and the
-- server checks that claim against its own estimate of when the press could
-- have been sent: receipt time minus half the player's round-trip ping.
--
-- A claim is trusted only within this tolerance of that estimate. Without the
-- check, a client that knows impactTime (it must, to draw the telegraph) could
-- send `timestamp = impactTime` at any point in a wide window and collect a
-- perfect parry every time. The tolerance covers honest one-way jitter, which
-- grows with ping, hence the ping-proportional term.
CombatConstants.MIN_TIMESTAMP_TOLERANCE = 0.05
CombatConstants.TIMESTAMP_TOLERANCE_PING_FRACTION = 0.5

-- Hard limits applied regardless of ping, so a spoofed or absurd ping reading
-- can never widen the trusted band without bound.
CombatConstants.MAX_ACCEPTED_LATENCY = 0.4
CombatConstants.FUTURE_TOLERANCE = 0.05

-- Extra reach beyond an attack's own range within which a player may still
-- parry it. A player can only parry an attack that could plausibly hit them —
-- otherwise, with several rooms running, a press could resolve against an
-- enemy swinging at someone else entirely.
CombatConstants.PARRY_RANGE_MARGIN = 4

--[[ Parrying ]]

-- Pressing the block key opens the weapon's parry frames (WeaponDefs
-- parry.earlyTolerance): a parryable hit landing inside them is parried.
-- A press whose frames catch nothing puts parrying on this cooldown, counted
-- from the end of those frames; presses during it only block. That is what
-- makes mashing fail: it blocks, it never parries.
CombatConstants.PARRY_COOLDOWN = 0.6

--[[ Blocking and posture ]]

-- Holding the block key guards against parryable hits from the front. A
-- blocked hit costs no health, but fills posture; when posture fills, the
-- guard breaks. Unparryable attacks ignore the guard: they must be dodged.
CombatConstants.MAX_POSTURE = 100
-- Posture a blocked hit adds, per point of the damage it would have dealt.
CombatConstants.BLOCK_POSTURE_PER_DAMAGE = 2.2
-- Posture drains back to zero, starting this long after it last filled.
CombatConstants.POSTURE_REGEN_DELAY = 1.5
CombatConstants.POSTURE_REGEN_PER_SECOND = 30
-- A clean parry takes this much posture off, so parrying well keeps you in
-- the fight and blocking everything doesn't.
CombatConstants.PARRY_POSTURE_RESTORE = 25
-- A broken guard stuns: no attacking, blocking or dodging, and the hit that
-- broke it lands in full.
CombatConstants.GUARD_BREAK_STUN = 1.2
-- How wide the guard covers, centred on where the player faces.
CombatConstants.BLOCK_ARC_DEGREES = 180

--[[ Hitstun ]]

-- Taking an unblocked hit stuns briefly and cancels a swing in progress.
CombatConstants.PLAYER_HIT_STUN = 0.35
-- A player's hit interrupts an enemy: a windup without hyper armour is
-- cancelled, and an idle enemy's next attack is delayed.
CombatConstants.ENEMY_FLINCH_DURATION = 0.45
-- After a flinch, an enemy can't be flinched again for this long, so its next
-- attack comes through and has to be parried, blocked or dodged. Otherwise
-- attacking first would simply lock every enemy down.
CombatConstants.ENEMY_FLINCH_IMMUNITY = 1.6

--[[ Dodging ]]

-- Seconds of invulnerability from the dodge press.
CombatConstants.DODGE_IFRAMES = 0.3
CombatConstants.DODGE_COOLDOWN = 1.8
-- The dash itself, applied by the client to its own character.
CombatConstants.DODGE_SPEED = 46
CombatConstants.DODGE_DURATION = 0.2

-- Extra recovery on a swing that hit nothing, and the combo dropping back to
-- its first step.
--
-- This is what stops melee being a mash. A swing that connects flows into the
-- next one; a swing at empty air costs you the opening. Without it the
-- cheapest thing a player can do is hold the button down and let the hitbox
-- find something, which is exactly the habit the combo is meant to replace.
CombatConstants.MISS_RECOVERY = 0.3

--[[ Cancelling ]]

-- A swing can be feinted (or dodge-cancelled) only in this first fraction of
-- its windup; past it, you're committed.
CombatConstants.CANCEL_WINDOW_FRACTION = 0.65
CombatConstants.FEINT_COOLDOWN = 1.5

--[[ Movement ]]

-- Walking speed while attacking, blocking or stunned, as a fraction of normal.
-- Applied by the client to its own character.
CombatConstants.ATTACK_WALK_FRACTION = 0.4
CombatConstants.BLOCK_WALK_FRACTION = 0.5
CombatConstants.STUN_WALK_FRACTION = 0.25

--[[ Stagger and punish ]]

-- How long an enemy is stunned after a successful parry, before the parrying
-- class's staggerMultiplier is applied. Shortened from 1.5 when the punish
-- bonus below was introduced: a stagger now carries double damage, and the
-- Tank's 1.5x payoff would otherwise make that window very long.
CombatConstants.STAGGER_DURATION = 1.2

-- Damage bonus for hitting a staggered target. This is the universal parry
-- payoff: every class's parry opens a punish window for the whole group, and
-- the Tank's longer stagger is what makes that window worth the most.
--
-- Deliberately larger than the maximum blacksmith upgrade (EconomyDefs), so a
-- fully upgraded weapon never out-earns landing parries — "skill must count as
-- much as level/gear", expressed as numbers. A test enforces the ordering.
CombatConstants.STAGGER_DAMAGE_MULTIPLIER = 2

-- Enemy recovery after a strike resolves, before it can wind up again.
CombatConstants.RECOVER_DURATION = 0.8

-- How long the server holds a strike open past impact before resolving damage,
-- so a parry pressed inside the late half of the window still has time to
-- arrive over the network.
--
-- A real tradeoff, and one playtesting has to settle: damage feedback lands
-- this many seconds after the visual impact, and a player whose round trip
-- exceeds it loses late-half parries they legitimately earned. The debug HUD
-- reports ping next to the parry delta so the two can be correlated.
CombatConstants.STRIKE_RESOLUTION_GRACE = 0.15

--[[ Encounters ]]

-- How long a killed enemy stays down before respawning in place. Chests stay
-- unlocked through respawns; the guard coming back is for repeat practice.
CombatConstants.ENEMY_RESPAWN_DELAY = 3

--[[ PvP ]]

-- Duel health is a virtual pool, not the real Humanoid — see PvP/Duelist.luau.
CombatConstants.PVP_STARTING_HEALTH = 100

return CombatConstants
