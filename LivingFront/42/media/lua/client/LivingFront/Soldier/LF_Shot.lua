-- Living Front: the shot table (combat overhaul, 0.72).
--
-- One set of numbers settles every round fired, on screen and off (Company of Heroes, Dawn of
-- War II: dice times modifiers, not ballistics):
--
--   chance to hit (percent) = the weapon's accuracy at that range (LF_Weapons: accBase falling by
--     accFall a tile, never under accMin)
--     x the target's cover against the shooter (the cover map, LF_Ground):
--         none 1.0 · light 0.55 · heavy 0.3 · garrison 0.35 (a window shows more of a man than a wall)
--     x the target's posture: down behind something 0.7 (crouched, in cover), on the move 0.85
--     x the shooter's state: badly hurt (under 50 health) down to half; suppressed (LF_Suppress)
--
--   what a hit does - one roll on the part it lands on (behind cover only what shows above it:
--   head, chest, arms), the weapon's punch (LF_Weapons impact) weighting the worse outcomes:
--         part       killed  critical  serious  light
--         head         70      20        10       0
--         chest        30      25        30      15
--         belly        20      25        35      20
--         arm           3       7        30      60
--         leg           5      15        40      40
--     a man already seriously or critically wounded who is hit again is killed (70%) or made
--     critical; a light wound hit again is at least serious.
--   The outcome goes straight to his grade (LF_Wounds); his body only shows it: the wound, his
--   health brought to the grade's level, no bleeding to death on top (the grade's clock does that).
--   A critical man whose squad medic can reach him goes down calling for him (LF_Medic) instead.
--
-- Off screen (LF_Clash) the same numbers are used as rates: each fit man's rounds a second x his
-- chance, summed over the unit, times CFG.duty - the share of the time a man in a firefight is
-- actually firing, aimed, at someone he can see (to be tuned so a fight comes out the same on
-- and off screen: the 0.72 gate test).

require "LivingFront/Core/LF_Core"
require "LivingFront/Soldier/LF_Weapons"

LF.Shot = LF.Shot or {}

local CFG = {
    duty = 0.2,             -- (0.73.4: 0.15 was set while the guns on screen hardly fired) off screen: share of the time a man in a fight is firing aimed rounds (0.72: 0.25 gave 1.7x the hits of the same fight on screen)
    down = 0.7,             -- target crouched behind something
    moving = 0.85,          -- target on the move
}
LF.Shot.CFG = CFG

-- Cover class (LF_Ground: 0 none, 1 light, 2 heavy, 3 garrison) -> hit-chance multiplier.
local COVER = { [0] = 1.0, [1] = 0.55, [2] = 0.3, [3] = 0.35 }
LF.Shot.COVER = COVER

-- Where a hit lands, by cover (weights by repetition).
local OPEN = { "Head", "Torso_Upper", "Torso_Upper", "Torso_Upper", "Torso_Lower", "Torso_Lower", "UpperArm_L", "UpperArm_R",
               "UpperLeg_L", "UpperLeg_R" }
local SHOWING = { "Head", "Head", "Torso_Upper", "Torso_Upper", "Torso_Upper", "UpperArm_L", "UpperArm_R" }
function LF.Shot.part(coverClass)
    local t = (coverClass and coverClass > 0) and SHOWING or OPEN
    return t[ZombRand(#t) + 1]
end

-- part -> { killed, critical, serious, light }
local OUTCOME = {
    Head = { 70, 20, 10, 0 },
    Torso_Upper = { 30, 25, 30, 15 },
    Torso_Lower = { 20, 25, 35, 20 },
    UpperArm_L = { 3, 7, 30, 60 }, UpperArm_R = { 3, 7, 30, 60 },
    UpperLeg_L = { 5, 15, 40, 40 }, UpperLeg_R = { 5, 15, 40, 40 },
    LowerLeg_L = { 3, 7, 40, 50 }, LowerLeg_R = { 3, 7, 40, 50 },
}
local NAMES = { "killed", "critical", "serious", "light" }

-- Chance to hit, in percent.
--   profile     - the weapon (LF_Weapons)
--   dist        - tiles
--   coverClass  - the target's cover against the shooter (0-3)
--   targetMul   - posture (LF.Shot.CFG.down / moving, or 1)
--   shooterMul  - the shooter's state (1 = fit and steady)
function LF.Shot.chance(profile, dist, coverClass, targetMul, shooterMul)
    local c = profile.accBase - dist * profile.accFall
    if c < profile.accMin then c = profile.accMin elseif c > profile.accBase then c = profile.accBase end
    return c * (COVER[coverClass or 0] or 1) * (targetMul or 1) * (shooterMul or 1)
end

-- What a hit does: "killed", "critical", "serious" or "light". grade = the man's grade now (or nil).
function LF.Shot.outcome(part, profile, grade)
    local w = OUTCOME[part] or OUTCOME.Torso_Upper
    local punch = profile and profile.impact or 1
    local k, c, s, l = w[1] * punch, w[2] * punch, w[3], w[4] / punch
    local roll = ZombRand(math.floor(k + c + s + l)) + 0.5
    local out = "light"
    if roll < k then out = "killed"
    elseif roll < k + c then out = "critical"
    elseif roll < k + c + s then out = "serious" end
    -- Hit again: worse.
    if grade == "serious" or grade == "critical" then
        out = ZombRand(100) < 70 and "killed" or "critical"
    elseif grade == "light" and out == "light" then
        out = "serious"
    end
    return out
end
LF.Shot.NAMES = NAMES

-- Rounds a second a man fires with this weapon in a sustained fight (bursts, bolt, belt).
function LF.Shot.rate(profile)
    if profile.rpm then return profile.rpm / 60 * 0.25 end          -- (a gun fires in bursts, not all the time)
    local cycle = (profile.interval or 120) + (profile.burst or 1) * (profile.gap or 0)
    return (profile.burst or 1) * 60 / math.max(30, cycle)
end
