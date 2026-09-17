# Design decisions — Roblox Dungeon Crawler

> Decisions and the reasoning behind them, so they don't get silently
> re-litigated across sessions. Add to this file — don't edit history away.
> If a decision changes, keep the old line, note the new one, and say why.

## Status

All ten build-order steps are code-complete (Sept 2026), plus R15 rigs and
rough animations for every enemy and for player combat. Lint and build are
clean, with 170 unit tests passing against the pure combat, economy,
save-data and animation modules (`lune run test`).
Steps 1–3 were built on this branch; steps 4–9 were built on Maat8688's fork
and merged in, re-based onto this branch's combat core (see
[Merge of Maat8688's fork](#merge-of-maat8688s-fork-sept-2026)).

What exists: a procedurally chained gray-box dungeon (a safe Start room, then
3–5 randomized combat rooms), each room's enemy guarding a barrier-locked
chest; four enemy types on one data-driven AI, leashed to their rooms; three
weapon-classes picked up from stands in the start room; server-authoritative
parry, hit-reg and stagger throughout; a bleed on the SkeletonWarrior's
unparryable slam; a Healer burst heal that reaches allies; kills paying coins
and class-keyed crystals, spent at a start-room anvil across five upgrade
tiers; an inventory panel; a 1v1 duel arena on the same combat rules; and
saved progress, session-locked across servers.

**None of it has had a tuning pass, and the merged whole has never run in
Studio.** Every number in `CombatConstants`, `WeaponDefs`, `EnemyDefs` and
`EconomyDefs` is a first guess. Asserted rather than tested: the Assassin's
80/50 ms window may be unplayable at real ping; the timestamp tolerance may
reject honest players during ping spikes; the Jest wiring in
`tests/jest.config.luau` has never been run under real Jest; and saving has
never touched a real DataStore — that needs the place published with Studio
API access enabled. Visuals are still rough: Part-built rigs and first-draft
animations waiting to be refined in the Animation Editor, and no sound.

## Core loop

Choose a weapon at start → weapon determines class → run a procedurally
generated dungeon → kill enemies for XP/coins → find enemy-guarded chests
(barrier drops once the guarding encounter group is cleared) → loot gear or
spend coins/crystals at the blacksmith to upgrade existing gear → repeat.

## Locked-in decisions

- **Class = equipped weapon**, not a separate stat or picker. Switching
  weapon switches class. Upgrade materials are class/weapon-type specific,
  so respeccing has a real cost and specialization is the natural path.
- **Combat is server-authoritative.** Parry input is validated server-side
  against the enemy's telegraph timeline, with a latency-compensation buffer
  (~ping/2). No full client-side prediction planned initially.
- **Skill must count as much as level/gear** — enforced through the
  parry/telegraph system, not stat-scaling tricks. Some attacks are
  deliberately unparryable (must-dodge AoEs) so it isn't "parry everything."
- **Healer must be near-indispensable.** Achieved via: (a) healing itself
  tied to the skill loop — e.g. a parry near allies triggers burst heal —
  rather than a passive HoT bot, and (b) dungeon mechanics with unavoidable
  chip damage / DoTs / execute thresholds that specifically require a healer
  to counter. Do not erode this via solo-balance changes without logging the
  change here first. **Implemented (step 8, Maat8688's fork):** (a) is the
  Staff's `burstHeal` payoff — a successful parry heals the parrying player
  and every other player within `burstHealRadius`. (b) is the
  SkeletonWarrior `GroundSlam`'s bleed `dot`, so a mistimed dodge is chip
  damage only sustain fully undoes. Execute thresholds and a room-wide pulse
  were deliberately not added: the bleed alone satisfies the pillar. Revisit
  only if playtesting shows it isn't enough.
- **Solo play is not the design target — dungeons are group content, tuned
  around a party having a healer.** *(Decided on Maat8688's fork; adopted by
  the repo owner at the merge.)* This licenses tuning chip damage, bleeds and
  execute thresholds hard without keeping a lone Tank or Assassin viable. A
  solo run being harder or outright unintended is acceptable, not a bug.
- **PvP has no simultaneous-parry clash rule, because there's nothing to
  resolve.** *(Decided on Maat8688's fork; adopted by the repo owner at the
  merge.)* A parry is always a reaction to one specific incoming swing, never
  a mutual action two players do at each other. If both players swing at
  once, each parry is judged independently against the other's telegraph —
  both can succeed, both fail, or one of each. Don't add clash or priority
  logic without a concrete case that needs it.
- **Magic enhances combat, it doesn't replace it** — except Mage, which is
  the explicit, deliberate exception.
- **Dungeon generation is room-prefab + connector based**, not noise/terrain
  generation. Hand-built Room models with marked enemy spawns and
  chest-vault rooms, stitched together by a layout algorithm.
- **Economy has two currencies**: coins (common, any kill) and rare crystals
  (tougher enemies/guards only), gating the higher blacksmith tiers so
  trash-mob grinding alone can't reach max gear.
- **Combat is primarily PvE** (zombies/monsters); PvP exists but reuses the
  same combat system rather than a separate one.

## Decisions made while building the vertical slice (Sept 2026)

These implement the locked-in decisions above; they are new commitments, not
changes to them.

- **The parry window is anchored to impact, not to the start of the windup** —
  `[impact - earlyTolerance, impact + lateTolerance]`. Anchoring to impact keeps
  the window correct no matter how long a given attack telegraphs for, so
  attacks with different windups don't each need their own hand-tuned window.
- **The early half is wider than the late half** (Tank: 0.20s vs 0.10s).
  Players anticipate the hit, so pressing slightly early is the common honest
  mistake and shouldn't be punished as hard as pressing after the fact.
- **Latency compensation is a bounded rewind, not prediction.** The server
  trusts the client's timestamp only if it falls within `MAX_ACCEPTED_LATENCY`
  (0.4s) of now and no further into the future than `FUTURE_TOLERANCE` (0.05s).
  This honours "no full client-side prediction" while still being fair to
  players on bad connections.
  *Amended at merge:* bounded rewind alone let a client that knows
  `impactTime` claim a perfect parry anywhere in a 450 ms span. The claim is
  now also checked against the server's receipt-time estimate — see the
  hybrid timestamp check under the merge.
- **Strike resolution is held open past impact** by `STRIKE_RESOLUTION_GRACE`
  (0.15s), so a parry pressed in the late half of the window has time to reach
  the server. **This is the slice's main open tradeoff:** damage feedback lands
  that much after the visual impact, and a player whose round trip exceeds it
  loses late-half parries they legitimately earned. The debug HUD shows ping
  beside the parry delta specifically so this can be set on evidence. Revisit
  before step 2. *(Still unrevisited: no playtest has happened yet.)*
- **A parry fully negates damage** (no chip). Keeps slice feedback unambiguous
  while the window is being tuned. If chip damage on parry is ever wanted, log
  it here before implementing.
- **Parry costs stamina and a whiff costs a lockout**, both server-enforced.
  Without this, mashing the key every frame beats the timing system outright,
  which would hollow out "skill must count as much as level/gear". A press with
  no attack incoming counts as a whiff for the same reason.
- **`GroundSlam` (unparryable) shipped in the slice**, not deferred. DESIGN.md
  requires that combat not become "parry everything"; building the parryable and
  unparryable paths together is cheaper than retrofitting and re-tuning later.
- **Combat math is pure Luau**, segregated from anything touching the Roblox
  API, so it can be unit-tested. See the pure-module rule in ARCHITECTURE.md.
  *Paid off (Sept 2026):* the same specs now also run headless under Lune
  (`lune run test`) with no rewrite, and that runner sandboxes the pure modules
  so a stray Roblox call fails the run instead of silently making a module
  untestable.

## Decisions made building the weapon/class framework (step 2, Sept 2026)

- **Class is derived, never stored.** There is no `ClassDefs` module and no
  class field on the player — `Loadout.classOf(weaponId)` reads `classTag` off
  the weapon. "Switching weapon switches class" is then true by construction
  instead of by keeping two fields in sync.
- **Everything that differentiates a class is data in `WeaponDefs`.** Adding a
  class is adding a row, not writing code. This is deliberately a hedge against
  the open roster question below: it costs nothing to stay open.
- **Each class converts a parry into a different advantage** (`ParryPayoff`),
  rather than every class parrying for the same effect with a different window
  width. Tank buys control (1.5× stagger), Assassin buys damage (2.5× riposte
  for 2.5s), Healer buys sustain (14hp self-heal). This is where "skill must
  count as much as level/gear" lives per class, and a test asserts every class
  has a non-trivial payoff so a future class can't silently skip one.
  *Amended at merge:* the Healer's 14 hp self-heal became Maat8688's 25 hp
  burst heal with a 20-stud radius, which completes the "parry near allies"
  half of the healer pillar.
- **Player attacks were built as part of step 2**, though the build order lists
  them nowhere explicitly. A weapon you can't swing can't express a class: the
  Assassin's riposte has nothing to amplify and the fast/slow attack contrast
  that defines the classes doesn't exist. Enemy health, death and a 3s respawn
  came with it so swings have consequences and tuning can iterate.
- **Swings carry no client timestamp.** Unlike a parry, an attack isn't
  reactive to a server-driven telegraph, so there's nothing to compensate for —
  the server resolves it on its own clock and the bounded-rewind machinery
  isn't needed.
- **Stamina is one pool shared by parrying and swinging.** Creates a real
  attack-or-defend tension rather than two independent budgets.
  *Extended at merge:* the same pool now covers duels too.
- **Weapon swaps are blocked mid-swing**, and each swing captures its weapon at
  windup. Otherwise a player could start a cheap fast swing and land a heavy
  one.
- **Number keys 1/2/3 swap weapons** as a tuning affordance only — the fastest
  way to feel two parry windows back to back. Build-order step 6 replaces it
  with inventory-driven equipping.
  *Amended at merge:* the real equip flow is Maat8688's diegetic weapon stands,
  not inventory-driven equipping. The number keys now work only in Studio, on
  both client and server, so no client-callable equip path ships.

## Decisions made generalizing enemy AI (step 3, Sept 2026)

- **Enemy behaviour is data, not code.** `AttackSelector` has no per-enemy
  branches: an enemy is its attack bands, its `preferredRange`, and its
  weights. The Spitter kites purely because its preferred range sits outside
  its own melee — there is no kiting code. A new enemy needing a branch in
  `AttackSelector` means the behaviour should have been data.
- **A parry resolves against whichever attack lands nearest the press**, and
  the client never names a target. The rejected alternative was "nearest
  *parryable* attack": that would silently redirect a parry away from an
  unparryable attack about to hit you, so the miss teaches nothing and reading
  which attack lands first stops mattering — which is the skill the telegraph
  system exists to test. Tested in `ParryMath.selectParryTarget`.
  *Amended at merge:* only attacks that could reach the player are candidates.
  With several rooms running, "nearest impact" alone could pick an enemy
  swinging at someone else entirely.
- **One state machine and one loop per enemy**, so a staggered Shambler doesn't
  hold up a Spitter across the room. Movement is stepped for all enemies on a
  single Heartbeat so they share a frame delta.
- **An enemy mid-windup cannot reposition.** Letting it drift during the
  telegraph makes the parry beat unreadable, so the wind-up is a commitment for
  the enemy as much as for the player.
- **Enemies move by stepping an anchored part's CFrame**, not via Humanoid
  pathfinding. The rigs are single parts and this keeps hit-reg reading exactly
  the positions the AI reasoned about. Revisit at step 4, when there are walls
  worth pathing around.
  *Revisited at merge (step 4 arrived):* still no pathfinding, but every enemy
  is now leashed to its room's bounds, for both movement and aggro. Stepping
  ignores walls, so without the leash a long-aggro enemy would have walked
  through a wall into the next room.
- **Player swings hit one target**, the nearest in the volume. Cleave is a
  weapon property that doesn't exist yet, and giving it away free would
  trivialise multi-enemy fights the moment they arrived.
- **Every enemy must have at least one parryable attack**, asserted by a test.
  Otherwise a future enemy could silently opt out of the parry system
  altogether, which would quietly erode "skill must count".

## Decisions from Maat8688's fork (steps 4–9, Sept 2026)

Recorded as he logged them, with a note wherever the merge changed the
outcome.

- **RemoteEvents are created at runtime**, not represented as Rojo-synced
  files, through one shared `Remotes.luau`. Keeps "everything lives in one
  place" without binary `.rbxm` assets in git. *(Both sides agreed. At merge,
  his create-on-first-request lookup gave way to this branch's fixed
  registry, so a mistyped name fails loudly instead of quietly creating a
  remote nobody listens to.)*
- **Parry timing is validated using server receipt time, not the client's
  timestamp**, since client and server `os.clock()` aren't synchronized.
  *Superseded at merge:* this branch stamps parries with
  `workspace:GetServerTimeNow()`, which *is* synchronized, so the premise
  doesn't hold. His receipt-time estimate survives as the check on the
  client's claim — see the hybrid timestamp check.
- **No weapon-select screen.** Weapons are picked up from physical stands near
  spawn (`ProximityPrompt`, server-side `Triggered`, no RemoteEvent needed).
  Re-equipping is unrestricted; the real cost of respeccing comes from
  class-specific crystals, not a lock. *(Kept as the real equip flow.)*
- **Equipped weapon is in-memory only** (`EquipService`), like all other game
  state, until DataStores land in step 10.
- **Correction**: ARCHITECTURE.md's planned `EnemyAI.luau` "turned out
  unnecessary", since `Enemy.luau` was already the generalized class.
  *Reversed at merge:* this branch's `EnemyAI.luau` plus the pure
  `AttackSelector` won over his `Enemy.luau`, bringing movement, attack bands,
  weights and cooldowns. His `Enemy:OnDeath` hook was carried across.
- **Correction**: `PlayerData.inventory` is a list (`{ ItemInstance }`), not a
  map keyed by `itemId` — a map can't hold two copies of the same item, and
  each copy can carry its own `upgradeLevel`. `ItemInstance.classTag` is
  optional (nil for class-neutral materials).
- **Correction**: `Dungeon/RoomTemplates` is one module, not a folder — each
  room kind is a short geometry recipe, matching how `WeaponDefs`/`EnemyDefs`
  keep all entries in one module.
- **Rename (step 7)**: `Economy/LootService.luau` → `Economy/CurrencyService.luau`.
  "Loot" already means chest items here (`LootTables`, `ChestOpened`), so a
  `LootService` holding coins and crystals would have read as the item
  pipeline.
- **Correction**: the planned `RequestUpgrade` RemoteFunction was not built.
  The blacksmith is a physical anvil whose `ProximityPrompt.Triggered` already
  fires server-side with the player, so a client-callable path into spending
  currency would widen the trust surface for no gain. The outcome goes back
  over a server→client `UpgradeResult` event. If a real shop UI ever lands,
  re-open this rather than assume it.
- **Correction**: enemy death hooks are a list that receives the killing
  player, not a single slot — the chest unlock and the kill payout are
  independent listeners. *(Kept, as `EnemyAI.onDeath`. At merge, each listener
  was isolated so one failing can't stop the others.)*
- **Upgrades are deliberately weaker than the parry payoff.** A fully upgraded
  weapon is +50% damage; a hit on a staggered target is +100%
  (`STAGGER_DAMAGE_MULTIPLIER`). That ordering is "skill must count as much as
  level/gear" expressed as numbers — don't raise the upgrade ceiling past the
  stagger bonus without logging why. *(A test now enforces the ordering.)*
- **PvP duel health is a virtual per-duel pool** (`Duelist.health`), not the
  real Humanoid, so a duel never damages or kills the character and there's no
  respawn flow to fight.
- **One shared PvP arena, one active duel at a time.** A third queued player
  waits. Revisit if queue times actually become a complaint.
- **PvP reuses `WeaponDefs`/`CombatConstants` directly** rather than
  PvP-specific numbers. The one new number is each weapon's PvP telegraph
  length — players have no `EnemyDefs` entry to read one from — with the Tank
  slowest to read and the Assassin fastest, matching each weapon's parry
  identity. *(Kept, as `attack.pvpTelegraph`.)*
- **Step 4**: the dungeon is a straight chain (a Start room, then 3–5 combat
  rooms of random kind and enemy type), not a branching graph. Still
  room-prefab + connector based and varied every server start; a real layout
  algorithm is a later enhancement, not a gap.
  *Superseded by the dungeon runs below:* a branching, seeded layout with
  room purposes and a boss.
- **Step 5**: each combat room's single enemy guards its chest 1:1. A locked
  chest shows a barrier and has no prompt at all; the guard's first death
  unlocks it permanently, even though the guard respawns. A multi-enemy
  `encounterGroupId` only matters once rooms hold more than one enemy.
  *Superseded by the dungeon runs below:* chests are in Elite and Treasure
  rooms only, locked until every enemy in the room is dead, and dungeon
  enemies don't respawn. `encounterGroupId` was never built and is retired.
- **Step 6**: chests grant a real `ItemInstance` with rarity fixed by which
  enemy guarded it, not rolled. Items are collectible only — not consumed as
  upgrade materials.
- **Step 7**: crystals are keyed by the class being *played* when the kill
  lands, which is what makes respeccing cost something. Upgrades are +10%
  damage per tier, five tiers, and tiers 3+ cost crystals — so trash-mob
  farming alone tops out at +2. Chest items stay mementos: making them
  spendable would mean deciding what a neutral-material sink does to "what's
  inside reflects who you beat", which is a balance question, not plumbing.
- **Step 8**: the balance pass was scoped to the two healer mechanics plus
  confirming solo play isn't a target, not a numeric sweep of every weapon and
  enemy. Those numbers need real playtesting before re-tuning them blind.
- **Step 2 note**: the Assassin's backstab was deferred because enemies had no
  facing direction. *Unblocked at merge:* enemies now turn to face their
  target, so a positional backstab is implementable.

## Merge of Maat8688's fork (Sept 2026)

Both sides built steps 1–3 independently, and the two cores couldn't coexist.
The repo owner's direction: import steps 4–9, and for 1–3 take whichever side
did each part better, carrying ideas across where one improves the other. His
history is preserved in the merge commit; the integration is a separate commit
so each adaptation can be reviewed on its own.

**Kept from this branch, over the fork's equivalent:**

- **Parry anti-spam.** The fork's `ParryAttempt` had no cost or rate limit, in
  PvE or PvP. An autoclicker parried every attack, and in duels each parry
  staggered the opponent into taking double damage, making that player
  effectively unbeatable. Stamina and the whiff lockout now apply everywhere,
  from one shared pool.
- **Late parries.** The fork resolved strikes the instant the telegraph ended,
  so the late half of every window closed before a late press could arrive.
  `STRIKE_RESOLUTION_GRACE` now applies to enemy attacks and duel swings.
- **Facing-aware hit-reg.** The fork checked range only, so every swing and
  enemy attack hit 360°, and duel swings ignored range entirely — a player
  could hit their opponent from across the arena. `DamageMath.isInHitVolume`
  now judges all three.
- **Asymmetric, impact-anchored windows** over a single symmetric
  `parryWindow`.
- **Weapon-keyed `WeaponDefs`** (`SwordAndShield`) over class-keyed
  (`Tank`), so a class can later own more than one weapon.
- **The generalized AI**, as above, and the fixed remote registry.
- **`TakeDamage`** over subtracting `Humanoid.Health`, so a ForceField is
  respected.

**Taken from the fork, over this branch's equivalent:**

- **Steps 4–9 wholesale**, ported onto this branch's APIs.
- **Diegetic weapon stands** as the equip flow. Players now start unequipped
  in the safe start room, which is literally the first step of the core loop.
  `Loadout.DEFAULT_WEAPON` was removed.
- **`EquipService`** as the one owner of equipped weapon and upgrade levels,
  keyed by this branch's weapon ids.
- **The universal stagger punish bonus** (2× damage against a staggered
  target). It gives the Tank's longer stagger real value: a longer
  double-damage window for the whole group. With it in place, the base
  `STAGGER_DURATION` came down from 1.5 s to the fork's 1.2 s, since the
  Tank's 1.5× payoff would otherwise make that window very long.
- **Death hooks with the killer**, isolated per listener.

**Combined — an idea from one side applied to the other:**

- **Hybrid timestamp check.** This branch's client timestamp is precise, but
  on its own a client that knows `impactTime` could send a perfect claim at
  leisure. The fork's receipt-time-minus-half-ping estimate can't be chosen by
  the client, but it's noisy for honest players. The server now trusts the
  client's claim only when it sits within a ping-scaled tolerance of that
  estimate (`ParryMath.plausibleSendWindow`), inside the old hard limits.
  Honest players keep precise timing; the free 450 ms band shrinks to a
  jitter-sized one. **Limit:** a bot that times its sends can still parry
  well, as with any reactive timing system — the client has to know when an
  attack lands to draw it. **Risk:** a sudden ping spike can push an honest
  press outside the tolerance, rejected as `rejected_stale`.
- **Burst heal as data.** The fork's mechanic, with its
  `if class == "Healer"` branch replaced by `burstHeal`/`burstHealRadius` in
  `WeaponDefs`, per this branch's rule that classes are rows, not code.
- **Reach-filtered parry targeting.** The fork's `PARRY_DETECTION_RANGE`
  instinct, applied per attack: an attack is only a parry candidate if the
  player is within its own range plus `PARRY_RANGE_MARGIN`.
- **Bonuses take the larger, not the product.** The stagger bonus and the
  Assassin's riposte both reward the same parry; multiplying them would make a
  riposte into a staggered target hit for 5×. A test keeps every riposte
  above the stagger bonus, so it still adds something.
- **A single dispatcher for PvE and PvP input.** In the fork, the PvE and PvP
  servers both listened on the same remotes and relied on never overlapping.
  `CombatServer` now owns both listeners and routes a dueling player to
  `PvPCombatServer`.

**Bugs the integration would otherwise have shipped:**

- An upgrade scaling a *shallow* copy of a weapon def would have mutated the
  nested `attack` table shared by every player, upgrading that weapon
  server-wide, permanently. Damage is now computed on demand
  (`EconomyDefs.upgradedDamage`).
- `TelegraphVFX` only searched Workspace's direct children, but the dungeon
  parents enemies inside a folder, so every telegraph would have been
  invisible. Enemies are now found by a CollectionService tag.
- `ChestService` looked loot up at open time, so a guard type with no
  `LootTables` row would have crashed in a player's hands. It now fails at
  generation, and a test requires a loot row for every enemy type.
- The `Spitter` wanted to stand 28 studs away inside a 40-stud room. Retuned
  to 16, with a test keeping every preferred range inside one room.
- The debug HUD only cleared telegraphs on stagger or death, never when a
  strike landed, so its "winding up" count grew forever.
- The duel arena spawned one player facing the wall.

**Dropped:** the fork's `Enemy.luau` (superseded by `EnemyAI` +
`CombatServer`), this branch's `RoomBuilder.luau` (superseded by
`RoomTemplates`, as step 1 planned), the fork's
`TELEGRAPH_POLL_INTERVAL` and `PARRY_DETECTION_RANGE` constants, and a joke
comment the fork added to `.gitignore`. Module functions follow this branch's
lowerCamelCase (`CombatServer.start`) rather than the fork's PascalCase.

## Decisions made building persistence (step 10, Sept 2026)

- **What's saved:** coins, class crystals, the equipped weapon, per-weapon
  upgrade levels, and the inventory. Combat resources (stamina, riposte) and
  duel state are session-only.
- **The equipped weapon is saved**, even though the core loop starts at the
  weapon stands. Picking a weapon every session adds nothing once you've
  chosen a class, and the stands are still right there for a respec.
- **One DataStore record per player holds both the data and a session lock.**
  Loading takes the lock in the same atomic `UpdateAsync` that reads the
  data, every save renews it, and leaving releases it. A server that finds its
  lock taken stops writing and kicks the player, so two servers never write
  one profile at once and the newer session always wins.
- **A lock is abandoned after 180 s without renewal** — three missed
  autosaves. That's the price of a server crash: its players can't rejoin for
  up to three minutes. A longer timeout rides out DataStore outages more
  safely but locks players out longer after a crash. Revisit if either shows
  up in practice.
- **Never overwrite what can't be read.** A record from a newer game version,
  or one that isn't a record at all, stops the load and leaves the stored
  value untouched, rather than being replaced with a fresh profile.
- **Sanitising never drops unrecognised ids.** An unknown weapon, class or
  item may be newer content; during a rollback, an older server re-saving a
  profile must not delete that progress. Malformed *shapes* are fixed or
  dropped; unknown *names* are kept. The one thing a rollback can cost is which
  weapon was equipped, because a server can't equip a weapon it doesn't have.
- **No session that won't save.** In a live server, a profile that can't be
  loaded safely kicks the player with a specific explanation, instead of
  letting them play and lose everything on leave.
- **Characters only exist once progress has loaded** (`CharacterAutoLoads`
  off; `SpawnService` spawns). Before that there is nothing to interact with,
  so nothing can change a profile that hasn't been read — no loading race to
  guard in every service.
- **Persisted services never clean up on `PlayerRemoving`.** Roblox doesn't
  guarantee handler order, so a service clearing its state could beat the
  final save and write an empty profile. `DataService` releases each service
  only after that save. This was a real bug in the first draft: all three
  services originally cleared themselves on leave.
- **Writes to one profile are serialised.** An autosave landing after the
  final release would silently re-lock the profile and keep the player out of
  their next server for the full stale timeout.
- **Studio uses its own DataStore** (`PlayerData_v1_Studio`), so playtests can
  never touch live progress. Without DataStore access, Studio runs an unsaved
  session and says so on screen, rather than kicking.
- **The inventory is capped at 500 items**, to keep one record well inside
  the DataStore size limit. A chest opened with a full inventory stays shut,
  rather than being consumed and losing its item to the cap at save time.

## Decisions made in the polish and VFX pass (step 10, Sept 2026)

Gray-box on purpose: no uploaded art, sounds or animations — only Roblox's
built-in defaults — so everything here is readable feedback, not final
visuals. *(Built on in the game-feel pass below, under the same no-uploads
rule.)*

- **All-around attacks draw their real hit area on the ground.** Their hit
  radius can exceed the range they're used from (the SkeletonWarrior slams
  from 10 studs but reaches 14), so without it the correct dodge distance was
  unknowable, which undercuts "must-dodge" as a skill. Directional attacks
  draw nothing: a full disc would misrepresent a cone, and they already read
  from the enemy turning to face you.
- **The stagger colour now survives hits.** Before, the first punish hit reset
  a staggered enemy to its normal colour, hiding the "punish now" cue at the
  one moment it mattered.
- **Enemies show health bars**; before this, enemy health was only visible on
  the debug HUD.
- **Damage numbers show your own hits only**, since only the attacker receives
  `AttackResult`. Riposte hits are larger and orange so the Assassin's payoff
  is visible as it happens.
- **A landed parry gets the biggest reaction** — sparks, a white flash and a
  "PARRY" callout — because it's the action the whole combat design rewards.
- **No sounds yet.** Roblox's built-in sound files aren't reliably present,
  and anything else is an uploaded asset, which belongs with the real art in
  a later pass.
  *Superseded in the game-feel pass:* the premise was half right. The client
  ships only about ten sound files (checked), but Roblox's own classic sounds
  are published assets marked public domain, usable with no upload. See
  that pass below.
- **Fixed: the Shambler's `Lunge` could be chosen from beyond its reach.** It
  was legal at up to 20 studs but hit only to 18, and enemies hold still
  through a windup, so a lunge started at 19–20 studs always missed. A test
  now requires every attack's `maxRange` to be at most its `range`.

## Decisions made adding rigs and animations (Sept 2026)

- **Enemies are built from Parts in code, not downloaded models.** From this
  repo there's no access to Studio's Toolbox or 3D importer, free Toolbox
  models are the most common source of Roblox backdoors, and models from
  other sites carry licence terms. Part-built rigs are free of all three
  problems. Real meshes can replace the parts one for one later, under the
  same names, without touching animation.
  *Partly superseded in the art pass:* the first reason is no longer true —
  Studio is reachable over MCP now, and can generate meshes as well as insert
  Toolbox models. The decision stands on the other two reasons plus a third
  found later (a part-built model is data in git; a mesh is not). See that
  pass below.
- **R15-style rigs** *(chosen by the repo owner)*: elbows and knees make proper
  walk cycles and attack arcs possible, and sharing a default R15 avatar's
  part and joint names means one animation vocabulary covers enemies and
  players, and any refined animation plays on any rig.
- **Players get combat animations too** *(chosen by the repo owner)*. A new
  `PlayerCombatAction` broadcast lets every client see every player's swings
  and parries; before it, nobody could see anyone else attack.
- **One source of truth for rigs and animations.** Both are plain data
  (`RigDefs`, `AnimationDefs`). The game builds enemy rigs from it, and the
  Lune workbench builds the rigs you refine on from it — through the same
  `RigAssembly` code, which takes the Roblox API as an argument so it runs in
  both places. What you refine is exactly what the game uses.
- **Rough animations play straight from data, on each client.** Joints are
  posed by writing `Motor6D.Transform`, so nothing has to be uploaded before
  the game animates — in Studio or live. Animation is purely visual, so it
  runs per client and costs the server nothing.
- **A published version takes over with no code change.** Add its ID to
  `AnimationIds` and that animation plays through Roblox's Animator instead;
  the rough version stays as the fallback. Strikes keep their timing through a
  keyframe named `Impact`.
- **Strike animations are stretched to the real windup**, not played at a
  fixed speed, so the visible hit always lands on the server's impact time —
  the moment the parry window is measured from.
- **Poses are written in `PreSimulation`**: after Roblox's Animator has posed
  the rig for the frame, before joints are applied. That's what lets a player's
  swing sit on top of their normal walk.
- **Your own swings and parries animate on input**, without waiting for the
  server. The client applies the checks it can (weapon equipped, swing
  cooldown); a swing the server then refuses for stamina will still have
  animated. Accepted, for responsive controls.
- **The hitbox didn't change.** It's still the same invisible 4×6×4 box, and
  every combat calculation reads it. The body is decoration hanging off it, so
  none of the combat tuning moved.
- **The wind-up cue became a glow over the whole rig** (a Highlight), since the
  hitbox it used to colour is now invisible. Each rig keeps its own colours at
  rest.
- **Death is drawn on clients** (the animation, then a grey tint); the server
  only turns off the body's collision so players can walk through it.
- **Animations are checked against the floor.** The workbench solves every rig
  at sampled moments of every animation and fails if anything sinks through
  the floor, idle feet lift or dig in, or a death doesn't end lying down. It
  caught two real bugs in the first draft: every death dropped the hips before
  the body had tipped, driving the legs through the floor, and the zombie's
  face-down fall pushed its arms into the ground.
- **Rough poses interpolate one Euler angle at a time.** For the single-axis
  swings these drafts use, that matches the Animation Editor; for big turns on
  several axes at once it can differ slightly, which refining resolves.
- **Asset uploads, if ever automated, use an Open Cloud API key, never an
  account password.** A key can be limited to asset uploads for this
  experience and revoked at any time; a password can't. Not needed yet: rough
  animations need no uploads at all.

## Decisions made in the game-feel pass (Sept 2026)

Asked for by the repo's co-developer: make the game look and feel less like
a gray box before the first playtest. Still no uploaded assets of our own —
everything is Parts, the client's built-in textures, and Roblox's
public-domain sounds — so it can all be swapped for real art later.

- **Feel never touches timing.** Every effect follows a server report, and
  nothing moves the visible impact of an enemy strike: hit-stop refuses to
  hold a strike before impact, and the extra keyframes added to strikes all
  sit inside the same windup-to-impact span that playback already stretches.
  The parry window is read off that impact, so this is non-negotiable.
- **Strikes coil, then snap, then follow through.** The rig eases into the
  windup, keeps drawing back a little (a "coil" keyframe), snaps linearly to
  impact, and carries past the hit pose before recovering. The coil is what
  reads as "about to hit", and the shorter snap makes every blow look heavier,
  without changing any impact time. Only upper-body rotations are
  exaggerated, so feet stay planted and the workbench's floor checks still
  pass.
- **One module owns intensity** (`CombatFeel`). A parry must always feel
  bigger than a hit, and an undodged slam bigger than both; that ordering is
  only maintainable if every number sits side by side. Current ladder, as
  camera trauma: hit 0.16, riposte 0.32, parry 0.36, taking a hit 0.2–0.6,
  slam 0.55 at the centre.
- **Camera shake is added after the camera script and removed before it.**
  Roblox's camera script works out where to look from the camera's own
  CFrame, so a shake left in place accumulates into drift. Yaw shake is kept
  smallest because CameraLock turns the character to match the camera.
- **Damage is an edge vignette, not a full-screen flash.** Covering the
  screen at the moment you're hit hides the next telegraph — the one thing you
  most need to see.
- **Weapons are built on the server** so everyone sees what everyone else
  holds, which is how you read a party's classes at a glance. Pieces are
  massless and non-colliding, and hit-reg still reads only the root part, so
  none of the combat tuning moved. Trails are per client.
- **Upgrades are visible.** A light from +1, sparkles from +3, a neon blade at
  +5. Progress you paid crystals for should show to the people next to you.
- **The start room's stations show what they do**: each weapon floats above
  its pedestal lit in its class colour, the blacksmith is an anvil by a
  burning forge, the duel stand has crossed blades.
- **Dusk, torches and fog** (`default.project.json` → Lighting, Future
  technology). Rooms stay open-topped, so the sky is part of the mood; torches
  do the lighting work. All numbers there are first guesses, like every other
  tunable.
- **Corridors are walled.** They were bare strips over the void, so a strafing
  player could simply walk off.
- **Sounds are data** (`SoundDefs`), keyed by name, the same way animations
  are. The ids in use are Roblox's own 2009 classic sounds (sword slash,
  lunge, unsheath, collide, snap, clicks), published by the Roblox account and
  marked public domain, plus two files shipped inside the client. One clip
  covers several sounds at different pitches. These are placeholders chosen
  because they're safe to use, not because they're right: replacing an id is
  the whole job.
- **An enemy windup makes a sound.** It's a second, audio cue for the parry
  beat, which matters for anyone fighting something at the edge of the
  screen. If it proves too noisy with many enemies, lower its volume before
  removing it.

## Decisions made building dungeon runs (Sept 2026)

Asked for by Maat8688: a randomised dungeon with one boss room to finish it,
rooms of different sizes, and rooms with different purposes. Three choices
were put to him and answered: when the boss dies, pay out and then replace
the dungeon with a new one; enemies don't respawn within a dungeon; and all
four proposed room types (Combat/Elite, Treasure, Shrine, Trap). *(Trap
rooms were replaced by ambush rooms after the first playtest — see below.)*

- **A dungeon is a run with an end.** running → boss dies → everyone in the
  dungeon is paid → 15 s countdown → players return to the start room → a new
  dungeon is generated. One server, no teleporting between places, so the
  whole loop can be played in Studio. Separate lobby and dungeon places are
  still the likely end state once parties exist; this doesn't block that.
- **Rooms stay cleared.** Dungeon enemies don't respawn, which is what makes
  "rooms cleared 3/6" mean something and a chest locked behind a room's
  enemies a real gate. This reverses the step-2/step-5 choice that guards
  respawn "for repeat practice": the practice is now the next dungeon.
  `CombatServer` still respawns enemies by default for anything that asks.
- **The shape is fixed; the details are random.** Every dungeon is Start →
  fights (one Elite in the back half, one Trap never first) → Shrine → Boss,
  with treasure branches off the fights. Randomness picks the length (6–8
  rooms after the Start), turns, sizes, layouts, enemies and branches. A
  fully random mix could put the shrine anywhere or the elite first; a fixed
  shape guarantees the pacing: warm up, get tested, recover, face the boss.
- **Layouts are generated in pure code from a seed**, with a hand-rolled
  generator rather than Roblox's `Random`, so the layout rules can be tested
  across hundreds of dungeons, and a broken one reproduced from its seed.
  Placement is place-and-check (each room off a random free side of the last,
  rejected if it or its corridor overlaps anything); a main path that boxes
  itself in throws the attempt away and retries, a branch that doesn't fit is
  skipped.
- **Everything grows north of the start room**, so the duel arena to the
  south can never collide with a dungeon.
- **The start room is permanent.** It holds the weapon stands, anvil and
  duel queue, and players are sent there during a reset, so it's built once
  and each dungeon starts from its north door.
- **One boss, only in the boss room, only through the shrine.** The boss room
  has a single door, so the fight can't be flanked or skipped into. The
  shrine heals to full once per player per dungeon, so a party meets the
  boss at full health: the boss is the test, not the attrition before it.
- **The Hollow King is built from every tool the game already teaches**: a
  fast parryable Cleave, a slow Overhead that's the big parry opportunity, an
  unparryable Shockwave with a bleed (the healer pillar), and a BoneSpear so
  kiting to heal isn't free. Tuned for a group like the rest of the dungeon;
  600 health will be slow solo, and that's acceptable under the group-first
  decision. It's a 1.6× rig, which needed rig scale support (below).
- **Rigs can be scaled.** Animations stay authored at size 1 and pose offsets
  are multiplied at playback and in the workbench, so one animation
  vocabulary still covers every rig and the floor checks still hold the boss
  to the same standard.
- **The clear is shared.** Every player in the server who isn't in a duel
  gets the clear reward and a Hollow Crown Shard, not only whoever landed the
  last hit. Group content should reward the group. The boss's own kill reward
  still goes to the killer. With one shared dungeon per server, "in the
  server" is the party; revisit when real parties exist.
- **Traps are unparryable telegraphs with no enemy**, drawn and felt exactly
  like a GroundSlam: a filling danger zone, then a blast. They only fire while
  someone is in the room, and some plates in every volley are the ones
  nearest a player, so standing still never works.
  *Superseded after the first playtest:* trap rooms were replaced by ambush
  rooms, in the same slot on the main path. See "Decisions from the first
  playtest".
- **Treasure is off the path, not on it.** Treasure rooms are always dead-end
  branches, sometimes behind an extra fight or trap: an optional detour with
  a known payoff (a relic, or the guard's loot, plus coins).
- **A room's purpose reads from its doorway**: torch colour per purpose (red
  for the elite hall, gold for a vault, teal for the shrine, blue ghost-fire
  for the throne room).
- **The TrainingDummy is in no dungeon pool.** A stationary enemy that
  punishes you for standing near it doesn't belong in a dungeon, and it would
  attack players shopping in the start room. It stays defined for tuning.

## Decisions from the first playtest (Sept 2026)

Maat8688's report after playing: "I don't see me swinging my weapon really",
"the parry is not engaging at all and very hard", and the trap room "was not
good at all — do it better or scrap it".

- **The swing wasn't subtle, it was missing.** Roblox's Avatar Joint Upgrade,
  now the default, builds player avatars from `AnimationConstraint`s instead
  of `Motor6D`s. Player animation only looked for `Motor6D`s, found none, and
  never animated a single swing or parry. Enemies were unaffected because
  their rigs are built here. Both joint kinds are now supported.
- **Swings are combos.** Three swings per weapon, each its own animation, the
  third a finisher (1.6–1.8× damage, longer recovery). Windups are roughly
  halved (sword 0.45 s → 0.26 s), since a sluggish button press read as the
  game not responding, and every swing draws a slash arc and steps the player
  forward. This softens step 2's "windup long enough to be committal": the
  commitment now lives in the combo — once the finisher starts, you're in it.
- **The parry got a timing cue: a ring that closes on impact.** The glow's
  brightness gave no precise moment to press on. The ring lands exactly on the
  server's impact time and its target turns gold for exactly the local
  player's own parry window, so the window is visible, and learnable, per
  weapon. Unparryable attacks get a red pulsing ring and "DODGE".
- **Parry windows roughly doubled** (Tank 200/100 → 300/160 ms, Healer
  140/80 → 240/130, Assassin 80/50 → 170/90). The ordering and the wider
  early half are unchanged; the old numbers were first guesses, and the first
  player found them too hard even in Studio with no ping.
- **Holding the parry key guards.** A parry was all-or-nothing: miss the
  window by a hair and take the full hit, which made trying to parry feel
  worse than not. Now the press still parries if it's in the window, and
  holding the key blocks what it missed: 25% of the damage, paid for in
  stamina, only from the front, and never against unparryable attacks. A hit
  the guard can't pay for breaks it. Guarding also halves walking speed.
  **This changes a locked-in rule**: "a whiff costs a lockout" still holds for
  parrying (0.5 s → 0.35 s), but a mistimed press now blocks instead of
  leaving you open. Parry anti-spam survives: mashing only ever blocks, which
  still takes damage and drains stamina, while a clean parry takes none and
  staggers. Press cost dropped 15 → 6, since the block's stamina cost is now
  where a missed read gets paid for.
- **Trap rooms are replaced by ambush rooms.** Dodging random floor plates
  tested nothing combat teaches and wasn't fun. An ambush seals the gates once
  you're inside and sends two waves (2, then 3 enemies), then opens with a
  chest: the combat itself, under pressure. A party that dies inside gets a
  reset, not a lock-out. `HazardTelegraph` and `TrapService` are gone.

## Decisions from the second playtest: Deepwoken-style combat (Sept 2026)

Maat8688's report: the animations still don't look good, the parry "should
not have those visuals", the swing trails aren't wanted, and the mechanics
should be "more like Deepwoken". This pass rebuilds the defensive and
offensive loop on Deepwoken's model while keeping this game's pillars:
server authority, class payoffs on parry, unparryable attacks that must be
dodged, and group content.

- **Parrying is a block press with frames, judged when the hit lands.**
  Pressing block opens the weapon's parry frames (Tank 280 ms, Healer 240,
  Assassin 200). Nothing is decided on the press: when each hit lands, one
  inside the frames of the player's last press, from the front, is parried.
  This replaces "evaluate the press against the nearest incoming attack":
  there's no target selection to get wrong, one press can catch several
  hits, and a press can't parry a hit that already landed. The timestamp
  authority check is unchanged.
- **Missing a parry puts it on cooldown, and holding block blocks.** A press
  whose frames catch nothing can't open frames again for 0.6 s; presses in
  that time only block. That is the anti-mash rule now, replacing stamina and
  the whiff lockout.
- **Stamina is gone; posture replaces it.** A blocked hit costs no health but
  fills posture. Posture drains back after 1.5 s without blocking. Filling it
  breaks the guard: a 1.2 s stun, and the hit lands in full. A clean parry
  takes posture off. This supersedes the stamina decisions from the slice
  ("parry costs stamina and a whiff costs a lockout") and the first playtest
  (block for 25% damage and stamina): blocking is safe for health but not
  forever, and parrying is what keeps a guard alive.
- **No timing visuals for parryable attacks.** The closing ring from the first
  playtest and the white wind-up glow are removed: attacks are read from
  their animations and the press is timed by eye, as in Deepwoken.
  Unparryable attacks still flash red at wind-up start, because they change
  the right answer (dodge, don't block) in a way a pose can't show. All-around
  attacks keep a faint danger zone, because their radius can't be judged
  from the animation.
- **Hits interrupt, both ways.** A hit that lands on a player stuns them for
  0.35 s and cancels their swing. A player's hit flinches an enemy: it cancels
  a windup unless the attack has hyper armour (every heavy or unparryable
  attack does), then the enemy can't be flinched again for 1.6 s. Without that
  immunity, attacking first would lock every enemy down forever.
- **Dodge (Q) is a dash with 0.3 s of invulnerability**, on a 1.8 s cooldown.
  The press is timestamped and checked like a parry. It can cancel a swing
  only early in its windup. This is now the main answer to unparryable
  attacks.
- **Critical (R) and feint (right click).** Each weapon has a heavy attack on
  a 5–6 s cooldown (the Staff's hits all around). A swing can be feinted in
  the first 65% of its windup, on a 1.5 s cooldown: baiting a parry matters
  more in duels than against enemies, but it's the same system. Criticals are
  dungeon-only for now; duels keep to the opening swing.
- **Four-hit combos with full-body animation.** Every weapon has four swings
  and a critical with real footwork (a stepping stance with the hips dropped
  so the feet stay planted, checked by the workbench), plus a fighting stance
  per weapon held under Roblox's walk. Strikes now ease into the hit and out
  of the follow-through (new `In`/`Out` easings) instead of moving linearly.
  Walking slows to 40% while attacking, 50% while blocking and 25% while
  stunned.
- **No trails, no slash arcs, no screen flash on parry.** A parry is felt
  through the clang, the sparks, the light and the freeze.
- **The debug readout is hidden** and Studio-only (F2). The game's own HUD
  shows only posture (while it's above zero) and the dodge and critical
  cooldowns.

## Decisions made in the art pass (Sept 2026)

The brief: weapons, enemies and dungeon geometry that read as a real place
rather than a gray-box, in one theme — **grim dark fantasy** *(chosen by the
repo owner)*. Cold wet stone, black iron gone to rust, old bone, tarnished
gold, and firelight as nearly the only warm thing on screen.

- **Still part-built, still in the repo** *(chosen by the repo owner)*. The
  earlier rule was justified by "from this repo there's no access to Studio's
  Toolbox or 3D importer" — that premise no longer holds, since Studio is now
  reachable over MCP and can generate meshes. The rule was kept anyway, on
  better grounds: a part-built model is data in git, reviewable in a diff and
  rebuildable from source, whereas a generated mesh lives in the place and the
  cloud, and the place is the one thing this project deliberately does not
  commit. Meshes can still replace pieces one-for-one under the same names.
- **One `Palette` module, and no colour literals in art data.** Rigs, weapons
  and rooms now take every colour from `src/shared/Palette.luau`. A named
  colour used in three places is what makes a sword, a skeleton and a wall
  sconce look like one world; three hand-picked greys is what makes them look
  like three people built them. It is pure, so `RoomTemplates` converts to
  `Color3` at the point of use.
- **Every stone colour is blue-shifted** — blue channel highest, red lowest.
  Warm stone reads as a sunlit castle however dark you make it, and the dusk
  `Lighting` in `default.project.json` already lays a warm tint over the whole
  frame. Cold stone is what lets the torches do the warming. *(Caught by
  building a room in Studio and looking at it: the first pass kept the old
  warm greys and read as sandstone.)*
- **Rig decorations can now carry a rotation**, as weapon pieces already
  could. Silhouette is most of what makes an enemy readable at a distance, and
  almost every strong silhouette cue — a horn, a splayed crown spike, a
  pauldron sloping off a shoulder, a jaw hanging open — needs a piece that
  isn't square to the part it hangs on.
- **The Spitter's acid sac rides above its shoulders and is left unskinned.**
  It is the only enemy that attacks from range, so it is the one that must be
  identifiable before it is in reach; the first version tucked the sac behind
  a translucent hide layer and the whole rig read as a green blob.
- **The Hollow King's greatsword was shortened** back to roughly its old
  reach. At `scale = 1.6` every stud of blade is 1.6 in the world, and a
  longer one drives through the floor on a ground slam.
- **Doorways are arched, and the doors stand open.** The arch is a ring of
  rotated voussoirs with a keystone, laid on the wall above a rectangular
  opening — collision stays a simple box, which is what keeps the leash and
  the corridors honest. The doors are dressing only: a shut door would block
  the corridor its room is reached by.
- **All new dressing is non-colliding.** Barrels, crates, bones, chains, webs,
  banners, ceiling ribs and floor seams never change a room's size, doors or
  leash. Only the floor, walls, door posts and the variant's pillars stop
  anything — those are the things a player expects to stop them, and the
  things an enemy's leash is measured against.
- **Flagstones are seams, not tiles.** Ruling a 56-stud floor into slabs with
  twelve thin strips costs twelve parts; laying it as a real grid costs
  forty-nine, per room, for the same read at standing height.

### Animation

The animations were first drafts: correct poses, but every part moving on the
same clock. The pass changed the shared helpers rather than the per-rig poses,
so every rig and every weapon improved at once.

- **Idle and stance run three clocks at once** — breath, a *lag* copy of that
  motion arriving late in the head and arms, and a slow weight shift from one
  foot to the other. Overlap is the difference between a body breathing and a
  rigid piece pumping in time with itself. The weight shift is one full cycle
  per loop so the loop still closes seamlessly.
- **The walk has ankles.** Feet were never posed before, so the rigs skated.
  Contact now lands heel-first with the toe up, the back foot pushes off toe
  down, and the swing foot lifts to clear the floor. Ankle angles are written
  as "flat, plus a tilt" via a helper, because a foot only lies flat when its
  own angle cancels the thigh and shin above it — working that sum out by hand
  at every keyframe is how feet end up through the floor.
- **Every strike now anticipates.** A short beat the *other* way before the
  windup. Only the upper body counter-moves; the hips and legs go straight to
  the windup stance, so the feet plant first and the arms follow — the order a
  real strike loads in.
- **The workbench's floor solver is the check that matters.** It solves joints
  exactly as the engine does across 24 samples of all 61 animations, and fails
  on anything that sinks, on idle feet that float or dig in, and on a death
  that doesn't end lying down. Every change above was landed against it.

## Decisions made making the dungeon grand (Sept 2026)

The brief: *"tall walls with statues and designs that make it look grand"*, and
weapons held **down** at rest rather than up.

- **Walls read 22 studs tall but are only solid to 12.** Nobody can jump
  twelve studs, so every stud above that is decoration — and building it
  `CanQuery = false` means the camera passes straight through it. Raising the
  whole wall as one solid slab would have made every room grander and played
  worse: the camera would jam into a wall every time a player backed up
  against one, in a game whose combat depends on seeing telegraphs.
- **Corridors stayed low, at 11 studs.** Stepping out of a tunnel into a
  22-stud hall is what sells the hall. Making both tall would flatten the
  contrast and cost twice the parts for it.
- **Grandeur is proportion and repetition, not just height.** Each wall gets
  buttresses at regular intervals, a recessed carved bay between each pair, a
  string course, a dentil frieze and a moulded cap. A tall blank wall reads as
  a big blank wall; a tall wall with a rhythm across it reads as built.
- **Stone sentinels stand in alternate bays**, and line the processional way
  in the boss hall. Only rooms 40 studs or wider get them — a small room lined
  with statues reads as cluttered, not grand.
- **A statue is made of taper, not detail.** The first version stacked boxes
  of roughly equal width and read as a lumpy pillar. What fixed it was a wide
  hem, a waist narrower than both, shoulders wider than everything, arms held
  clear of the body, and a head big enough to find — plus Marble instead of
  Granite, whose speckle at that size is just noise. Silhouette does the work.
- **Every room has an inlaid figure at the centre of its floor.** Rooms are
  fought in from the middle outward, so that is the piece of floor most often
  on screen.
- **A resting weapon dips as far as its length allows, and no further.** The
  hand sits about 2.3 studs up, so a piece `L` long angled `a` below
  horizontal puts its tip at `2.3 - L*sin(a)`. The arming sword (~4.5 studs)
  can only drop about 25 degrees before its point is through the floor; the
  daggers (~1.8) hang nearly straight down; the staff already stands upright
  from a hanging arm and only needed the arm lowered. The **wrist** does the
  dipping, not the shoulder — swinging the shoulder back far enough to aim a
  blade down reads as winding up, not resting.
- **Only the resting stance lowered.** Every guard and every swing still
  raises the weapon; the point was a relaxed idle, not a weaker block.

### The camp, the queue and the one-weapon rule

- **One weapon at a time, swapped only in camp** *(chosen by the repo owner)*.
  Picking a weapon from a stand replaces the one you carry rather than adding
  to it, and the swap is only possible in the start area — never mid-run.
  Upgrade levels stay per weapon (`EquipService` already stored them that
  way), so returning to a weapon you previously upgraded keeps its level.
  This **reverses** the earlier locked-in decision that respeccing is free and
  unrestricted; the cost is now the walk back to camp as well as the crystals.
- **The camp rule is checked, not assumed.** The stands only stand in camp, so
  reaching one already means being in camp — but `WeaponPickups` asks
  `DungeonService.isInCamp` anyway, so the rule survives anyone later putting
  a stand somewhere else. The Studio-only 1/2/3 debug swap deliberately
  bypasses it: it exists to compare weapons back to back while tuning.
- **The equipped weapon shows in the inventory panel**, as its own section
  above the loot list rather than as a fake `ItemInstance`. Weapons are not
  loot: listing one as an item would mean inventing itemIds for every weapon,
  paying the `MAX_INVENTORY` cap for something that is always exactly one, and
  teaching the save format about a second kind of thing. It carries no rarity
  colour either, for the same reason.
- **The dungeon is entered through a ready-check queue.** Interacting with the
  gate starts a ten-second countdown; anyone who queues before it ends goes in
  with them, and a solo player still gets in when it expires. A queue that
  waits for N players would strand the only person online, which is most
  servers most of the time.
- **The gate burns while a ready check is running.** Anyone in camp can see a
  run is about to leave without reading any UI, which is the whole point of
  putting the queue on a physical gate rather than in a menu.
- **The countdown shows on the dungeon status line**, replacing room progress
  while you are queued. You are standing in camp at that moment; how many
  rooms are cleared in a dungeon you are not in is not the useful thing.
- **If the dungeon is mid-reset when the countdown fires, the queue holds**
  rather than sending anyone into a torn-down run. `DungeonService.entryCFrame`
  returns nil in that window, which is the signal to wait and retry.
- **The camp's north doorway is closed by a portcullis**, so the queue is the
  way in rather than a suggestion. Nothing blocks the corridor from the far
  side: a finished run still walks home.
- **The blacksmith got a building.** An anvil standing in the open read as a
  prop; a timber-framed forge with a hearth, chimney, blade rack, quench
  trough and a hanging sign reads as a shop. Its forge fire is deliberately
  the warmest light in the game — it is what the camp is read by, against all
  that cold stone.
- **The dungeon stays in this server.** It already did — the start room is at
  the origin and each dungeon is generated north of it in the same
  `Workspace`, with no `TeleportService` anywhere. Worth writing down because
  "queue" usually implies a reserved server, and here it deliberately does not.

## Open / not yet decided

- ~~Is solo play fully supported, or is this group-first content? This changes
  how hard healer-necessity can be tuned.~~ *Resolved: group-first — see
  Locked-in decisions.*
- Fixed class roster (Tank/Assassin/Healer/Mage/...) or open to add more later?
  *(Still open, but no longer urgent: step 2 made classes pure data in
  `WeaponDefs`, so adding one is a row rather than a refactor. Mage is the one
  that will actually force the question, since "magic replaces combat" can't be
  expressed as a weapon row alone.)*
- ~~PvP: does a simultaneous parry cause a clash/neutral outcome, or does one
  side win?~~ *Resolved: neither — there is no clash to resolve. See Locked-in
  decisions.*

## Build order

1. ~~Vertical slice: one room, one enemy, one weapon — get parry, hit-reg, and
   stagger feeling right, fully server-authoritative.~~ Built; needs its
   tuning pass.
2. ~~Weapon/class data framework (2–3 classes).~~ Built: Tank, Assassin,
   Healer. Still ahead: Assassin backstab (now unblocked), Mage.
3. ~~Enemy AI + telegraph system, generalized across enemy types.~~ Built:
   four enemy types on one data-driven AI.
4. ~~Room-based dungeon generator.~~ Built on Maat8688's fork: a linear chain.
5. ~~Chest/encounter gating.~~ Built on Maat8688's fork: one guard per chest.
6. ~~Loot + inventory/equip system.~~ Built on Maat8688's fork.
7. ~~Blacksmith/economy.~~ Built on Maat8688's fork.
8. ~~Healer-specific mechanics + a real balance pass.~~ Built on Maat8688's
   fork; the numeric balance pass still needs playtesting.
9. ~~PvP arena mode.~~ Built on Maat8688's fork; rebuilt on this branch's
   combat rules at the merge.
10. ~~Persistence (DataStores), polish, VFX.~~ Built: session-locked
    saving, plus a gray-box feedback pass (danger zones, health bars, damage
    numbers, parry sparks). Saving is untested against a real DataStore until
    the place is published with Studio API access enabled; real art, sound and
    animation are still ahead.
11. ~~Dungeon runs: randomised layouts, room sizes and purposes, a boss.~~
    Built: see "Decisions made building dungeon runs". Needs playtesting for
    pacing, ambush waves and boss health.
