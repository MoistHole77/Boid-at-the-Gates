-- Living Front: off-screen simulation.
-- Records without a body keep living: needs rise at the rates measured from real bodies.
-- (Bodies tick their own needs natively, so they are skipped here.)
-- Later this is where the strategic layer runs: squads, sectors, the front line.

require "LivingFront/LF_Core"
require "LivingFront/LF_Records"
require "LivingFront/LF_Bodies"

LF.Sim = LF.Sim or {}

local function clamp01(v)
    if v < 0 then return 0 end
    if v > 1 then return 1 end
    return v
end

function LF.Sim.tickOffscreen()
    local r = LF.Config.rates
    for id, rec in pairs(LF.Records.all()) do
        if rec.alive and not LF.Bodies.get(id) then
            rec.hunger = clamp01(rec.hunger + r.hunger)
            rec.thirst = clamp01(rec.thirst + r.thirst)
            rec.fatigue = clamp01(rec.fatigue + r.fatigue)
        end
    end
end

Events.EveryTenMinutes.Add(function()
    LF.try("tickOffscreen", function() LF.Sim.tickOffscreen(); return true end)
end)
