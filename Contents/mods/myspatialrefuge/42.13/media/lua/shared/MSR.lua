-- MSR.lua - Global namespace for My Spatial Refuge mod
-- All mod modules register themselves under the MSR namespace to avoid conflicts
--
-- LOAD ORDER (PZ loads alphabetically, period < underscore):
-- 1. MSR.lua (this file) - creates MSR namespace
-- 2. MSR_00_KahluaCompat.lua - creates global K (Kahlua workarounds)
-- 3. MSR_01_Logging.lua - creates global L (debug logging)
-- 4. MSR_Config.lua, MSR_Data.lua, etc. - can use MSR, K, L safely

if MSR and MSR._loaded then
    return MSR
end

MSR = MSR or {}
MSR._loaded = true

-- Note: K and L globals are created by MSR_00/01 files AFTER this file loads.
-- Use K and L directly in your code, not MSR.KahluaCompat/MSR.Logging.

return MSR
