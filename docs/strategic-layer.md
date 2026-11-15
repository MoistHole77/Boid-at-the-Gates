# Living Front: Strategic Layer Plan

Nov 14, 2026 · copy of the Claude Doc "Living Front: Strategic Layer Plan" (https://claude.ai/artifact/TjUpbcViA4Q4hzn1DcW2QT)

## Where we start

The strategic layer's foundations are already in place:

- **Sectors, the front line and each side's fog of war** (`LF_Front`)
- **Off-screen fighting** (`LF_Clash`)
- **The influence map** (`LF_Influence`)
- **Captains who take and garrison objectives** (`LF_Captain`)
- **The XO's resupply and replacement runs** (`LF_XO`)
- **The 12-objective district** (`LF_District`)

What's missing is everything above a single company. Today a war only exists if you spawn two companies from the debug menu and point them at each other. The strategic layer's job is a district that fights its own battle for the whole of a save, over days, without you.

## Control and the front line

Control works at three levels, finest to coarsest, and the front line is drawn from the finest one that covers the whole city. Today control is all-or-nothing per sector, so the line barely moves in a slow battle; these levels let it creep building by building.

**1. Inside buildings: sections**

- Every building in the sites file is split into sections: its stair sections or wings, or the whole building if it's small.
- A section belongs to the side whose fit men hold posts in it; both sides inside, it's contested; nobody there, it keeps its last owner until someone moves in.
- A section changes hands only when it's cleared in an assault and the attackers take up posts in it. Walking through doesn't count.
- Men keep their posts off-screen, so a building can stay split between the sides for weeks.

**2. Across the city: the control map**

- A grid over the district at 4 tiles a cell (the grid the sector borders already use). Each cell is German, Soviet, contested or no-man's land.
- A building's cells follow its sections. Open ground belongs to whoever's held buildings cover it; where both sides' posts cover it, it's no-man's land (9 January Square).
- Ground isn't taken by standing on it, only by holding the buildings around it.

**3. Sectors and the district: scoring**

- As now: a sector belongs to whoever holds its objective, the district to whoever holds more than half its 16 points.
- The district panel also shows how much of each sector each side controls ("Central Workshops: German, 70% of its buildings"), so progress shows before an objective falls.

**The line**

- Drawn along the edge between German and Soviet ground on the control map, with no-man's land as a shaded band and shared buildings striped; sector borders stay as thin dashed lines. On the world map it's inked in red and blue pencil, to match the hand-drawn style.

**Fog of war**

- Each side plans on what it believes (`LF_Front` already keeps a picture per side): its own sections it knows, the enemy's only as last seen.
- The player is neutral for now: his map shows the line as last reported, and a debug view shows the truth.

**How the AI uses it**

- The battalion and captains choose the next building to take next to ground they already hold, so attacks creep instead of leaping.
- They keep posts manned along their edge of the line and route men through their own ground; reinforcements and supply runs come in only through it.

**Cost and saves**

- Sections and cells are worked out again only for buildings with men in or near them, about every 5 simulated seconds; the rest keep their last state.
- All of it is saved, so a split building is still split after a reload.

**Where it's built**

- S1: sections and their posts (holding part of a building), the control map, and its start state on 18 November 1942.
- S6: the line on the world map and the per-sector shares in the district panel.

## The plan, in build order

### S1. Order of battle and starting positions

- Start on 18 November 1942 (in detail below). Each side gets a starting order of battle; for example, the Soviet 13th Guards' 42nd Regiment against the German 71st Infantry Division's regiments, broken down to battalions and companies.
- Decide who holds which of the 12 sectors on day one. The battle sets itself up the first time the save runs, as off-screen records placed in their sectors, never next to you.
- Set a men budget. Companies not yet in the fight are held as headcounts, not 170 individual records, until they're committed. That keeps the off-screen simulation cheap.

#### S1 in detail: Downtown North on 18 November 1942

_Status: built in 0.88 (`LF_Battle`, `LF_Control`, `LF_Sites_DowntownNorth`; the sites file comes from `buildings/sites.py` in the map pipeline). Awaiting in-game test._

The first time a save runs on the Stalingrad map, the district is set up as it stood on 18 November 1942, the eve of Operation Uranus, when the Germans held about 90% of the city. From then on only gameplay moves the front; no historical events are scripted.

**Start state**

| Objective | Worth | Held by on day 1 |
| --- | --- | --- |
| Rail Depot | 1 | German |
| Railwaymen's House | 1 | German (a strongpoint until 3 December, historically) |
| 9 January Square | 2 | No-man's land: Soviet posts on Pavlov's side, Germans in the Milk House |
| Pavlov's House | 2 | Soviet |
| Gerhardt's Mill | 2 | Soviet |
| Engineering Works | 1 | German |
| Central Workshops | 1 | German |
| Riverside Warehouses | 1 | Soviet |
| Stalingrad-1 Station | 2 | German |
| Depot | 1 | German |
| Nail Factory | 1 | German |
| Machine Works | 1 | German |

The Germans hold 9 of the district's 16 points, so the district starts German. The Soviets hold a strip along the Volga from the Mill down to the Riverside Warehouses, with Pavlov's House as its outpost.

**Forces**

- Soviet: elements of the 13th Guards Rifle Division (the 42nd Guards Rifle Regiment): one battalion in the line, its companies garrisoning Pavlov's House, the Mill and the Warehouses, battalion headquarters by the riverbank.
- German: elements of the 71st Infantry Division: one battalion holding the western and southern sectors and Railwaymen's House.
- Both sides start badly under strength (by November companies were down to a few dozen men): companies at 40-60%, platoons missing squads.
- Reserves are headcounts held by the battalion (S2) until committed, not individual records.
- Every size lives in one config table, set by playtesting for performance and pacing.

**Positions on day 1**

- A garrison in every held objective, in the building defence.
- Front-line posts: the buildings along each sector border that face the enemy get a squad or a team each, so the line is a chain of strongpoints, not open ground.
- Shared buildings: a few buildings on the line start held by both sides at once, each holding its own stair sections, floors or rooms. This needs a new capability: holding part of a building, with a boundary neither side crosses without an assault, and a building with both sides in it not changing hands at once.
- Company headquarters and aid posts in rear buildings; nobody placed within a set distance of the player's start.
- Positions come from a sites file generated by the map pipeline: every building in each sector with its anchor square, stair sections, storeys, and which side of the line it faces. It's regenerated whenever the map is.
- After weeks facing each other, each side knows the other's front-line posts (sightings filled in at the start), but not his reserves or headquarters.

**The pace rules S1 needs**

- A static front: two units facing each other from held positions fight off-screen at a harassment rate (snipers, a mortar round, the odd grenade), on the order of one man hit per company every few hours. The full rate applies only during an assault.
- Captains hold by default: no assault without an order from the battalion (S2) and high odds; probes rare. Until S2 exists, captains only defend and probe.
- On screen the same: a quiet line, men keeping to their posts, occasional exchanges of fire.
- The result to aim for: fights for a building last days to weeks, so a player who brings men and supplies can break the deadlock.

**Files**

- `LF_Battle.lua` (new): the start state, the force table, seeding once per save after the district's objectives, a save version, debug tools to seed or reset the battle.
- `LF_Sites_DowntownNorth.lua` (new, generated by the map pipeline): buildings per sector, their sections, which way they face.
- `LF_District`: starting holders, including no-man's land.
- `LF_Objective` and `LF_Defence`: holding part of a building; both sides in one building without an instant change of hands.
- `LF_Clash`: the static-front rate.
- `LF_Captain`: the hold posture.
- `LF_Front`: sightings filled in at the start.
- `LF_Map` and `LF_Debug`: a debug overlay of every unit, BATTLE lines in the log, and a count of records, bodies and simulation time for the budget playtests.

**Done when**

1. In a new game, within a minute the log shows the battle seeded (companies, men, positions) and the world map shows 9 German, 5 Soviet and the square as no-man's land.
2. At Pavlov's House the Soviets are inside, the Germans in the Milk House and Railwaymen's House, and at least one building on the line has both sides in it.
3. Left running for a game day at speed, no objective changes hands, casualties stay in single figures a side, and no unit wanders off.
4. Records, bodies and simulation time are logged for the budget playtests.

### S2. Battalion command, the layer above the captains

- A battalion commander per side reads the district's influence map and objective values. He gives each company an area and a mission: attack, hold a stretch of the line, or reserve.
- He times attacks (the Germans by day, the Soviets often at night), commits reserves where the line is breaking, and pulls a company out when it's spent.
- The captains keep doing what they do now, but only within the area they're given.

### S3. The flow of men and supplies over time

- Each side has a pool. Soviet reinforcements cross the Volga at night to the central landing, which is already on the map. German replacements come in from the west by day.
- The XO's existing runs draw from that pool, so a side that bleeds faster than it's fed weakens.
- Finite ammunition, carried by the same runs, fits here. It's the "Later" item in the README, but it's optional at this stage.

### S4. Artillery and air

- Fire missions on a sector: German bombing and shelling by day, Soviet artillery from the east bank.
- Near you, they're real explosions. Off-screen, they're casualties and suppression through the same hit and suppression rules the existing fighting uses.
- This isn't required, but it's much of what made Stalingrad Stalingrad.

### S5. Tempo

- Day and night rhythm, lulls between pushes, and spent companies rotating to the rear to rebuild.
- No scripted historical events: after the start, the battle follows gameplay.

### S6. What you can see

- The front line drawn on the world map from the control map, a feed of battle reports ("Stalingrad-1 fell to the Germans, 14:20"), and warnings when you enter an active sector.
- A debug view comparing what's really there with each side's picture of the battle.

### S7. How it ends

- What happens when one side holds the district: it stays held, it's counter-attacked, or the battle clock runs on to Operation Uranus on 19 November and the Soviet side goes over to the attack.

### S8. Load, saves and a long-run test

- A test that runs three game days at top speed and logs the sector-by-sector timeline and the frame cost.
- A save format version so existing saves carry over.

## Decisions

**Settled**

1. **Start date:** the day the Germans held the most of the city, 18 November 1942. After that the battle follows gameplay, not history.
2. **Scale:** set by playtesting, for performance and pacing.
3. **Pace:** very slow without the player. Fights for a building last days to weeks, with each side holding different rooms of the same building for long stretches. The player, once he has the men and supplies, is what turns the battle.

**Still open**

1. **Artillery and air, and finite ammo.** In this pass, or later?
2. **The player.** A bystander for now, or should S6 be built around the role he'll take later?

## Suggested order

Build S1, S2 and S8 first: a self-starting district battle with battalion command and a long-run test. Then S3 and S6, then S4, S5 and S7.
