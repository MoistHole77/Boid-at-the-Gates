-- Living Front: period weapons, magazines and reloading.
--
-- Who carries what:
--   privates and corporals - bolt-action rifles: Kar98k (German), Mosin-Nagant (Soviet)
--   sergeants              - submachine guns:    MP40 (German),   PPSh-41 (Soviet)
--   platoon sergeants      - the same submachine guns
--   lieutenants            - pistols:            P38 (German),    TT-33 (Soviet) - an officer
--                            leads his platoon, he doesn't fight it: 8 rounds, quick to aim,
--                            poor beyond ~10 tiles
--   armed civilians        - Mosin-Nagant
-- The game has no WWII guns, so each is drawn and heard as the closest vanilla firearm (the
-- `item` field); the behaviour is entirely ours.
--
-- Balance: each pair has the same damage per second as its counterpart, reached differently.
--   Kar98k: faster bolt, standard round.     Mosin: slower bolt, slightly heavier round.
--   MP40:   bursts of 4, ~500 rpm, 32 rounds. PPSh: bursts of 6, ~900 rpm, 71-round drum,
--           lighter per round, slower to reload.
-- Rifles are accurate at range; SMGs spray - deadly close, poor beyond ~12 tiles - and lay down
-- more suppression per burst.
-- Machine guns (gunners of a machine-gun squad's gun teams; fired by LF_MG, not the rifle drill):
--   MG34  (German): 900 rounds a minute, 250-round belts, quick-change barrel every ~250 rounds.
--   DP-27 (Soviet): 550 rounds a minute, 47-round pan, no quick-change barrel - it has to be
--                   rested to cool instead.
-- Each round on its own is unlikely to hit (accBase is per round, not per burst); it's the
-- number of them, and the suppression they lay down, that counts.
--
-- Ammunition is infinite for now (magazines refill on reload); only the magazine is counted.
-- Timings are in ticks (60 = one second at normal speed).

require "TimedActions/ISBaseTimedAction"
require "LivingFront/Core/LF_Core"
require "LivingFront/Core/LF_Records"

LF.Weapons = LF.Weapons or {}

local W = {
    Kar98k = {
        name = "Kar98k", item = "Base.HuntingRifle", kind = "bolt",
        clip = 5, interval = 140, burst = 1, gap = 0, aimTicks = 60, recover = 50,
        wound = 50, impact = 1.0, suppress = 1.0,
        accBase = 78, accFall = 2.4, accMin = 20,
        reload = 200,
    },
    Mosin = {
        name = "Mosin", item = "Base.VarmintRifle", kind = "bolt",
        clip = 5, interval = 156, burst = 1, gap = 0, aimTicks = 62, recover = 56,
        wound = 55, impact = 1.1, suppress = 1.0,
        accBase = 79, accFall = 2.4, accMin = 20,
        reload = 220,
    },
    MP40 = {
        name = "MP40", item = "Base.ShotgunSawnoff", sound = "TrapperCarbineShoot", kind = "smg",
        clip = 32, interval = 130, burst = 4, gap = 7, aimTicks = 45, recover = 20,
        wound = 30, impact = 0.55, suppress = 0.55,
        accBase = 58, accFall = 4.0, accMin = 4,
        reload = 210,
    },
    MG34 = {
        name = "MG34", item = "Base.AssaultRifle", sound = "M14Shoot", kind = "mg",
        clip = 250, rpm = 900, interval = 240, burst = 1, gap = 0, aimTicks = 20, recover = 20,
        wound = 50, impact = 1.0, suppress = 1.0,
        accBase = 4.0, accFall = 0.08, accMin = 1.2, zoneHit = 7,
        reload = 300, barrelAt = 250, barrel = 480,
    },
    DP27 = {
        name = "DP-27", item = "Base.AssaultRifle2", sound = "L94Shoot", kind = "mg",
        clip = 47, rpm = 550, interval = 240, burst = 1, gap = 0, aimTicks = 20, recover = 20,
        wound = 55, impact = 1.1, suppress = 1.0,
        accBase = 4.4, accFall = 0.08, accMin = 1.3, zoneHit = 7,
        reload = 240, coolAt = 160,
    },
    P38 = {
        name = "P38", item = "Base.Pistol2", sound = "M1911Shoot", kind = "pistol",
        clip = 8, interval = 55, burst = 1, gap = 0, aimTicks = 30, recover = 25,
        wound = 32, impact = 0.6, suppress = 0.35,
        accBase = 60, accFall = 5.0, accMin = 3,
        reload = 150,
    },
    TT33 = {
        name = "TT-33", item = "Base.Pistol", sound = "M9Shoot", kind = "pistol",
        clip = 8, interval = 55, burst = 1, gap = 0, aimTicks = 30, recover = 25,
        wound = 32, impact = 0.6, suppress = 0.35,
        accBase = 60, accFall = 5.0, accMin = 3,
        reload = 150,
    },
    PPSh = {
        name = "PPSh", item = "Base.ShotgunSawnoff", sound = "M16Shoot", kind = "smg",
        clip = 71, interval = 150, burst = 6, gap = 4, aimTicks = 45, recover = 20,
        wound = 26, impact = 0.45, suppress = 0.45,
        accBase = 54, accFall = 4.0, accMin = 4,
        reload = 300,
    },
}
LF.Weapons.PROFILES = W

LF.Weapons.MG_OF = { GER = "MG34", SOV = "DP27" }

-- Which weapon a record carries (decided once, kept through promotions).
function LF.Weapons.keyFor(rec)
    if rec.weapon and W[rec.weapon] then return rec.weapon end
    local key
    local smg = rec.rank == "SGT" or rec.rank == "SSG"
    if rec.faction == "GER" then
        key = rec.rank == "LT" and "P38" or smg and "MP40" or "Kar98k"
    elseif rec.faction == "SOV" then
        key = rec.rank == "LT" and "TT33" or smg and "PPSh" or "Mosin"
    else
        key = "Mosin"
    end
    rec.weapon = key
    return key
end

function LF.Weapons.profile(rec)
    return W[LF.Weapons.keyFor(rec)]
end

-- The profile for a body (via its record), or the Kar98k as a safe default.
function LF.Weapons.profileOf(body)
    local rec = LF.Records.get(body:getModData().LF_id)
    return rec and LF.Weapons.profile(rec) or W.Kar98k
end

-- ---- magazines ------------------------------------------------------------------------------

local mags = {}      -- record id -> rounds left in the magazine (runtime; full when unknown)

local function idOf(body) return body:getModData().LF_id end

function LF.Weapons.rounds(body)
    local id = idOf(body)
    local left = id and mags[id]
    if left == nil then return LF.Weapons.profileOf(body).clip end
    return left
end

-- Use one round. Returns false if the magazine was already empty.
function LF.Weapons.useRound(body)
    local id = idOf(body)
    if not id then return true end
    local left = LF.Weapons.rounds(body)
    if left <= 0 then return false end
    mags[id] = left - 1
    return true
end

function LF.Weapons.refill(body)
    local id = idOf(body)
    if id then mags[id] = LF.Weapons.profileOf(body).clip end
end

function LF.Weapons.forget(id) mags[id] = nil end
function LF.Weapons.forgetAll() mags = {} end

-- ---- reloading ------------------------------------------------------------------------------

LF_ReloadAction = ISBaseTimedAction:derive("LF_ReloadAction")

local function play(body, name)
    if name and name ~= "" then body:playSound(name) end
end
local function ejectSound(body, gun) play(body, gun:getEjectAmmoSound()) end
local function insertSound(body, gun) play(body, gun:getInsertAmmoSound()) end
local function rackSound(body, gun) play(body, gun:getRackSound()) end
LF.Weapons.rackSound = rackSound

function LF_ReloadAction:isValid()
    return not self.character:isDead()
end

function LF_ReloadAction:waitToStart()
    return false
end

function LF_ReloadAction:start()
    self:setActionAnim("LF_Reload")
    if self.gun then self:setOverrideHandModels(self.gun, nil) end
    if self.gun then LF.guard("reload sound", ejectSound, self.character, self.gun) end
end

function LF_ReloadAction:stop()
    ISBaseTimedAction.stop(self)
end

function LF_ReloadAction:perform()
    LF.Weapons.refill(self.character)
    if self.gun then
        LF.guard("reload sound", insertSound, self.character, self.gun)
        if self.profile.kind == "bolt" then LF.guard("rack sound", rackSound, self.character, self.gun) end
    end
    ISBaseTimedAction.perform(self)
end

function LF_ReloadAction:new(character, gun, profile)
    local o = ISBaseTimedAction.new(self, character)
    o.gun = gun
    o.profile = profile
    o.maxTime = profile.reload
    o.stopOnWalk = false
    o.stopOnRun = false
    o.stopOnAim = false
    o.ignoreHandsWounds = true
    return o
end

-- Queue a reload (unless already busy). Returns true if one was queued.
function LF.Weapons.reload(body, gun, why)
    if not gun or body:isPerformingAnAction() then return false end
    local profile = LF.Weapons.profileOf(body)
    ISTimedActionQueue.add(LF_ReloadAction:new(body, gun, profile))
    if LF.Config.logShots then
        LF.log("RELOAD #" .. tostring(idOf(body)) .. " " .. profile.name .. " (" .. (why or "empty") .. ")")
    end
    return true
end
