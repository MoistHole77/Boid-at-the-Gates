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
| Squads: fixed units (sergeant + 4 fire teams of 4) saved with the world, spawned in formation | Working (stress-tested: ~60-80 bodies is the practical budget) |
| Squad-aware soldiers: formation slots and leash, shared contacts, spread fire, enemy-leader spotting, succession (incl. badly wounded leaders) | Working |
| Suppression, area fire, sergeant intent (advance / hold / fall back), corporal bounding drills, shouted orders | Working |
| Squad maneuver: flanking on fire superiority (alpha teams go round, bravo teams pin; one side at a time); opening "bearings" seconds; self-aid; safer hiding spots; corporal repositions | Working |
| Period weapons: Kar98k / Mosin (privates, corporals), MP40 / PPSh (sergeants); bursts, bolt cycling, magazines and reloads (ammo infinite for now) | Working |
| Stances: offensive (everything above) and defensive - an all-round defence (alpha teams north and west, bravo teams south and east, turned to face a known threat), men stay in cover, wounded go down in place, no maneuver orders, fight to the death | Built, awaiting in-game test |
| Defensive stance inside buildings (each team takes a wall's windows) | Next |
| Casualty care by others, ammo supply, MG teams, objectives, platoon level | Later |
| Ammo, period weapons | Later |
| Strategic war layer (sectors, front line, off-screen battles) | Planned, after the map is decided |

The player is currently neutral: NPCs ignore you.

## Install (development)

Copy the `LivingFront` folder into `C:\Users\<you>\Zomboid\mods\` and enable **Living Front**
in the game's Mods menu. Use a throwaway save, ideally with zombies turned off in sandbox settings.

Testing tools are in the right-click menu under **Living Front (debug)**, including
**Combat / brains → Skirmish**. Every decision, shot and death is logged to
`Zomboid\console.txt` with the `[LivingFront]` tag.

## Code layout

`LivingFront/42/media/lua/client/LivingFront/`

| File | Role |
|------|------|
| `LF_Core.lua` | Config, factions, hostility table, shared helpers |
| `LF_Records.lua` | NPC records in global ModData (the single source of truth) |
| `LF_Appearance.lua` | Builds a consistent person (sex, skin, hair, clothing) from a record |
| `LF_Bodies.lua` | Spawns bodies near the player, despawns far ones, draws them, detects deaths |
| `LF_Sim.lua` | Off-screen simulation (needs tick while an NPC has no body) |
| `LF_Combat.lua` | Gunfire: turning, aiming stance, hit resolution, damage, gunfire memory |
| `LF_ShootAction.lua` | Timed actions: aim + fire (with target tracking), flinch |
| `LF_MoveAction.lua` | Walk / run / sprint to a square (the timed action that makes running work) |
| `LF_Sense.lua` | Perception: grid of live bodies, capped line-of-sight checks |
| `LF_Squad.lua` | Squad knowledge (contacts, recognised enemy leaders) and formation slots |
| `LF_Posture.lua` | NPC crouch/stand, immune to the player's crouch key |
| `LF_Names.lua` | German and Russian names |
| `LF_Suppress.lua` | Suppression: near misses pin soldiers, slowing and spoiling their fire |
| `LF_Tactics.lua` | Unit tactics: commander intent, corporal bounding drills, shouted orders, the defensive perimeter |
| `LF_Stance.lua` | Unit stances (offensive / defensive) and their settings |
| `LF_Aid.lua` | Self-aid: wounded soldiers bandage their bleeding wounds |
| `LF_Weapons.lua` | Weapon profiles (who carries what, fire rate, bursts, accuracy, damage), magazines, reloading |
| `LF_Units.lua` | Squads and fire teams: structure, ranks, formation spawning, unit report |
| `LF_Perf.lua` | Stress-test logging: frame rate and the mod's own cost per frame |
| `LF_Cover.lua` | Cover quality per square, firing positions, hiding spots, cover effect on incoming fire |
| `LF_Brain.lua` | Perceive / decide / act loop per NPC |
| `LF_Debug.lua` | Right-click debug menu |

`LivingFront/42/media/AnimSets/player/actions/` registers the game's own rifle aim, rifle fire,
bolt-rack, magazine-reload and shot-reaction clips as action animations (`LF_AimRifle`,
`LF_FireRifle`, `LF_RackBolt`, `LF_Reload`, `LF_HitShot`).

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
