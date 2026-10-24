-- Living Front: NPC posture (crouching / standing) that ignores the player's crouch key.
--
-- The bug: NPC bodies are IsoPlayers with player index 0, so the engine's crouch-key handler
-- (IsoPlayer.updateSneakKey -> CharacterInputComponent, keyboard mode for index 0) reads the
-- real keyboard for them too. Every press of the player's crouch key toggled every NPC.
-- The index can't be changed from Lua.
--
-- The fix: the mod decides each NPC's posture (LF.Posture.set), and enforces it from the
-- OnPlayerUpdate event, which the engine fires for each NPC just before its crouch-key check
-- in the same update. If the crouch key was pressed this frame, the engine is about to flip
-- the posture, so we set the opposite first and the flip lands on the posture we want.

require "LivingFront/Core/LF_Core"

LF.Posture = LF.Posture or {}

local want = {}            -- record id -> true (crouch) / nil (stand)
local canReadKey = nil     -- can Lua call isCrouchButtonPressed on a body? (checked once)

local function readKey(body)
    return body:isCrouchButtonPressed()
end

-- Choose a posture for an NPC body (true = crouched).
function LF.Posture.set(body, crouch)
    local id = body:getModData().LF_id
    if not id then return end
    want[id] = crouch or nil
    if body:isSneaking() ~= (crouch == true) then body:setSneaking(crouch == true) end
end

function LF.Posture.crouched(body)
    local id = body:getModData().LF_id
    return id ~= nil and want[id] == true
end

function LF.Posture.forget(id)
    want[id] = nil
end

local function onPlayerUpdate(body)
    local id = body:getModData().LF_id
    if not id then return end    -- the real player, or someone else's character
    local desired = want[id] == true
    local target = desired
    if canReadKey == nil then
        local ok = pcall(readKey, body)
        canReadKey = ok
        LF.log("POSTURE crouch-key prediction " .. (ok and "available" or "UNAVAILABLE (NPCs may twitch on the crouch key)"))
    end
    if canReadKey and body:isCrouchButtonPressed() then target = not desired end
    if body:isSneaking() ~= target then body:setSneaking(target) end
end

Events.OnPlayerUpdate.Add(function(body) LF.guard("posture", onPlayerUpdate, body) end)
