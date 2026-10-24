# Boid at the Gates

A Project Zomboid (Build 42, single player) mod that fills the world with living NPCs for a
three-sided war: **civilians**, **Germans** and **Soviets**. Soldiers capture and hold ground,
civilians try to survive, resist and help the Soviets. The mod code currently lives in the
`LivingFront` folder (its working name in game).

Pure Lua. No Java, no ZombieBuddy.

## Status

| Area | State |
|------|-------|
| NPC records that persist across save/load and distance | Working |
| Consistent identity and look (sex by faction, light skin, hair, outfits) | Working |
| Visible human NPC bodies near the player | Working |
| Rifle combat: aim, track a moving target, fire, flinch, wounds, death, corpses | Working |
| Brain v1: soldiers find and engage visible enemies, retreat when badly hurt | Working |
| Civilians flee gunfire; armed civilians fight Germans | Working |
| Cover: soldiers crouch behind low cover, wounded hide behind walls; cover reduces hit chance | Built, awaiting in-game test |
| Running and sprinting (real run animations, endurance limits) | Built, awaiting in-game test |
| Squads: fixed units (sergeant, two fire teams of 4 - Alpha and Bravo - and the squad medic: 10 men) saved with the world, spawned in formation (squads were 17 men before 0.49) | Working (stress-tested: ~60-80 bodies is the practical budget) |
| Squad-aware soldiers: formation slots and leash, shared contacts, spread fire, enemy-leader spotting, succession (incl. badly wounded leaders) | Working |
| Suppression, area fire, sergeant intent (advance / hold / fall back), corporal bounding drills, shouted orders | Working |
| Squad maneuver: flanking on fire superiority (alpha teams go round, bravo teams pin; one side at a time); opening "bearings" seconds; self-aid; safer hiding spots; corporal repositions | Working |
| Period weapons: Kar98k / Mosin (privates, corporals), MP40 / PPSh (sergeants), P38 / TT-33 pistols (lieutenants); bursts, bolt cycling, magazines and reloads (ammo infinite for now) | Working |
| Stances: offensive (everything above) and defensive - an all-round defence (a pair to each quarter), men stay in cover, wounded go down in place, no maneuver orders, fight to the death | Working (0.16.0) |
| Defence re-forms around a known threat (front, two flanks, rear security; cover faces the enemy); sergeant takes his own cover; corporals cut off from their sergeant run their own teams; repositions work outward and round instead of back and forth | Built, awaiting in-game test |
| Defensive stance inside buildings: teams take walls (compass, then front/flanks/rear by threat), doors covered from inside, men stand in the windows to fire, back line, blank walls one man; posts dealt once | Working (0.17) |
| Furniture in windows (fire from a tile back, shove it aside); windows smashed out with the rifle butt | Working (0.18) |
| Clearing a building (a team stacks on the door, breaches, goes in one at a time) | Built, awaiting in-game test (fixed in 0.19) |
| Building defence: men at windows never leave them; spares fill windows toward the enemy | Built, awaiting in-game test |
| Sergeants choose their stance (dig in when outnumbered / shot up / by a building with the enemy coming / stalled; move up with the numbers or when it's gone quiet) | Working (0.19) |
| Troop movements: a squad marches by road in a tactical column (staggered files, sergeant in the centre), halts on contact, forms up again after | Working (0.20) |
| Patrolling stance: ranger file, tactical column, wedge; men fall in as the point man passes; halted, everyone crouches and aims outboard; ADS pace and scanning | Working (0.21) |
| Sergeant chooses the formation from the ground (most men in woods -> file, road -> column, off the road -> wedge); long patrols planned in legs | Built, awaiting in-game test |
| Objectives: take (patrol in, rally, base of fire + flank, clear, consolidate) and hold; who holds it | Built, awaiting in-game test |
| Machine-gun squads: two gun teams and the medic (MG34 / DP-27; gunner, assistant, two security); real rates of fire in ~4 s bursts, beaten zone, heavy suppression; belts, barrel changes (MG34) and cooling (DP-27); the guns take turns; crews replaced as men fall; guns leapfrog, take the front in a defence and the best windows in a building, cover a clearing from outside, support a nearby friendly squad; the enemy targets the crews, grenades and flanks the guns | Built, awaiting in-game test (0.43) |
| Platoons: lieutenant (pistol, greatcoat and peaked cap), platoon sergeant, radio operator (the only radio in the platoon) and two squads. The lieutenant gives each squad its task and watches from cover behind the main effort: take (main effort assaults, the other squad - the MG squad if there is one - supports by fire from a flank; a failed assault is taken over or the platoon withdraws), hold (the main effort holds the objective, the other squad the nearest building), withdraw (break contact by bounds, march to the rally point, dig in). Orders by voice; out of earshot the platoon sergeant runs them over, then goes back to the main effort. Succession: the platoon sergeant takes over | Built, awaiting in-game test (0.49) |
| Platoon patrol: the squads abreast with their sergeants leading at the front, the headquarters in the centre rear | Built, awaiting in-game test (0.50) |
| Standing by (and quiet spells in a held building, for men off the windows and doors): men sit on chairs, couches and benches near their place | Built, awaiting in-game test (0.50) |
| Morale: per soldier; down with losses, the lieutenant's death, a squad breaking, a withdrawal, being pinned; up with the officers close by and with tasks the lieutenant gave carried out. Moves the pinned level, suppression taken and when a squad falls back | Built, awaiting in-game test (0.49) |
| Ammo supply | Later |
| Ammo, period weapons | Later |
| Strategic war layer (sectors, front line, off-screen battles) | Planned, after the map is decided |

The player is currently neutral: NPCs ignore you.

## Install

Build the release copy and install that:

    python3 tools/build.py        # writes dist/LivingFront

Copy `dist/LivingFront` into `C:\Users\<you>\Zomboid\mods\` and enable **Living Front** in the
game's Mods menu. Use a throwaway save, ideally with zombies turned off in sandbox settings.
(The `LivingFront` source folder also runs as-is; the build only strips comments and indentation
to make the download about a third smaller. Line numbers are kept, so errors in `console.txt`
point at the same line of the source.)

Testing tools are in the right-click menu under **Living Front (debug)**. Every decision, shot
and death is logged to `Zomboid\console.txt` with the `[LivingFront]` tag.

## Code layout (for contributors)

`LivingFront/42/media/lua/client/LivingFront/`, in folders that follow the order things are
built on each other: a file only depends on files in its own folder or the ones above it.

| Folder | File | Role |
|--------|------|------|
| **Core** - settings and saved data | `LF_Core` | Config, factions, hostility, shared helpers, logging |
| | `LF_Records` | NPC records in global ModData (the single source of truth) |
| | `LF_Names` | German and Russian names |
| | `LF_Perf` | Stress-test logging: frame rate and the mod's own cost |
| **World** - bodies and what they can see | `LF_Bodies` | Spawns bodies near the player, despawns far ones, draws them, deaths |
| | `LF_Appearance` | A consistent person (sex, skin, hair, clothing) from a record |
| | `LF_Sense` | Perception: grid of live bodies, capped line-of-sight checks |
| | `LF_Building` | Building layouts: inside squares, windows and doors by wall |
| | `LF_Cover` | Cover quality, firing positions, hiding spots, cover against incoming fire |
| | `LF_Watch` | Keeps the real player visible |
| | `LF_Sim` | Off-screen simulation |
| **Soldier** - one man | `LF_Posture` | Crouch / stand, immune to the player's crouch key |
| | `LF_MoveAction` | Walk / run / sprint / limp; stepping round other men |
| | `LF_ShootAction` | Aim + fire, flinch and hold-aim actions |
| | `LF_Weapons` | Weapon profiles, magazines, reloading |
| | `LF_Combat` | Gunfire: aiming, hit resolution, damage, knock-downs, melee |
| | `LF_Suppress` | Near misses pin soldiers |
| | `LF_Aid` | Self-aid: bandaging |
| | `LF_Idle` | What a man does standing by (and the wounded nursing their wounds) |
| | `LF_Brain` | Perceive / decide / act loop per NPC |
| | `LF_Service` | Service records and earned traits |
| | `LF_Morale` | Morale: what lowers and raises it, and what it does |
| **Units** - squads and teams | `LF_Units` | Squads and fire teams: structure, ranks, spawning |
| | `LF_Squad` | Shared contacts, formation slots |
| | `LF_Stance` | Offensive / defensive / patrolling settings |
| | `LF_Join` | Idle teams joining a unit given a task |
| | `LF_March` | Patrolling: routes, formations, halts |
| | `LF_Objective` | Take / hold objectives |
| **Tactics** - what a unit does in a fight | `LF_Tactics` | Shared core: settings, shouts, placement, commander intent |
| | `LF_Manoeuvre` | Bounding drills, repositioning, flanking, a corporal on his own |
| | `LF_Defence` | All-round defence, holding a building |
| | `LF_Clearing` | Clearing a building room by room; a man knocked down inside dragged out |
| | `LF_Command` | Stance choice, standing by, the squad update loop |
| | `LF_Platoon` | Platoons: headquarters, the lieutenant's missions and orders, the runner, succession |
| **Specialists** - special roles | `LF_Grenade` | Grenades |
| | `LF_Downed` | Men down on their back, getting up, being dragged |
| | `LF_Medic` | The squad medic and critical wounds |
| | `LF_MG` | Machine-gun squads: gun teams, bursts at the real rate of fire, belts and barrels, the guns taking turns, leapfrogging |
| **UI** | `LF_Inspect` | The inspect window |
| | `LF_Debug` | Right-click debug menu (tests) |

Conventions:

* Each file starts with a header comment saying what it does, then its `require`s, then a
  `CFG` table of its settings. Files talk to each other through the `LF.<Module>` tables;
  nothing else is global except the timed-action classes (`LF_*Action`).
* Require paths include the folder: `require "LivingFront/World/LF_Cover"`.
* The tactics files share their internals through `LF.Tactics.I`: each one borrows names at its
  top and lends its own at the bottom. Load order is core -> manoeuvre -> defence -> clearing
  -> command; `require "LivingFront/Tactics/LF_Command"` loads them all.
* Tables shared this way are reset in place (never replaced), so every file keeps seeing the
  same table.
* Animations: `LivingFront/42/media/AnimSets/player/{actions,idle,movement}/`. Each node is
  switched on by an `LF...` animation variable that the Lua sets. A new or changed XML needs
  the game restarted, not just a reload.

## Engine findings (Build 42.21)

Hard-won facts from reading the game's code and testing. Each one shapes the design.

1. **NPC bodies are plain `IsoPlayer` objects created from Lua** (`IsoPlayer.new` + `setNpc(true)`).
   Their needs (hunger, thirst, fatigue, boredom) tick natively, and they pathfind with
   `ISWalkToTimedAction`.
2. **The engine never draws them.** `FBORenderCell.renderMovingObject` skips any object whose
   exact class is `IsoPlayer`, and `renderPlayers` only draws the local player slots. We draw
   our bodies ourselves from the `RenderOpaqueObjectsInWorld` Lua event, the same way the
   engine's `renderPlayer` does (shadow, then `render`).
3. **Map squares only save dead bodies**, so live NPC bodies are never saved. Records are the
   truth; bodies are rebuilt from them.
4. **Outfits:** `IsoPlayer:dressInNamedOutfit` only builds a preview for non-local players. We
   turn the preview into worn items ourselves (`HumanVisual:dressInNamedOutfit` into an
   `ItemVisuals`, then `WornItems:setFromItemVisuals` and `addItemsToItemContainer`).
5. **Sex** is fixed when a descriptor is created; after `setFemale` call
   `SurvivorFactory.setTorso(desc)` (as the character creator does).
6. **The engine's aim/fire pipeline is unusable for NPCs:** for an NPC, `isAiming()` returns a
   hidden AI component value Lua cannot reach. Firing is therefore a timed action that plays
   the game's rifle clips and resolves the shot itself.
7. **`Hit()` does nothing to an `IsoPlayer` NPC.** Damage is `BodyPart:damageFromFirearm` (a
   bleeding wound) plus `BodyDamage:ReduceGeneralHealth` by hit location.
8. **The engine's hit-reaction state never shows for NPCs** (and can freeze them). Flinches
   are played as a short action instead.
9. **The rifle aim clip holds the rifle 45° left of the body** (bladed stance). Vanilla hides
   this with player-input torso twist, which NPCs lack, so twist is disabled and the body turns
   45° right of the target.
10. **Turning:** before aiming, the body turns with the normal turning animation
    (`faceLocation`) until `getAnimAngle()` catches up. While aiming, setting the direction
    directly (`setForwardDirection` + `setTargetAndCurrentDirection`) does rotate the drawn
    body, so the aim sweeps to follow a moving target.
11. **Line of sight** uses `LosUtil.lineClear`; `Blocked` and closed doors stop sight.
12. **Running:** an NPC's running flag is cleared and then overwritten from the hidden AI
    component every frame (`IsoPlayer.updateInternal2` → `AIComponent.postUpdatePlayer`), so
    setting it from `OnTick` or `OnPlayerUpdate` never sticks. The character's timed action is
    updated later in the same frame, and the animation state machine after that, so
    `setRunning(true)` from a timed action's `update()` reaches the animation. Movement speed
    comes from the animation's own root motion, so this is a real run, not a speed change.
    The engine still refuses to run when the endurance moodle is 3 or higher.
13. **Crouching:** `setSneaking` is only changed by the crouch key handler, so it sticks on
    NPCs (but see 15). There is no crouched rifle-aim clip; crouched NPCs stand to fire and drop back down.
14. **Cover** is read from square edges toward the threat (`isWallTo`, `isWindowTo`,
    `isHoppableTo`, `isSolidTrans`, vehicles, trees).
15. **NPC bodies share the player's input slot** (player index 0), so the engine's crouch-key
    handler reads the real keyboard for them. Posture is enforced from `OnPlayerUpdate`, which
    fires for each NPC just before that check.
16. **Performance:** each live NPC body costs the engine about 0.23 ms per frame regardless of
    our code; around 60-80 bodies near the player is the practical budget.
