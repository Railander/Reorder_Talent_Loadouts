--[[
    Reorder Talent Loadouts
    Author: Railander
    Description: Allows reordering talent loadouts in Retail World of Warcraft
                 by click-and-holding and moving them in the loadout dropdown.
--]]

local ADDON_NAME, ns = ...;

-- Global Database
ReorderTalentLoadoutsDB = ReorderTalentLoadoutsDB or {};

-- Local state variables
local isDragging = false;
local potentialDrag = false;
local justFinishedDragging = false;
local dragSourceConfigID = nil;
local dragSourceButton = nil;
local dragStartX, dragStartY = 0, 0;
local currentDropTargetIndex = nil;
local activeLoadoutButtons = {};

-- ----------------------------------------------------------------------------
-- Utility Functions
-- ----------------------------------------------------------------------------

function ns.GetPlayerKey()
    if UnitGUID then
        local guid = UnitGUID("player");
        if guid and guid ~= "" then
            return guid;
        end
    end
    if UnitName and GetRealmName then
        local name = UnitName("player");
        local realm = GetRealmName();
        if name and realm and name ~= "" and realm ~= "" then
            return name .. "-" .. realm;
        end
    end
    return "DefaultPlayer";
end

function ns.ArraysEqual(a, b)
    if not a or not b then return a == b; end
    if #a ~= #b then return false; end
    for i = 1, #a do
        if a[i] ~= b[i] then return false; end
    end
    return true;
end

-- ----------------------------------------------------------------------------
-- Database & Order Management
-- ----------------------------------------------------------------------------

function ns.GetSavedOrder(playerKey, specID)
    if not ReorderTalentLoadoutsDB or not specID then
        return nil;
    end
    if playerKey and ReorderTalentLoadoutsDB[playerKey] and ReorderTalentLoadoutsDB[playerKey][specID] then
        return ReorderTalentLoadoutsDB[playerKey][specID];
    end
    -- Fallback: check Name-Realm if playerKey was GUID or vice-versa
    if UnitName and GetRealmName then
        local name = UnitName("player");
        local realm = GetRealmName();
        if name and realm and name ~= "" and realm ~= "" then
            local altKey = name .. "-" .. realm;
            if altKey ~= playerKey and ReorderTalentLoadoutsDB[altKey] and ReorderTalentLoadoutsDB[altKey][specID] then
                return ReorderTalentLoadoutsDB[altKey][specID];
            end
        end
    end
    return nil;
end

function ns.SaveOrder(playerKey, specID, orderList, configIDToName)
    if not playerKey or not specID or not orderList then return end

    ReorderTalentLoadoutsDB[playerKey] = ReorderTalentLoadoutsDB[playerKey] or {};

    local namesMap = {};
    if configIDToName then
        for _, id in ipairs(orderList) do
            if configIDToName[id] then
                namesMap[id] = configIDToName[id];
            end
        end
    end

    local cleanOrder = {};
    for _, id in ipairs(orderList) do
        table.insert(cleanOrder, id);
    end

    ReorderTalentLoadoutsDB[playerKey][specID] = {
        order = cleanOrder,
        names = namesMap,
    };
end

function ns.SortConfigIDs(specID, currentConfigIDs, configIDToName)
    if not currentConfigIDs or #currentConfigIDs <= 1 then
        return currentConfigIDs;
    end

    local playerKey = ns.GetPlayerKey();
    if not playerKey then
        return currentConfigIDs;
    end

    local saved = ns.GetSavedOrder(playerKey, specID);
    if not saved or not saved.order or #saved.order == 0 then
        return currentConfigIDs;
    end

    local currentSet = {};
    local nameToCurrentID = {};
    for _, id in ipairs(currentConfigIDs) do
        currentSet[id] = true;
        if configIDToName and configIDToName[id] then
            nameToCurrentID[configIDToName[id]] = id;
        end
    end

    local result = {};
    local placed = {};
    local changed = false;

    -- 1. First pass: Place all saved IDs in their saved order
    for _, savedID in ipairs(saved.order) do
        local idToPlace = nil;
        if currentSet[savedID] then
            idToPlace = savedID;
        elseif saved.names and saved.names[savedID] and nameToCurrentID[saved.names[savedID]] then
            -- ConfigID changed (e.g. server transfer or patch), but name matched!
            local newID = nameToCurrentID[saved.names[savedID]];
            if currentSet[newID] and not placed[newID] then
                idToPlace = newID;
                changed = true;
            end
        end

        if idToPlace and not placed[idToPlace] then
            table.insert(result, idToPlace);
            placed[idToPlace] = true;
        end
    end

    -- 2. Second pass: Append any current IDs not present in saved order (new loadouts)
    for _, id in ipairs(currentConfigIDs) do
        if not placed[id] then
            table.insert(result, id);
            placed[id] = true;
            changed = true;
        end
    end

    -- If any saved IDs were deleted, or count changed, mark changed so DB is purged
    if #saved.order ~= #result then
        changed = true;
    end

    -- If any IDs were updated/added/purged, update the saved DB
    if changed and #result > 0 then
        ns.SaveOrder(playerKey, specID, result, configIDToName);
    end

    return result;
end

function ns.CalculateNewOrder(list, fromIndex, targetIndex)
    if not list or #list <= 1 or not fromIndex or not targetIndex then
        return list, false;
    end
    if targetIndex == fromIndex or targetIndex == fromIndex + 1 then
        return list, false;
    end
    if fromIndex < 1 or fromIndex > #list then
        return list, false;
    end

    local item = table.remove(list, fromIndex);
    local insertPos = targetIndex;
    if insertPos > fromIndex then
        insertPos = insertPos - 1;
    end
    if insertPos < 1 then insertPos = 1; end
    if insertPos > #list + 1 then insertPos = #list + 1; end

    table.insert(list, insertPos, item);
    return list, true;
end

-- ----------------------------------------------------------------------------
-- Talent Frame Detection & Helpers
-- ----------------------------------------------------------------------------

local cachedTalentsFrame = nil;
local cachedLoadSystem = nil;

function ns.GetSpecID(talentsFrame)
    local specID = talentsFrame and talentsFrame.GetSpecID and talentsFrame:GetSpecID();
    if not specID then
        if PlayerUtil and PlayerUtil.GetCurrentSpecID then
            specID = PlayerUtil.GetCurrentSpecID();
        elseif C_SpecializationInfo and C_SpecializationInfo.GetSpecialization and C_SpecializationInfo.GetSpecializationInfo then
            local curSpec = C_SpecializationInfo.GetSpecialization();
            if curSpec then
                specID = C_SpecializationInfo.GetSpecializationInfo(curSpec);
            end
        elseif GetSpecialization and GetSpecializationInfo then
            local curSpec = GetSpecialization();
            if curSpec then
                specID = GetSpecializationInfo(curSpec);
            end
        end
    end
    return specID;
end

function ns.GetConfigIDToName(talentsFrame, configIDs)
    if talentsFrame and talentsFrame.configIDToName then
        return talentsFrame.configIDToName;
    end
    local map = {};
    if configIDs and C_Traits and C_Traits.GetConfigInfo then
        for _, id in ipairs(configIDs) do
            local info = C_Traits.GetConfigInfo(id);
            if info and info.name then
                map[id] = info.name;
            end
        end
    end
    return map;
end

local function GetTalentsFrame(ownerRegion, useCache)
    if PlayerSpellsFrame and PlayerSpellsFrame.TalentsFrame then
        return PlayerSpellsFrame.TalentsFrame;
    elseif ClassTalentFrame then
        if ClassTalentFrame.TalentsTab and ClassTalentFrame.TalentsTab.LoadSystem then
            return ClassTalentFrame.TalentsTab;
        elseif ClassTalentFrame.LoadSystem then
            return ClassTalentFrame;
        end
    end
    if ownerRegion and ownerRegion.GetParent then
        local parent = ownerRegion:GetParent();
        if parent and parent.possibleSelections and (parent.GetDropdown or parent.Dropdown) then
            local grandParent = parent:GetParent();
            if grandParent and (grandParent.configIDs or grandParent.RefreshLoadoutOptions) then
                return grandParent;
            end
        end
    end
    if useCache then
        return cachedTalentsFrame;
    end
    return nil;
end

local function GetLoadSystem(ownerRegion, useCache)
    local talentsFrame = GetTalentsFrame(ownerRegion, useCache);
    if talentsFrame and talentsFrame.LoadSystem then
        return talentsFrame.LoadSystem;
    end
    if ownerRegion and ownerRegion.GetParent then
        local parent = ownerRegion:GetParent();
        if parent and parent.possibleSelections and (parent.GetDropdown or parent.Dropdown) then
            return parent;
        end
    end
    if useCache then
        return cachedLoadSystem;
    end
    return nil;
end

-- ----------------------------------------------------------------------------
-- UI Indicators (Drag Preview & Insertion Line)
-- ----------------------------------------------------------------------------

local dragPreviewFrame = nil;
local insertionLine = nil;

local function CreateUIElements()
    if dragPreviewFrame then return end

    -- Floating Drag Thumbnail
    dragPreviewFrame = CreateFrame("Frame", "ReorderTalentLoadoutsDragPreview", UIParent, "BackdropTemplate");
    dragPreviewFrame:SetSize(200, 26);
    dragPreviewFrame:SetFrameStrata("TOOLTIP");
    dragPreviewFrame:SetFrameLevel(9999);
    dragPreviewFrame:SetClampedToScreen(true);
    dragPreviewFrame:EnableMouse(false);

    if dragPreviewFrame.SetBackdrop then
        dragPreviewFrame:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8X8",
            edgeFile = "Interface\\Buttons\\WHITE8X8",
            tile = false,
            edgeSize = 1,
            insets = { left = 1, right = 1, top = 1, bottom = 1 },
        });
        dragPreviewFrame:SetBackdropColor(0.08, 0.08, 0.12, 0.95);
        dragPreviewFrame:SetBackdropBorderColor(0.9, 0.75, 0.15, 1.0);
    end

    local icon = dragPreviewFrame:CreateTexture(nil, "ARTWORK");
    icon:SetSize(18, 18);
    icon:SetPoint("LEFT", 4, 0);
    icon:SetTexture("Interface\\Icons\\INV_Misc_Book_09");
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92);
    dragPreviewFrame.icon = icon;

    local label = dragPreviewFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal");
    label:SetPoint("LEFT", icon, "RIGHT", 6, 0);
    label:SetPoint("RIGHT", -6, 0);
    label:SetJustifyH("LEFT");
    label:SetText("");
    label:SetTextColor(1.0, 0.82, 0.0, 1.0);
    dragPreviewFrame.label = label;

    dragPreviewFrame:Hide();

    -- Insertion Indicator Line
    insertionLine = CreateFrame("Frame", "ReorderTalentLoadoutsInsertionLine", UIParent);
    insertionLine:SetHeight(3);
    insertionLine:SetFrameStrata("TOOLTIP");
    insertionLine:SetFrameLevel(9998);
    insertionLine:EnableMouse(false);

    -- Glowing bar texture behind the line
    local glow = insertionLine:CreateTexture(nil, "BACKGROUND");
    glow:SetHeight(7);
    glow:SetPoint("LEFT", -4, 0);
    glow:SetPoint("RIGHT", 4, 0);
    glow:SetPoint("CENTER", 0, 0);
    glow:SetColorTexture(0.1, 0.55, 1.0, 0.45);
    insertionLine.glow = glow;

    -- Sharp center line
    local lineTex = insertionLine:CreateTexture(nil, "ARTWORK");
    lineTex:SetHeight(3);
    lineTex:SetAllPoints();
    lineTex:SetColorTexture(0.2, 0.8, 1.0, 1.0);
    insertionLine.lineTex = lineTex;

    -- Left indicator arrow
    local leftArrow = insertionLine:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall");
    leftArrow:SetPoint("RIGHT", insertionLine, "LEFT", -1, 0);
    leftArrow:SetText("▶");
    leftArrow:SetTextColor(0.2, 0.8, 1.0, 1.0);

    -- Right indicator arrow
    local rightArrow = insertionLine:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall");
    rightArrow:SetPoint("LEFT", insertionLine, "RIGHT", 1, 0);
    rightArrow:SetText("◀");
    rightArrow:SetTextColor(0.2, 0.8, 1.0, 1.0);

    insertionLine:Hide();
end

-- ----------------------------------------------------------------------------
-- Drag & Drop Engine
-- ----------------------------------------------------------------------------

function ns.StartDrag(button)
    if isDragging or not button or not button.rtLoadoutConfigID then
        return;
    end
    if InCombatLockdown and InCombatLockdown() then
        return;
    end

    CreateUIElements();

    isDragging = true;
    potentialDrag = false;
    dragSourceButton = button;
    dragSourceConfigID = button.rtLoadoutConfigID;

    -- Dim the source row to visually distinguish it
    button:SetAlpha(0.35);

    -- Set drag thumbnail text and icon
    local talentsFrame = GetTalentsFrame(button, true);
    local configIDToName = ns.GetConfigIDToName(talentsFrame, { dragSourceConfigID });
    local loadoutName = configIDToName[dragSourceConfigID];
    if not loadoutName or loadoutName == "" then
        if button.fontString and button.fontString.GetText then
            local btnText = button.fontString:GetText();
            if btnText and btnText ~= "" then
                loadoutName = btnText;
            end
        end
    end
    loadoutName = loadoutName or "Loadout";

    dragPreviewFrame.label:SetText(loadoutName);
    dragPreviewFrame:Show();

    ns.UpdateDrag();
end

function ns.UpdateDrag()
    if not isDragging then return end

    local cursorX, cursorY;
    if InputUtil and InputUtil.GetCursorPosition and UIParent then
        cursorX, cursorY = InputUtil.GetCursorPosition(UIParent);
    else
        local curX, curY = GetCursorPosition();
        local scale = UIParent and UIParent:GetEffectiveScale() or 1;
        cursorX = curX / scale;
        cursorY = curY / scale;
    end

    -- Position the floating preview frame near the cursor
    if dragPreviewFrame then
        dragPreviewFrame:ClearAllPoints();
        dragPreviewFrame:SetPoint("CENTER", UIParent, "BOTTOMLEFT", cursorX + 25, cursorY - 12);
    end

    local totalButtons = #activeLoadoutButtons;
    if totalButtons == 0 or not insertionLine then
        if insertionLine then insertionLine:Hide(); end
        currentDropTargetIndex = nil;
        return;
    end

    -- Check bounds relative to the loadout rows
    local firstBtn = activeLoadoutButtons[1];
    local lastBtn = activeLoadoutButtons[totalButtons];
    local bLeft, bBottom, bWidth, bHeight = firstBtn:GetRect();
    local lastLeft, lastBottom, lastWidth, lastHeight = lastBtn:GetRect();
    if not bLeft or not lastBottom then
        insertionLine:Hide();
        currentDropTargetIndex = nil;
        return;
    end

    local menuTop = bBottom + (bHeight or 0);
    local menuBottom = lastBottom;

    -- If cursor is moved too far away horizontally (> 120px) or vertically (> 60px), cancel drop indication
    if cursorX < (bLeft - 120) or cursorX > (bLeft + bWidth + 120)
       or cursorY > (menuTop + 60) or cursorY < (menuBottom - 60) then
        insertionLine:Hide();
        currentDropTargetIndex = nil;
        return;
    end

    -- Find target index based on vertical cursor position (top-to-bottom layout)
    local targetIndex = totalButtons + 1;
    for i = 1, totalButtons do
        local btn = activeLoadoutButtons[i];
        local left, bottom, width, height = btn:GetRect();
        if left and bottom and height then
            local midY = bottom + height / 2;
            if cursorY >= midY then
                targetIndex = i;
                break;
            end
        end
    end

    currentDropTargetIndex = targetIndex;

    -- Anchor the insertion line directly at the boundary
    insertionLine:ClearAllPoints();
    if targetIndex == 1 then
        insertionLine:SetPoint("BOTTOMLEFT", activeLoadoutButtons[1], "TOPLEFT", -2, -1);
        insertionLine:SetPoint("BOTTOMRIGHT", activeLoadoutButtons[1], "TOPRIGHT", 2, -1);
    elseif targetIndex <= totalButtons then
        insertionLine:SetPoint("BOTTOMLEFT", activeLoadoutButtons[targetIndex], "TOPLEFT", -2, -1);
        insertionLine:SetPoint("BOTTOMRIGHT", activeLoadoutButtons[targetIndex], "TOPRIGHT", 2, -1);
    else
        insertionLine:SetPoint("TOPLEFT", activeLoadoutButtons[totalButtons], "BOTTOMLEFT", -2, 1);
        insertionLine:SetPoint("TOPRIGHT", activeLoadoutButtons[totalButtons], "BOTTOMRIGHT", 2, 1);
    end
    insertionLine:Show();
end

function ns.FinishDrag()
    if not isDragging and not potentialDrag then
        return;
    end

    local wasDragging = isDragging;
    isDragging = false;
    potentialDrag = false;
    justFinishedDragging = true;

    -- Suppress click handling for a brief moment after releasing drag
    if C_Timer and C_Timer.After then
        C_Timer.After(0.2, function()
            justFinishedDragging = false;
        end);
    else
        justFinishedDragging = false;
    end

    if dragPreviewFrame then dragPreviewFrame:Hide(); end
    if insertionLine then insertionLine:Hide(); end

    if dragSourceButton then
        dragSourceButton:SetAlpha(1.0);
    end

    if not wasDragging or not currentDropTargetIndex or not dragSourceConfigID then
        dragSourceButton = nil;
        dragSourceConfigID = nil;
        currentDropTargetIndex = nil;
        return;
    end

    local talentsFrame = GetTalentsFrame(dragSourceButton, true);
    local loadSystem = GetLoadSystem(dragSourceButton, true);
    if not talentsFrame or not loadSystem then
        dragSourceButton = nil;
        dragSourceConfigID = nil;
        currentDropTargetIndex = nil;
        return;
    end

    local possibleSelections = loadSystem.possibleSelections;
    if not possibleSelections or #possibleSelections <= 1 then
        dragSourceButton = nil;
        dragSourceConfigID = nil;
        currentDropTargetIndex = nil;
        return;
    end

    -- Find source index
    local fromIndex = nil;
    for i, id in ipairs(possibleSelections) do
        if id == dragSourceConfigID then
            fromIndex = i;
            break;
        end
    end

    local toIndex = currentDropTargetIndex;
    dragSourceButton = nil;
    dragSourceConfigID = nil;
    currentDropTargetIndex = nil;

    if not fromIndex then return end

    -- Calculate new list
    local newList, moved = ns.CalculateNewOrder(CopyTable(possibleSelections), fromIndex, toIndex);
    if not moved then
        return;
    end

    -- Persist the new order
    local specID = ns.GetSpecID(talentsFrame);
    local configIDToName = ns.GetConfigIDToName(talentsFrame, newList);

    local playerKey = ns.GetPlayerKey();
    if playerKey and specID then
        ns.SaveOrder(playerKey, specID, newList, configIDToName);
    end

    -- Update loadSystem selections and talentsFrame cache
    loadSystem.possibleSelections = CopyTable(newList);
    if talentsFrame.configIDs then
        talentsFrame.configIDs = CopyTable(newList);
    end

    -- Play a satisfying sound
    if PlaySound and SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON then
        PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON);
    end

    -- Seamlessly refresh the dropdown to display the new order immediately
    local dropdown = loadSystem.GetDropdown and loadSystem:GetDropdown();
    if dropdown and dropdown.GenerateMenu then
        dropdown:GenerateMenu();
    elseif loadSystem.UpdateSelectionOptions then
        loadSystem:UpdateSelectionOptions();
    elseif dropdown and dropdown.CloseMenu and dropdown.OpenMenu then
        dropdown:CloseMenu();
        dropdown:OpenMenu();
    end
end

function ns.CancelDrag()
    if isDragging or potentialDrag then
        isDragging = false;
        potentialDrag = false;
        justFinishedDragging = true;
        if C_Timer and C_Timer.After then
            C_Timer.After(0.2, function()
                justFinishedDragging = false;
            end);
        else
            justFinishedDragging = false;
        end

        if dragPreviewFrame then dragPreviewFrame:Hide(); end
        if insertionLine then insertionLine:Hide(); end

        if dragSourceButton then
            dragSourceButton:SetAlpha(1.0);
        end

        dragSourceButton = nil;
        dragSourceConfigID = nil;
        currentDropTargetIndex = nil;
    end
end

function ns.ClearActiveButtons()
    wipe(activeLoadoutButtons);
end

-- ----------------------------------------------------------------------------
-- Button Setup & Menu Hook
-- ----------------------------------------------------------------------------

local function IsMouseOverUtilityButton(button)
    if not button or not button.GetChildren then return false; end
    local children = { button:GetChildren() };
    for _, child in ipairs(children) do
        if child and child.IsMouseOver and child:IsMouseOver() and (not child.IsShown or child:IsShown()) then
            return true;
        end
    end
    return false;
end

function ns.SetupLoadoutButton(button, description, menu, configID)
    button.rtLoadoutConfigID = configID;
    button.rtLoadoutDesc = description;
    button.rtLoadoutMenu = menu;

    -- Register in activeLoadoutButtons
    local alreadyPresent = false;
    for i, b in ipairs(activeLoadoutButtons) do
        if b == button then
            alreadyPresent = true;
            break;
        end
    end
    if not alreadyPresent then
        table.insert(activeLoadoutButtons, button);
    end

    -- ALWAYS re-arm drag on pooled buttons every time they are initialized from the pool
    if button.RegisterForDrag then
        button:RegisterForDrag("LeftButton");
    end
    if button.SetScript then
        button:SetScript("OnDragStart", function(self)
            if not (InCombatLockdown and InCombatLockdown()) then
                if not IsMouseOverUtilityButton(self) then
                    ns.StartDrag(self);
                end
            end
        end);
        button:SetScript("OnDragStop", function(self)
            if isDragging then
                ns.FinishDrag();
            end
        end);
    end

    if not button.rtDragHooked then
        button.rtDragHooked = true;

        if button.HookScript then
            button:HookScript("OnMouseDown", function(self, mouseButton)
                if mouseButton == "LeftButton" and not (InCombatLockdown and InCombatLockdown()) then
                    if IsMouseOverUtilityButton(self) then
                        return;
                    end

                    potentialDrag = true;
                    dragSourceButton = self;
                    dragSourceConfigID = self.rtLoadoutConfigID;
                    dragStartX, dragStartY = GetCursorPosition();
                end
            end);

            button:HookScript("OnMouseUp", function(self, mouseButton)
                if mouseButton == "LeftButton" then
                    if isDragging then
                        ns.FinishDrag();
                    else
                        potentialDrag = false;
                    end
                end
            end);
        end
    end
end

local InitializeTalentHooks;

local function OnModifyTalentMenu(ownerRegion, rootDescription, contextData)
    local talentsFrame = GetTalentsFrame(ownerRegion);
    local loadSystem = (talentsFrame and talentsFrame.LoadSystem) or GetLoadSystem(ownerRegion);
    if not loadSystem then return end
    if talentsFrame and talentsFrame.IsInspecting and talentsFrame:IsInspecting() then return end

    if talentsFrame then
        cachedTalentsFrame = talentsFrame;
    end
    if loadSystem then
        cachedLoadSystem = loadSystem;
    end

    if InitializeTalentHooks then
        InitializeTalentHooks();
    end

    local possibleSelections = loadSystem.possibleSelections or {};
    local selectionSet = {};
    for _, id in ipairs(possibleSelections) do
        selectionSet[id] = true;
    end

    -- Clear active buttons for the newly generated menu instance
    wipe(activeLoadoutButtons);

    -- Auto-cancel drag and cleanup when the menu is released/closed
    if rootDescription.AddMenuReleasedCallback then
        rootDescription:AddMenuReleasedCallback(function()
            ns.CancelDrag();
            ns.ClearActiveButtons();
            cachedTalentsFrame = nil;
            cachedLoadSystem = nil;
        end);
    end

    for index, desc in rootDescription:EnumerateElementDescriptions() do
        if desc and desc.GetData then
            local data = desc:GetData();
            if data and selectionSet[data] then
            -- This description represents a loadout entry!
            -- Suppress click selection during drag
            desc:SetCanSelect(function()
                if isDragging or justFinishedDragging then
                    return false;
                end
                return true;
            end);

            -- Suppress click sound when dragging or immediately after dropping
            -- Note: In WoW 12.1+, desc:GetSoundKit() raises an error if soundKit is nil, so wrap in pcall
            local origSoundKit = nil;
            if desc.GetSoundKit then
                local ok, sk = pcall(desc.GetSoundKit, desc);
                if ok then
                    origSoundKit = sk;
                end
            end
            desc:SetSoundKit(function(elementDesc)
                if isDragging or justFinishedDragging then
                    return 0;
                end
                if type(origSoundKit) == "function" then
                    return origSoundKit(elementDesc);
                elseif type(origSoundKit) == "number" then
                    return origSoundKit;
                end
                return (SOUNDKIT and SOUNDKIT.U_CHAT_SCROLL_BUTTON) or 0;
            end);

            desc:AddInitializer(function(button, description, menu)
                ns.SetupLoadoutButton(button, description, menu, data);
            end);
            end
        end
    end
end

-- ----------------------------------------------------------------------------
-- Talent UI Hooks
-- ----------------------------------------------------------------------------

local hooksInstalled = false;

local function OnRefreshLoadoutOptions(talentsFrame)
    if not talentsFrame or not talentsFrame.LoadSystem then return end
    if talentsFrame.IsInspecting and talentsFrame:IsInspecting() then return end
    if InCombatLockdown and InCombatLockdown() then return end

    local specID = ns.GetSpecID(talentsFrame);
    if not specID then return end

    local loadSystem = talentsFrame.LoadSystem;
    local currentSelections = loadSystem.possibleSelections;
    if not currentSelections or #currentSelections <= 1 then return end

    local configIDToName = ns.GetConfigIDToName(talentsFrame, currentSelections);
    local sorted = ns.SortConfigIDs(specID, currentSelections, configIDToName);
    if not ns.ArraysEqual(currentSelections, sorted) then
        loadSystem.possibleSelections = CopyTable(sorted);
        if talentsFrame.configIDs then
            talentsFrame.configIDs = CopyTable(sorted);
        end
        loadSystem:UpdateSelectionOptions();
    end
end

local function OnSetSelectionOptions(loadSystem, possibleSelections)
    local talentsFrame = GetTalentsFrame();
    if not talentsFrame or (talentsFrame.IsInspecting and talentsFrame:IsInspecting()) then return end
    if InCombatLockdown and InCombatLockdown() then return end

    local specID = ns.GetSpecID(talentsFrame);
    if not specID or not loadSystem.possibleSelections or #loadSystem.possibleSelections <= 1 then return end

    local configIDToName = ns.GetConfigIDToName(talentsFrame, loadSystem.possibleSelections);
    local sorted = ns.SortConfigIDs(specID, loadSystem.possibleSelections, configIDToName);
    if not ns.ArraysEqual(loadSystem.possibleSelections, sorted) then
        loadSystem.possibleSelections = CopyTable(sorted);
        loadSystem:UpdateSelectionOptions();
    end
end

InitializeTalentHooks = function()
    if hooksInstalled then return end

    local talentsFrame = GetTalentsFrame();
    if not talentsFrame or not talentsFrame.LoadSystem then return end

    hooksInstalled = true;

    if hooksecurefunc then
        hooksecurefunc(talentsFrame, "RefreshLoadoutOptions", OnRefreshLoadoutOptions);
        hooksecurefunc(talentsFrame.LoadSystem, "SetSelectionOptions", OnSetSelectionOptions);
    end

    -- Hook Hide to cancel any active drag if the window is closed
    if talentsFrame.HookScript then
        talentsFrame:HookScript("OnHide", ns.CancelDrag);
    end

    -- Hook Dropdown menu close callback to cancel any active drag
    local loadSystem = talentsFrame.LoadSystem;
    local dropdown = loadSystem.GetDropdown and loadSystem:GetDropdown();
    if dropdown and dropdown.RegisterCallback then
        local onMenuCloseEvent = (DropdownButtonMixin and DropdownButtonMixin.Event and DropdownButtonMixin.Event.OnMenuClose) or "OnMenuClose";
        pcall(dropdown.RegisterCallback, dropdown, onMenuCloseEvent, function()
            ns.CancelDrag();
            ns.ClearActiveButtons();
        end);
    end

    -- Apply initial sort if options already exist
    OnRefreshLoadoutOptions(talentsFrame);
end

ns.InitializeTalentHooks = InitializeTalentHooks;
ns.OnRefreshLoadoutOptions = OnRefreshLoadoutOptions;

-- ----------------------------------------------------------------------------
-- Core Event Controller Frame
-- ----------------------------------------------------------------------------

local function IsAddOnLoadedSafe(addonName)
    if C_AddOns and C_AddOns.IsAddOnLoaded then
        return C_AddOns.IsAddOnLoaded(addonName);
    elseif IsAddOnLoaded then
        return IsAddOnLoaded(addonName);
    end
    return false;
end

local eventFrame = CreateFrame("Frame", "ReorderTalentLoadoutsEventFrame");
eventFrame:RegisterEvent("ADDON_LOADED");
eventFrame:RegisterEvent("PLAYER_LOGIN");
eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED");
eventFrame:RegisterEvent("GLOBAL_MOUSE_DOWN");
eventFrame:RegisterEvent("GLOBAL_MOUSE_UP");

eventFrame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 == ADDON_NAME then
            ReorderTalentLoadoutsDB = ReorderTalentLoadoutsDB or {};
            if IsAddOnLoadedSafe("Blizzard_PlayerSpells") or IsAddOnLoadedSafe("Blizzard_ClassTalentUI") then
                InitializeTalentHooks();
            end
        elseif arg1 == "Blizzard_PlayerSpells" or arg1 == "Blizzard_ClassTalentUI" then
            InitializeTalentHooks();
        end
    elseif event == "PLAYER_LOGIN" then
        ReorderTalentLoadoutsDB = ReorderTalentLoadoutsDB or {};
        if IsAddOnLoadedSafe("Blizzard_PlayerSpells") or IsAddOnLoadedSafe("Blizzard_ClassTalentUI") then
            InitializeTalentHooks();
        end
    elseif event == "PLAYER_REGEN_DISABLED" then
        -- Cancel any drag operations when entering combat
        ns.CancelDrag();
    elseif event == "GLOBAL_MOUSE_DOWN" then
        local buttonName = arg1;
        if buttonName == "LeftButton" and not (InCombatLockdown and InCombatLockdown()) then
            for _, btn in ipairs(activeLoadoutButtons) do
                if btn:IsShown() and btn.IsMouseOver and btn:IsMouseOver() then
                    if not IsMouseOverUtilityButton(btn) then
                        potentialDrag = true;
                        dragSourceButton = btn;
                        dragSourceConfigID = btn.rtLoadoutConfigID;
                        dragStartX, dragStartY = GetCursorPosition();
                    end
                    break;
                end
            end
        end
    elseif event == "GLOBAL_MOUSE_UP" then
        if isDragging then
            ns.FinishDrag();
        else
            potentialDrag = false;
        end
    end
end);

eventFrame:SetScript("OnUpdate", function(self, elapsed)
    if potentialDrag and not isDragging then
        if IsMouseButtonDown and IsMouseButtonDown("LeftButton") then
            local curX, curY = GetCursorPosition();
            local dx = curX - dragStartX;
            local dy = curY - dragStartY;
            -- Threshold of 5 pixels to initiate drag
            if (dx * dx + dy * dy) > 25 then
                ns.StartDrag(dragSourceButton);
            end
        else
            potentialDrag = false;
        end
    end

    if isDragging then
        if IsMouseButtonDown and not IsMouseButtonDown("LeftButton") then
            ns.FinishDrag();
            return;
        end

        ns.UpdateDrag();
    end
end);

-- Register with Blizzard Menu framework (available in 11.0+)
if Menu and Menu.ModifyMenu then
    Menu.ModifyMenu("MENU_CLASS_TALENT_PROFILE", OnModifyTalentMenu);
end

-- ----------------------------------------------------------------------------
-- Slash Commands (Reset & Help)
-- ----------------------------------------------------------------------------

SLASH_REORDERTALENTLOADOUTS1 = "/rtl";
SLASH_REORDERTALENTLOADOUTS2 = "/reordertalentloadouts";

SlashCmdList["REORDERTALENTLOADOUTS"] = function(msg)
    local cmd = msg and string.lower(string.trim(msg)) or "";
    if cmd == "reset" then
        local talentsFrame = GetTalentsFrame();
        local specID = ns.GetSpecID(talentsFrame);
        local playerKey = ns.GetPlayerKey();
        if playerKey and specID then
            if ReorderTalentLoadoutsDB[playerKey] then
                ReorderTalentLoadoutsDB[playerKey][specID] = nil;
            end
            if talentsFrame and talentsFrame.RefreshLoadoutOptions then
                talentsFrame:RefreshLoadoutOptions();
            end
            if DEFAULT_CHAT_FRAME then
                DEFAULT_CHAT_FRAME:AddMessage("|cff00ccffReorder Talent Loadouts:|r Loadout order reset to default for this spec.");
            end
        end
    else
        if DEFAULT_CHAT_FRAME then
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ccffReorder Talent Loadouts:|r Click and hold any loadout in the talent dropdown to drag it into a new position. Use |cffffd100/rtl reset|r to reset the current spec's order.");
        end
    end
end;
