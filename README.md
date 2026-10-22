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
| Tactical depth (running, cover, squads, ammo, period weapons) | Next |
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
| `LF_Brain.lua` | Perceive / decide / act loop per NPC |
| `LF_Debug.lua` | Right-click debug menu |

`LivingFront/42/media/AnimSets/player/actions/` registers the game's own rifle aim, rifle fire
and shot-reaction clips as action animations (`LF_AimRifle`, `LF_FireRifle`, `LF_HitShot`).

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
12. **Not reachable from Lua:** the NPC's running flag (also driven by the hidden AI component).
