local _, namespace = ...
local PoolManager = namespace.PoolManager
local channeledSpells = namespace.channeledSpells
local castTimeDecreases = namespace.castTimeDecreases

local addon = CreateFrame("Frame")
addon:RegisterEvent("PLAYER_LOGIN")
addon:SetScript("OnEvent", function(self, event, ...)
    -- this will basically trigger addon:EVENT_NAME(arguments)
    return self[event](self, ...)
end)

local activeGUIDs = {}
local activeTimers = {}
local activeFrames = {}

addon.AnchorManager = namespace.AnchorManager
addon.defaultConfig = namespace.defaultConfig
addon.activeFrames = activeFrames
namespace.addon = addon
ClassicCastbars = addon -- global ref for ClassicCastbars_Options

-- upvalues for speed
local pairs = _G.pairs
local UnitGUID = _G.UnitGUID
local GetSpellInfo = _G.GetSpellInfo
local GetSpellTexture = _G.GetSpellTexture
local CombatLogGetCurrentEventInfo = _G.CombatLogGetCurrentEventInfo
local GetTime = _G.GetTime
local next = _G.next
local GetSpellSubtext = _G.GetSpellSubtext
local CastingInfo = _G.CastingInfo or _G.UnitCastingInfo

function addon:StartCast(unitGUID, unitID)
    if not activeTimers[unitGUID] then return end

    local castbar = self:GetCastbarFrame(unitID)
    if not castbar then return end

    castbar._data = activeTimers[unitGUID] -- set ref to current cast data
    self:DisplayCastbar(castbar, unitID)
end

function addon:StopCast(unitID)
    local castbar = activeFrames[unitID]
    if not castbar then return end

    castbar._data = nil
    if not castbar.isTesting then
        castbar:Hide()
    end
end

function addon:StartAllCasts(unitGUID)
    if not activeTimers[unitGUID] then return end

    -- partyX, nameplateX and target might be the same guid, so we need to loop through them all
    -- and start the castbar for each frame found
    for unit, guid in pairs(activeGUIDs) do
        if guid == unitGUID then
            self:StartCast(guid, unit)
        end
    end
end

function addon:StopAllCasts(unitGUID)
    for unit, guid in pairs(activeGUIDs) do
        if guid == unitGUID then
            self:StopCast(unit)
        end
    end
end

function addon:StoreCast(unitGUID, spellName, iconTexturePath, castTime, spellRank, isChanneled)
    local currTime = GetTime()

    -- Store cast data from CLEU in an object, we can't store this in the castbar frame itself
    -- since nameplate frames are constantly recycled between different units.
    activeTimers[unitGUID] = {
        spellName = spellName,
        spellRank = spellRank,
        icon = iconTexturePath,
        maxValue = castTime / 1000,
        --timeStart = currTime,
        endTime = currTime + (castTime / 1000),
        unitGUID = unitGUID,
        isChanneled = isChanneled,
    }

    self:StartAllCasts(unitGUID)
end

-- Delete cast data for unit, and stop any active castbars
function addon:DeleteCast(unitGUID)
    if unitGUID then -- sanity check
        self:StopAllCasts(unitGUID)
        activeTimers[unitGUID] = nil
    end
end

-- Spaghetti code inc, you're warned
function addon:CastPushback(unitGUID, percentageAmount, auraFaded)
    if not self.db.pushbackDetect then return end
    local cast = activeTimers[unitGUID]
    if not cast then return end

    -- if cast.prevCurrTimeModValue then print("stored total:", #cast.prevCurrTimeModValue) end

    -- Set cast time modifier (i.e Curse of Tongues)
    if not auraFaded and percentageAmount and percentageAmount > 0 then
        if not cast.currTimeModValue or cast.currTimeModValue < percentageAmount then -- run only once unless % changed to higher val
            if cast.currTimeModValue then -- already was reduced
                -- if existing modifer is e.g 50% and new is 60%, we only want to adjust cast by 10%
                percentageAmount = percentageAmount - cast.currTimeModValue

                -- Store previous lesser modifier that was active
                cast.prevCurrTimeModValue = cast.prevCurrTimeModValue or {}
                cast.prevCurrTimeModValue[#cast.prevCurrTimeModValue + 1] = cast.currTimeModValue
                -- print("stored lesser modifier")
            end

            -- print("refreshing timer", percentageAmount)
            cast.currTimeModValue = (cast.currTimeModValue or 0) + percentageAmount -- highest active modifier
            cast.maxValue = cast.maxValue + (cast.maxValue * percentageAmount) / 100
            cast.endTime = cast.endTime + (cast.maxValue * percentageAmount) / 100
        elseif cast.currTimeModValue == percentageAmount then
            -- new modifier has same percentage as current active one, just store it for later
            -- print("same percentage, storing")
            cast.prevCurrTimeModValue = cast.prevCurrTimeModValue or {}
            cast.prevCurrTimeModValue[#cast.prevCurrTimeModValue + 1] = percentageAmount
        end
    elseif auraFaded and percentageAmount then
        -- Reset cast time modifier
        if cast.currTimeModValue == percentageAmount then
            cast.maxValue = cast.maxValue - (cast.maxValue * percentageAmount) / 100
            cast.endTime = cast.endTime - (cast.maxValue * percentageAmount) / 100
            cast.currTimeModValue = nil

            -- Reset to lesser modifier if available
            if cast.prevCurrTimeModValue then
                local highest, index = 0
                for i = 1, #cast.prevCurrTimeModValue do
                    if cast.prevCurrTimeModValue[i] and cast.prevCurrTimeModValue[i] > highest then
                        highest, index = cast.prevCurrTimeModValue[i], i
                    end
                end

                if index then
                    cast.prevCurrTimeModValue[index] = nil
                    -- print("resetting to lesser modifier", highest)
                    return self:CastPushback(unitGUID, highest)
                end
            end
        end

        if cast.prevCurrTimeModValue then
            -- Delete 1 old modifier (doesn't matter which one aslong as its the same %)
            for i = 1, #cast.prevCurrTimeModValue do
                if cast.prevCurrTimeModValue[i] == percentageAmount then
                    -- print("deleted lesser modifier, new total:", #cast.prevCurrTimeModValue - 1)
                    cast.prevCurrTimeModValue[i] = nil
                    return
                end
            end
        end
    else -- normal pushback
        if not cast.isChanneled then
            cast.maxValue = cast.maxValue + 0.5
            cast.endTime = cast.endTime + 0.5
        else
            -- channels are reduced by 25%
            cast.maxValue = cast.maxValue - (cast.maxValue * 25) / 100
            cast.endTime = cast.endTime - (cast.maxValue * 25) / 100
        end
    end
end

function addon:ToggleUnitEvents(shouldReset)
    if self.db.target.enabled then
        self:RegisterEvent("PLAYER_TARGET_CHANGED")
    else
        self:UnregisterEvent("PLAYER_TARGET_CHANGED")
    end

    if self.db.nameplate.enabled then
        self:RegisterEvent("NAME_PLATE_UNIT_ADDED")
        self:RegisterEvent("NAME_PLATE_UNIT_REMOVED")
    else
        self:UnregisterEvent("NAME_PLATE_UNIT_ADDED")
        self:UnregisterEvent("NAME_PLATE_UNIT_REMOVED")
    end

    if shouldReset then
        self:PLAYER_ENTERING_WORLD() -- reset all data
    end
end

function addon:PLAYER_ENTERING_WORLD(isInitialLogin)
    if isInitialLogin then return end

    -- Reset all data on loading screens
    wipe(activeGUIDs)
    wipe(activeTimers)
    wipe(activeFrames)
    PoolManager:GetFramePool():ReleaseAll() -- also wipes castbar._data
end

-- Copies table values from src to dst if they don't exist in dst
local function CopyDefaults(src, dst)
    if type(src) ~= "table" then return {} end
    if type(dst) ~= "table" then dst = {} end

    for k, v in pairs(src) do
        if type(v) == "table" then
            dst[k] = CopyDefaults(v, dst[k])
        elseif type(v) ~= type(dst[k]) then
            dst[k] = v
        end
    end

    return dst
end

function addon:PLAYER_LOGIN()
    ClassicCastbarsDB = next(ClassicCastbarsDB or {}) and ClassicCastbarsDB or namespace.defaultConfig

    -- Reset old settings
    if ClassicCastbarsDB.version and ClassicCastbarsDB.version == "1" or
        ClassicCastbarsDB.nameplate and not ClassicCastbarsDB.version then
        wipe(ClassicCastbarsDB)
        print("ClassicCastbars: All settings reset due to major changes. See /castbar for new options.")
    end

    -- Copy any settings from default if they don't exist in current profile
    self.db = CopyDefaults(namespace.defaultConfig, ClassicCastbarsDB)
    self.db.version = namespace.defaultConfig.version

    -- config is not needed anymore if options are not loaded
    if not IsAddOnLoaded("ClassicCastbars_Options") then
        self.defaultConfig = nil
        namespace.defaultConfig = nil
    end

    self.PLAYER_GUID = UnitGUID("player")
    self:ToggleUnitEvents()
    self:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
    self:RegisterEvent("PLAYER_ENTERING_WORLD")
    self:UnregisterEvent("PLAYER_LOGIN")
    self.PLAYER_LOGIN = nil
end

-- Bind unitIDs to unitGUIDs so we can efficiently get unitIDs in CLEU events
function addon:PLAYER_TARGET_CHANGED()
    activeGUIDs.target = UnitGUID("target") or nil

    self:StopCast("target") -- always hide previous target's castbar
    self:StartCast(activeGUIDs.target, "target") -- Show castbar again if available
end

function addon:NAME_PLATE_UNIT_ADDED(namePlateUnitToken)
    local unitGUID = UnitGUID(namePlateUnitToken)
    activeGUIDs[namePlateUnitToken] = unitGUID

    self:StartCast(unitGUID, namePlateUnitToken)
end

function addon:NAME_PLATE_UNIT_REMOVED(namePlateUnitToken)
    activeGUIDs[namePlateUnitToken] = nil

    -- Release frame, but do not delete cast data
    local castbar = activeFrames[namePlateUnitToken]
    if castbar then
        PoolManager:ReleaseFrame(castbar)
        activeFrames[namePlateUnitToken] = nil
    end
end

function addon:COMBAT_LOG_EVENT_UNFILTERED()
    local _, eventType, _, srcGUID, _, _, _, dstGUID,  _, _, _, spellID, spellName, _, _, _, _, resisted, blocked, absorbed = CombatLogGetCurrentEventInfo()

    if eventType == "SPELL_CAST_START" then
        local _, _, icon, castTime = GetSpellInfo(spellID)
        if not castTime or castTime == 0 then return end
        local rank = GetSpellSubtext(spellID) -- async so won't work on first try but thats okay

        return self:StoreCast(srcGUID, spellName, icon, castTime, rank) -- return for tail call optimization and immediately exiting function
    elseif eventType == "SPELL_CAST_SUCCESS" then
        -- Channeled spells are started on SPELL_CAST_SUCCESS instead of stopped
        -- Also there's no castTime returned from GetSpellInfo for channeled spells so we need to get it from our own list
        local castTime = channeledSpells[spellName]
        if castTime then
            return self:StoreCast(srcGUID, spellName, GetSpellTexture(spellID), castTime * 1000, nil, true)
        end

        -- non-channeled spell, finish it
        return self:DeleteCast(srcGUID)
    elseif eventType == "SPELL_AURA_APPLIED" then
        if castTimeDecreases[spellID] then
            -- Aura that slows casting speed was applied
            return self:CastPushback(dstGUID, namespace.castTimeDecreases[spellID])
        end
    elseif eventType == "SPELL_AURA_REMOVED" then
        -- Channeled spells has no SPELL_CAST_* event for channel stop,
        -- so check if aura is gone instead since most (all?) channels has an aura effect
        if channeledSpells[spellName] then
            return self:DeleteCast(srcGUID)
        elseif castTimeDecreases[spellID] then
            -- Aura that slows casting speed was removed
            return self:CastPushback(dstGUID, castTimeDecreases[spellID], true)
        end
    elseif eventType == "SPELL_CAST_FAILED" or eventType == "SPELL_INTERRUPT" then
        if srcGUID == self.PLAYER_GUID then
            -- Spamming cast keybinding triggers SPELL_CAST_FAILED so check if actually casting or not for the player
            if not CastingInfo("player") then
                return self:DeleteCast(srcGUID)
            end
        else
            return self:DeleteCast(srcGUID)
        end
    elseif eventType == "PARTY_KILL" or eventType == "UNIT_DIED" then
        -- no idea if this is needed tbh
        return self:DeleteCast(dstGUID)
    elseif eventType == "SWING_DAMAGE" or eventType == "ENVIRONMENTAL_DAMAGE" or eventType == "RANGE_DAMAGE" or eventType == "SPELL_DAMAGE" then
        if resisted or blocked or absorbed then return end
        return self:CastPushback(dstGUID)
    end
end

addon:SetScript("OnUpdate", function(self)
    if not next(activeTimers) then return end

    local currTime = GetTime()
    local pushbackEnabled = self.db.pushbackDetect

    -- Update all active castbars in a single OnUpdate call
    for unit, castbar in pairs(activeFrames) do
        local cast = castbar._data

        if cast then
            local castTime = cast.endTime - currTime

            if (castTime > 0) then
                local value = cast.maxValue - castTime
                if cast.isChanneled then -- inverse
                    value = cast.maxValue - value
                end

                if pushbackEnabled then
                    castbar:SetMinMaxValues(0, cast.maxValue)
                end
                castbar:SetValue(value)
                castbar.Timer:SetFormattedText("%.1f", castTime)

                local sparkPosition = (value / cast.maxValue) * castbar:GetWidth()
                castbar.Spark:SetPoint("CENTER", castbar, "LEFT", sparkPosition, 0)
            else
                -- Delete cast incase stop event wasn't detected in CLEU (i.e unit out of range)
                self:DeleteCast(cast.unitGUID)
            end
        end
    end
end)
