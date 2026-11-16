# Living Front: Soldier AI Rewrite

Nov 15, 2026. Built from published designs only: Killzone's position evaluation (Guerrilla, GDC Europe 2005), F.E.A.R.'s goal planning and squad behaviours (Orkin, GDC 2006) and Crysis' tactical point system. No game's code.

## What was wrong

From the 0.88 playtest and the code:

- **Bad positions in buildings.** The Stalingrad ruins have empty window frames and breaches, not glazed windows. The game's window test only finds frames that still hold a window, so every building logged "openings 0/0/0/0": the defence had nothing to post men at, and a man behind an empty sill counted as behind a blank wall.
- **Bad cover outside.** The squad's cover placement never considered a square inside a building, in a battle fought in buildings, and judged cover against one averaged enemy direction.
- **Pointless movement.** Four position finders (the open-ground finder, the squad placement, the hiding-spot finder, the brain's "step to cover") had grown apart, with a dozen patches on top (held cover, flanked spots, shelter retries, steps to cover). Men re-judged their cover against whoever they were aiming at and ran between spots of about the same worth.

## Phase 1 (0.89): positions

**One tactical position system (`LF_TPS`)** answers every "where do I stand" question with a scored query:

1. **Generate:** the squares around his anchor (where his orders put him) that he can stand on and nobody has claimed. Open ground, rubble and building interiors all count; the inside of a building the enemy holds doesn't. The square he holds and the one he stands on are always candidates, so staying put is always an option.
2. **Score cheaply:** distance from his anchor, the walk, spacing from his mates, the range his weapon wants, and an estimate of each square's cover (a few square reads, no line test).
3. **Score exactly** (the best 10 by estimate):
   - protection from his target and from every other enemy his squad knows of (out of sight, low cover he can fire over, a wall);
   - the line of fire;
   - the walk there (fences to climb, open ground in the enemy's view);
   - a penalty for standing in the open in the enemy's sight.
4. **Weights per kind of query:** fight, watch, shelter and hide each have their own (`LF.TPS.PROFILES`).

**Commitment** (the brain): a man holds the position he has.

- He looks again only every 5 s, at once when his squad gets new orders, or when he's under fire with nothing between him and the shooter.
- He moves only for a position better by a clear margin: 14 points, 26 for a dug-in man, and 16 more in his first 10 s after arriving. When he's exposed under fire, any gain will do.
- A spot he couldn't get to is set aside for a minute.

**Openings in ruins:** empty window frames count as windows (fire through them, low cover), and breaches in a wall count as openings for the building defence.

**Removed:** the old finders' bodies, the squad's per-placement candidate lists, the flank checks and the steps to cover. The old entry points (`LF.Cover.findFiringPosition`, `LF.Cover.findHidingSpot`, `LF.SquadBrain.spotFor`) now ask the position system.

**Debug:** Debug Tools → "Positions: log every choice" writes a TPS line for every answer with its score breakdown, plus counts of how often men kept or moved.

## Phase 2: decisions

Replace the brain's 370-line if-ladder (`decide()`) with utility selection: each candidate behaviour (fight from position, move to a better one, follow orders, fall back, help a wounded mate, rest) scores itself from considerations (threat, health, suppression, ammunition, orders, morale), and the best one runs with inertia so men don't flicker between behaviours.

## Phase 3: squad tactics

F.E.A.R.-style squad behaviours on top of the position system:

- **Get-to-cover:** one man suppresses while the rest move.
- **Advance-cover:** bounding forward.
- **Orderly advance and search:** pairs clearing rooms.

Killzone-style tactical paths that avoid friendly lines of fire and the enemy's view, suppression aimed at where a hidden enemy can fire from, and blind fire from cover.
