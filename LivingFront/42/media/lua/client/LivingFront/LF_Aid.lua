-- Living Front: self-aid. A wounded soldier who has got out of the fight bandages his bleeding
-- wounds one at a time with the game's own bandaging animations. That stops the bleeding (and
-- the trail of blood on the ground), so the wounded stabilise instead of slowly bleeding out.

require "TimedActions/ISBaseTimedAction"
require "LivingFront/LF_Core"

LF.Aid = LF.Aid or {}

-- Body part name prefix -> the game's bandaging animation variant.
local BANDAGE_TYPE = {
    Head = "Head", Neck = "Head",
    Torso_Upper = "UpperBody", Torso_Lower = "LowerBody", Groin = "LowerBody",
    UpperArm_L = "LeftArm", ForeArm_L = "LeftArm", Hand_L = "LeftArm",
    UpperArm_R = "RightArm", ForeArm_R = "RightArm", Hand_R = "RightArm",
    UpperLeg_L = "LeftLeg", LowerLeg_L = "LeftLeg", Foot_L = "LeftLeg",
    UpperLeg_R = "RightLeg", LowerLeg_R = "RightLeg", Foot_R = "RightLeg",
}

local function firstBleeding(body)
    local parts = body:getBodyDamage():getBodyParts()
    for i = 0, parts:size() - 1 do
        local p = parts:get(i)
        if p:bleeding() then return p end
    end
    return nil
end

-- The first bleeding body part, or nil.
function LF.Aid.bleedingPart(body)
    return LF.guard("find bleeding", firstBleeding, body)
end

-- How many of these bodies are bleeding (for the performance log).
function LF.Aid.countBleeding(bodies)
    local n = 0
    for _, b in pairs(bodies) do
        if not b:isDead() and LF.Aid.bleedingPart(b) then n = n + 1 end
    end
    return n
end

LF_AidAction = ISBaseTimedAction:derive("LF_AidAction")

function LF_AidAction:isValid()
    return not self.character:isDead()
end

function LF_AidAction:start()
    self:setActionAnim("Bandage")
    self:setAnimVariable("BandageType", self.bandageType)
end

function LF_AidAction:stop()
    ISBaseTimedAction.stop(self)
end

local function bandage(part)
    part:setBleeding(false)
    part:setBleedingTime(0)
    part:setBandaged(true, 10)
end

function LF_AidAction:perform()
    if self.part then
        LF.guard("bandage", bandage, self.part)
        LF.log("AID #" .. tostring(self.character:getModData().LF_id) .. " bandaged " .. self.partName)
    end
    ISBaseTimedAction.perform(self)
end

function LF_AidAction:new(character, part)
    local o = ISBaseTimedAction.new(self, character)
    o.part = part
    o.partName = tostring(part:getType())
    o.bandageType = BANDAGE_TYPE[o.partName] or "UpperBody"
    o.maxTime = 150
    o.stopOnWalk = false
    o.stopOnRun = false
    o.stopOnAim = false
    o.ignoreHandsWounds = true
    return o
end
