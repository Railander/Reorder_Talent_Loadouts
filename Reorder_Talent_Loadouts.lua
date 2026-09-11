--[[
    Reorder Talent Loadouts
    Author: Railander
    Description: Allows reordering talent loadouts in Retail World of Warcraft
                 by click-and-holding and moving them in the loadout dropdown.
--]]

local ADDON_NAME, ns = ...;

-- Global Database
ReorderTalentLoadoutsDB = ReorderTalentLoadoutsDB or {};

-- The addon is built fail-open: an internal error must never break Blizzard's menu
-- generation or the talent frame init chain; errors are reported to chat (once per
-- scope) and swallowed.
local reportedErrors = {};

local unpack = unpack or table.unpack;

-- Runs fn(...) while converting any error into a captured report.
-- This guarantees the calling (Blizzard) execution chain always continues.
-- NOTE: WoW runs Lua 5.1, where xpcall takes exactly (fn, errfunc) and silently
-- drops any further arguments -- so fn must be closed over its arguments here.
-- Passing them straight to xpcall used to nil out every parameter (drag buttons,
-- talent frames, menu descriptions) with no error raised.
local function SafeInvoke(scope, fn, ...)
	local args = {};
	local n = select("#", ...);
	for i = 1, n do
		args[i] = select(i, ...);
	end
	local results = { xpcall(function()
		return fn(unpack(args, 1, n));
	end, function(e)
		local stack;
		if debugstack then
			stack = debugstack(2, 6, 0);
		elseif debug and debug.traceback then
			stack = debug.traceback("", 2);
		end
		return tostring(e) .. (stack and ("\n" .. stack) or "");
	end) };
	if not results[1] then
		local err = tostring(results[2] or "unknown error");
		if not reportedErrors[scope] then
			reportedErrors[scope] = err;
			if DEFAULT_CHAT_FRAME then
				DEFAULT_CHAT_FRAME:AddMessage("|cffff3333Reorder Talent Loadouts [" .. scope .. "] error:|r " .. err);
			end
		end
		return false;
	end
	return true;
end

-- Local state variables
local isDragging = false;
local potentialDrag = false;
local justFinishedDragging = false;
local dragSourceConfigID = nil;
local dragSourceButton = nil;
local dragStartX, dragStartY = 0, 0;
local currentDropTargetIndex = nil;
local trackedButtons = {}; -- addon-side registry of loadout menu buttons: { button, configID }; never written onto Blizzard frames
local UpdateResetButton; -- forward declaration: refreshes reset-button visibility (defined near the reset button)

-- Restriction-state variables (WoW 12.x). Declared HERE (not in the restriction
-- module below) because the drag/sort/menu paths above the module assign them;
-- Lua locals bind lexically, so a later `local` would leave those paths writing
-- to a same-named global instead.
local restrictionsActive = false;
local restrictedTypes = {}; -- per-type marks from ADDON_RESTRICTION_STATE_CHANGED payloads
local gatedInitDeferred = false;
local reconcileQueued = false;

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

function ns.SortInPlace(tbl, sorted)
    if not tbl or not sorted then return end
    for i = 1, #sorted do
        tbl[i] = sorted[i];
    end
    for i = #sorted + 1, #tbl do
        tbl[i] = nil;
    end
end

-- ----------------------------------------------------------------------------
-- Database & Order Management
-- ----------------------------------------------------------------------------

-- An order entry is usable only in its canonical shape. Anything else (a bare
-- array from hand-editing, a scalar from corruption, a missing names map) is
-- treated as absent -- never raised on. Live databases have carried this shape
-- since v1.0, and every shipped version reads it through this function.
local function AsOrderEntry(bucket, specID)
    if type(bucket) ~= "table" then
        return nil;
    end
    local entry = bucket[specID];
    if type(entry) == "table" and type(entry.order) == "table" then
        return entry;
    end
    return nil;
end

function ns.GetSavedOrder(playerKey, specID)
    if not ReorderTalentLoadoutsDB or not specID then
        return nil;
    end
    if playerKey then
        local direct = AsOrderEntry(ReorderTalentLoadoutsDB[playerKey], specID);
        if direct then
            return direct;
        end
    end
    -- Fallback: check Name-Realm if playerKey was GUID or vice-versa
    if UnitName and GetRealmName then
        local name = UnitName("player");
        local realm = GetRealmName();
        if name and realm and name ~= "" and realm ~= "" then
            local altKey = name .. "-" .. realm;
            if altKey ~= playerKey then
                local alt = AsOrderEntry(ReorderTalentLoadoutsDB[altKey], specID);
                if alt then
                    return alt;
                end
            end
        end
    end
    return nil;
end

function ns.SaveOrder(playerKey, specID, orderList, configIDToName)
    if not playerKey or not specID or not orderList then return end

    -- A corrupt (non-table) character bucket is replaced, not indexed into.
    if type(ReorderTalentLoadoutsDB[playerKey]) ~= "table" then
        ReorderTalentLoadoutsDB[playerKey] = {};
    end

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
    if PlayerUtil and PlayerUtil.GetCurrentSpecID then
        local specID = PlayerUtil.GetCurrentSpecID();
        if specID then
            return specID;
        end
    end
    local specID = talentsFrame and talentsFrame.GetSpecID and talentsFrame:GetSpecID();
    if not specID then
        if C_SpecializationInfo and C_SpecializationInfo.GetSpecialization and C_SpecializationInfo.GetSpecializationInfo then
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
            -- pcall: name resolution must never raise into sort/refresh paths
            -- (mirrors the Repopulate translator below).
            local ok, info = pcall(C_Traits.GetConfigInfo, id);
            if ok and info and info.name then
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

local insertionLine = nil;

local function CreateUIElements()
    if insertionLine then return end

    -- Insertion Indicator Line: a plain bar in the loadout-name text color (yellowish),
    -- matching Blizzard's NORMAL_FONT_COLOR used for dropdown loadout entries.
    insertionLine = CreateFrame("Frame", "ReorderTalentLoadoutsInsertionLine", UIParent);
    insertionLine:SetHeight(2);
    insertionLine:SetFrameStrata("TOOLTIP");
    insertionLine:SetFrameLevel(9998);
    insertionLine:EnableMouse(false);

    local lineTex = insertionLine:CreateTexture(nil, "ARTWORK");
    lineTex:SetAllPoints();
    lineTex:SetColorTexture(1.0, 0.82, 0.0, 1.0);
    insertionLine.lineTex = lineTex;

    insertionLine:Hide();
end

-- ----------------------------------------------------------------------------
-- Drag & Drop Engine
-- ----------------------------------------------------------------------------

local function StartDragInner(button)
    if isDragging or not button or not ns.FindTrackedEntry(button) then
        return;
    end
    if ns.IsInteractionLocked() then
        return;
    end

    CreateUIElements();

    local entry = ns.FindTrackedEntry(button);
    isDragging = true;
    potentialDrag = false;
    dragSourceButton = button;
    dragSourceConfigID = entry and entry.configID or nil;

    -- Dim the source row to visually distinguish it
    button:SetAlpha(0.35);

    ns.UpdateDrag();
end

function ns.StartDrag(button)
    -- Fail-open: drag start must never raise into Blizzard input handling.
    SafeInvoke("startDrag", StartDragInner, button);
end

local function UpdateDragInner()
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

    local totalButtons = #trackedButtons;
    if totalButtons == 0 or not insertionLine then
        if insertionLine then insertionLine:Hide(); end
        currentDropTargetIndex = nil;
        return;
    end

    -- Check bounds relative to the loadout rows
    local firstBtn = trackedButtons[1].button;
    local lastBtn = trackedButtons[totalButtons].button;
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
        local btn = trackedButtons[i].button;
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
        insertionLine:SetPoint("BOTTOMLEFT", trackedButtons[1].button, "TOPLEFT", -2, -1);
        insertionLine:SetPoint("BOTTOMRIGHT", trackedButtons[1].button, "TOPRIGHT", 2, -1);
    elseif targetIndex <= totalButtons then
        insertionLine:SetPoint("BOTTOMLEFT", trackedButtons[targetIndex].button, "TOPLEFT", -2, -1);
        insertionLine:SetPoint("BOTTOMRIGHT", trackedButtons[targetIndex].button, "TOPRIGHT", 2, -1);
    else
        insertionLine:SetPoint("TOPLEFT", trackedButtons[totalButtons].button, "BOTTOMLEFT", -2, 1);
        insertionLine:SetPoint("TOPRIGHT", trackedButtons[totalButtons].button, "BOTTOMRIGHT", 2, 1);
    end
    insertionLine:Show();
end

function ns.UpdateDrag()
    SafeInvoke("updateDrag", UpdateDragInner);
end

local function FinishDragInner()
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

    if insertionLine then insertionLine:Hide(); end

    if dragSourceButton then
        dragSourceButton:SetAlpha(1.0);
    end

    -- Race guard: protection activated mid-drag (activation cancels drags, but a
    -- release landing in the same frame still arrives here) -- visuals are
    -- cleaned up above, then the gesture is dropped without persisting,
    -- sounding, or regenerating anything.
    if ns.IsInteractionLocked() then
        dragSourceButton = nil;
        dragSourceConfigID = nil;
        currentDropTargetIndex = nil;
        return;
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

    -- Update loadSystem selections in place without touching talentsFrame.configIDs
    -- IMPORTANT (WoW 12.1+): We must NEVER mutate talentsFrame.configIDs as that taints ClassTalentsFrame,
    -- causing C_ClassTalents.GetConfigIDsBySpecID to fail with SecretArguments AllowedWhenUntainted.
    ns.SortInPlace(loadSystem.possibleSelections, newList);

    -- Play a satisfying sound
    if PlaySound and SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON then
        PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON);
    end

    -- Seamlessly refresh the dropdown to display the new order immediately
    -- We use Blizzard's untainted menu generator via dropdown:GenerateMenu().
    -- NEVER call loadSystem:UpdateSelectionOptions() as that creates an addon closure in SetupMenu!
    local dropdown = loadSystem.GetDropdown and loadSystem:GetDropdown();
    if dropdown and dropdown.GenerateMenu then
        dropdown:GenerateMenu();
    elseif dropdown and dropdown.CloseMenu and dropdown.OpenMenu then
        dropdown:CloseMenu();
        dropdown:OpenMenu();
    end
end

function ns.FinishDrag()
    -- Fail-open: the drop applies the persisted order; never raise into input handlers.
    SafeInvoke("finishDrag", FinishDragInner);
    if UpdateResetButton then UpdateResetButton(); end
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
    wipe(trackedButtons);
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

-- Called from the sanctioned menu-description initializer. Button state lives in the
-- addon-side registry; the only things we add to the button itself are drag post-hooks
-- via HookScript (the sanctioned form -- runs after Blizzard's handlers, and verified
-- working in-game on these menu buttons). We do not touch any other Blizzard frame.
function ns.SetupLoadoutButton(button, description, menu, configID)
    local entry = nil;
    for i, e in ipairs(trackedButtons) do
        if e.button == button then
            entry = e;
            break;
        end
    end
    if entry then
        entry.configID = configID; -- pooled button re-used for a different entry
    else
        entry = { button = button, configID = configID };
        table.insert(trackedButtons, entry);
    end

    -- While protected, leave the button as a plain Blizzard row: no drag arming,
    -- no taint-able script installs. The registry entry above still tracks the
    -- row, so a lift-while-open regenerates into full behavior on next open.
    local installLocked = ns.IsInteractionLocked();
    -- Drag UX hooks (post-hooks only; verified safe on menu item buttons).
    if button.RegisterForDrag and not installLocked then
        button:RegisterForDrag("LeftButton");
    end
    if button.HookScript and not button.rtDragHooked and not installLocked then
        button.rtDragHooked = true;
        button:HookScript("OnMouseDown", function(self, mouseButton)
            if mouseButton == "LeftButton" and not ns.IsInteractionLocked() then
                if IsMouseOverUtilityButton(self) then
                    return;
                end
                potentialDrag = true;
                dragSourceButton = self;
                local e = ns.FindTrackedEntry(self);
                dragSourceConfigID = e and e.configID or nil;
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
    if button.SetScript and not installLocked then
        button:SetScript("OnDragStart", function(self)
            if not ns.IsInteractionLocked() and not IsMouseOverUtilityButton(self) then
                ns.StartDrag(self);
            end
        end);
        button:SetScript("OnDragStop", function(self)
            if isDragging then
                ns.FinishDrag();
            end
        end);
    end

    return entry;
end

function ns.FindTrackedEntry(button)
    for i, entry in ipairs(trackedButtons) do
        if entry.button == button then
            return entry, i;
        end
    end
    return nil;
end

local InitializeTalentHooks;

local function OnModifyTalentMenuInner(ownerRegion, rootDescription, contextData)
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
        -- Menu opened while protected: leave Blizzard's rows fully plain (still
        -- selectable) and retry the queued work on lift. This callback is also
        -- the self-heal for a /reload-in-combat: opening the dropdown after the
        -- fight (re)runs the deferred gated setup via EnsureGatedInit.
        if ns.IsInteractionLocked() then
            reconcileQueued = true;
            return;
        end
        ns.EnsureGatedInit();
    end

    local possibleSelections = loadSystem.possibleSelections or {};
    local selectionSet = {};
    for _, id in ipairs(possibleSelections) do
        selectionSet[id] = true;
    end

    -- Clear the addon-side button registry for the newly generated menu instance
    wipe(trackedButtons);

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
                local ok = SafeInvoke("menu-element", function()
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
                        local okSk, sk = pcall(desc.GetSoundKit, desc);
                        if okSk then
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

                    -- The initializer runs later on Blizzard's render path, outside
                    -- this SafeInvoke: keep it fail-open too, so a throwing
                    -- install can never blank the dropdown.
                    desc:AddInitializer(function(button, description, menu)
                        SafeInvoke("button-init", function()
                            ns.SetupLoadoutButton(button, description, menu, data);
                        end);
                    end);
                end);
            end
        end
    end
end

local function OnModifyTalentMenu(ownerRegion, rootDescription, contextData)
    -- Fail-open: an error in this callback would abort Blizzard's GenerateMenu, which is
    -- exactly what blanking the dropdown looks like. Capture and continue instead.
    SafeInvoke("menu", OnModifyTalentMenuInner, ownerRegion, rootDescription, contextData);
end

-- ----------------------------------------------------------------------------
-- Talent UI Hooks
-- ----------------------------------------------------------------------------

local hooksInstalled = false;
local showHookInstalled = false;

local function OnRefreshLoadoutOptionsInner(talentsFrame)
    if not talentsFrame or not talentsFrame.LoadSystem then return end
    if talentsFrame.IsInspecting and talentsFrame:IsInspecting() then return end
    if ns.IsInteractionLocked() then
        reconcileQueued = true;
        return;
    end

    local specID = ns.GetSpecID(talentsFrame);
    if not specID then return end

    local loadSystem = talentsFrame.LoadSystem;
    local currentSelections = loadSystem.possibleSelections;
    if not currentSelections or #currentSelections <= 1 then return end

    local configIDToName = ns.GetConfigIDToName(talentsFrame, currentSelections);
    local sorted = ns.SortConfigIDs(specID, currentSelections, configIDToName);
    if not ns.ArraysEqual(currentSelections, sorted) then
        ns.SortInPlace(loadSystem.possibleSelections, sorted);
        local dropdown = loadSystem.GetDropdown and loadSystem:GetDropdown();
        if dropdown and dropdown.IsMenuOpen and dropdown:IsMenuOpen() and dropdown.GenerateMenu
            and not isDragging and not potentialDrag then
            dropdown:GenerateMenu();
        end
    end
end

local function OnRefreshLoadoutOptions(talentsFrame)
    -- Fail-open: never break Blizzard's execution chain from a secure hook.
    SafeInvoke("refresh", OnRefreshLoadoutOptionsInner, talentsFrame);
end
ns.OnRefreshLoadoutOptions = OnRefreshLoadoutOptions;

-- ----------------------------------------------------------------------------
-- Reconciliation (event-driven; WoW 12.x taint rules)
-- ----------------------------------------------------------------------------
-- The addon contains ZERO secure hooks and never installs scripts or fields on Blizzard
-- frames (12.x Forbidden Aspects such as UntrustedScriptExecution can silently disable
-- addon-installed handlers on flagged frames, and taint we add to Blizzard execution
-- degrades restricted APIs like C_ClassTalents.GetConfigIDsBySpecID, which then returns
-- {} and collapses the loadout list).
--
-- In-game it was verified that restricted talent APIs still work from addon execution
-- even while Blizzard's own population came back degraded. The addon therefore
-- reconciles the dropdown from its own execution on the same events Blizzard uses for
-- loadout changes (TRAIT_CONFIG_LIST_UPDATED / TRAIT_CONFIG_CREATED / DELETED,
-- ACTIVE_PLAYER_SPECIALIZATION_CHANGED, PLAYER_ENTERING_WORLD, ZONE_CHANGED,
-- ZONE_CHANGED_NEW_AREA, ADDON_RESTRICTION_STATE_CHANGED, PLAYER_REGEN_ENABLED) plus bounded checks
-- after login -- never by continuous polling. While interaction-locked (any of the
-- six 12.x restriction types active) reconcile requests only queue; the queue
-- flushes on lift. Reconciliation restores any missing
-- loadouts (merge-only: entries injected by other addons are never removed) and applies
-- the saved order at the data level, which menu generation tolerates by design.

local reconcilePending = false;
local ScheduleReconcile; -- forward declaration (used by ReconcileInner deferral)

local function RepopulateLoadoutOptionsInner(talentsFrame, missingIDs)
    local loadSystem = talentsFrame.LoadSystem;
    local current = loadSystem.possibleSelections or {};

    -- Merge-only: keep every entry currently present, append the missing ground truth.
    local merged = {};
    for i, id in ipairs(current) do merged[i] = id; end
    for _, id in ipairs(missingIDs) do
        table.insert(merged, id);
    end

    -- Name resolution: Blizzard's frame cache first, C_Traits from addon context as fallback.
    local baseNames = ns.GetConfigIDToName(talentsFrame, merged);
    local function nameTranslation(configID)
        local name = baseNames[configID];
        if name then return name; end
        local ok, info = pcall(C_Traits and C_Traits.GetConfigInfo, configID);
        return (ok and info and info.name) or "";
    end

    loadSystem:SetSelectionOptions(merged, nameTranslation, loadSystem.selectionColor, loadSystem.tooltipTranslation);
end

local function ReconcileInner()
    -- Never rebuild anything mid-drag: a SetSelectionOptions-driven regeneration would
    -- release the open menu and cancel an in-progress drag (phantom release bug).
    if isDragging or potentialDrag then
        ScheduleReconcile();
        return;
    end

    -- While protected, queue instead of writing: ground-truth reads are gated
    -- and dropdown writes must not touch taint-able elements. The queue flushes
    -- on lift (restriction event, regen-enabled, login backstop, next event).
    if ns.IsInteractionLocked() then
        reconcileQueued = true;
        return;
    end

    local talentsFrame = GetTalentsFrame();
    if not talentsFrame or not talentsFrame.LoadSystem then return end
    if talentsFrame.IsInspecting and talentsFrame:IsInspecting() then return end

    local loadSystem = talentsFrame.LoadSystem;
    local current = loadSystem.possibleSelections;
    if not current then return end

    -- Ground truth from addon execution (restricted APIs work there).
    local specID = ns.GetSpecID(talentsFrame);
    local groundIDs = nil;
    if specID and C_ClassTalents and C_ClassTalents.GetConfigIDsBySpecID then
        local ok, ids = pcall(C_ClassTalents.GetConfigIDsBySpecID, specID);
        if ok and type(ids) == "table" then
            groundIDs = ids;
        end
    end

    -- Degraded population: find loadouts missing from the dropdown.
    local missing = {};
    if groundIDs then
        local present = {};
        for _, id in ipairs(current) do present[id] = true; end
        for _, id in ipairs(groundIDs) do
            if not present[id] then
                table.insert(missing, id);
            end
        end
    end

    if #missing > 0 then
        RepopulateLoadoutOptionsInner(talentsFrame, missing);
    end

    -- Apply the saved order to the (possibly restored) list.
    local after = loadSystem.possibleSelections;
    if after and #after > 1 then
        OnRefreshLoadoutOptions(talentsFrame);
    end

    if UpdateResetButton then UpdateResetButton(); end
end

ns.Reconcile = function()
    SafeInvoke("reconcile", ReconcileInner);
end

ScheduleReconcile = function()
    if reconcilePending then return end
    reconcilePending = true;
    if C_Timer and C_Timer.After then
        C_Timer.After(0.25, function()
            reconcilePending = false;
            ns.Reconcile();
        end);
    else
        reconcilePending = false;
        ns.Reconcile();
    end
end

ns.ScheduleReconcile = ScheduleReconcile;

-- Resets the current spec's saved order and restores Blizzard's default order in the
-- dropdown. IMPORTANT (WoW 12.x taint rules): never call the frame's RefreshLoadoutOptions
-- method from addon execution; its body invokes the restricted
-- C_ClassTalents.GetConfigIDsBySpecID. The pure-Lua load system replica below is safe.
function ns.ResetCurrentSpecOrder(announce)
    local talentsFrame = GetTalentsFrame();
    local specID = ns.GetSpecID(talentsFrame);
    local playerKey = ns.GetPlayerKey();
    if not playerKey or not specID then return false; end

    if type(ReorderTalentLoadoutsDB[playerKey]) == "table" then
        ReorderTalentLoadoutsDB[playerKey][specID] = nil;
    end

    local loadSystem = talentsFrame and talentsFrame.LoadSystem;
    if loadSystem and talentsFrame.configIDs and loadSystem.SetSelectionOptions then
        local function nameTranslation(configID)
            return talentsFrame.configIDToName and talentsFrame.configIDToName[configID];
        end
        local function tooltipTranslation(configID)
            if talentsFrame.IsStarterBuildConfig and talentsFrame:IsStarterBuildConfig(configID) then
                if YELLOW_FONT_COLOR and YELLOW_FONT_COLOR.WrapTextInColorCode and TALENT_FRAME_DROP_DOWN_STARTER_BUILD_TOOLTIP then
                    return YELLOW_FONT_COLOR:WrapTextInColorCode(TALENT_FRAME_DROP_DOWN_STARTER_BUILD_TOOLTIP);
                end
                return TALENT_FRAME_DROP_DOWN_STARTER_BUILD_TOOLTIP;
            end
            return nil;
        end
        loadSystem:SetSelectionOptions(talentsFrame.configIDs, nameTranslation, NORMAL_FONT_COLOR, tooltipTranslation);
    end

    -- talentsFrame.configIDs may be stale/degraded (Blizzard's population); reconciliation
    -- merges in the ground truth right away and leaves the default (unsorted) order intact.
    ns.Reconcile();

    if announce and DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ccffReorder Talent Loadouts:|r Loadout order reset to default for this spec.");
    end
    return true;
end

local resetButton = nil;

local function ddOpen(dropdown)
    return dropdown and dropdown.IsMenuOpen and dropdown:IsMenuOpen();
end

-- The button only makes sense when the current spec's order deviates from default,
-- i.e. a saved order exists in the DB.
local function IsSavedOrderPresent()
    local talentsFrame = GetTalentsFrame();
    local specID = ns.GetSpecID(talentsFrame);
    local saved = ns.GetSavedOrder(ns.GetPlayerKey(), specID);
    return saved ~= nil and saved.order ~= nil and #saved.order > 0;
end

UpdateResetButton = function()
    if not resetButton then return end
    -- While protected the button stays hidden (no taint-able interaction); the
    -- cosmetic press-depress normalize below is skipped too (SetPoint is gated).
    if ns.IsInteractionLocked() then
        resetButton:Hide();
        return;
    end
    -- The button hides at press, so its OnMouseUp (icon restore) never fires; normalize
    -- the press-depress offset whenever visibility is refreshed.
    if resetButton.Icon then
        resetButton.Icon:SetPoint("CENTER", resetButton, "CENTER");
    end
    local talentsFrame = GetTalentsFrame();
    local loadSystem = talentsFrame and talentsFrame.LoadSystem;
    local dropdown = loadSystem and loadSystem.GetDropdown and loadSystem:GetDropdown();
    if ddOpen(dropdown) and IsSavedOrderPresent() then
        resetButton:Show();
    else
        resetButton:Hide();
    end
end
ns.UpdateResetButton = UpdateResetButton;

-- Icon button styled after the talents pane's "Undo Pending Changes" button
-- (IconButtonTemplate + talents-button-undo). Visible only while the loadout dropdown is
-- open AND the current spec has a non-default saved order; it disappears the moment it is
-- pressed and the reset happens on press (not release) so the dropdown never collapses.
local function CreateResetButton(talentsFrame)
    if resetButton or not CreateFrame then
        return nil;
    end

    local loadSystem = talentsFrame.LoadSystem;
    local dropdown = loadSystem.GetDropdown and loadSystem:GetDropdown();
    if not dropdown then return nil; end

    local btn = CreateFrame("Button", "ReorderTalentLoadoutsResetButton", dropdown:GetParent() or dropdown, "IconButtonTemplate");
    btn:SetSize(25, 25);
    if btn.SetAtlas then
        btn:SetAtlas("talents-button-undo", true);
    end
    if btn.SetHighlightAtlas then
        btn:SetHighlightAtlas("talents-button-undo", "ADD");
        if btn.GetHighlightTexture then
            local highlight = btn:GetHighlightTexture();
            highlight:SetPoint("TOPLEFT", btn.Icon, "TOPLEFT");
            highlight:SetPoint("BOTTOMRIGHT", btn.Icon, "BOTTOMRIGHT");
        end
    end
    btn:SetPoint("RIGHT", dropdown, "LEFT", -6, 0);
    btn:Hide();

    -- Reset on PRESS: the button vanishes immediately, the saved order is cleared, and the
    -- menu (which the menu system closes on this outside mouse-down) is reopened on the
    -- next frame -- so the dropdown only ever flickers for at most a single frame.
    btn:SetScript("OnMouseDown", function(self, mouseButton)
        if mouseButton ~= "LeftButton" then return end
        if ns.IsInteractionLocked() then
            return;
        end
        if self.Icon then
            self.Icon:SetPoint("CENTER", self, "CENTER", 1, -1); -- press-depress visual
        end
        self:Hide();
        SafeInvoke("resetButton", function()
            ns.ResetCurrentSpecOrder(false);
            if C_Timer and C_Timer.After then
                C_Timer.After(0, function()
                    local talentsFrame = GetTalentsFrame();
                    local loadSystem = talentsFrame and talentsFrame.LoadSystem;
                    local dd = loadSystem and loadSystem.GetDropdown and loadSystem:GetDropdown();
                    if not ddOpen(dd) and dd and dd.OpenMenu then
                        dd:OpenMenu();
                    end
                    UpdateResetButton();
                end);
            end
        end);
    end);
    btn:SetScript("OnMouseUp", function(self)
        if self.Icon then
            self.Icon:SetPoint("CENTER", self, "CENTER"); -- restore press-depress visual
        end
    end);

    -- Tooltip (own button; plain script is fine here)
    btn:SetScript("OnEnter", function(self)
        if GameTooltip then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT");
            GameTooltip:SetText("Reset Loadout Order", 1, 0.82, 0);
            GameTooltip:AddLine("Restores this specialization's loadout order to the default.", 1, 1, 1, true);
            GameTooltip:Show();
        end
    end);
    btn:SetScript("OnLeave", function()
        if GameTooltip then GameTooltip:Hide(); end
    end);

    -- Visibility is fully derived: menu open AND a non-default saved order exists.
    if dropdown.RegisterCallback and DropdownButtonMixin and DropdownButtonMixin.Event then
        pcall(dropdown.RegisterCallback, dropdown, DropdownButtonMixin.Event.OnMenuOpen, function()
            UpdateResetButton();
        end);
        pcall(dropdown.RegisterCallback, dropdown, DropdownButtonMixin.Event.OnMenuClose, function()
            -- Hidden next frame: visually instant, but still ordered after the current
            -- input dispatch so a press landing on the button as the menu closes (outside
            -- click) always reaches the button's OnMouseDown first (reset happens on press).
            if C_Timer and C_Timer.After then
                C_Timer.After(0, function()
                    if not ddOpen(dropdown) then
                        btn:Hide();
                    end
                end);
            else
                btn:Hide();
            end
        end);
    end

    return btn;
end

local function InitializeTalentHooksInner()
    local talentsFrame = GetTalentsFrame();
    if not talentsFrame or not talentsFrame.LoadSystem then
        return
    end

    hooksInstalled = true;

    -- IMPORTANT (WoW 12.x taint rules): the addon contains ZERO secure hooks. Hooking a
    -- Blizzard Lua method injects addon taint into Blizzard's execution, and even hooking a
    -- SecretArguments-protected C function (C_ClassTalents.GetConfigIDsBySpecID) was
    -- observed in-game to degrade its results, collapsing the loadout list. The addon only
    -- ever registers via Menu.ModifyMenu (the sanctioned customization API) and mutates
    -- loadout DATA (possibleSelections) from its own execution. Reconciliation is
    -- event-driven and the initial sort runs below.

    -- Apply initial sort if options already exist
    local loadSystem = talentsFrame.LoadSystem;
    if loadSystem and loadSystem.possibleSelections and #loadSystem.possibleSelections > 1 then
        OnRefreshLoadoutOptions(talentsFrame);
    end

    -- Reset-order button (undo-arrow icon), visible only while the dropdown is open.
    resetButton = CreateResetButton(talentsFrame) or resetButton;

    -- Reconcile the moment the talent pane becomes visible. Without this, the first
    -- dropdown open after a reload shows Blizzard's default order: the pane's first
    -- population fires no TRAIT_CONFIG event we can react to, and our menu callback can
    -- only sort data that the description being generated has already consumed. OnShow
    -- runs after that population and before any human can open the dropdown, so the
    -- first paint already uses the saved order.
    if talentsFrame.HookScript and not showHookInstalled then
        showHookInstalled = true;
        talentsFrame:HookScript("OnShow", function()
            ns.Reconcile();
        end);
    end
end

-- Assign the forward-declared local (captured by OnModifyTalentMenuInner); do not shadow it.
InitializeTalentHooks = function()
    if hooksInstalled then return end

    -- Fail-open: hook installation must never raise into Blizzard's load flow.
    SafeInvoke("initHooks", InitializeTalentHooksInner);
end

ns.InitializeTalentHooks = InitializeTalentHooks;
ns._ResetHookStateForTest = function() -- private-suite seam: re-run installation
    hooksInstalled = false;
    showHookInstalled = false;
end

-- ----------------------------------------------------------------------------
-- Restriction State (WoW 12.x): lock taint-able interactions while protected
-- ----------------------------------------------------------------------------
-- Midnight gates tainted (addon) execution while ANY addon restriction is active
-- (Enum.AddOnRestrictionType: Combat, Encounter, ChallengeMode, PvPMatch, Map,
-- Chat -- six types; rated PvP and Mythic+ hold them essentially full-time, so
-- InCombatLockdown alone is the wrong check). While protected the addon must not
-- touch taint-able elements: no drag arming, no reset presses, no dropdown
-- writes, no gated setup -- and a /reload landing mid-protection must defer
-- setup instead of half-installing hooks that would fail silently.
--
-- Gate audit (vs Blizzard_APIDocumentationGenerated, 12.1 -- full table in
-- AGENTS.md): HookScript/SetScript, RegisterEvent/UnregisterEvent,
-- RegisterForDrag, SetPoint/SetSize/SetHeight, SetShown, PlaySound,
-- C_Timer.After, IsMouseButtonDown, C_ClassTalents.GetConfigIDsBySpecID,
-- C_Traits.GetConfigInfo and C_RestrictedActions.IsAddOnRestrictionActive itself
-- are all AllowedWhenUntainted. Safe while protected: Show/Hide (no gate
-- annotation -- used for all visibility toggles), SetAlpha (AllowedWhenTainted),
-- GetRect/GetCursorPosition, Menu.ModifyMenu + the menu-description proxy
-- whitelist. Chat AddMessage is equally gated -- and since notices neither
-- render while locked nor get read in combat, the addon emits none at all.
--
-- While locked: drags silently refuse, reconcile/sort requests queue instead
-- of writing, the reset button hides; everything flushes when protection
-- lifts (ADDON_RESTRICTION_STATE_CHANGED, PLAYER_REGEN_ENABLED backstop, login
-- backstops, next talent event -- whichever confirms clear outside dispatch
-- first). No chat output exists on any lock path: notices neither render while
-- protected nor get read in combat, so blocked input just does nothing.

local RESTRICTION_TYPE_FALLBACK = { 0, 1, 2, 3, 4, 5 }; -- Combat, Encounter, ChallengeMode, PvPMatch, Map, Chat
local RESTRICTION_STATE_FALLBACK = { inactive = 0, activating = 1, active = 2 };

local function GetRestrictionTypeIDs()
    if Enum and Enum.AddOnRestrictionType then
        local t = Enum.AddOnRestrictionType;
        local out = {};
        for _, id in ipairs({ t.Combat, t.Encounter, t.ChallengeMode, t.PvPMatch, t.Map, t.Chat }) do
            if id ~= nil then
                table.insert(out, id);
            end
        end
        if #out > 0 then
            return out;
        end
    end
    return RESTRICTION_TYPE_FALLBACK;
end

local function RestrictionStateID(name)
    if Enum and Enum.AddOnRestrictionState and Enum.AddOnRestrictionState[name] ~= nil then
        return Enum.AddOnRestrictionState[name];
    end
    return RESTRICTION_STATE_FALLBACK[name];
end

local RegisterAddonEvents; -- forward declaration: assigned after the event frame exists

-- Full all-types query. Must NEVER run during ADDON_RESTRICTION_STATE_CHANGED
-- dispatch (IsAddOnRestrictionActive reads false there by design); the event
-- handler below maintains per-type marks from the payload instead.
function ns.AreRestrictionsActive()
    if C_RestrictedActions and C_RestrictedActions.IsAddOnRestrictionActive then
        for _, rtype in ipairs(GetRestrictionTypeIDs()) do
            local ok, active = pcall(C_RestrictedActions.IsAddOnRestrictionActive, rtype);
            if ok and active then
                return true;
            end
        end
        return false;
    end
    if InCombatLockdown then
        return InCombatLockdown() and true or false;
    end
    return false;
end

-- Live check: the flag covers dispatch windows where the query reads false by
-- design; the query covers events missed while a registration was down. Either
-- side locks. Callers are input/event-driven (never per-frame), so the handful
-- of pcall'd queries per gesture is negligible -- OnUpdate pre-filters on drag
-- state before asking.
function ns.IsInteractionLocked()
    return restrictionsActive or ns.AreRestrictionsActive();
end

local function ApplyRestrictionsActive()
    restrictionsActive = true;
    ns.CancelDrag();
    if UpdateResetButton then UpdateResetButton(); end
end

local function ApplyRestrictionsCleared()
    restrictionsActive = false;
    wipe(restrictedTypes);
    ns.EnsureGatedInit();
    if reconcileQueued then
        reconcileQueued = false;
        ns.Reconcile();
    end
    if UpdateResetButton then UpdateResetButton(); end
end

-- Re-query outside event dispatch; clears the lock only when every type is idle.
local function ConfirmRestrictionsCleared()
    if not ns.AreRestrictionsActive() then
        ApplyRestrictionsCleared();
    end
end

-- Re-query and apply whichever side is true. Both sides are silent: no chat
-- output exists on any lock path (verified in game -- notices neither render
-- while protected nor get read in combat, so blocked input just does nothing).
-- Clear side is cheap when there is nothing to resume: only a lock episode, a
-- deferred init, a queued reconcile, or a never-installed hook runs the full
-- resume. Zone crossings fire often -- the common case is just the query.
local function RefreshRestrictionState()
    if ns.AreRestrictionsActive() then
        ApplyRestrictionsActive();
        return true;
    end
    if restrictionsActive or gatedInitDeferred or reconcileQueued or not hooksInstalled then
        ApplyRestrictionsCleared();
    elseif UpdateResetButton then
        -- Already clear with nothing to resume (e.g. combat ended but no lock
        -- episode was ever latched): the reset button may still need showing.
        UpdateResetButton();
    end
    return false;
end

-- Idempotent gated setup: (re)registers events and installs talent hooks. Safe
-- to call from any event or menu callback; defers (and remembers) while
-- protected so a /reload-in-combat never half-installs silently.
function ns.EnsureGatedInit()
    if ns.AreRestrictionsActive() then
        gatedInitDeferred = true;
        return false;
    end
    gatedInitDeferred = false;
    if RegisterAddonEvents then RegisterAddonEvents(); end
    InitializeTalentHooks();
    return true;
end

function ns.IsGatedInitDeferred()
    return gatedInitDeferred;
end

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

local function OnAddonEvent(self, event, arg1, arg2)
    if event == "ADDON_LOADED" then
        if arg1 == ADDON_NAME then
            if IsAddOnLoadedSafe("Blizzard_PlayerSpells") or IsAddOnLoadedSafe("Blizzard_ClassTalentUI") then
                ns.EnsureGatedInit();
            end
        elseif arg1 == "Blizzard_PlayerSpells" or arg1 == "Blizzard_ClassTalentUI" then
            ns.EnsureGatedInit();
        end
    elseif event == "ADDON_RESTRICTION_STATE_CHANGED" then
        -- Payload is (restrictionType, newState). IsAddOnRestrictionActive reads
        -- FALSE during this dispatch by design, so never query here -- maintain
        -- per-type marks from the payload and confirm outside dispatch.
        if arg2 == RestrictionStateID("inactive") then
            if arg1 ~= nil then restrictedTypes[arg1] = nil; end
            if next(restrictedTypes) == nil then
                if C_Timer and C_Timer.After then
                    C_Timer.After(0, ConfirmRestrictionsCleared);
                end
            end
        else
            -- Activating (fired before enforcement starts), Active, or unknown.
            if arg1 ~= nil then restrictedTypes[arg1] = true; end
            ApplyRestrictionsActive();
        end
    elseif event == "PLAYER_REGEN_DISABLED" then
        -- Entering combat: cancel drags immediately; mark locked only if the
        -- query agrees. The lock transition is silent by design.
        ns.CancelDrag();
        if ns.AreRestrictionsActive() then
            ApplyRestrictionsActive();
        end
    elseif event == "PLAYER_REGEN_ENABLED" then
        -- Backstop wake-up: covers a restriction-changed registration missed
        -- during a /reload-in-combat.
        RefreshRestrictionState();
    elseif event == "PLAYER_LOGIN" or event == "PLAYER_ENTERING_WORLD" then
        if IsAddOnLoadedSafe("Blizzard_PlayerSpells") or IsAddOnLoadedSafe("Blizzard_ClassTalentUI") then
            ns.EnsureGatedInit();
        end
        if event == "PLAYER_LOGIN" then
            -- Midnight: restricted-data predicates (CanPlayerUseTalentUI, talent config
            -- reads, ...) stay pending right after a reload until the player's first real
            -- input finalizes them -- pressing the talent keybind before that silently
            -- no-ops. Reconcile at the moment of first movement (when the pane becomes
            -- usable), with late bounded fallbacks for players who never move.
            -- Every Reconcile queues harmlessly while locked.
            if C_Timer and C_Timer.After then
                for _, delay in ipairs({ 5, 15, 30 }) do
                    C_Timer.After(delay, ns.Reconcile);
                end
            end
        else
            -- Loading-screen zone change (dungeon/arena/instance entry): check
            -- protected status first (M+/rated maps restrict on entry), then
            -- reconcile the new zone's data (queues while locked).
            RefreshRestrictionState();
            ScheduleReconcile();
        end
    elseif event == "ZONE_CHANGED" or event == "ZONE_CHANGED_NEW_AREA" then
        -- Zone change without a loading screen (zone-line crossings, M+/arena
        -- boundary transitions): same protected-status check -- rated PvP and
        -- Mythic+ hold restrictions while out of combat -- then reconcile.
        RefreshRestrictionState();
        ScheduleReconcile();
    elseif event == "PLAYER_STARTED_MOVING" then
        if self and self.UnregisterEvent then
            self:UnregisterEvent("PLAYER_STARTED_MOVING");
        end
        ns.Reconcile();
    elseif event == "TRAIT_CONFIG_LIST_UPDATED" or event == "TRAIT_CONFIG_CREATED"
        or event == "TRAIT_CONFIG_DELETED" or event == "ACTIVE_PLAYER_SPECIALIZATION_CHANGED" then
        -- Resume backstop: protection lifting without a caught restriction event
        -- still reinstalls + flushes on the next talent event.
        ns.EnsureGatedInit();
        ScheduleReconcile();
    end
end

local function OnAddonUpdate(self, elapsed)
    -- OnUpdate only services click-and-hold drag state; list reconciliation is event-driven.
    -- Idle frames return before the lock check (the query costs a few C calls --
    -- nothing per-frame). While locked an in-flight gesture is cancelled: the
    -- activation path already did, so reaching here means a missed event.
    if not potentialDrag and not isDragging then return end
    if ns.IsInteractionLocked() then
        ns.CancelDrag();
        return;
    end

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
end

-- All event/script installs funnel through here so a deferred boot can retry
-- them idempotently once protection lifts. Re-registering an event is a no-op
-- and scripts are simply replaced.
RegisterAddonEvents = function()
    if not eventFrame then return end
    eventFrame:RegisterEvent("ADDON_LOADED");
    eventFrame:RegisterEvent("PLAYER_LOGIN");
    eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD");
    eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED");
    eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED");
    eventFrame:RegisterEvent("ADDON_RESTRICTION_STATE_CHANGED");
    eventFrame:RegisterEvent("PLAYER_STARTED_MOVING");
    -- Zone changes: with a loading screen (ENTERING_WORLD above) and without
    -- one -- both re-check protected status (M+/rated zones restrict on entry).
    eventFrame:RegisterEvent("ZONE_CHANGED");
    eventFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA");
    -- The same events Blizzard's ClassTalentFrame uses to drive the loadout dropdown.
    eventFrame:RegisterEvent("TRAIT_CONFIG_LIST_UPDATED");
    eventFrame:RegisterEvent("TRAIT_CONFIG_CREATED");
    eventFrame:RegisterEvent("TRAIT_CONFIG_DELETED");
    eventFrame:RegisterEvent("ACTIVE_PLAYER_SPECIALIZATION_CHANGED");
    eventFrame:SetScript("OnEvent", OnAddonEvent);
    eventFrame:SetScript("OnUpdate", OnAddonUpdate);
end

RegisterAddonEvents();

-- Register with Blizzard Menu framework (available in 11.0+).
if Menu and Menu.ModifyMenu then
    Menu.ModifyMenu("MENU_CLASS_TALENT_PROFILE", OnModifyTalentMenu);
end

-- Boot-time restriction evaluation: a /reload landing mid-protection silently
-- defers all gated setup instead of half-installing hooks that would fail
-- silently. Recovery order on lift: restriction-changed confirm, regen-enabled,
-- login backstops, next talent event, next dropdown open.
SafeInvoke("bootstrap", function()
    ns.EnsureGatedInit();
end);

