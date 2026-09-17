# Architecture — Roblox Dungeon Crawler

> Read this file (and DESIGN.md) at the start of every session before writing code.
> They exist so decisions made in one session don't get silently redone or
> contradicted in the next.

## Before adding anything new

1. **Search this file first** for the thing you're about to name — a RemoteEvent,
   a ModuleScript, a data field, a class/rarity/tag string. If it already has a
   name, reuse that exact name and casing. Do not invent a synonym.
2. If it's genuinely new, **add one line to the relevant table below before
   finishing this session.** Don't leave a new RemoteEvent, module, or constant
   undocumented — the next session has no other way to know it exists.
3. Never silently rename something already listed here. If a rename is truly
   needed, update every reference, then log the rename (old name → new name,
   and why) in DESIGN.md's decision log.

## Project layout (Rojo → Roblox services)

Source folders are mapped by `default.project.json`. Files are `.luau`.
Module functions are lowerCamelCase (`CombatServer.start`). Entries marked
*(planned)* do not exist yet — see the build order in DESIGN.md.

```
src/shared/            -> ReplicatedStorage.Shared
  CombatConstants.luau   -- shared combat tunables: timestamp authority, parry
                         -- cooldown, posture, hitstun, dodge, feint, movement,
                         -- stagger + punish bonus, strike grace, respawn, PvP
  ParryMath.luau         -- timestamp authority, parry frames and their
                         -- cooldown, dodge windows (pure)
  PostureMath.luau       -- posture: filling on a block, draining, breaking (pure)
  DamageMath.luau        -- damage resolution, blocking, hit-reg geometry (pure)
  AttackSelector.luau    -- enemy attack choice, movement intent, room leash (pure)
  Loadout.luau           -- equip validation + class-from-weapon derivation (pure)
  WeaponDefs.luau        -- weaponId -> class, parry profile, attack, payoff
  EnemyDefs.luau         -- enemyId -> stats, movement, rewards, attack timelines
  LootTables.luau        -- enemyId -> chest loot descriptor
  EconomyDefs.luau       -- upgrade cost curve, tiers, upgraded damage (pure).
                         -- Shared so the client can show a price; the server
                         -- always recomputes before charging
  PlayerDataSchema.luau  -- saved-progress shape: defaults, migration,
                         -- sanitising, session-lock rules (pure). Shared only
                         -- so it's testable; the client never uses it
  Palette.luau           -- the one colour palette every rig, weapon and room
                         -- draws from: stone, metal, bone, cloth, firelight,
                         -- plus shade/mix helpers (pure)
  RigDefs.luau           -- the shared R15 skeleton + each rig's look (pure)
  AnimationDefs.luau     -- every rough animation, as keyframe data (pure)
  AnimationIds.luau      -- published replacements for those animations (pure)
  KeyframeMath.luau      -- sampling, easing, blending, strike timing (pure)
  RigAssembly.luau       -- builds rigs from RigDefs using an API it's handed,
                         -- so the game and the Lune workbench share it
  DungeonDefs.luau       -- the rules dungeons are generated from: room sizes,
                         -- purposes, enemy pools, traps, rewards (pure)
  DungeonLayout.luau     -- seeded dungeon layout generator: rooms, purposes,
                         -- positions, doors, enemies, corridors (pure)
  WeaponModelDefs.luau   -- weaponId -> the parts its in-hand model is built
                         -- from, trail and glow colours, upgrade look (pure)
  SoundDefs.luau         -- sound name -> asset id, volume, pitch range (pure)
  Remotes.luau           -- every RemoteEvent is created here, from a fixed list;
                         -- nothing created ad hoc elsewhere
  __tests__/             -- Jest specs, mounted by test.project.json only

src/server/            -> ServerScriptService.Server
  init.server.luau       -- bootstrap: combat, dungeon, stations, arena, then
                         -- players
  DataService.luau       -- loads and saves progress: session locks, autosave,
                         -- final save on leave and on shutdown
  SpawnService.luau      -- when characters exist: first spawn only once a
                         -- profile has loaded, start-room placement, respawn
  EquipService.luau      -- the only owner of equipped weapon + upgrade levels;
                         -- onChanged tells listeners when either changes
  InventoryService.luau  -- the only owner of inventory
  WeaponPickups.luau     -- weapon stands in the camp (ProximityPrompt), each
                         -- showing its weapon. One weapon at a time: taking
                         -- one replaces the one you carry, and only in camp
  WeaponVisuals.luau     -- builds WeaponModelDefs models: welded into players'
                         -- hands on equip/respawn, and on the stands
  Combat/
    CombatServer.luau    -- the authority: enemy state machines, PvE parry and
                         -- swing resolution, bleeds, burst heal. Owns the
                         -- ParryAttempt/AttackRequest listeners for PvP too,
                         -- routing duelists to PvPCombatServer
    EnemyAI.luau         -- enemy rigs, movement, leash, death hooks
    PlayerCombatState.luau -- per-player posture, stun, guard and parry press,
                         -- dodge/critical/feint cooldowns, riposte, swing
                         -- timing; one record shared by PvE and PvP
    Characters.luau      -- character lookups + XZ projection + half-ping
  Dungeon/
    DungeonService.luau  -- the run: builds the start room once, generates a
                         -- dungeon, tracks room clears and the boss fight,
                         -- pays the clear reward, then replaces the dungeon
    DungeonGenerator.luau -- builds a DungeonLayout into the world: rooms,
                         -- corridors, enemies (no respawn), chests, shrine,
                         -- traps — all in one folder, torn down whole
    RoomTemplates.luau   -- room geometry: any size, doors on any side,
                         -- variants (Empty/Pillars/Ruins/Hall), corridors,
                         -- arched doorways, buttressed bays, statues,
                         -- torches; owns the dungeon's look. One module, not
                         -- a folder — see DESIGN.md
    QueueService.luau    -- the gate into the dungeon: a ready-check queue on a
                         -- ProximityPrompt, a countdown, and the portcullis
                         -- that makes the gate the way in
    ChestService.luau    -- chests locked until every guard in the room is
                         -- dead (open at once if none); lid opens on loot
    AmbushService.luau   -- ambush rooms: gates seal on entry, enemies arrive in
                         -- waves, gates and chest open when the last falls
    ShrineService.luau   -- the pre-boss fountain: full heal, once per player
                         -- per dungeon
  Economy/
    CurrencyService.luau -- the only owner of coins + class-keyed crystals; pays
                         -- the killer via each enemy's death hook, and
                         -- non-kill rewards through grant
    BlacksmithService.luau -- the start-room anvil: prices an upgrade, takes
                         -- payment, hands off to EquipService
  PvP/
    ArenaService.luau    -- the arena room, the duel queue, who duels whom
    Duelist.luau         -- one side of a duel: state machine + virtual health
    PvPCombatServer.luau -- resolves duel swings and parries on the PvE rules;
                         -- listens on no remote itself

src/client/            -> StarterPlayer.StarterPlayerScripts.Client
  init.client.luau       -- bootstrap
  CombatClient.luau      -- combat input (attack, critical, feint, block, dodge),
                         -- local prediction, the dash and lunge, movement
                         -- slowdowns, and Studio-only 1/2/3 weapon swaps
  CameraLock.luau        -- toggleable shift-lock camera (Left Shift)
  RigAnimation.luau      -- plays AnimationDefs on one rig via joint Transforms
                         -- (Motor6D or AnimationConstraint), or a published
                         -- version via Animator; stances layer over avatars
  EnemyAnimation.luau    -- picks each enemy's animation from server events
  PlayerAnimation.luau   -- player stances, combo swings, criticals, guard,
                         -- feint, dodge, flinch and guard break
  TelegraphVFX.luau      -- red flash and danger zone for unparryable attacks,
                         -- stagger and death tints. Nothing for parryable ones
  WorldFeedback.luau     -- enemy health bars, damage numbers, hit and
                         -- parry sparks, shockwaves, death bursts, heal motes
  CombatFeel.luau        -- the one place deciding how hard each moment hits:
                         -- server events -> shake, hit-stop, sound, screen FX
  CameraShake.luau       -- trauma-based screen shake, undone every frame
  ScreenFX.luau          -- damage/heal/low-health vignettes, parry colour
                         -- flash and field-of-view kick
  SoundFX.luau           -- plays SoundDefs sounds, positional or flat
  GameUI.luau            -- player-facing UI: posture bar, dodge/critical
                         -- cooldowns, weapon, currency, loot, upgrades,
                         -- inventory (I), dungeon status, duel status
  DebugHUD.luau          -- Studio-only combat tuning readout, hidden until F2

tests/                 -> mounted only by test.project.json, never shipped
  jest.config.luau
  TestRunner.server.luau

lune/                  -> not mapped by Rojo; Lune scripts run from the repo root
  test.luau              -- `lune run test`: runs the same specs headless, with
                         -- pure modules sandboxed away from the Roblox API
  animation-workbench.luau -- `lune run animation-workbench`: every rig with its
                         -- rough animations as KeyframeSequences, self-checked
  lib/sharedModules.luau -- loads src/shared outside Roblox, sandboxed

workbench/             -> generated by the workbench script; gitignored
```

**Pure-module rule.** `CombatConstants`, `ParryMath`, `DamageMath`,
`AttackSelector`, `Loadout`, `WeaponDefs`, `EnemyDefs`, `LootTables`,
`EconomyDefs`, `PlayerDataSchema`, `Palette`, `RigDefs`, `AnimationDefs`,
`AnimationIds`, `KeyframeMath`, `WeaponModelDefs`, `SoundDefs`, `DungeonDefs`,
`DungeonLayout` and `PostureMath` must not call any Roblox API. (`DungeonLayout` has its own
seeded generator rather than Roblox's `Random` for exactly this reason.)
`RigAssembly` is the one shared module that creates instances, and it only
ever uses the API passed to it, never globals. That is what keeps the combat and
economy math unit-testable, and what lets the same specs run headless under
Lune. Anything needing `game`, `workspace` or `Instance` belongs in the server
or client layer, not in these files. `lune run test` enforces this for every
module a spec loads: those globals are traps in its sandbox.

**Spec rule.** A spec may only require pure shared modules, through
`ReplicatedStorage.Shared`, and may only use the Jest matchers the Lune runner
implements (`toBe`, `toEqual`, `toBeCloseTo`, `toBeNil`, and `never`). The
runner fails loudly on anything else — extend it rather than working around it.

**Single-owner rule.** Equipped weapon and upgrade levels live only in
`EquipService`, inventory only in `InventoryService`, currency only in
`CurrencyService`, per-player combat resources only in `PlayerCombatState`.
Everything else asks them.

**Persistence rule.** Each persisted service exposes `hydrate`, `snapshot`
and `release`, and only `DataService` calls them. **A persisted service must
never clear a player's state on `PlayerRemoving`:** Roblox doesn't guarantee
the order those handlers run in, so a cleanup could beat the final save and
write an empty profile. `DataService` calls `release` once that save is done.
A new persisted field needs all three hooks, a `PlayerDataSchema` field, and
(if its shape changes) a migration.

## Naming registry — RemoteEvents

All payloads are a single table.

| Name | Direction | Payload | Purpose |
|---|---|---|---|
| `ParryAttempt` | Client → Server | `{ timestamp }` | Parry key pressed: attempts a parry and raises the guard, which stays up until `GuardReleased`. `timestamp` is `workspace:GetServerTimeNow()` on the client; the server checks it against its own receipt-time estimate (`ParryMath.plausibleSendWindow`) |
| `GuardReleased` | Client → Server | *(none)* | Parry key released: the guard comes down |
| `CriticalRequest` | Client → Server | *(none)* | Heavy attack. The server checks the cooldown |
| `FeintRequest` | Client → Server | *(none)* | Cancel the swing in progress, if still early enough |
| `DodgeRequest` | Client → Server | `{ timestamp }` | Dash. Invulnerability counts from `timestamp`, checked like a parry's |
| `CombatStateChanged` | Server → Client | `{ posture, postureUpdatedAt, postureDamagedAt, stunnedUntil, dodgeReadyAt, criticalReadyAt, riposteUntil }` | The player's own posture, stun and cooldowns, in server time, for the HUD and local prediction. The client drains posture forward with `PostureMath` between sends |
| `AttackRequest` | Client → Server | *(none)* | Player swings. Carries no timestamp — a swing isn't reactive, so the server resolves it on its own clock |
| `EquipWeapon` | Client → Server | `{ weaponId }` | **Studio only** — the 1/2/3 debug swap. Ignored by a live server; weapon stands are the real equip path |
| `EnemyTelegraphStart` | Server → Client | `{ enemyId, attackId, duration, impactTime, parryable }` | Attack is winding up. `impactTime` is absolute so a delayed packet doesn't shift the cue |
| `EnemyStaggered` | Server → Client | `{ enemyId, duration, kind }` | Enemy interrupted. `kind` `stagger`: a parry (`duration` already scaled by the parrier's class payoff). `kind` `flinch`: a player's hit |
| `EnemyHealthChanged` | Server → Client | `{ enemyId, health, maxHealth, alive }` | Enemy spawn, damage, death and respawn |
| `PlayerHit` | Server → Client | `{ amount, sourceId, attackId, bleed?, blocked?, guardBroken?, dodged? }` | A hit reaching the player. `sourceId` is an enemy id, or the attacker's name in a duel. `bleed` marks a damage-over-time tick. `blocked`: a guard took it (`amount` 0; posture filled). `guardBroken`: posture filled up, the guard broke and the hit landed. `dodged`: it passed through a dodge (`amount` 0) |
| `ParryResult` | Server → Client | `{ verdict, success, deltaMs, riposteUntil, enemyId? }` | Sent only for a successful parry, when the hit it caught lands. `deltaMs` is the press's signed distance from impact. `enemyId` is what was parried (the attacker's name in a duel) |
| `AttackResult` | Server → Client | `{ hit, reason, damage, riposte, enemyId? }` | Swing outcome. `reason` is from the attack-result registry below |
| `HealBurst` | Server → Client | `{ amount, healerName }` | Fired to each player actually healed by a parry-triggered burst heal, or by the shrine (`healerName` `Shrine`) |
| `PlayerCombatAction` | Server → Client (all) | `{ userId, action, weaponId, windup?, step? }` | A player's move, so every client can animate it. `action` is `swing` \| `critical` \| `parry` (block key down) \| `guard_end` \| `feint` \| `dodge`; `windup` is how long a swing or critical takes to land and `step` which combo swing it is. Clients ignore their own, already animated on input |
| `ProfileLoaded` | Server → Client | `{ persistent }` | The player's progress is ready. `persistent` is false only in a Studio session running without DataStore access |
| `WeaponEquipped` | Server → Client | `{ weaponId, classTag, upgradeLevel }` | Fired on equip, on load, and whenever the equipped weapon's upgrade level changes |
| `ChestOpened` | Server → Client | `{ chestId, loot, inventoryFull? }` | `loot` is a list holding one `LootTables` descriptor (display info, not the stored `ItemInstance`). With `inventoryFull`, `loot` is empty and the chest stays shut |
| `InventoryUpdated` | Server → Client | `{ items }` | The player's full `ItemInstance` list whenever it changes |
| `CurrencyUpdated` | Server → Client | `{ coins, crystals }` | Whenever a balance changes; `crystals` is keyed by class |
| `UpgradeResult` | Server → Client | `{ success, reason?, newLevel? }` | Blacksmith outcome; `reason` is player-facing refusal text |
| `PvPStatusChanged` | Server → Client | `{ status, opponentName?, message? }` | `status` is `idle` \| `queued` \| `dueling`; `message` is set when a duel ends |
| `PvPTelegraphStart` | Server → Client | `{ attackerName, duration, impactTime }` | Sent to the defending duelist when their opponent swings |
| `PvPParryResult` | Server → Client | `{ success, message }` | Sent to both duelists when a duel swing is parried |
| `PvPHealthChanged` | Server → Client | `{ yours, opponent }` | Both duelists' virtual health, whenever either changes |
| `DungeonUpdated` | Server → Client (all) | `{ run, phase, roomsCleared, roomsTotal, resetAt? }` | Where the dungeon run stands. `phase` is `running` \| `cleared` \| `resetting`; `resetAt` (server time) is set while `cleared`. Also sent to each joining player |
| `DungeonNotice` | Server → Client | `{ text, tone }` | A message to show: room cleared, boss awakens, shrine used. `tone` is `good` \| `bad` \| `info` \| `danger` \| `victory` |
| `BossEncounter` | Server → Client (all) | `{ enemyId, name, active, defeated }` | The boss fight starting (a player entered the boss room), ending (everyone left for a while), or won (`defeated`) |
| `DungeonQueueChanged` | Server → Client | `{ queued, count, entersAt? }` | The dungeon ready-check. `queued` is whether *this* player is in it, `count` how many are waiting, `entersAt` (server time) when the countdown fires. Sent to everyone queued whenever anyone joins or leaves, and once with `queued = false` when they go in |
| *(add new rows here as they're built)* | | | |

### Retired remote names

Planned or built under these names at some point; none exist now. Don't reuse
them for something different.

| Name | Fate |
|---|---|
| `RequestUpgrade` | Planned RemoteFunction, never built — the blacksmith is a `ProximityPrompt`, and the outcome goes over `UpgradeResult` (see DESIGN.md) |
| `AttackAttempt` | Maat8688's fork name for `AttackRequest`; retired at the merge |
| `EnemyStateChanged` | Maat8688's fork; replaced at the merge by `EnemyTelegraphStart`, `EnemyStaggered` and `EnemyHealthChanged` |
| `HazardTelegraph` | Trap-room plates; retired with trap rooms, replaced by ambush rooms (see DESIGN.md) |

## Naming registry — Classes

| Id | Weapon type | Status | Notes |
|---|---|---|---|
| `Tank` | Sword + Shield | built | Widest parry window; its payoff is the longest stagger, i.e. the longest double-damage window for the group. A distinct shield-bash counter isn't built |
| `Assassin` | Daggers | built | Tightest window, highest payoff — currently the riposte. Backstab is unblocked (enemies now have a facing) but not built |
| `Healer` | Staff / Mace | built | Parries trigger a burst heal that reaches allies |
| `Mage` | Staff / Wand | not built | Exception — magic replaces basic combat, not just enhances it. Needs its own combat model, deliberately not a `WeaponDefs` row yet |
| *(add new rows here as they're built)* | | | |

## Naming registry — Weapons

Class is derived from the weapon, so this table *is* the class roster. There is
deliberately no `ClassDefs` module. Exact numbers live in `WeaponDefs.luau`;
this table is the summary.

| Id | Class | Parry window | Parry payoff | PvP telegraph |
|---|---|---|---|---|
| `SwordAndShield` | `Tank` | 280 ms frames — longest | Control: 1.5× stagger duration | 0.50 s |
| `Daggers` | `Assassin` | 200 ms frames — shortest | Damage: 2.5× for 2.5 s (riposte) | 0.30 s |
| `Staff` | `Healer` | 240 ms frames | Sustain: 25 hp burst heal, 20-stud radius | 0.45 s |

**Combos.** Every weapon's `attack.combo` is a list of swings (4 today), each
with its own windup, damage multiplier and animation (`swing_<weaponId>_<step>`);
the last is the finisher. Pressing again within `comboWindow` of a swing landing
continues the combo (`Loadout.nextComboStep`, shared by server and client).
Duels use step 1 only, on `pvpTelegraph`. `attack.critical` is the heavy attack
(`critical_<weaponId>`), on its own cooldown; dungeon only for now.

**Parrying and blocking.** Pressing block opens the weapon's parry frames
(`parry.earlyTolerance`) and raises a guard held until release. Nothing is
judged on the press: when each hit lands, a parryable hit from the front
(`BLOCK_ARC_DEGREES`) inside those frames is parried (`ParryMath.catches`).
A press whose frames catch nothing puts parrying on `PARRY_COOLDOWN`; presses
during it only block (`ParryMath.pressOpensFrames`). A blocked hit costs no
health but fills posture (`PostureMath`); filling it breaks the guard, stuns
for `GUARD_BREAK_STUN`, and lands the hit in full. Unparryable attacks ignore
parries and guards alike. Mid-swing or stunned, the guard doesn't count.

**Hitstun and flinching.** A hit that lands on a player stuns them briefly and
cancels their swing. A player's hit flinches an enemy: cancels its windup
unless the attack has `hyperArmor`, or delays its next move if idle, then leaves
it immune to flinching for `ENEMY_FLINCH_IMMUNITY`.

**Dodging and feinting.** A dodge makes the player invulnerable for
`DODGE_IFRAMES` from its (timestamped) press, on `DODGE_COOLDOWN`. A swing can be
feinted, or dodge-cancelled, only in the first `CANCEL_WINDOW_FRACTION` of its
windup.
| *(add new rows here as they're built)* | | | | |

**Class-derivation rule.** A player's class is never stored. It is always read
from their equipped weapon's `classTag` via `Loadout.classOf`, which makes
"switching weapon switches class" true by construction. Adding a class means
adding a row to `WeaponDefs` — there should never be an
`if classTag == "..."` branch anywhere in combat.

## Naming registry — Enemies / attacks

Behaviour is data, not code. An enemy is defined by its attack bands
(`minRange`/`maxRange`), where it wants to stand (`preferredRange`) and how it
weights its options — a charging melee type and a kiting ranged type come out of
the same `AttackSelector` with no per-enemy branches. **If a new enemy needs a
branch in `AttackSelector`, the behaviour belongs in `EnemyDefs` as data
instead.** Every enemy is leashed to its room, and any enemy type can guard a
chest, so a new enemy also needs a `LootTables` row. Enemies hold still through
a windup, so every attack's `maxRange` must be at most its `range` — a test
enforces it.

| Enemy id | Role | Rewards | Attack id | Parryable | Notes |
|---|---|---|---|---|---|
| `TrainingDummy` | stationary; in no dungeon pool | 10 coins | `Overhead` | yes | Baseline parryable attack |
| | | | `GroundSlam` | **no** | Must-dodge; exists so combat isn't "parry everything" |
| `SkeletonWarrior` | melee, tough | 25 coins, 1 crystal | `Slash` | yes | Quick parryable swing |
| | | | `GroundSlam` | **no** | Hit volume (14) wider than its use range (10); leaves a bleed |
| `Shambler` | melee, closes | 15 coins | `Claw` | yes | Fast pressure at touching range |
| | | | `Lunge` | yes | Long reach, `minRange` 9 so it reads as a lunge, not a swing |
| `Spitter` | ranged, kites | 15 coins | `Spit` | yes | Narrow 25° cone at range |
| | | | `Spray` | **no** | Point-blank panic option, so closing the gap isn't a free win |
| `HollowKing` | boss, 1.6× size | 250 coins, 4 crystals | `Cleave` | yes | Fast wide sweep |
| | | | `Overhead` | yes | Slow, hardest-hitting; the big parry opportunity |
| | | | `Shockwave` | **no** | Radius 20 from 14; leaves a bleed |
| | | | `BoneSpear` | yes | Long narrow throw, so backing off isn't safe |
| *(add new rows here as they're built)* | | | | | |

Enemy models carry the attributes `EnemyId` and `EnemyDefId`.

## Naming registry — CollectionService tags

| Tag | On | Purpose |
|---|---|---|
| `Enemy` | every enemy model | Client lookup by `EnemyId` wherever the model is parented (`EnemyAI.TAG`). Clients also watch it for enemies streaming in, so they never assume a model exists yet |

**Client-only VFX instances.** `DangerZone` and `Shockwave` parts in
Workspace, `SoundFX` attachments under Terrain, `HealthBar_<enemyId>`
BillboardGuis and the `ScreenFX` ScreenGui in PlayerGui, the `CombatGrade`
ColorCorrectionEffect in Lighting, the `StateTint` and `UnparryableFlash`
Highlights, hit/parry Highlights and spark attachments under enemy models, and
`CombatPush` attachments (the dash and lunge) under the local character are
created by each client for itself and never replicate.
Nothing on the server may look for them. Particles use only textures that ship
inside the Roblox client (`rbxasset://textures/particles/...`) — no uploaded
assets.

**Server-built visuals.** Each character's weapon is a Model named
`EquippedWeapon` (`WeaponModelDefs.MODEL_NAME`), built by `WeaponVisuals`, and
the character carries a `WeaponId` attribute (`WeaponModelDefs.WEAPON_ATTRIBUTE`)
that clients read to pick its stance. Weapon pieces are massless and never
collide, query or touch, so they can't change movement or hit-reg.

## Naming registry — Rigs

Every rig uses the R15 part and joint names below, the same as a default
Roblox R15 avatar. That shared vocabulary is what lets one animation play on
any rig and on players.

| Rig id | Used for | Look |
|---|---|---|
| `TrainingDummy` | the enemy | Wooden mannequin, target on the chest |
| `SkeletonWarrior` | the enemy | Bone spine and ribs, dark eye sockets, sword in the right hand |
| `Shambler` | the enemy | Green skin, torn shirt, glowing red eyes |
| `Spitter` | the enemy | Bloated body on thin limbs, glowing acid sac |
| `HollowKing` | the boss | Crowned skeleton in black iron, cape, glowing greatsword; `scale` 1.6 |
| `R15Player` | the workbench only | Plain grey figure standing in for a player avatar |

**Rig scale.** A style's `scale` multiplies every part, joint, decoration and
the hitbox (`RigDefs.rootSize`). Animations stay authored at size 1:
`RigAnimation` and the workbench multiply pose offsets (px/py/pz) by the
rig's scale, and the workbench's floor tolerances scale with it. A published
Animator version of a scaled rig's animation does *not* get this for free —
author it on the scaled workbench rig.
| *(add new rows here as they're built)* | | |

An enemy's rig id is its `EnemyDefs` id. **An enemy model** is:
`HumanoidRootPart` (the invisible 4×6×4 hitbox — the only part that collides,
and the one every combat position is read from), the 15 body parts on Motor6D
joints under it, welded decorations, and an `AnimationController` with an
`Animator`.

| Part | Joint (inside the part) | Parent |
|---|---|---|
| `LowerTorso` | `Root` | `HumanoidRootPart` |
| `UpperTorso` | `Waist` | `LowerTorso` |
| `Head` | `Neck` | `UpperTorso` |
| `RightUpperArm` / `LeftUpperArm` | `RightShoulder` / `LeftShoulder` | `UpperTorso` |
| `RightLowerArm` / `LeftLowerArm` | `RightElbow` / `LeftElbow` | the upper arm |
| `RightHand` / `LeftHand` | `RightWrist` / `LeftWrist` | the lower arm |
| `RightUpperLeg` / `LeftUpperLeg` | `RightHip` / `LeftHip` | `LowerTorso` |
| `RightLowerLeg` / `LeftLowerLeg` | `RightKnee` / `LeftKnee` | the upper leg |
| `RightFoot` / `LeftFoot` | `RightAnkle` / `LeftAnkle` | the lower leg |

## Naming registry — Animations

| Name | Rigs | Plays when |
|---|---|---|
| `idle` | every enemy | standing |
| `walk` | every enemy | the hitbox is moving; tempo follows speed |
| `stagger` | every enemy | `EnemyStaggered`, stretched over its duration |
| `death` | every enemy | `EnemyHealthChanged` with `alive` false; holds the last frame |
| `hurt` | every enemy, `R15Player` | Enemy: a flinch (`EnemyStaggered` kind `flinch`), or health dropping while nothing else plays. Player: a hit that lands, cancelling a swing. Upper body only |
| `attack_<attackId>` | the enemy that owns the attack | `EnemyTelegraphStart`, strike timed to `impactTime` |
| `swing_<weaponId>_<step>` | `R15Player` | the player's combo swing `step` with that weapon; full body, with footwork |
| `critical_<weaponId>` | `R15Player` | that weapon's heavy attack; full body |
| `stance_<weaponId>` | `R15Player` | looping base while that weapon is carried; upper body, over Roblox's walk and run |
| `guard_<weaponId>` | `R15Player` | the block key goes down: a snap into that weapon's guard, held until release; upper body |
| `dodge` | `R15Player` | the dash |
| `guard_break` | `R15Player` | posture filled and the guard broke |

**Player overlay rule.** Stances and guards never pose `LowerTorso` or the
legs, so Roblox's own walk keeps playing underneath (a test enforces it).
Strikes, criticals and dodges may: they're short, and slow walking right down
while they play.

**Player joints.** Player avatars now spawn with `AnimationConstraint` joints
(Roblox's Avatar Joint Upgrade) rather than `Motor6D`; enemy rigs are still
built with `Motor6D`. `RigAnimation` finds and drives both kinds. Anything new
that looks for a character's joints must accept both, or it will silently find
none on a player.

**Impact keyframe.** Attack and swing animations carry an `impact` time and a
keyframe exactly there, which the workbench names `Impact`. Playback stretches
everything before it over the real windup, so the strike lands when the server
resolves the hit. A refined, published version must keep a keyframe named
`Impact`, or it plays at its own speed.

**Refining.** `lune run animation-workbench` → drag
`workbench/AnimationWorkbench.rbxm` into Studio → load an animation from a
rig's `AnimSaves` in the Animation Editor → refine → publish → add the ID to
`AnimationIds.PUBLISHED`. That animation then plays through the Animator
everywhere, with no code change; the rough version stays as the fallback.

**Hit-stop.** `RigAnimation.hitStop` freezes a rig's pose for a few frames
when a blow lands. It never holds a strike before its impact, so a visible
enemy hit can't drift off the server's impact time.

## Naming registry — Sounds

Every name is a `SoundDefs.SOUNDS` key, played through `SoundFX`. Swap an
asset id there and it changes everywhere.

| Name | Plays when |
|---|---|
| `swing_<weaponId>` | Any player's swing comes through, every combo step (positional) |
| `block` / `guard_break` | Your guard takes a hit / breaks |
| `dodge` / `feint` / `critical_windup` | Any player's dash / feint / heavy attack starting (positional) |
| `hit` / `hit_riposte` | Your blow lands |
| `parry` + `parry_crack` | You land a parry (layered) |
| `enemy_windup` | An enemy starts a telegraph — an audio cue for the parry beat |
| `enemy_slam` | An all-around attack reaches impact without being interrupted |
| `enemy_death` | An enemy dies |
| `player_hurt` | You take a hit (not a bleed tick) |
| `equip` / `upgrade` / `refused` | Weapon change, blacksmith success, any refusal |
| `chest_open` / `coins` / `heal` | Loot, coins gained, a burst heal reaches you |
| `ambush` | A `danger` dungeon notice (an ambush springs, a new wave, the boss awakens) |
| `room_cleared` | A `good` dungeon notice (a room cleared, the shrine used) |
| `boss_awakens` / `dungeon_cleared` | The boss fight starts / the boss dies |

## Naming registry — Parry verdicts

Produced by `ParryMath`. Only `parried` is ever sent (over `ParryResult`);
a press that catches nothing sends nothing, and simply blocks. The timestamp
verdicts are why a press or dodge is silently ignored.

| Verdict | Meaning |
|---|---|
| `parried` | A hit landed inside the press's parry frames |
| `early` / `late` | `ParryMath.evaluate` only: outside the window on that side |
| `unparryable` | `ParryMath.evaluate` only: attack cannot be parried |
| `rejected_future` | Claimed a later press than a message arriving now could have been sent |
| `rejected_stale` | Claimed an earlier press than the player's connection accounts for |

## Naming registry — Attack results

`AttackResult.reason` values.

| Reason | Meaning |
|---|---|
| `hit` | Landed |
| `missed` | Nothing inside the swing volume |
| `cooldown` | Still swinging, recovering, or the critical isn't ready |
| `stunned` | Hitstun or a broken guard |
| `guarding` | Holding block; release it to attack |
| `blocked` / `dodged` | Duels: the opponent blocked or dodged it |
| `unequipped` | No weapon picked up yet |
| `no_target` | No character to swing from |

## Naming registry — Loot

| Item id | Dropped by | Rarity |
|---|---|---|
| `PracticeToken` | `TrainingDummy` chest | common |
| `BoneHiltShard` | `SkeletonWarrior` chest | uncommon |
| `RottedClaw` | `Shambler` chest | common |
| `AcidGland` | `Spitter` chest | common |
| `HollowCrownShard` | `HollowKing`: given to every player in the dungeon when it dies | epic |
| `GildedRelic` | an unguarded Treasure room's chest (`DungeonDefs.TREASURE_LOOT`) | rare |
| *(add new rows here as they're built)* | | |

A chest is locked until every enemy in its room is dead (`ChestService`), and
holds the loot of the room's first enemy: an Elite room's elite, a Treasure
room's guard. Plain Combat rooms have no chest. `encounterGroupId` is
retired: "every enemy in the room" is the group.

## Dungeon structure

Generated by `DungeonLayout` from `DungeonDefs`, built by `DungeonGenerator`,
run by `DungeonService`.

| Purpose | Size | What's in it |
|---|---|---|
| `Start` | Medium | The stations. Built once, never rebuilt; one door, north |
| `Combat` | Small/Medium/Large | 1–3 enemies by size; counts toward rooms cleared |
| `Elite` | Large | An elite plus two from the late pool; chest (+40 coins); one per dungeon, back half of the main path |
| `Ambush` | Large | Gates seal once you're inside; waves of 2 then 3 enemies (`AmbushService`); chest (+50 coins) when the last falls; resets if everyone inside dies. One per dungeon, on the main path, never first |
| `Treasure` | Small | Chest (+60 coins), 50% guarded; always a dead-end branch |
| `Shrine` | Small | Healing fountain (`ShrineService`); always right before the boss |
| `Boss` | Huge | The `HollowKing`; one door, from the shrine |

**Layout rules** (all enforced by `DungeonLayout.spec`): the Start is at the
origin with one door north, and every other room is north of it, which keeps
the south free for the duel arena. Rooms and corridors never overlap. Every
room is reachable. The only way into the boss room is through the shrine.

**Dungeon enemies never respawn** (`CombatServer.spawnEnemy` with
`respawns = false`). `CombatServer.despawnEnemy` removes them when the dungeon
is torn down.

## Naming registry — Currencies

| Id | Meaning |
|---|---|
| `coins` | Common currency, paid by every kill (`EnemyDefs.coinReward`) |
| `crystals` | Keyed by **class** — `crystals.Tank`, `crystals.Assassin`, `crystals.Healer`. You earn the class you had equipped when the kill landed, so crystals don't carry across a respec. Only tougher enemies pay them (`EnemyDefs.crystalReward`) |

There is no separate crystal-type namespace: a crystal type *is* a Classes
entry. Adding a class adds its crystal type for free — don't invent a parallel
`TankCrystal`-style id.

## Data schemas

```lua
-- Stored DataStore value, one per player. Store "PlayerData_v1"
-- ("PlayerData_v1_Studio" from Studio), key "player_<UserId>".
{
  data: PlayerData,
  session: SessionLock?,   -- absent when no server holds the profile
}

-- SessionLock (PlayerDataSchema.SessionLock)
{
  jobId: string,           -- game.JobId of the owning server
  heartbeat: number,       -- os.time() of its last save; stale after 180 s
}

-- PlayerData (PlayerDataSchema.PlayerData)
{
  version: number,         -- schema version; a newer one than the server
                           -- knows stops the load rather than being replaced
  coins: number,
  crystals: { [classTag]: number },
  equipped: { weapon: weaponId? },  -- a table so armour slots can join later
  upgradeLevels: { [weaponId]: number },
  inventory: { ItemInstance },      -- a list, not keyed by itemId: a player can
                                    -- hold several copies of one item, each
                                    -- with its own upgradeLevel. Capped at
                                    -- PlayerDataSchema.MAX_INVENTORY
}
-- Unknown class, weapon and item ids are preserved, never dropped: they may
-- belong to newer content, and a rollback must not delete that progress.

-- ItemInstance (InventoryService.ItemInstance)
{
  itemId: string,
  rarity: string,        -- "common" | "uncommon" | "rare" | "epic" ...
  upgradeLevel: number,
  classTag: string?,     -- a Classes entry, or nil for a class-neutral
                         -- material or memento (see LootTables)
}

-- EnemyDef (EnemyDefs.EnemyDef)
{
  displayName: string,
  maxHealth: number,
  attackInterval: number,
  preferredRange: number,  -- distance it tries to hold; drives approach/retreat
  moveSpeed: number,       -- 0 = stationary
  aggroRange: number,
  coinReward: number,      -- paid to whoever lands the killing blow
  crystalReward: number,   -- 0 for trash mobs; gates the higher upgrade tiers
  attacks: {
    [attackId]: {
      telegraphDuration: number,
      parryable: boolean,  -- false = must-dodge; no timing blocks it
      damage: number,
      range: number,       -- hit volume, and how close a player must be to parry it
      arcDegrees: number,
      minRange: number,    -- band in which the attack is a legal choice
      maxRange: number,
      weight: number,
      cooldown: number,
      dot: { tickDamage: number, tickInterval: number, ticks: number }?,
                           -- bleed applied on an unparried hit
    },
  },
}
```
