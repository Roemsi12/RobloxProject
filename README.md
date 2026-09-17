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
grand: 22-stud walls, buttressed bays, stone sentinels and inlaid floors. Every
colour comes from [`src/shared/Palette.luau`](src/shared/Palette.luau). Nothing
has had a numeric tuning pass yet. See [`DESIGN.md`](DESIGN.md).

The start area is a camp: weapon stands, a blacksmith's forge, the duel stand,
and a gate into the dungeon. You carry **one** weapon — taking one from a stand
leaves the last one behind, and only in camp. The dungeon is entered through the
gate's ready-check queue: a ten-second countdown anyone else in camp can join,
which a solo player still passes through alone. The dungeon itself is generated
in this same server, north of the camp.

## Controls

| Input | Action |
|---|---|
| **Left click** / R2 | Attack; keep clicking for a 4-hit combo |
| **R** / R1 | Critical: a heavy attack on a cooldown |
| **Right click** / X | Feint: cancel a swing early in its windup |
| **F** / L1 | Press just before a hit lands to parry; hold to block |
| **Q** / B | Dodge: a quick dash you can't be hit during |
| **F2** | Combat debug readout — **Studio only** |
| **Left Shift** | Toggle camera lock |
| **I** | Inventory |
| **E** at a stand, anvil, gate or chest | Take a weapon, upgrade it, queue for the dungeon, open a chest |
| **1 / 2 / 3** | Swap weapon instantly — **Studio only**, for tuning |

You start unequipped in the start room: pick a weapon from one of the three stands
first. The blue stand queues you for a duel.

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

## Animations

Every enemy (idle, walk, each attack, stagger, death) and every player combat move
(a swing per weapon, the parry) is animated from keyframe data in
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

## Dungeons

Every server generates a random dungeon north of the start room. Each has a winding
main path through fights, one elite hall and one ambush, then a shrine that
heals you to full, then the throne room of **The Hollow King**. Treasure vaults branch
off to the sides. Rooms stay cleared. Kill the boss and everyone in the dungeon is
paid; 15 seconds later you're back in the start room and a new dungeon has formed.

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
