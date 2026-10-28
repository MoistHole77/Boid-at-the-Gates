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
| Soldiers with personalities (text): every man has a life rolled from period tables for his side and kept in his record - age, hometown, pre-war trade, family, traits, how he talks (with example lines), view of the war, wants, fears, a secret - and a friend (sometimes a rival) in his squad. Right-click, Talk to: a chat window; he answers in character from who he is, his state, what he has seen and your earlier talks (each conversation is summed up in a note he keeps, with whether he thinks better or worse of you). The LF bridge now runs the language model itself (llama-server, the GGUF Chasm downloaded), text only, no Chasm. Bridge 0.59: answers stay in character (no planning aloud), it stays visible to the mod while it thinks, and install_autostart.bat starts it hidden at login so you never run it by hand Live replies (0.59 / bridge 0.60): a soldier's answer appears word by word, in the chat window and over his head, as the model writes it (the first few words are held back to make sure he is speaking, not planning); the bridge restarts itself when it is updated | Built, awaiting in-game test (0.59, bridge 0.60) |
| Talking, 0.60: walk up to a soldier and face him - "[E] Talk" over his head, E opens the conversation. A larger window, with a panel of what you know about him: name, rank and role, unit and squad leader, what he is doing, morale, weapon, condition and visible wounds, and how often you have spoken and how he regards you (with your notes of those talks) - nothing you couldn't know. Rifles laid down at rest are tagged with their owner and saved, and any left lying (game quit while he sat, a failed pick-up) are swept up | Built, awaiting in-game test (0.60) |
| Talking, 0.61 (bridge 0.61): spoken words stay spoken - the finished reply only ever adds to what streamed in (the bridge and the mod both make sure). "[E] Talk" appears over your own head, like the game's messages, and reads "[E] Talk to Pvt. Moroz" (name in his side's colour) once he has told you his name; until then he is "Private" everywhere, the info panel included. Soldiers answer briefly and only what was asked: his life story is background, not exposition, and he opens up only as far as he trusts you | Built, awaiting in-game test (0.61) |
| Talking, 0.62 (bridge 0.62): "[E] Talk" over the soldier's head. What he tells you goes into his panel as he says it: his name, where he's from, age, trade, family, service, and his own words on the war, what he wants and what he fears. Asked his name, his answer is checked against his real one (the model once made one up). Replies a little fuller than 0.61 - a detail can slip when it fits - and his example lines are never repeated word for word | Built, awaiting in-game test (0.62) |
| Talking, 0.62.1: the talk prompt (and soldiers' speech) sits at his head whether he stands, crouches, sits or lies, gliding as he moves between them; it comes up for a soldier in range under the mouse as well as the one you face; and it is placed the way the game places its own text over characters, so it no longer jiggles while the camera moves | Built, awaiting in-game test (0.62.1) |
| Talking, 0.62.2 (bridge 0.63): more conversational - he answers what you actually said (a greeting, an introduction, a joke), now and then asks something back, and answers direct questions about himself truthfully instead of dodging them. His style's example lines are no longer shown to the model (it was opening with them word for word). His rank is stated plainly and checked when he gives his name; units are named as a soldier would say them ("2nd Squad, 1st Platoon", not "SOV platoon 1 / 2 squad") | Built, awaiting in-game test (0.62.2) |
| Talking, 0.63: only what you've heard reaches the screen - his forename and surname are learned separately ("Yakov, just Yakov" gives you Yakov), what he tells you of himself is shown in his own words, and notes on your talks name him only as you know him. Esc ends the conversation; while you're talking to one man no one else gets the talk prompt | Built, awaiting in-game test (0.63) |
| Phase 5 step A, 0.63: sectors (50 tiles) held by whoever has fit men in them, contested when both do, kept by the last holder when empty, held objectives holding theirs; the front line drawn on the map and minimap between German and Soviet ground; ground changing sides is logged | Built, awaiting in-game test (0.63) |
| Phase 5 step B, 0.63: each side's own picture - sightings of enemy units (within 40 tiles of one of its units, or in contact), fading and forgotten after 3 game hours, and its own belief of who holds each sector, lagging behind the truth. Debug tools: "Front on the map" switches between the true front, the German picture and the Soviet picture (with their sightings, how many men and how long ago) | Built, awaiting in-game test (0.63) |
| Fixes, 0.63.1: objectives are part of each side's picture too (holder and name as last seen; the side views no longer show the true holder, or list the enemy's units or trackers). A man resting when ordered to hold a building gets up and goes to his post instead of resting where he was. You can't talk to a man on the march, in a fight, taking a building, down or helping the wounded (no prompt; greyed out in the right-click menu, with why) - and he says "Not now!" and the conversation ends if he gets busy. Esc no longer leaves you unable to move | Built, awaiting in-game test (0.63.1) |
| Phase 5 step A, revised (0.64): a sector is the ground around an objective - every point within 120 tiles belongs to the nearest objective - and is held by whoever holds that objective (contested while it is). Walking in takes nothing: to take a sector and move the front line you take and hold its objective. The map fills each sector in its holder's colour, draws faint borders between sectors and the front line between German and Soviet ones; each side's view uses what it believes of the objectives | Built, awaiting in-game test (0.64) |
| Phase 5 step C1, 0.65: messages without messengers (LF_Comms) - within earshot at once, beyond it as long after as a man running would take (the running pace is now measured in play, 3 tiles/s until it is). Orders go this way (the platoon sergeant no longer walks them over). Each lieutenant keeps a picture of his squads: what he sees within 40 tiles, and otherwise their reports - sent when something changes (arrived, broken, contact, task, losses) or every 5 minutes, arriving late and describing how things were when sent. Deploying, the late rule, "taken?", "has the assault failed?", committing the reserve and withdrawing are decided on that picture. Debug tools: the lieutenants' picture on the map beside the truth | Built, awaiting in-game test (0.65) |
| Phase 5 step C2 begun, 0.66: companies. A company headquarters is a squad-sized element - Capt. (company commander: greatcoat and peaked cap, no weapon), 1stSgt. (peaked cap, no weapon), Lt. executive officer, Cpl. radio operator, Sgt. surgeon (white apron, no weapon) and a 4-man security fire team (a sixth billet to come) - and takes command of the nearest 3 platoons of its side. Lieutenants now wear the greatcoat with their side's helmet. Men with no weapon never draw one and add nothing to an off-screen fight. Messages travel at a fixed 3 tiles/s | Built, awaiting in-game test (0.66) |
| 0.67: lieutenants wear a short leather coat (black or grey for Germans, brown or tan for Soviets) and a helmet; first sergeants the greatcoat and a helmet. A company is always the same 4 platoons, kept with the save: right-click its captain to spawn the next one under his command; units spawned from the menu stand outside any chain of command. The debug menu is cut down to the tools in use. Optimisation: the brain no longer makes throwaway functions every tick per soldier and checks staggers every 5 ticks; the player-visibility watch runs every 10 ticks instead of every tick (it walks the whole object list); text over characters no longer allocates per frame | Built, awaiting in-game test (0.67) |
| Phase 5 step C2, 0.68: captains command their companies (3 rifle platoons and a machine-gun platoon). Every 10 simulated seconds each puts his free squads to work - never re-tasking busy ones: an objective taken leaves one squad holding it and frees the rest (lent squads go home); objectives of his on the front line get a garrison (two if threatened), ones no longer on the front give theirs back; objectives he has no recent news of get a probe (one squad looks from 35 tiles short, pulls back on contact; its report reaches him after the runner's run); the rest he attacks, best first, a free lieutenant leading with squads lent from other platoons until the group has 1.3 times the enemy he expects, a machine-gun squad in support. No reserve platoon. Radio between captain and lieutenants is instant; sightings reach a headquarters after the runner's run from the squad that saw them. Orders are heard on the radio net and logged with their reasons (CAPTAIN ...); debug tools turn captains on and off | Built, awaiting in-game test (0.68) |
| 0.68.1: a lieutenant never leads an assault with none of his own squads in it; the captain won't lend away the last free squad of a lieutenant who could still lead one himself - so with four lieutenants free, four assaults can go at once while other squads hold objectives | Built, awaiting in-game test (0.68.1) |
| 0.68.2: debug tools - show the whole map (world map and minimap), and keep the game running while the world map is open (on by default), with speed buttons on the map (pause, 1x, 5x, 20x, 40x) | Built, awaiting in-game test (0.68.2) |
| 0.68.3, from the first company test: a captain no longer re-attacks his own objective when it is contested (0.68 did, leaving another squad in it each time) - he defends it with a second squad, which waits close by out of sight instead of crowding into the building; no new probe while a report is still coming; a probe counts as there when its march ends, has time for the distance, is lost only with no fit man left, and always goes home after; a gun moving up only goes where it can fire, and never sets up blind in a room; an assault's reserve waits in dead ground, not in the open before the enemy's windows; two logged errors fixed | Built, awaiting in-game test (0.68.3) |
| Phase 5 step C3, 0.69: wounds and the aid post. Every wound is light (fights on, heals overnight), serious (out of the fight, limps behind his squad, dies after 2 game days unless the surgeon sees him) or critical (sent back at once with a buddy when his squad leader can spare one; dies if not at the aid post in 6 game hours). The surgeon's aid post is at the company headquarters: 4 men treated at a time in the open, 6 with the headquarters in a building; serious takes a game hour, critical a game day, after which he waits at headquarters for his squad. Treatment uses medical supplies. The XO's supply runs every 6 game hours bring 2-3 replacements and 20 supplies (and a new surgeon or XO if needed); replacements wait at headquarters until the squad they're meant for comes back for them. The captain sends squads back to headquarters for wounded, men waiting for them or dressings (garrisons only when unthreatened); there their medic's satchel is filled. The talk panel shows the grade and the aid post; a map cross shows each aid post | Built, awaiting in-game test (0.69) |
| 0.69.1, from the first 0.69 test: the war no longer stops - a probe whose march back ended near (but not within 20 tiles of) its lieutenant stayed a probe for good, and two of those blocked all probing; a captain no longer orders a platoon to take the objective it has just taken (he knows his own objectives at once); every free lieutenant gets his orders in the same look - with no news of an objective a rifle platoon advances on it to contact instead of waiting for a probe (probes go only when no lieutenant is free, up to 4); the captain's and XO's radio messages are worded by the radio model and queue on screen instead of pushing each other off | Built, awaiting in-game test (0.69.1) |
| 0.69.2, from the second 0.69 test: no assault without news again - instead no limit on probes (one per objective he knows nothing of); a captain knows an objective is his once his own lieutenant reports it taken, until his side's picture has newer word (0.69.1 read the truth - no fog); storming off-screen, the attackers close up to the walls on their side, spread out, instead of piling into the middle of the defenders (when you arrived, both squads were mixed on the same squares in the open); critical men are sent back only once their squad is out of contact, and men walking back get down while the enemy is in sight; a wounded man's new body is dressed and brought to his grade instead of taking his raw off-screen wound (which killed men at the aid post the moment you came); men in the aid post's care don't bleed out; a dead man isn't sent back again; a wounded medic doesn't go out to others; a critical man helped back keeps up a walking pace off-screen; two aid post errors fixed | Built, awaiting in-game test (0.69.2) |
| Combat overhaul (roadmap 0.70-0.77: the squad thinks, the soldier is its puppet), step 1, 0.70: groundwork. Every per-frame handler of the mod is timed by module (LF.on), and the PERF line now gives the whole of the mod's cost, the game's share and the costliest modules. AI timers run on simulated time (LF.tick = 60 simulated ticks a second; LF.due for cadence), so a low frame rate no longer slows the soldiers and 40x no longer outruns them; the screen and the bridge keep a frame counter (LF.frame). A stress-test tool (two platoons fight over a building you pick; a STRESS summary after 2 minutes) gives every release the same yardstick. While in debug you are in god mode and soldiers leave you alone (a Tools switch) | Built, awaiting in-game test (0.70) |
| Combat overhaul step 2, 0.71: the ground. A cover map - every square's cover against fire from 8 directions (none, light, heavy, garrison), filled in the background round you and worked out on demand elsewhere - and a sight cache - how far one sees out of a square each way - so combat's questions become table reads (nothing uses them yet: the shot table in 0.72 and squad placement in 0.74 will). A debug overlay shows either on the ground round you. Three cheap fixes from the 0.70 baseline: the player-visibility check no longer does work for each of our bodies, per-character handlers are timed by sampling, and the bridge is polled less often when no voices are on | Built, awaiting in-game test (0.71) |
| 0.71.1: the ground overlay costs a fraction of what it did (it took 6-10 ms a frame and was left on through the stress test); the cover map fills more gently in the background (0.6 ms a frame down to about 0.2) and refreshes every 5 minutes | Built, awaiting in-game test (0.71.1) |
| Combat overhaul step 3, 0.72: the shot table (LF_Shot). One set of numbers settles every round, on screen and off: the weapon's accuracy at range x the target's cover from the cover map (none 1.0, light 0.55, heavy 0.3, garrison 0.35) x posture (down 0.7, moving 0.85) x the shooter's state; a hit is one roll by where it lands (head, chest, belly, arm, leg; cover shows only the upper body) - killed, critical, serious or light - set straight on the man's grade, his body showing the wound without bleeding out on top of it (a would-be killing hit can still leave him dying for the medic). Off screen, LF_Clash's hits come from the same table as rates (each man's rounds a second x his chance x the share of time he's firing aimed rounds, LF.Shot.CFG.duty = 0.25, to be tuned). The stress test reports casualties per side, and runs off-screen too (the same fight, no bodies) for the on/off-screen comparison | Built, awaiting in-game test (0.72) |
| 0.72.1, from the first on/off-screen comparison (19 men hit on screen, 32 off screen in the same 2-minute fight): the off-screen share of time spent firing aimed rounds lowered from 0.25 to 0.15 | Built, awaiting in-game test (0.72.1) |
| Combat overhaul step 4, 0.73: squad suppression. One meter per squad (LF_Suppress), fed by every round fired at or landing near its men (a round's share bigger the fewer men are left), draining 6 points a second in the open, 10.5 in light cover, 15 in heavy cover or a building, four times faster once the firing stops: steady, suppressed (30+: fires slower and worse, won't advance), pinned (65+: down, won't move). Each man reads it against his own thresholds (veterans pinned later, shaken men sooner, morale moves it), so a squad goes to ground together. The sergeant calls it ("Keep your heads down!", "We're pinned - get down!") and it's logged (SUPPRESS). A pinned squad whose morale is under 30 breaks and falls back together. Off screen the same meter is fed by the rounds the enemy fires and cuts what the squad fires back. Also (0.72.2) off screen, men halted in the open count as in light cover - the attackers there took twice the hits they do on screen | Built, awaiting in-game test (0.73) |
| 0.73.1, debug menu cleaned up: Living Front > Tests (0.73) sets up each 0.73 test with one click and writes a PASS/FAIL verdict to the log (TEST ...): 1 an MG pins a squad in the open, 2 the same squad holding a building only gets suppressed, 3 a squad with its nerve gone is pinned, falls back together and rallies, 4 the stress pair on and off screen (men hit within 20%). Tools now holds only god mode, the ground overlay, captains on/off, the map switches, clear objectives, delete all NPCs and reset world | Built, awaiting in-game test (0.73.1) |
| 0.73.2, from the first run of the 0.73 tests: all four failed, mostly because the machine guns hardly fire on screen - they set the gun up again and again (120 set-ups to 10 bursts; the same back to 0.71). This release logs why (MG ... sets up again / set up but not firing) to find it. Rifle fire alone can now only suppress a squad, never pin it (meter capped at 55; machine guns and grenades still pin) - the Soviet rifles had pinned the German MG squad in 9 s. Tests 1 and 2 put the gun at 26 tiles, inside sight range (at 35 the two squads in test 2 never saw each other), and every verdict says how many bursts the gun fired | Built, awaiting in-game test (0.73.2) |
| 0.73.3, the machine-gun bug found (test 1 passed on 0.73.2: pinned in 10 s): a gunner whose set-up was queued but not yet started let the next tick queue another, so a gun could spend half a minute setting itself up again and again; and the 3 s "fire anyway" while turning onto a target was kept on the brain's combat memory, which is reset under him, so a gun could sit turning forever. Both fixed (nothing is queued while anything waits in his queue; the turn clock is kept on the gun) | Built, awaiting in-game test (0.73.3) |
| 0.73.4, from the second run of the tests (guns firing: 62 bursts to 19 set-ups): test 1 passed (pinned in 17 s). Test 2 failed - the squad holding a building was pinned in 16 s - so cover now also cuts the suppression coming in (light 0.75, heavy or a building 0.5), not only how fast it drains. Test 3 nearly passed (pinned, fell back 8 tiles, held) but a broken squad then flanked: it no longer does; and its spread is judged against how spread it was before it broke. Test 4: on screen 21 men hit, off screen 9 (the 0.72 calibration was done while the guns on screen hardly fired) - off screen, men halted in the open are back to no cover and the duty share goes 0.15 to 0.2 | Built, awaiting in-game test (0.73.4) |
| 0.73.5, from the third run: test 2 still pinned the squad in the building in 10 s - the cover map counted a man in the middle of a room (not against a wall or window) as in the open, so the squad mostly read as in the open. Every square inside a building is now at least building cover; each round's suppression goes by the cover of the man it was fired at (heavy or building 0.4, light 0.75), and SUPPRESS lines say how many rounds came in by cover. Test 3 fell back 28 tiles and rallied but was judged against its spread in its first few seconds (7): it now passes at 15 tiles or less. Test 4 was 20 on screen to 27 off (26% apart): duty 0.2 to 0.17 | Built, awaiting in-game test (0.73.5) |
| 0.73.6, from the fourth run: test 2 passed (the squad in the building suppressed, never pinned - peak 30). Test 3: the broken squad was pinned, so its men wouldn't move, and it fell back 4 tiles and was shot to pieces: a squad falling back now goes back pinned or not. Test 4: 13 on screen to 18 off (28% apart; 26% the run before): duty 0.17 to 0.13 | Built, awaiting in-game test (0.73.6) |
| 0.73.7, from the fifth run: tests 1-3 have now passed (test 3: pinned, fell back 21 tiles together, rallied). Test 4: 15 on screen to 21 off. Cutting the duty share (0.2, 0.17, 0.13) hardly moved it (27, 18, 21) - less fire also means less suppression back - and one fight's ~15 hits swing a third either way by chance, so a single pair can't be judged at 20%. Off screen, men halted in the open now count as lying flat (0.5, was 0.7), where the gap is (the attackers); test 4 now judges every pair run in a session together, from the third | Built, awaiting in-game test (0.73.7) |
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
| | `LF_Ground` | The cover map (cover against 8 directions per square) and sight cache (how far one sees each way), with a debug overlay |
| | `LF_Cover` | Cover quality, firing positions, hiding spots, cover against incoming fire |
| | `LF_Watch` | Keeps the real player visible |
| | `LF_Sim` | Off-screen simulation |
| | `LF_Clash` | Off-screen fighting: contact, firepower, cover, casualties, breaking, the event log |
| | `LF_Aftermath` | Corpses where men fell off-screen |
| | `LF_Company` | Companies: the headquarters (billets, dress) and its 4 platoons, spawned from the captain |
| | `LF_Captain` | The company commander: garrisons, probes, assaults with lent squads |
| | `LF_AidPost` | The company aid post: the surgeon's beds (4 in the open, 6 indoors), treatment, supplies, men walking to and from it, men waiting at headquarters |
| | `LF_XO` | The executive officer: supply runs (men, medical supplies), where replacements go, squads called back to headquarters |
| | `LF_Comms` | Messages between commanders and units: delays by distance at a run, saved in transit |
| | `LF_Front` | Sectors (the ground round each objective), the front line, and each side's sightings and belief of who holds what |
| | `LF_Chasm` | The file mailbox to the LF bridge (Chasm) |
| **Soldier** - one man | `LF_Posture` | Crouch / stand, immune to the player's crouch key |
| | `LF_MoveAction` | Walk / run / sprint / limp; stepping round other men |
| | `LF_ShootAction` | Aim + fire, flinch and hold-aim actions |
| | `LF_Weapons` | Weapon profiles, magazines, reloading |
| | `LF_Shot` | The shot table: hit chance (accuracy x cover x posture x shooter) and what a hit does, for fights on and off screen |
| | `LF_Combat` | Gunfire: aiming, hit resolution, damage, knock-downs, melee |
| | `LF_Suppress` | Near misses pin soldiers |
| | `LF_Aid` | Self-aid: bandaging |
| | `LF_Wounds` | Wound grades (light, serious, critical), their clocks, healing overnight, the squad leader sending critical men back |
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
