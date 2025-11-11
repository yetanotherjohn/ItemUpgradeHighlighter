-- ItemUpgradeHighlighter.lua
local ADDON = "ItemUpgradeHighlighter"
local DEBUG = true
local THRESHOLD = 10 -- ilvl difference needed to trigger highlight

local function dbg(...)
    if DEBUG then
        print("|cffffff00["..ADDON.."]|r", ...)
    end
end

-- slotID -> CharacterFrame slot frame name
local SLOT_FRAMES = {
    [1]  = "CharacterHeadSlot",
    [2]  = "CharacterNeckSlot",
    [3]  = "CharacterShoulderSlot",
    [5]  = "CharacterChestSlot",
    [6]  = "CharacterWaistSlot",
    [7]  = "CharacterLegsSlot",
    [8]  = "CharacterFeetSlot",
    [9]  = "CharacterWristSlot",
    [10] = "CharacterHandsSlot",
    [11] = "CharacterFinger0Slot",
    [12] = "CharacterFinger1Slot",
    [13] = "CharacterTrinket0Slot",
    [14] = "CharacterTrinket1Slot",
    [15] = "CharacterBackSlot",
    [16] = "CharacterMainHandSlot",
    [17] = "CharacterSecondaryHandSlot",
}

-- create / show pulsing amber border around character slot
local PULSE_SPEED = 2 -- seconds for full pulse cycle

local function EnsureBorder(frame)
    if not frame then return end
    if not frame.UpgradeBorder then
        local b = CreateFrame("Frame", nil, frame, "BackdropTemplate")
        b:SetAllPoints(frame)
        b:SetBackdrop({
            edgeFile = "Interface\\Buttons\\WHITE8X8", -- plain white square
            edgeSize = 2,
            insets = { left = 0, right = 0, top = 0, bottom = 0 }
        })
        b:SetBackdropColor(0,0,0,0)              -- fully transparent background
        b:SetBackdropBorderColor(1,0.7,0,1)      -- amber color
        b:Hide()

        b:EnableMouse(false)                      -- crucial: allow mouse events to pass through

        -- start pulse animation
        b._pulseTime = 0
        b:SetScript("OnUpdate", function(self, elapsed)
            if self:IsShown() then
                self._pulseTime = self._pulseTime + elapsed
                local alpha = 0.3 + 0.2 * math.sin(self._pulseTime / PULSE_SPEED * 2 * math.pi)
                self:SetAlpha(alpha)
            end
        end)

        frame.UpgradeBorder = b
    end
end

local function SetHighlight(frame, enable)
    if not frame then return end
    EnsureBorder(frame)
    if enable then
        frame.UpgradeBorder:Show()
    else
        frame.UpgradeBorder:Hide()
    end
end



-- get effective ilvl safely
local function GetEffectiveILvl(link)
    if not link then return 0 end
    local lvl = 0
    if C_Item and C_Item.GetDetailedItemLevelInfo then
        lvl = C_Item.GetDetailedItemLevelInfo(link) or 0
    else
        lvl = select(4, GetDetailedItemLevelInfo(link)) or 0
    end
    return lvl
end

-- return numeric equipLoc for a bag item
local function GetItemEquipType(link)
    if not link then return nil end
    local itemID = GetItemInfoInstant(link)
    if not itemID then return nil end
    if C_Item and C_Item.GetItemInventoryTypeByID then
        return C_Item.GetItemInventoryTypeByID(itemID) -- numeric equipLoc
    else
        local _, _, _, _, _, _, _, _, equipLocStr = GetItemInfo(itemID)
        -- fallback: convert known strings to numeric if needed, optional
        return equipLocStr
    end
end

-- find best bag item for given slotID
local function FindBestBagItemLevel(slotID)
    local bestILvl, bestLink = 0, nil
    for bag = 0, NUM_BAG_SLOTS do
        local count = C_Container.GetContainerNumSlots(bag)
        for slot = 1, count do
            local link = C_Container.GetContainerItemLink(bag, slot)
            if link then
                local equipLoc = GetItemEquipType(link)
                if equipLoc == slotID 
                   or (equipLoc == 11 and (slotID == 11 or slotID == 12))
                   or (equipLoc == 13 and (slotID == 13 or slotID == 14)) then
                    local ilvl = GetEffectiveILvl(link)
                    if ilvl > bestILvl then
                        bestILvl = ilvl
                        bestLink = link
                    end
                end
            end
        end
    end
    return bestILvl, bestLink
end

-- update highlights for all character slots
local function UpdateHighlights()
    for slotID, frameName in pairs(SLOT_FRAMES) do
        local frame = _G[frameName]
        local eqLink = GetInventoryItemLink("player", slotID)
        local eqILvl = GetEffectiveILvl(eqLink)
        local bagILvl, bagLink = FindBestBagItemLevel(slotID)
        if bagILvl > 0 and (bagILvl - eqILvl) >= THRESHOLD then
            SetHighlight(frame, true)
        else
            SetHighlight(frame, false)
        end
    end
end

-- event frame
local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
f:RegisterEvent("BAG_UPDATE_DELAYED")
f:SetScript("OnEvent", function(_, event)
    C_Timer.After(0.2, UpdateHighlights)
end)
