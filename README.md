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
| Objectives are buildings: each keeps its ground-floor footprint and kind (house, church...) and is drawn on the world map and minimap, tinted by who holds it (contested when both sides are inside), named when zoomed in; hovering shows a street-name style label with its holder and the units taking or holding it | Built, awaiting in-game test (0.52) |
| Objectives are lettered and named in the spelling alphabet of the side holding them (Objective Ivan to the Soviets, Objective Ida to the Germans), names on the map at twice the size. Right-click a building on the world map to make it an objective (or remove one) and order any platoon or squad to take, hold, patrol or withdraw there - buildings anywhere on the map. Door closers shut doors only once the whole unit is inside | Built, awaiting in-game test (0.53) |
| Off-screen movement (step 1 of the off-screen war): a march goes on with nobody near - at the patrol pace in simulated time (game speed counts, pause stops it), round buildings from the map's outlines, each man kept at his place in the formation - and the men get their bodies back in formation when you come near. A platoon lieutenant waits for every squad and goes without stragglers only 20 s after he expected them in | Tested OK (0.54) |
| Off-screen war step 2: marches and platoon orders are saved with the game and resume after a reload; orders reach a squad wherever it is (a runner, or the lieutenant, walks there off-screen at a run); objective tasks run off-screen - a squad arriving at its rally point goes into the assault, walks into an empty objective and takes it (with the enemy there it waits: off-screen fighting is step 3), holding squads are put inside the building; the platoon headquarters keeps its places off-screen; hold spreads squads over nearby buildings from the map data | Tested OK (0.55) |
| Off-screen war step 3: hostile units with nobody near you fight off-screen once a simulated second - firepower from fit men (MG gunners count 5), cut by range, ammunition, suppression and morale, landing according to cover (held building, dug in, open, on the march); named men killed or wounded where they stand (wounds show on their bodies when they spawn), morale worn down under fire, units break and fall back below 35% fit or morale 25, objectives empty and change hands; a contact with men near you is fought for real and the far side is spawned in; every hit and break logged with its witnesses for phase 4; the simulated clock is saved; marching men scan every 6-15 s (the platoon HQ too) | Built, awaiting in-game test (0.56) |
| Unit trackers on the world map and minimap: a marker for every squad and platoon HQ where its men are (on- or off-screen), a line to where it is marching, and zoomed in its name, fit men and what it is doing (red outline fighting, amber broken); toggle in the debug tools. A platoon's file closes up at the destination - squads side by side, HQ centre rear - before the lieutenant deploys; off-screen men fall in and walk to their places instead of being put there (0.56 sent a file's rear 180 tiles back) | Built, awaiting in-game test (0.56.1) |
| Off-screen assaults finish: halted by contact near the objective a squad goes straight into the assault, works forward to its rally point and storms once it has the upper hand (3:1 in fit men nearby, enemy morale under 30, or 2:1 after two minutes) - stormed defenders lose most of their cover; only fit men hold a building, the wounded left inside are taken prisoner; a broken unit runs instead of halting to fight; a man wounded again is likely to die; a hold order on an enemy-held objective becomes a take | Built, awaiting in-game test (0.56.2) |
| Off-screen war step 4 (aftermath and reports): men killed off-screen leave corpses where they fell once you come near; every event (killed, wounded, captured, broke, contact, objective) is logged with who saw it, on- or off-screen, and each man remembers what he saw (saved with the game); the radio net - each platoon's radio operator reports contact, casualties, breaks and objectives at the top of the screen (listen to German, Soviet, both or off); right-click a soldier to talk to him - he answers from who he is and what he has seen. With the LF bridge (tools/lf_bridge) and Chasm, the words come from the language model and are voiced (placed by distance and direction, radio reports over the radio) | Built, awaiting in-game test (0.57) |
| Soldiers with personalities (text): every man has a life rolled from period tables for his side and kept in his record - age, hometown, pre-war trade, family, traits, how he talks (with example lines), view of the war, wants, fears, a secret - and a friend (sometimes a rival) in his squad. Right-click, Talk to: a chat window; he answers in character from who he is, his state, what he has seen and your earlier talks (each conversation is summed up in a note he keeps, with whether he thinks better or worse of you). The LF bridge now runs the language model itself (llama-server, the GGUF Chasm downloaded), text only, no Chasm | Built, awaiting in-game test (0.58) |
| Machine-gun squads: two gun teams and the medic (MG34 / DP-27; gunner, assistant, two security); real rates of fire in ~4 s bursts, beaten zone, heavy suppression; belts, barrel changes (MG34) and cooling (DP-27); the guns take turns; crews replaced as men fall; guns leapfrog, take the front in a defence and the best windows in a building, cover a clearing from outside, support a nearby friendly squad; the enemy targets the crews, grenades and flanks the guns | Built, awaiting in-game test (0.43) |
| Platoons: lieutenant (pistol, greatcoat and peaked cap), platoon sergeant, radio operator (the only radio in the platoon) and four squads (an MG platoon: three rifle squads and an MG squad). The lieutenant gives each squad its task and watches from cover behind the main effort: take (main effort assaults, the MG squad (or the second rifle squad) supports by fire from a flank, the rest wait in reserve behind; a failed assault is taken over by the reserve first, or the platoon withdraws), hold (the main effort holds the objective, each other squad one of the nearest buildings), withdraw (break contact by bounds, march to the rally point, dig in). Orders by voice; out of earshot the platoon sergeant runs them over, then goes back to the main effort. Succession: the platoon sergeant takes over | Built, awaiting in-game test (0.49) |
| Platoon movement: in a ranger file or tactical column the platoon is one file (lead squad, the other squads one behind another, each sergeant at his squad's head, the headquarters at the rear); in a wedge the squads go abreast, sergeants leading, the headquarters in the centre rear. Taking an objective from afar, the platoon moves up together to an assembly area ~40 tiles short of it, then deploys. Orders to squads whose men aren't spawned wait for them | Built, awaiting in-game test (0.51) |
| Standing by (and quiet spells in a held building, for men off the windows and doors): men sit on chairs, couches and benches near their place; sitting, a man lays his rifle on the ground beside him or slings it, and takes it back when he gets up | Built, awaiting in-game test (0.51) |
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
| | `LF_Clash` | Off-screen fighting: contact, firepower, cover, casualties, breaking, the event log |
| | `LF_Aftermath` | Corpses where men fell off-screen |
| | `LF_Chasm` | The file mailbox to the LF bridge (Chasm) |
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
| | `LF_Memory` | What each man remembers: the events he witnessed, in words |
| | `LF_Persona` | Who each man is: his life, his ties in the squad, his notes on you |
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
| | `LF_Radio` | The radio net: platoon reports from the event log |
| **Specialists** - special roles | `LF_Grenade` | Grenades |
| | `LF_Downed` | Men down on their back, getting up, being dragged |
| | `LF_Medic` | The squad medic and critical wounds |
| | `LF_MG` | Machine-gun squads: gun teams, bursts at the real rate of fire, belts and barrels, the guns taking turns, leapfrogging |
| **UI** | `LF_Inspect` | The inspect window |
| | `LF_Map` | Objectives drawn on the world map and minimap |
| | `LF_Talk` | Talking to a soldier (right-click) |
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
