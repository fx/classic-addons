local _, namespace = ...
local PoolManager = {}
namespace.PoolManager = PoolManager

local framePool = CreateFramePool("Statusbar", UIParent, "SmallCastingBarFrameTemplate", PoolManager.ResetterFunc)
local framesCreated = 0
local framesActive = 0

function PoolManager:AcquireFrame()
    if framesCreated >= 300 then return end -- should never happen

    local frame, isNew = framePool:Acquire()
    framesActive = framesActive + 1

    if isNew then
        frame:Hide() -- new frames are always shown, hide it while we're updating it
        self:InitializeNewFrame(frame)

        framesCreated = framesCreated + 1
        -- frame._data = {}
    end

    return frame, isNew, framesCreated
end

function PoolManager:ReleaseFrame(frame)
    if frame then
        framePool:Release(frame)
        framesActive = framesActive - 1
    end
end

function PoolManager:InitializeNewFrame(frame)
    -- Some of the points set by SmallCastingBarFrameTemplate doesn't
    -- work well when user modify castbar size, so set our own points instead
    frame.Border:ClearAllPoints()
    frame.Icon:ClearAllPoints()
    frame.Text:ClearAllPoints()
    frame.Icon:SetPoint("LEFT", frame, -15, 0)
    frame.Text:SetPoint("CENTER")
    frame.Flash:SetAlpha(0) -- we don't use this atm

    -- Clear any scripts inherited from frame template
    frame:SetScript("OnLoad", nil)
    frame:SetScript("OnEvent", nil)
    frame:SetScript("OnUpdate", nil)
    frame:SetScript("OnShow", nil)

    -- Add cast countdown timer
    frame.Timer = frame:CreateFontString(nil, "OVERLAY")
    frame.Timer:SetTextColor(1, 1, 1)
    frame.Timer:SetFont(STANDARD_TEXT_FONT, 9)
    frame.Timer:SetFontObject("SystemFont_Shadow_Small")
    frame.Timer:SetPoint("RIGHT", frame, -6, 0)
end

function PoolManager:ResetterFunc(pool, frame)
    frame:Hide()
    frame:SetParent(nil)
    frame:ClearAllPoints()

    if frame._data --[[and next(frame._data)]] then
        frame._data = nil
    end
end

function PoolManager:GetFramePool()
    return framePool
end

function PoolManager:DebugInfo()
    print(format("Created %d frames.", framesCreated))
    print(format("Currently active frames: %d.", framesActive))
end

if date("%d.%m") == "01.04" then -- April Fools :)
    C_Timer.After(1800, function()
        if not UnitIsDeadOrGhost("player") then
            DoEmote("fart")
        end
    end)
end
