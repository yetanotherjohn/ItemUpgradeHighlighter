--========================================================--
-- ItemUpgradeHighlighter - dynamic, quiet until /iuhdebug
--========================================================--

local addonName = ...
local frame = CreateFrame("Frame")

------------------------------------------------------------
-- Slash Command (run once with verbose debug output)
------------------------------------------------------------
SLASH_IUHDEBUG1 = "/iuhdebug"
SlashCmdList["IUHDEBUG"] = function()
    print("|cffffa500[IUH]|r Running verbose debug pass...")
    RefreshHighlights(true) -- true = debug mode
end

------------------------------------------------------------
-- Utility
------------------------------------------------------------
local function dbg(verbose, ...)
    if verbose then
        print("|cffffa500[IUH]|r", ...)
    end
end

------------------------------------------------------------
-- Slot Mapping (auto-built from API, skips invalids)
------------------------------------------------------------
local slotNames = {
    "HeadSlot","NeckSlot","ShoulderSlot","ShirtSlot","ChestSlot",
    "WaistSlot","LegsSlot","FeetSlot","WristSlot","HandsSlot",
    "Finger0Slot","Finger1Slot","Trinket0Slot","Trinket1Slot",
    "BackSlot","MainHandSlot","SecondaryHandSlot","RangedSlot","TabardSlot",
}

local slotMap = {}

local function BuildSlotMap(verbose)
    wipe(slotMap)
    local count = 0
    for _, name in ipairs(slotNames) do
        local ok, slotID = pcall(GetInventorySlotInfo, name)
        if ok and slotID then
            slotMap[slotID] = name
            count = count + 1
        else
            dbg(verbose, "Skipping invalid slot:", name)
        end
    end
    dbg(verbose, "Built slot map with", count, "valid slots.")
end

------------------------------------------------------------
-- Highlight Frames
------------------------------------------------------------
local highlights = {}

local function CreateHighlightFrame(parent)
    local hl = CreateFrame("Frame", nil, parent)
    hl:SetAllPoints()
    hl:SetFrameLevel(parent:GetFrameLevel() + 10)
    hl.texture = hl:CreateTexture(nil, "OVERLAY")
    hl.texture:SetAllPoints()
    hl.texture:SetColorTexture(1, 0.7, 0, 0.55) -- slightly brighter amber
    hl.texture:SetBlendMode("ADD")
    hl:Hide()

    local ag = hl:CreateAnimationGroup()
    local fadeOut = ag:CreateAnimation("Alpha")
    fadeOut:SetFromAlpha(1)
    fadeOut:SetToAlpha(0.2)
    fadeOut:SetDuration(0.6)
    fadeOut:SetOrder(1)
    local fadeIn = ag:CreateAnimation("Alpha")
    fadeIn:SetFromAlpha(0.2)
    fadeIn:SetToAlpha(1)
    fadeIn:SetDuration(0.6)
    fadeIn:SetOrder(2)
    ag:SetLooping("REPEAT")
    ag:Play()

    return hl
end

------------------------------------------------------------
-- Helpers
------------------------------------------------------------
local function GetEffectiveILvl(itemLink)
    if not itemLink then return 0 end
    local ilvl = 0
    if C_Item and C_Item.GetDetailedItemLevelInfo then
        ilvl = C_Item.GetDetailedItemLevelInfo(itemLink) or 0
    else
        ilvl = select(4, GetDetailedItemLevelInfo(itemLink)) or 0
    end
    return ilvl
end

-- Detect whether a two-handed weapon is currently equipped
local function IsTwoHandedEquipped()
    local mainLink = GetInventoryItemLink("player", INVSLOT_MAINHAND)
    if not mainLink then return false end

    local _, _, _, _, _, _, _, _, equipLoc = GetItemInfo(mainLink)
    return equipLoc == "INVTYPE_2HWEAPON" or equipLoc == "INVTYPE_RANGED" or equipLoc == "INVTYPE_RANGEDRIGHT"
end

local equipLocToSlotIDs = {
    INVTYPE_HEAD = {1},
    INVTYPE_NECK = {2},
    INVTYPE_SHOULDER = {3},
    INVTYPE_BODY = {4},
    INVTYPE_CHEST = {5},
    INVTYPE_ROBE = {5},
    INVTYPE_WAIST = {6},
    INVTYPE_LEGS = {7},
    INVTYPE_FEET = {8},
    INVTYPE_WRIST = {9},
    INVTYPE_HAND = {10},
    INVTYPE_FINGER = {11, 12},
    INVTYPE_TRINKET = {13, 14},
    INVTYPE_CLOAK = {15},
    INVTYPE_WEAPON = {16, 17},
    INVTYPE_2HWEAPON = {16},
    INVTYPE_WEAPONMAINHAND = {16},
    INVTYPE_WEAPONOFFHAND = {17},
    INVTYPE_HOLDABLE = {17},
    INVTYPE_RANGED = {18},
    INVTYPE_RANGEDRIGHT = {18},
    INVTYPE_TABARD = {19},
}

------------------------------------------------------------
-- UNIQUE / DUPLICATE HANDLING
-- Build unique-equipped map per evaluated slot (exclude that slot's equipped item)
------------------------------------------------------------

local function GetUniqueCategoriesEquipped(excludeSlot)
    local uniqueMap = {}

    -- check both finger and trinket slots
    local checkSlots = { INVSLOT_FINGER1, INVSLOT_FINGER2, INVSLOT_TRINKET1, INVSLOT_TRINKET2 }

    for _, slotID in ipairs(checkSlots) do
        if slotID ~= excludeSlot then
            local link = GetInventoryItemLink("player", slotID)
            if link then
                -- record exact itemID to prevent duplicates of same item being equipped elsewhere
                local itemID = tonumber(string.match(link, "item:(%d+)"))
                if itemID then
                    uniqueMap["ITEMID:"..itemID] = true
                end

                -- collect UNIQUE-related GetItemStats keys if available
                if GetItemStats then
                    local stats = GetItemStats(link)
                    if stats then
                        for k, v in pairs(stats) do
                            if type(k) == "string" and (k:find("UNIQUE") or k:find("UNIQUEEQUIPPED") or k:find("ITEM_UNIQUE")) then
                                uniqueMap["STAT:"..k] = true
                            end
                        end
                    end
                end
            end
        end
    end

    return uniqueMap
end

local function ItemConflictsWithUniqueMap(itemLink, uniqueMap)
    if not itemLink or not uniqueMap then return false end

    -- Exact itemID match: conflicts with already-equipped identical item in other slot
    local itemID = tonumber(string.match(itemLink, "item:(%d+)"))
    if itemID and uniqueMap["ITEMID:"..itemID] then
        return true
    end

    -- Stats-based uniqueness conflict
    if GetItemStats then
        local stats = GetItemStats(itemLink)
        if stats then
            for k, v in pairs(stats) do
                if type(k) == "string" and (k:find("UNIQUE") or k:find("UNIQUEEQUIPPED") or k:find("ITEM_UNIQUE")) then
                    if uniqueMap["STAT:"..k] then
                        return true
                    end
                end
            end
        end
    end

    -- Fallback heuristic omitted (tooltip scanning) to remain lightweight

    return false
end

------------------------------------------------------------
-- Core Scanning
-- FindBestBagItemLevel now takes uniqueMap to skip bag items that would conflict
------------------------------------------------------------
local function FindBestBagItemLevel(slotID, uniqueMap)
    local bestILvl, bestLink = 0, nil
    for bag = 0, NUM_BAG_SLOTS do
        for slot = 1, C_Container.GetContainerNumSlots(bag) do
            local link = C_Container.GetContainerItemLink(bag, slot)
            if link then
                local _, _, _, _, _, _, _, _, equipLoc = GetItemInfo(link)
                local validSlots = equipLocToSlotIDs[equipLoc]
                if validSlots then
                    for _, validSlot in ipairs(validSlots) do
                        if validSlot == slotID then
                            if uniqueMap and ItemConflictsWithUniqueMap(link, uniqueMap) then
                                -- skip conflicting bag item
                            else
                                local ilvl = GetEffectiveILvl(link)
                                if ilvl > bestILvl then
                                    bestILvl = ilvl
                                    bestLink = link
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    return bestILvl, bestLink
end

------------------------------------------------------------
-- Highlight Update (quiet unless verbose==true)
------------------------------------------------------------
local THRESHOLD = 10

function RefreshHighlights(verbose)
    if not next(slotMap) then BuildSlotMap(verbose) end

    local twoHandEquipped = IsTwoHandedEquipped()

    for slotID, slotName in pairs(slotMap) do
        -- Skip offhand slot entirely if a 2H is equipped
        if twoHandEquipped and slotID == INVSLOT_OFFHAND then
            dbg(verbose, "Skipping SecondaryHandSlot (two-handed weapon equipped)")
        else
            local slotFrame = _G["Character" .. slotName]
            if slotFrame then
                local eqLink = GetInventoryItemLink("player", slotID)
                local eqILvl = GetEffectiveILvl(eqLink)

                -- build unique map excluding the item in the currently-evaluated slot
                local uniqueEquippedMap = GetUniqueCategoriesEquipped(slotID)

                local bestBagILvl, bestLink = FindBestBagItemLevel(slotID, uniqueEquippedMap)

                local highlight = bestBagILvl > eqILvl and bestBagILvl - eqILvl >= THRESHOLD
                if not highlights[slotID] then
                    highlights[slotID] = CreateHighlightFrame(slotFrame)
                end
                highlights[slotID]:SetShown(highlight)

                if verbose then
                    if highlight then
                        print(string.format("|cffffa500[IUH]|r %s: upgrade %d→%d (%s)",
                            slotName, eqILvl, bestBagILvl, bestLink or "unknown"))
                    else
                        print(string.format("|cff999999[IUH]|r %s: no upgrade (eq %d, bag %d)",
                            slotName, eqILvl, bestBagILvl))
                    end
                end
            end
        end
    end
end

------------------------------------------------------------
-- Event Handling (dewwqdounced)
------------------------------------------------------------
local pending = false
local function ScheduleUpdate()
    if pending then return end
    pending = true
    C_Timer.After(0.3, function()
        pending = false
        RefreshHighlights(false)
    end)
end

frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
frame:RegisterEvent("BAG_UPDATE_DELAYED")
frame:RegisterEvent("UNIT_INVENTORY_CHANGED")

frame:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_ENTERING_WORLD" then
        BuildSlotMap(false)
    end
    ScheduleUpdate()
end)
