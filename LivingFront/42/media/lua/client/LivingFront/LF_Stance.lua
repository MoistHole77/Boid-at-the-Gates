-- Living Front: unit stances.
--
-- Every squad (and lone fire team) has a stance, set by its sergeant or by the scene (for now,
-- by the debug menu). The stance is a table of settings that the brain (LF_Brain) and the
-- leaders (LF_Tactics) read, so a new stance is mostly a new table.
--
--   offensive - everything built before stances: bearings, advance, hold, reposition, flank,
--               fall back when broken; wounded men pull back to the rear.
--   defensive - all-round defence (a 360-degree perimeter) around where the sergeant called it:
--               every man is in cover facing out of his team's sector and is reluctant to leave
--               it; leaders give no maneuver orders; wounded men go down where they are; the
--               unit fights to the death (no withdrawal - kept as a setting so a sergeant can be
--               given that order later).
--
-- The stance is saved on the unit (squad.stance); a unit without one is offensive.

require "LivingFront/LF_Core"
require "LivingFront/LF_Units"

LF.Stance = LF.Stance or {}

local S = {
    offensive = {
        name = "offensive",
        maneuvers = true,        -- leaders may order advance / flank / reposition
        bearings = true,         -- opening seconds of a fight: everyone finds the nearest cover
        woundedWithdraw = true,  -- badly wounded men hide or pull back to the squad's rear
        withdrawWhenBroken = true,
        stickyCover = false,     -- keep a cover spot even when it is only so-so
    },
    defensive = {
        name = "defensive",
        maneuvers = false,
        bearings = false,        -- already in cover
        woundedWithdraw = false, -- wounded go down where they are
        withdrawWhenBroken = false, -- fight to the death
        stickyCover = true,      -- stay in cover unless it no longer protects at all
        sectorLeash = 3,         -- cover within this of his perimeter spot
        shiftLeash = 3,          -- a man without a shot may shift this far within his sector
        shiftInterval = 1800,    -- ... at most once per ~30 s
        radius = 7,              -- squad perimeter: teams this far out from the centre
        loneRadius = 3,          -- lone fire team: each man this far out
        arcCos = 0.34,           -- a man's sector is +-70 degrees either side of its direction
    },
}
LF.Stance.SETTINGS = S

function LF.Stance.get(squad)
    return S[squad and squad.stance or "offensive"] or S.offensive
end

-- The stance a soldier fights in (his unit's; a man without a unit is offensive).
function LF.Stance.of(rec)
    local squad = rec and rec.squad and LF.Units.get(rec.squad)
    return LF.Stance.get(squad)
end

function LF.Stance.isDefensive(rec)
    return LF.Stance.of(rec).name == "defensive"
end
