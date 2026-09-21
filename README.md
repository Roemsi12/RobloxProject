# Roblox Dungeon Crawler

A Roblox dungeon crawler built around parry-based, server-authoritative combat.
Your equipped weapon *is* your class — pick a weapon, run a procedurally generated
dungeon, clear the enemy guarding each chest, and spend coins and crystals at the
blacksmith to upgrade what you carry. A 1v1 duel arena runs on the same combat rules.

**Status:** all ten build-order steps are code-complete, including saved progress.
Dungeons are randomised runs ending in a boss fight.
Enemies are Part-built R15 rigs, animated from keyframe data in this repo.
A game-feel pass added weapons in hand, hit-stop, screen shake, sound, torch-lit
rooms and dusk lighting, all from built-in or public-domain assets. An art pass
then took the whole game to one **grim dark fantasy** look — cold stone, rusted
iron, old bone and firelight — across weapons, enemy rigs and dungeon geometry,
and gave the animations overlap, ankles and anticipation. Rooms were then rebuilt
grand, and then rebuilt again at half again the size, with ceilings over every one
of them, pillars floor to ceiling, and a hub that is a cathedral of a room. Every
colour comes from [`src/shared/Palette.luau`](src/shared/Palette.luau); every
piece of masonry from [`src/server/Stonework.luau`](src/server/Stonework.luau).
Nothing has had a numeric tuning pass yet. See [`DESIGN.md`](DESIGN.md).

The start area is a **hub**: one huge vaulted hall, 150 by 190 studs, with two
rows of pillars running floor to ceiling and an arcade of arches between them.
Down the west aisle stand three **class altars** — Tank, Assassin, Healer — and
taking up a class is how you choose one. The blacksmith's forge and the duel
stand are in the east aisle. Three **gates** stand in the north wall, each with
its own ready-check queue into the dungeon.

You carry **one** weapon — taking up a class leaves the last one behind, and
only in the hub. Queueing at a gate starts a ten-second countdown anyone else
can join at that gate, which a solo player still passes through alone; when it
fires you are pulled through into the dungeon's entry hall. The dungeon itself
is generated in this same server, well north of the hub.

## Controls

| Input | Action |
|---|---|
| **Left click** / R2 | Attack; keep clicking for a 4-hit combo |
| **R** / R1 | Critical: a heavy attack on a cooldown |
| **Right click** / X | Feint: cancel a swing early in its windup |
| **F** / L1 | Press just before a hit lands to parry; hold to block |
| **Q** / B | Dodge: a roll the way you're moving, that you can't be hit during |
| **Z** / **X** / **C** | The abilities you unlocked in the skill tree |
| **F2** | Combat debug readout — **Studio only** |
| **Left Shift** | Toggle camera lock (on by default) |
| **I** | Inventory |
| **K** | Skills: your weapon's tree, and the points to spend in it |
| **E** at an altar, anvil, gate, chest or mirror | Take up a class, upgrade your weapon, queue for the dungeon, open a chest, change how you look |
| **1 / 2 / 3** | Swap weapon instantly — **Studio only**, for tuning |

You start unequipped on the dais at the south end of the hub: walk up the hall
and take up a class at one of the three altars first. You carry one weapon at a
time, and can only change it here. The anvil upgrades what you carry, the blue
stand queues you for a duel, and any of the three gates queues you for the
dungeon.

## Documentation

- [`DESIGN.md`](DESIGN.md) — locked-in design decisions and the reasoning behind them
- [`ARCHITECTURE.md`](ARCHITECTURE.md) — project layout, plus the naming registries for
  remotes, classes, enemies, loot and data schemas

Both are meant to be read before writing code, so decisions don't get silently redone.

## Getting started

Toolchain versions are pinned in [`rokit.toml`](rokit.toml)
([Rokit](https://github.com/rojo-rbx/rokit) is the toolchain manager), and test
dependencies in [`wally.toml`](wally.toml):

```sh
rokit install
wally install
```

Then start a [Rojo](https://rojo.space) server and connect to it from the Rojo plugin in
Roblox Studio:

```sh
rojo serve
```

### Saving in Studio

Progress saves to a DataStore. Studio uses a separate store from live servers, so
playtests never touch real players' progress. Studio can only reach DataStores once
the place is published and **Game Settings → Security → Enable Studio Access to API
Services** is on. Without that, Studio runs an unsaved session and says so on screen.

### Linting

Lint the source with [selene](https://github.com/Kampfkarren/selene):

```sh
selene src/ tests/ lune/
```

## Tests

The combat and economy math lives in pure Luau modules with no Roblox API, and is
covered by [Jest Lua](https://github.com/jsdotlua/jest-lua) specs in
`src/shared/__tests__/`.

Run them from the terminal, no Studio needed:

```sh
lune run test              # every spec
lune run test ParryMath    # only matching spec files
```

This runs the same spec files under [Lune](https://github.com/lune-org/lune), with the
pure modules sandboxed so any Roblox API call from them fails the run. It exits
non-zero on failure.

To run them under real Jest instead, serve the separate test place (so no test code
ships in the game), connect from Studio and press Play:

```sh
rojo serve test.project.json
```

## Your character

Everyone wears the same body. A player's own Roblox avatar is replaced on spawn
with the default blocky R15 build — no bundle, no clothing, no accessories, at
fixed proportions — and what they choose is what goes *on* it: build, skin,
face, hair and its colour, markings, garb, and the garb, legwear and trim
colours. Ten rows,
every one of them a list in
[`src/shared/AppearanceDefs.luau`](src/shared/AppearanceDefs.luau).

Change it at the **looking glass** in the hub's east aisle, opposite the class
altars. Changes save as they are made.

This is not only a look. Every stance, guard and attack tell in the game is
authored against R15's proportions, and a catalogue bundle that puts the
shoulders somewhere else makes a parry tell harder to read through no fault of
the player trying to read it.

> **One manual step.** The rig type is a *universe* setting, not something the
> place file can carry, so Rojo cannot set it. In Studio: **File → Game
> Settings → Avatar → Rig Type → R15**. Without it, players spawn as R6, and
> `PlayerAnimation` skips R6 avatars entirely — no stances, no swings, no
> rolls.

> **Avatar textures have to be uploaded once.** Clothes, faces and markings
> are our own PNGs in `art/avatar/textures`, and a game can only use images
> that are on Roblox. Make an Open Cloud API key (create.roblox.com → Open
> Cloud → API Keys, Assets API read + write), put it in `ROBLOX_API_KEY`, and
> run `lune run upload-avatar --user-id <id>` (or `--group-id` if a
> group owns the game). It writes the ids into
> `src/shared/AvatarTextures.luau`. Until then players spawn with hair but
> no clothes or face, and the server warns which textures are missing.
> To change the art, edit `art/avatar/generate.py`, run it, check
> `art/avatar/preview.png` (from `preview.py`), then re-upload with `--force`.

Adding a hairstyle is a row in `AppearanceDefs.HAIR`. The editor is generated
from `AppearanceDefs.CATEGORIES` and has no hardcoded choice in it, so nothing
else has to change — and a test checks every category names a field the saved
look actually has.

## Classes

A class *is* the weapon you carry ([`WeaponDefs`](src/shared/WeaponDefs.luau)),
so there are seven of each:

| Class | Weapon | Plays like |
|---|---|---|
| Tank | Sword & Shield | Wide parry frames; a parry buys the whole group a long punish window |
| Assassin | Daggers | The tightest frames and the biggest riposte |
| Healer | Staff | A parry heals you and everyone near you |
| Berserker | Greataxe | The slowest, heaviest swings in the game, and a short sharp riposte |
| Duelist | Rapier | The widest frames and the lowest melee damage to pay for them |
| Ranger | Longbow | Shoots at 52 studs; the worst parry frames, on purpose |
| Mage | Arcane Focus | The weakest combo, the widest critical, and a tree that buys ability power |

Each has a full four-hit combo, a critical, a guard, a walking stance, a
planted idle, a three-branch skill tree, and three abilities at the ends of
those branches. Take one up at its altar in the hub's west aisle.

## Animations

Every enemy (idle, walk, each attack, stagger, death) and every player combat move
(a swing per weapon, the parry, the planted idle, the four dodge rolls) is animated from keyframe data in
[`src/shared/AnimationDefs.luau`](src/shared/AnimationDefs.luau). The game plays them
as-is; nothing needs uploading.

Most of the motion comes from a handful of shared helpers — `idle`, `walk`,
`strike`, `stanceLoop` — so a change to one improves every rig and every weapon at
once. They carry the timing principles the animations rely on: overlap (arms and
head arrive late), weight shift, heel-strike and toe-off at the ankles, and a beat
of anticipation before every windup. To refine an individual one in Roblox's
Animation Editor:

1. Build the workbench — every rig, with every animation loaded on it:
   ```sh
   lune run animation-workbench
   ```
2. Drag `workbench/AnimationWorkbench.rbxm` into a Studio place.
3. Select a rig, open the Animation Editor, and load an animation from its saves.
4. Refine it. For attacks and swings, keep the keyframe named **Impact** on the
   moment the hit lands — the game times the strike to the server with it.
5. Publish, and paste the ID into
   [`src/shared/AnimationIds.luau`](src/shared/AnimationIds.luau) under the rig and
   animation name. The game uses your version from then on.

The workbench script checks its output before reporting success, including solving
every animation against the floor. Regenerating replaces the file, so publish (or keep
your own copy of) anything in progress first.

## Levels and skills

Every kill pays XP to everyone carrying a weapon, not just whoever landed the
blow. Each level is a skill point, up to level 20.

Points are spent in the tree of the weapon you are holding (**K**). Each
weapon has its own tree of three branches, and its own points — picking up the
daggers at level 15 gives you a full 14 points to spend in *their* tree
without touching the sword's. No tree can be filled: 26 ranks, 19 points at
the cap, so what you leave out matters as much as what you take.

Each branch ends in an **ability**, and finishing a branch is the only way to
get one. The branch's position decides its key: leftmost is **Z**, then **X**,
then **C**. Nine in all — the Tank's Last Stand, Shield Break and Breach; the
Assassin's Shadowstep, Evasion and Flurry; the Healer's Mending Pulse,
Sanctified Ward and Arcane Nova. Swapping weapon swaps the tree, the abilities
and the keys together.

Unlocking all three of a weapon's abilities is possible at the level cap and
costs over half your points, so the real choice is three shallow abilities or
one you have actually invested in.

The abilities are data in
[`src/shared/AbilityDefs.luau`](src/shared/AbilityDefs.luau); the trees are in
[`src/shared/SkillTreeDefs.luau`](src/shared/SkillTreeDefs.luau) and the curve
is in
[`src/shared/ProgressionDefs.luau`](src/shared/ProgressionDefs.luau). Adding a
node is a row; adding a new *kind* of effect is a row plus wiring it at the one
place in combat that reads it. `lune run test SkillTreeDefs` checks that no
node is unreachable, that no tree can be completed, and that every node's
effects can be put into words for the panel.

## Chests

Opening a chest shows what is inside rather than pushing it into your bags.
Click a row to take it; anything you leave stays in the chest for whoever comes
next, and a full inventory no longer means a chest you daren't open. The chest
owns its contents, so two players searching the same one see the same rows go.

## Dungeons

Every server generates a random dungeon well north of the hub. A gate drops you in
its entry hall; from there a winding main path leads through fights, one elite hall
and one ambush, then a shrine that heals you to full, then the throne room of
**The Hollow King**. Treasure vaults branch off to the sides. Rooms stay cleared.
Kill the boss and everyone in the dungeon is paid; 15 seconds later you're back in
the hub and a new dungeon has formed.

The rules (room sizes, how many of each room, enemy pools, ambush waves, rewards) are
data in [`src/shared/DungeonDefs.luau`](src/shared/DungeonDefs.luau). The generator
is [`src/shared/DungeonLayout.luau`](src/shared/DungeonLayout.luau), and
`lune run test DungeonLayout` checks its rules across 300 generated dungeons.

## Sounds

Every sound is named in [`src/shared/SoundDefs.luau`](src/shared/SoundDefs.luau) with
its asset id, volume and pitch range. The current ones are placeholders: Roblox's own
public-domain classic sounds. To replace one, find a clip in Studio's **Toolbox → Audio**
(anything published by the Roblox account is free to use), copy its id, and paste it
over the old one as `rbxassetid://<id>`. The sound changes everywhere it plays.

## Lighting

The dusk sky, fog, bloom and colour grade are set in `default.project.json` under
`Lighting`, so Rojo applies them. If Studio still looks flat after connecting, check
**Lighting → Technology** is **Future**.

## Layout

`default.project.json` maps `src/` into Roblox services:

| Path | Roblox location |
|---|---|
| `src/shared` | `ReplicatedStorage.Shared` |
| `src/server` | `ServerScriptService.Server` |
| `src/client` | `StarterPlayer.StarterPlayerScripts.Client` |

The place file itself is not committed — it's generated by Rojo from this source.

## Credits

Steps 1–3 and the combat core were built on this repository. The dungeon, chests,
loot, inventory, economy, healer mechanics and duel arena (steps 4–9) were built by
[Maat8688](https://github.com/Maat8688) on
[his fork](https://github.com/Maat8688/RobloxProject) and merged in.
