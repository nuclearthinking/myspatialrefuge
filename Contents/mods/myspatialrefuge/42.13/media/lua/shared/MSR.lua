-- MSR.lua - Global namespace for My Spatial Refuge mod
-- This file MUST be required before any other MSR_* modules
-- All mod modules register themselves under the MSR namespace to avoid conflicts

if MSR and MSR._loaded then
    return MSR
end

MSR = MSR or {}
MSR._loaded = true

return MSR
