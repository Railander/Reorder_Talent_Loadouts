--[[
    Reorder Talent Loadouts
    Author: Railander
    Description: Allows reordering talent loadouts in Retail World of Warcraft
                 by click-and-holding and moving them in the loadout dropdown.

    TAINT MODEL (12.x) -- the whole design follows from these rules:
    * The addon's product is DATA: the order of loadout config IDs. It rewrites
      `loadSystem.possibleSelections` in place from addon execution, which is the
      supported data-level path (read/sort/mutate the data, never call the
      frame's restricted methods).
    * No Blizzard method that runs a restricted C read or rebuilds menu
      descriptions is called from addon execution: no RefreshLoadoutOptions,
      no SetSelectionOptions, no UpdateSelectionOptions, no GenerateMenu.
      Those are the calls that taint the loadout/commit path.
    * Blizzard-facing integrations, all deliberate:
      - the sanctioned menu surface: Menu.ModifyMenu and the menu proxy
        whitelist (GetData, SetCanSelect, AddInitializer,
        AddMenuReleasedCallback, EnumerateElementDescriptions);
      - a HookScript("OnShow") post-hook on the talent pane (first-open sort);
      - HookScript OnMouseDown/OnMouseUp + SetScript OnDragStart/OnDragStop
        on the pooled menu-item buttons (drag), re-installed every generation
        because the menu pool resets released frames (see SetupLoadoutButton);
      - `loadSystem.nameTranslation` is wrapped ONLY when a degraded
        repopulation restores IDs that Blizzard's name cache lacks;
      - `talentsFrame.enableCommitCastBar` is forced false (cast-bar taint fix;
        never while a commit is running).
      There is no hooksecurefunc anywhere.
    * SetCanSelect runs inside securecallfunction at click time; the dropdown's
      SignalUpdate also calls it directly, where it only reads addon flags.
    * Refreshing an OPEN dropdown is done by closing and reopening it on the next
      frame, both calls routed through securecallfunction so the cycle runs in
      Blizzard's secure execution context, as a user click does. Blizzard's own
      OpenMenu owns generation (the description generator runs under
      securecallfunction).
    * Drag input needs scripts on the pooled menu-item buttons. OnMouseDown/
      OnMouseUp are post-hooks (Blizzard assigns OnMouseDown after our
      initializer, so SetScript there would be replaced); OnDragStart/OnDragStop
      are ours alone and are re-set on every generation, because releasing a
      pooled menu frame runs SetToDefaults and drops its scripts. Those buttons
      hold plain loadout rows, never unit/combat/aura data.
--]]

local ADDON_NAME, ns = ...;

-- Global Database
ReorderTalentLoadoutsDB = ReorderTalentLoadoutsDB or {};
if type(ReorderTalentLoadoutsDB) ~= "table" then
    -- A hand-edited or corrupted SavedVariables root must not break every read.
    ReorderTalentLoadoutsDB = {};
end

-- The addon is built fail-open: an internal error must never break Blizzard's menu
-- generation or the talent frame init chain; errors are reported to chat (once per
-- scope) and swallowed.
local reportedErrors = {};

local unpack = unpack or table.unpack;

-- Runs fn(...) while converting any error into a captured report.
-- This guarantees the calling (Blizzard) execution chain always continues.
-- NOTE: WoW runs Lua 5.1, where xpcall takes exactly (fn, errfunc) and silently
-- drops any further arguments -- so fn must be closed over its arguments here.
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
                -- Best-effort report: the error path must stay fail-open too, so a
                -- refused or throwing AddMessage can never escape into the caller.
                pcall(DEFAULT_CHAT_FRAME.AddMessage, DEFAULT_CHAT_FRAME,
                    "|cffff3333Reorder Talent Loadouts [" .. scope .. "] error:|r " .. err);
            end
        end
        return false;
    end
    return true;
end

-- Calls a Blizzard function in secure execution when the client provides
-- securecallfunction (12.x does), so an addon-initiated UI cycle has the same
-- taint profile as the user's own click. Falls back to a plain call when the
-- client does not provide it.
local function SecureCall(fn, ...)
    if securecallfunction then
        return securecallfunction(fn, ...);
    end
    return fn(...);
end

-- Local state
local isDragging = false;
local potentialDrag = false;
local justFinishedDragging = false;
local dragSourceConfigID = nil;
local dragSourceButton = nil;
local dragStartX, dragStartY = 0, 0;
local currentDropTargetIndex = nil;
local trackedButtons = {}; -- addon-side registry of loadout menu buttons: { button, configID }
local hookedButtons = setmetatable({}, { __mode = "k" }); -- pooled buttons that already carry our hooks
local insertionLine = nil;
local resetButton = nil;
local paneHooked = false;
local menuCallbacksInstalled = false;
-- The talent frame/load system of the menu currently being generated. Used as a
-- fallback when a pooled button's parent chain is unavailable (e.g. during
-- release, after the menu description is gone).
local activeTalentsFrame = nil;
local activeLoadSystem = nil;

local UpdateResetButton; -- forward declaration: refreshes reset-button visibility
local ArmDragPump;       -- forward declaration: attaches the drag OnUpdate
local EnsureChrome;      -- forward declaration: creates the reset button + dropdown hooks
local ScheduleReconcile; -- forward declaration (used by ReconcileInner deferral)

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

-- Copies `sorted` into `tbl` in place and trims the tail. The table identity is
-- preserved: Blizzard's menu generator captures the table, not a copy.
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

-- A hand-edited order can contain a nil hole. ipairs stops at the first hole,
-- so every entry after it would silently vanish from the next save even though
-- the client still reports those loadouts. Compact the numeric keys once, in
-- index order, so a still-existing entry keeps its slot.
local function CompactOrder(order)
    local keys, maxIndex = {}, 0;
    for key in pairs(order) do
        if type(key) == "number" and key >= 1 and key == math.floor(key) then
            table.insert(keys, key);
            if key > maxIndex then maxIndex = key; end
        end
    end
    if #keys == maxIndex then
        return order; -- already a clean sequence
    end
    table.sort(keys);
    local compact = {};
    for _, key in ipairs(keys) do
        table.insert(compact, order[key]);
    end
    return compact;
end

-- An order entry is usable only in its canonical shape. Anything else (a bare
-- array from hand-editing, a scalar from corruption, a missing names map) is
-- treated as absent -- never raised on. Saved databases have carried this shape
-- since the first release, and every version reads it through this function.
local function AsOrderEntry(bucket, specID)
    if type(bucket) ~= "table" then
        return nil;
    end
    local entry = bucket[specID];
    if type(entry) == "table" and type(entry.order) == "table" then
        entry.order = CompactOrder(entry.order);
        return entry;
    end
    return nil;
end

function ns.GetSavedOrder(playerKey, specID)
    if type(ReorderTalentLoadoutsDB) ~= "table" or not specID then
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

-- fallbackNames supplies names for entries the current names map lacks (saved
-- loadouts kept while absent from the visible list).
function ns.SaveOrder(playerKey, specID, orderList, configIDToName, fallbackNames)
    if not playerKey or not specID or not orderList then return end

    if type(ReorderTalentLoadoutsDB) ~= "table" then
        ReorderTalentLoadoutsDB = {};
    end

    -- A corrupt (non-table) character bucket is replaced, not indexed into.
    if type(ReorderTalentLoadoutsDB[playerKey]) ~= "table" then
        ReorderTalentLoadoutsDB[playerKey] = {};
    end

    local namesMap = {};
    for _, id in ipairs(orderList) do
        -- Empty is not a name: Blizzard writes "" when GetConfigInfo fails for
        -- an ID. Fall back to the last saved name instead of erasing it, so a
        -- transient read failure cannot destroy the name-based safety net.
        local name = configIDToName and configIDToName[id];
        if not name or name == "" then
            name = fallbackNames and fallbackNames[id];
        end
        if name and name ~= "" then
            namesMap[id] = name;
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

local function StarterBuildID()
    return Constants and Constants.TraitConsts and Constants.TraitConsts.STARTER_BUILD_TRAIT_CONFIG_ID;
end

-- The spec's real loadouts from the client, or nil when the read fails or comes
-- back empty (degraded) -- nil means "unknown", never "everything deleted".
local function GetLiveConfigIDs(specID)
    if not specID or not C_ClassTalents or not C_ClassTalents.GetConfigIDsBySpecID then
        return nil;
    end
    local ok, ids = pcall(C_ClassTalents.GetConfigIDsBySpecID, specID);
    if not ok or type(ids) ~= "table" or #ids == 0 then
        return nil;
    end
    return ids;
end

local function GetLiveConfigSet(specID)
    local ids = GetLiveConfigIDs(specID);
    if not ids then return nil; end
    local set = {};
    for _, id in ipairs(ids) do set[id] = true; end
    return set;
end

-- The persisted order is the visible order plus every saved entry that is merely
-- absent from it right now (a partial or degraded population), each kept right
-- after its saved predecessor. isGone(id) marks entries that must be dropped.
function ns.MergeAbsent(visible, savedOrder, isGone)
    local inVisible = {};
    for _, id in ipairs(visible) do inVisible[id] = true; end
    local seen = {};
    local after = {};
    local anchor = false; -- false = before the first visible entry
    for _, id in ipairs(savedOrder or {}) do
        if inVisible[id] then
            -- Only the first occurrence anchors; duplicates are ignored below.
            if not seen[id] then
                seen[id] = true;
                anchor = id;
            end
        elseif not seen[id] and not isGone(id) then
            -- A kept entry is NOT visible, so a duplicate of it must never
            -- become the anchor: later absent entries would be filed under an
            -- ID the merge loop never walks and silently disappear.
            seen[id] = true;
            after[anchor] = after[anchor] or {};
            table.insert(after[anchor], id);
        end
    end
    local merged = {};
    for _, id in ipairs(after[false] or {}) do table.insert(merged, id); end
    for _, id in ipairs(visible) do
        table.insert(merged, id);
        for _, kept in ipairs(after[id] or {}) do table.insert(merged, kept); end
    end
    return merged;
end

-- Saved entries absent from the visible list are dropped from the DB only when the
-- client confirms they no longer exist. A name re-identification is a guess
-- (Blizzard allows duplicate names), so it never purges on its own: only a
-- successful, non-empty GetConfigIDsBySpecID that lacks the ID proves it is gone.
local function MakeIsGone(specID)
    local starterID = StarterBuildID();
    local live, queried = nil, false;
    return function(id)
        -- GetConfigIDsBySpecID does NOT include the Starter Build: Blizzard
        -- appends it separately in RefreshLoadoutOptions. Treating that list as
        -- complete would purge the Starter Build's saved slot whenever the
        -- visible list is degraded (the exact case this fallback exists for).
        if starterID ~= nil and id == starterID then return false; end;
        if not queried then
            queried = true;
            live = GetLiveConfigSet(specID);
        end
        -- nil live means "unknown", never "everything deleted": keep the slot.
        return live ~= nil and not live[id];
    end;
end

local function NamesChanged(order, savedNames, configIDToName)
    if not configIDToName then return false; end
    for _, id in ipairs(order) do
        local name = configIDToName[id];
        if name and name ~= "" and (type(savedNames) ~= "table" or savedNames[id] ~= name) then
            return true;
        end
    end
    return false;
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
    if not saved or #saved.order == 0 then
        return currentConfigIDs;
    end
    local savedNames = type(saved.names) == "table" and saved.names or nil;

    local currentSet = {};
    local nameToCurrentID = {};
    local nameCount = {};
    for _, id in ipairs(currentConfigIDs) do
        currentSet[id] = true;
        local name = configIDToName and configIDToName[id];
        if name and name ~= "" then
            nameToCurrentID[name] = id;
            nameCount[name] = (nameCount[name] or 0) + 1;
        end
    end

    local result = {};
    local placed = {};

    -- Saved IDs that are still visible are already owned by their own entry.
    -- A name re-identification must never steal one of them: deleting one of two
    -- same-named loadouts makes the survivor's name unique among the visible
    -- rows, and mapping the deleted entry onto it would move the survivor.
    local owned = {};
    for _, savedID in ipairs(saved.order) do
        if currentSet[savedID] then owned[savedID] = true; end
    end

    -- 1. Place all saved IDs in their saved order. A name re-identification
    -- never purges the old ID here: MergeAbsent keeps the old slot until a
    -- successful ground-truth read proves the ID is gone.
    for _, savedID in ipairs(saved.order) do
        local idToPlace = nil;
        if currentSet[savedID] then
            idToPlace = savedID;
        elseif savedNames and savedNames[savedID] then
            -- ConfigID changed (e.g. server transfer or patch), but name matched.
            -- Only a UNIQUE, unowned name identifies an entry: Blizzard allows
            -- duplicate loadout names, and guessing could swap two same-named
            -- loadouts.
            local name = savedNames[savedID];
            local target = nameCount[name] == 1 and nameToCurrentID[name];
            if target and not owned[target] then
                idToPlace = target;
            end
        end

        if idToPlace and not placed[idToPlace] then
            table.insert(result, idToPlace);
            placed[idToPlace] = true;
        end
    end

    -- 2. Append current IDs missing from the saved order (new loadouts). Like
    -- Blizzard's default list, they go above a trailing Starter Build.
    local starterID = StarterBuildID();
    local insertAt = nil;
    if starterID ~= nil and result[#result] == starterID then
        insertAt = #result;
    end
    for _, id in ipairs(currentConfigIDs) do
        if not placed[id] then
            if insertAt then
                table.insert(result, insertAt, id);
                insertAt = insertAt + 1;
            else
                table.insert(result, id);
            end
            placed[id] = true;
        end
    end

    -- 3. Persist when the order or any name moved on (no rewrite churn otherwise).
    local persisted = ns.MergeAbsent(result, saved.order, MakeIsGone(specID));
    if not ns.ArraysEqual(persisted, saved.order) or NamesChanged(result, savedNames, configIDToName) then
        ns.SaveOrder(playerKey, specID, persisted, configIDToName, savedNames);
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
            -- pcall: name resolution must never raise into sort/refresh paths.
            local ok, info = pcall(C_Traits.GetConfigInfo, id);
            if ok and info and info.name and info.name ~= "" then
                map[id] = info.name;
            end
        end
    end
    return map;
end

local function GetTalentsFrame(ownerRegion)
    if PlayerSpellsFrame and PlayerSpellsFrame.TalentsFrame then
        return PlayerSpellsFrame.TalentsFrame;
    end
    if ownerRegion and ownerRegion.GetParent then
        local parent = ownerRegion:GetParent();
        if parent and parent.possibleSelections and (parent.GetDropdown or parent.Dropdown) then
            local grandParent = parent:GetParent();
            if grandParent and grandParent.configIDs then
                return grandParent;
            end
        end
    end
    return nil;
end

local function GetLoadSystem(ownerRegion)
    local talentsFrame = GetTalentsFrame(ownerRegion);
    if talentsFrame and talentsFrame.LoadSystem then
        return talentsFrame.LoadSystem;
    end
    if ownerRegion and ownerRegion.GetParent then
        local parent = ownerRegion:GetParent();
        if parent and parent.possibleSelections and (parent.GetDropdown or parent.Dropdown) then
            return parent;
        end
    end
    return nil;
end

-- IMPORTANT (WoW 12.x taint): Blizzard's talent-commit feedback can swap the real
-- player cast bar out for OverlayPlayerCastingBarFrame and back via
-- PlayerCastingBarFrame:SetAndUpdateShowCastbar(false/true). A loadout picked in the
-- dropdown runs on the list this addon reordered (loadSystem.possibleSelections),
-- so that swap can run on a tainted path, and PlayerCastingBarFrame's Show() is
-- then refused in combat: the bar disappears until /reload.
-- enableCommitCastBar is an optional talent-frame mode (the shared talent template
-- defaults it OFF; ClassTalentFrame opts in), and the commit spinner covers the
-- same feedback. Opting out keeps the real player cast bar out of the commit path.
-- This is a plain boolean field -- no Blizzard method or restricted API is touched.
-- IMPORTANT: never flip it while commit visuals are active. SetCommitVisualsActive(false)
-- only calls SetCommitCastBarActive(false) when the flag is truthy, so a flip in
-- the middle of a commit would skip EndReplacingPlayerBar and strand the real cast
-- bar hidden until /reload. That window is wider than IsCommitInProgress(): the
-- New-Loadout / import path runs SetCommitVisualsActive(true) with no committed
-- config, and areBaseCommitVisualsActive covers both windows. A commit that started
-- with the mode on already has the bar enabled; the next generation/event flips it
-- after the visuals end.
local function OptOutOfCommitCastBar(talentsFrame)
    if not (talentsFrame and talentsFrame.enableCommitCastBar) then
        return;
    end
    if (talentsFrame.IsCommitInProgress and talentsFrame:IsCommitInProgress())
        or talentsFrame.areBaseCommitVisualsActive then
        return;
    end
    talentsFrame.enableCommitCastBar = false;
end

-- ----------------------------------------------------------------------------
-- Selection writes (the addon's only mutation of Blizzard state)
-- ----------------------------------------------------------------------------

-- Writes a list into loadSystem.possibleSelections IN PLACE. Pure data: no
-- LoadSystem method (SetSelectionOptions would re-run SetupMenu/GenerateMenu),
-- no UpdateSelectionOptions, no window calls. Table identity is preserved.
local function WriteSelections(loadSystem, list)
    local target = loadSystem.possibleSelections;
    if type(target) ~= "table" then
        target = {};
        loadSystem.possibleSelections = target;
    end
    ns.SortInPlace(target, list);
    return target;
end

-- Blizzard's name translator reads talentsFrame.configIDToName, which does not
-- contain loadouts restored from C_ClassTalents in a degraded state. When that
-- happens, wrap the LOAD SYSTEM's translator (never the talent frame) with a
-- pcall'd C_Traits fallback. The generator calls it inside its secure generation,
-- and it only ever returns a string.
local nameFallbacks = setmetatable({}, { __mode = "k" });

local function InstallNameFallback(loadSystem)
    local current = loadSystem.nameTranslation;
    if current ~= nil and nameFallbacks[loadSystem] == current then
        return;
    end
    local base = current;
    local function fallbackName(configID)
        local name = base and base(configID);
        if name then return name; end
        if C_Traits and C_Traits.GetConfigInfo then
            local ok, info = pcall(C_Traits.GetConfigInfo, configID);
            if ok and info and info.name then
                return info.name;
            end
        end
        return "";
    end
    nameFallbacks[loadSystem] = fallbackName;
    loadSystem.nameTranslation = fallbackName;
end

-- ----------------------------------------------------------------------------
-- Dropdown refresh (no GenerateMenu / SetSelectionOptions from addon code)
-- ----------------------------------------------------------------------------

local function GetDropdown(loadSystem)
    return loadSystem and loadSystem.GetDropdown and loadSystem:GetDropdown();
end

local function IsDropdownOpen(dropdown)
    return dropdown ~= nil and dropdown.IsMenuOpen ~= nil and dropdown:IsMenuOpen();
end

-- Refresh an OPEN dropdown by closing and reopening it on the next frame,
-- through securecallfunction: Blizzard's OpenMenu owns generation (its
-- description generator and menu.Open run under securecallfunction), and the
-- secure wrapper gives the whole cycle the same execution profile as a user
-- click. The close and reopen land in the same frame, before rendering, so the
-- flicker is not visible. When the dropdown is closed (most of the game) this
-- is a no-op: the next open reads the sorted data anyway.
-- Pending refresh per dropdown: a request for one dropdown must never suppress
-- another's, and a lost timer must not latch the whole session off.
local refreshPending = setmetatable({}, { __mode = "k" });

local function RefreshDropdownSoon(dropdown)
    if not dropdown or refreshPending[dropdown] then return end
    if not IsDropdownOpen(dropdown) then return end
    if not (dropdown.CloseMenu and dropdown.OpenMenu) then return end
    if not (C_Timer and C_Timer.After) then return end

    refreshPending[dropdown] = true;
    local ok = pcall(C_Timer.After, 0, function()
        refreshPending[dropdown] = nil;
        if not IsDropdownOpen(dropdown) then return; end -- user closed it first
        -- A disabled dropdown cannot be reopened (OpenMenu early-returns), so
        -- closing it would leave it closed: leave it as-is.
        if dropdown.IsEnabled and not dropdown:IsEnabled() then return; end
        -- Two guarded steps: if closing raises, still try to reopen, otherwise
        -- the user's open menu would simply be gone.
        SafeInvoke("refreshClose", function()
            SecureCall(dropdown.CloseMenu, dropdown);
        end);
        SafeInvoke("refreshOpen", function()
            SecureCall(dropdown.OpenMenu, dropdown);
        end);
    end);
    if not ok then
        refreshPending[dropdown] = nil;
    end
end

-- ----------------------------------------------------------------------------
-- UI Indicators (Drag Preview & Insertion Line)
-- ----------------------------------------------------------------------------

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
    local entry = button and ns.FindTrackedEntry(button);
    if isDragging or not entry then
        return;
    end

    CreateUIElements();

    isDragging = true;
    potentialDrag = false;
    dragSourceButton = button;
    dragSourceConfigID = entry.configID;

    -- Dim the source row to visually distinguish it
    button:SetAlpha(0.35);
    ArmDragPump();

    ns.UpdateDrag();
end

function ns.StartDrag(button)
    -- Fail-open: drag start must never raise into Blizzard input handling.
    SafeInvoke("startDrag", StartDragInner, button);
end

local function UpdateDragInner()
    if not isDragging then return end

    -- A failed read or anchor must never leave the previous frame's target
    -- behind: the release would then reorder to an index the cursor has left.
    currentDropTargetIndex = nil;

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
    local lastBottom = select(2, lastBtn:GetRect());
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
        local left, bottom, _, height = btn:GetRect();
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

-- Ends the press/drag gesture: clears all drag state and restores visuals. Returns
-- what the drop needs (whether a drag was live, its source and target).
local function EndGesture()
    local result = {
        wasDragging = isDragging,
        sourceButton = dragSourceButton,
        sourceConfigID = dragSourceConfigID,
        targetIndex = currentDropTargetIndex,
    };
    isDragging = false;
    potentialDrag = false;
    dragSourceButton = nil;
    dragSourceConfigID = nil;
    currentDropTargetIndex = nil;

    -- Suppress click selection/sound for a brief moment after releasing.
    -- Fail-open: the guard window must end even if the client refuses the timer;
    -- a stuck flag would refuse every loadout click until /reload.
    justFinishedDragging = true;
    if C_Timer and C_Timer.After then
        local scheduled = pcall(C_Timer.After, 0.2, function()
            justFinishedDragging = false;
        end);
        if not scheduled then
            justFinishedDragging = false;
        end
    else
        justFinishedDragging = false;
    end

    if insertionLine then insertionLine:Hide(); end
    if result.sourceButton then
        result.sourceButton:SetAlpha(1.0);
    end
    return result;
end

local function FinishDragInner()
    if not isDragging and not potentialDrag then
        return;
    end

    local drop = EndGesture();
    if not drop.wasDragging or not drop.targetIndex or not drop.sourceConfigID then
        return;
    end

    local talentsFrame = GetTalentsFrame(drop.sourceButton) or activeTalentsFrame;
    local loadSystem = GetLoadSystem(drop.sourceButton) or activeLoadSystem;
    if not talentsFrame or not loadSystem then
        return;
    end

    local possibleSelections = loadSystem.possibleSelections;
    if not possibleSelections or #possibleSelections <= 1 then
        return;
    end

    -- Find source index
    local fromIndex = nil;
    for i, id in ipairs(possibleSelections) do
        if id == drop.sourceConfigID then
            fromIndex = i;
            break;
        end
    end
    if not fromIndex then return end

    -- Calculate new list
    local newList, moved = ns.CalculateNewOrder(CopyTable(possibleSelections), fromIndex, drop.targetIndex);
    if not moved then
        return;
    end

    -- Persist the new order (saved loadouts absent from the list right now keep their slot)
    local specID = ns.GetSpecID(talentsFrame);
    local configIDToName = ns.GetConfigIDToName(talentsFrame, newList);

    local playerKey = ns.GetPlayerKey();
    if playerKey and specID then
        local saved = ns.GetSavedOrder(playerKey, specID);
        local persisted = newList;
        local savedNames = nil;
        if saved then
            savedNames = type(saved.names) == "table" and saved.names or nil;
            persisted = ns.MergeAbsent(newList, saved.order, MakeIsGone(specID));
        end
        ns.SaveOrder(playerKey, specID, persisted, configIDToName, savedNames);
    end

    -- Apply the order at the DATA level only. Never mutate talentsFrame.configIDs:
    -- that is Blizzard's ground-truth list and is read by restricted C APIs.
    WriteSelections(loadSystem, newList);

    -- No addon sound: the close+reopen refresh already plays Blizzard's own
    -- dropdown close/open sounds, and three sounds for one drop is noise.

    -- The open menu still shows the old data; close+reopen it on the next frame.
    RefreshDropdownSoon(GetDropdown(loadSystem));
end

function ns.FinishDrag()
    -- Fail-open: the drop applies the persisted order; never raise into input handlers.
    SafeInvoke("finishDrag", FinishDragInner);
    if UpdateResetButton then SafeInvoke("resetVisibility", UpdateResetButton); end
end

function ns.CancelDrag()
    -- Fail-open: this runs from Blizzard's menu-released callback; a throw here
    -- would abort the menu teardown. State is cleared before any visual restore,
    -- so a failing restore still leaves no half-armed gesture behind.
    SafeInvoke("cancelDrag", function()
        if isDragging or potentialDrag then
            EndGesture();
        end
    end);
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

-- Drag handlers (named so the installation below can tell whether they survived).
-- OnDragStart/OnDragStop are OURS ALONE: Blizzard's menu templates never assign
-- them, so SetScript is safe and, unlike a hook, is not tied to a base script.
-- OnMouseDown/OnMouseUp must be post-hooks: Blizzard assigns OnMouseDown AFTER
-- our initializer (Menu.lua InitializeFrame), and SetScript would replace it.
local function OnRowMouseDown(self, mouseButton)
    if mouseButton ~= "LeftButton" then return end
    SafeInvoke("drag-input", function()
        local e = ns.FindTrackedEntry(self);
        if not e or IsMouseOverUtilityButton(self) then
            return;
        end
        -- Read the cursor before arming anything: a failed read must leave no
        -- half-armed gesture behind.
        local x, y = GetCursorPosition();
        potentialDrag = true;
        ArmDragPump();
        dragSourceButton = self;
        dragSourceConfigID = e.configID;
        dragStartX, dragStartY = x, y;
    end);
end

local function OnRowMouseUp(self, mouseButton)
    if mouseButton ~= "LeftButton" then return end
    SafeInvoke("drag-input", function()
        if isDragging then
            ns.FinishDrag();
        elseif potentialDrag then
            potentialDrag = false;
            dragSourceButton = nil;
            dragSourceConfigID = nil;
        end
    end);
end

local function OnRowDragStart(self)
    SafeInvoke("drag-input", function()
        if not IsMouseOverUtilityButton(self) then
            ns.StartDrag(self);
        end
    end);
end

local function OnRowDragStop()
    SafeInvoke("drag-input", function()
        if isDragging then
            ns.FinishDrag();
        end
    end);
end

-- Called from the sanctioned menu-description initializer. Button state lives in the
-- addon-side registry; the button itself only receives drag scripts (and they are
-- re-installed whenever a pooled frame comes back reset). Menu buttons are pooled
-- across every menu in the game, so every handler acts only while the button is a
-- tracked loadout row.
--
-- IMPORTANT (pooled menu rows): menu element frames are released to a shared pool
-- on EVERY menu close (Menu.lua DiscardChildFrames -> MenuElementFactory
-- :Release), and releasing one runs ResetMenuElement -> SetToDefaults, which returns
-- the frame to "just-created" state and drops its scripts. Our drop path closes and
-- reopens the menu after every move, so a once-only HookScript on OnDragStart/
-- OnDragStop silently stops firing after the first close: drags die after a
-- couple of moves and only /reload brings them back. Re-set the drag scripts on
-- every generation, and re-hook the mouse handlers when the frame came back reset.
function ns.SetupLoadoutButton(button, description, menu, configID)
    local entry = ns.FindTrackedEntry(button);
    if entry then
        entry.configID = configID; -- pooled button re-used for a different entry
    else
        entry = { button = button, configID = configID };
        table.insert(trackedButtons, entry);
    end

    if button.RegisterForDrag then
        button:RegisterForDrag("LeftButton");
    end

    -- Did this pooled frame come back reset (fresh, or released and wiped by the
    -- pool)? Our own OnDragStart handler missing means yes. Check BEFORE setting
    -- it, so a repeated setup in the same generation does not stack the hooks.
    local reset = not (button.GetScript and button:GetScript("OnDragStart") == OnRowDragStart);

    if button.SetScript then
        button:SetScript("OnDragStart", OnRowDragStart);
        button:SetScript("OnDragStop", OnRowDragStop);
    end

    if button.HookScript and (not hookedButtons[button] or reset) then
        hookedButtons[button] = true;
        button:HookScript("OnMouseDown", OnRowMouseDown);
        button:HookScript("OnMouseUp", OnRowMouseUp);
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
        OptOutOfCommitCastBar(talentsFrame);
        activeTalentsFrame = talentsFrame;
        -- Chrome is created lazily here too: the dropdown exists exactly when the
        -- menu does, which is later than some ADDON_LOADED orderings.
        SafeInvoke("chrome", EnsureChrome, talentsFrame);
        -- Blizzard invokes ModifyMenu callbacks under securecallfunction; the
        -- callback only performs data-level writes either way (no frame method).
        ns.OnRefreshLoadoutOptions(talentsFrame);
    end
    activeLoadSystem = loadSystem;

    if InitializeTalentHooks then
        -- Self-heal for late-loading talent UI: re-registering is a no-op and
        -- hook installation is idempotent.
        ns.EnsureInit();
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
            activeTalentsFrame = nil;
            activeLoadSystem = nil;
        end);
    end

    for index, desc in rootDescription:EnumerateElementDescriptions() do
        if desc and desc.GetData then
            local data = desc:GetData();
            if data and selectionSet[data] then
                -- This description represents a loadout entry!
                SafeInvoke("menu-element", function()
                    -- Suppress click selection during/just after a drag. This runs
                    -- inside Menu's securecallfunction(SecureCanSelect), so its
                    -- taint is contained and cannot reach Pick()'s responder.
                    desc:SetCanSelect(function()
                        if isDragging or justFinishedDragging then
                            return false;
                        end
                        return true;
                    end);

                    -- Deliberately NO sound-kit wrapper here. MenuTemplates calls
                    -- the sound-kit function in OnButtonClick *before* Pick(),
                    -- outside any securecall: an addon closure at that spot taints
                    -- the whole click execution, which nullifies Pick()'s
                    -- securecall barriers and lets taint reach the loadout commit.
                    -- Blizzard's own button sound stays in place.

                    -- The initializer runs later on Blizzard's render path, outside
                    -- this SafeInvoke: keep it fail-open too, so a throwing install
                    -- can never blank the dropdown.
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
-- Talent Hooks (data-only)
-- ----------------------------------------------------------------------------

local hooksInstalled = false;
local lastSortWrote = false;

local function OnRefreshLoadoutOptionsInner(talentsFrame)
    lastSortWrote = false;
    if not talentsFrame or not talentsFrame.LoadSystem then return end
    if talentsFrame.IsInspecting and talentsFrame:IsInspecting() then return end

    local specID = ns.GetSpecID(talentsFrame);
    if not specID then return end

    local loadSystem = talentsFrame.LoadSystem;
    local currentSelections = loadSystem.possibleSelections;
    if not currentSelections or #currentSelections <= 1 then return end

    -- Cheap gate before resolving names through C_Traits.
    local saved = ns.GetSavedOrder(ns.GetPlayerKey(), specID);
    if not saved or #saved.order == 0 then return end

    local configIDToName = ns.GetConfigIDToName(talentsFrame, currentSelections);
    local sorted = ns.SortConfigIDs(specID, currentSelections, configIDToName);
    if not ns.ArraysEqual(currentSelections, sorted) then
        WriteSelections(loadSystem, sorted);
        lastSortWrote = true;
    end
end

local function OnRefreshLoadoutOptions(talentsFrame)
    -- Fail-open: never break Blizzard's execution chain. Returns whether the
    -- visible order was actually rewritten (the caller may refresh an open menu).
    SafeInvoke("refresh", OnRefreshLoadoutOptionsInner, talentsFrame);
    return lastSortWrote;
end
ns.OnRefreshLoadoutOptions = OnRefreshLoadoutOptions;

-- ----------------------------------------------------------------------------
-- Reconciliation (event-driven; data-only, merge-only)
-- ----------------------------------------------------------------------------
-- Restrictions (12.x) target unit/combat/aura data flowing through secrets into
-- marked objects -- not wholesale execution bans. Nothing this addon touches can
-- be secret-marked: menu buttons are plain loadout rows, config IDs are plain
-- numbers, and no unit/combat/aura data is ingested. Every operation therefore
-- attempts blindly under any restriction state; a refusal errors LOUDLY through
-- SafeInvoke (Bugsack) instead of hiding in a queue nobody reports.
--
-- Reconciliation only ever writes plain data:
--   * missing ground-truth loadouts are appended (merge-only, never removed),
--   * the saved order is applied in place.
-- It never rebuilds a menu, never calls a LoadSystem/Frame method, and never
-- touches talentsFrame.configIDs.

local reconcilePending = false;

local function ReconcileInner()
    -- Never reshape the data mid-drag: the drop owns the list until it finishes.
    if isDragging or potentialDrag then
        ScheduleReconcile();
        return;
    end

    local talentsFrame = GetTalentsFrame();
    if not talentsFrame or not talentsFrame.LoadSystem then return end
    if talentsFrame.IsInspecting and talentsFrame:IsInspecting() then return end

    -- A commit that was already running when we first met this frame may have
    -- kept the cast-bar mode on (OptOutOfCommitCastBar refuses mid-commit);
    -- flip it on the first event/timer after the commit ends.
    OptOutOfCommitCastBar(talentsFrame);

    local loadSystem = talentsFrame.LoadSystem;
    local current = loadSystem.possibleSelections;
    if type(current) ~= "table" then return end

    local wrote = false;
    local specID = ns.GetSpecID(talentsFrame);
    local groundIDs = GetLiveConfigIDs(specID);
    if groundIDs then
        local present = {};
        for _, id in ipairs(current) do present[id] = true; end
        local missing = {};
        for _, id in ipairs(groundIDs) do
            if not present[id] then
                table.insert(missing, id);
                present[id] = true;
            end
        end
        if #missing > 0 then
            local merged = {};
            for i, id in ipairs(current) do merged[i] = id; end
            for _, id in ipairs(missing) do table.insert(merged, id); end
            WriteSelections(loadSystem, merged);
            InstallNameFallback(loadSystem);
            wrote = true;
        end
    end

    -- Apply the saved order to the (possibly restored) list.
    local after = loadSystem.possibleSelections;
    if after and #after > 1 then
        if OnRefreshLoadoutOptions(talentsFrame) then wrote = true; end
    end

    -- Blizzard may have repopulated the list while the menu was open (our
    -- reorder is data-only), so an open menu showing the old order must be
    -- rebuilt. Closed menus do not need this; the next open reads the data.
    if wrote then
        RefreshDropdownSoon(GetDropdown(loadSystem));
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
        -- pcall: a failed timer must not latch reconciliation off forever.
        local ok = pcall(C_Timer.After, 0.25, function()
            reconcilePending = false;
            ns.Reconcile();
        end);
        if not ok then
            reconcilePending = false;
        end
    else
        reconcilePending = false;
        ns.Reconcile();
    end
end

ns.ScheduleReconcile = ScheduleReconcile;

-- ----------------------------------------------------------------------------
-- Reset (pure-Lua replica of Blizzard's default order; no frame methods)
-- ----------------------------------------------------------------------------

-- Resets the current spec's saved order and restores Blizzard's default order in
-- the dropdown. IMPORTANT (WoW 12.x taint rules): never call the frame's
-- RefreshLoadoutOptions method from addon execution; its body invokes the
-- restricted C_ClassTalents.GetConfigIDsBySpecID. The data write below is the
-- sanctioned data-level path.
--
-- Clear EVERY bucket GetSavedOrder can serve from. A legacy Name-Realm bucket
-- (written before UnitGUID was readable) otherwise resurrects the order the
-- user just reset, because GetSavedOrder falls back to it.
local function ClearSavedOrder(playerKey, specID)
    if type(ReorderTalentLoadoutsDB) ~= "table" then return end
    if type(ReorderTalentLoadoutsDB[playerKey]) == "table" then
        ReorderTalentLoadoutsDB[playerKey][specID] = nil;
    end
    if UnitName and GetRealmName then
        local name, realm = UnitName("player"), GetRealmName();
        if name and realm and name ~= "" and realm ~= "" then
            local altKey = name .. "-" .. realm;
            if altKey ~= playerKey and type(ReorderTalentLoadoutsDB[altKey]) == "table" then
                ReorderTalentLoadoutsDB[altKey][specID] = nil;
            end
        end
    end
end

function ns.ResetCurrentSpecOrder()
    local talentsFrame = GetTalentsFrame();
    local specID = ns.GetSpecID(talentsFrame);
    local playerKey = ns.GetPlayerKey();
    if not playerKey or not specID then return false; end

    ClearSavedOrder(playerKey, specID);

    local loadSystem = talentsFrame and talentsFrame.LoadSystem;
    if talentsFrame and loadSystem and type(talentsFrame.configIDs) == "table" then
        -- Merge-only: Blizzard's defaults first, then any entry another addon
        -- injected that Blizzard does not know about.
        local defaults = {};
        local seen = {};
        for _, id in ipairs(talentsFrame.configIDs) do
            if not seen[id] then
                table.insert(defaults, id);
                seen[id] = true;
            end
        end
        for _, id in ipairs(loadSystem.possibleSelections or {}) do
            if not seen[id] then
                table.insert(defaults, id);
                seen[id] = true;
            end
        end
        WriteSelections(loadSystem, defaults);
    end

    -- talentsFrame.configIDs may be stale/degraded (Blizzard's population);
    -- reconciliation merges in the ground truth right away and leaves the
    -- default (unsorted) order intact.
    ns.Reconcile();
    return true;
end

-- ----------------------------------------------------------------------------
-- Reset Button
-- ----------------------------------------------------------------------------

local function ddOpen(dropdown)
    return dropdown and dropdown.IsMenuOpen and dropdown:IsMenuOpen();
end

-- The button only makes sense when the current spec's order deviates from default:
-- a saved order exists AND the shown list differs from Blizzard's own order (a drag
-- back to the default arrangement leaves nothing to reset).
local function IsCustomOrderActive(talentsFrame, loadSystem)
    local specID = ns.GetSpecID(talentsFrame);
    local saved = ns.GetSavedOrder(ns.GetPlayerKey(), specID);
    if not saved or #saved.order == 0 then
        return false;
    end
    local defaults = talentsFrame and talentsFrame.configIDs;
    local shown = loadSystem and loadSystem.possibleSelections;
    if type(defaults) ~= "table" or type(shown) ~= "table" or #defaults == 0 then
        return true;
    end
    local isDefault = {};
    for _, id in ipairs(defaults) do isDefault[id] = true; end
    local shownDefaults = {};
    for _, id in ipairs(shown) do
        if isDefault[id] then table.insert(shownDefaults, id); end
    end
    return not ns.ArraysEqual(shownDefaults, defaults);
end

UpdateResetButton = function()
    if not resetButton then return end
    -- The button hides at press, so its OnMouseUp (icon restore) never fires; normalize
    -- the press-depress offset whenever visibility is refreshed.
    if resetButton.Icon then
        resetButton.Icon:SetPoint("CENTER", resetButton, "CENTER");
    end
    local talentsFrame = GetTalentsFrame();
    local loadSystem = talentsFrame and talentsFrame.LoadSystem;
    local dropdown = loadSystem and loadSystem.GetDropdown and loadSystem:GetDropdown();
    if ddOpen(dropdown) and IsCustomOrderActive(talentsFrame, loadSystem) then
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
local function CreateResetButton(talentsFrame, dropdown)
    if resetButton or not CreateFrame or not dropdown then
        return nil;
    end

    local parent = (dropdown.GetParent and dropdown:GetParent()) or dropdown;
    local btn = CreateFrame("Button", "ReorderTalentLoadoutsResetButton", parent, "IconButtonTemplate");
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
        if self.Icon then
            self.Icon:SetPoint("CENTER", self, "CENTER", 1, -1); -- press-depress visual
        end
        self:Hide();
        SafeInvoke("resetButton", ns.ResetCurrentSpecOrder);
        -- Scheduled regardless of the reset's success: the outside press already
        -- closed the menu, and leaving it closed is worse than an unapplied reset.
        if C_Timer and C_Timer.After then
            C_Timer.After(0, function()
                SafeInvoke("resetReopen", function()
                    local tf = GetTalentsFrame();
                    local ls = tf and tf.LoadSystem;
                    local dd = ls and ls.GetDropdown and ls:GetDropdown();
                    if not ddOpen(dd) and dd and dd.OpenMenu
                        and (not dd.IsShown or dd:IsShown()) then
                        SecureCall(dd.OpenMenu, dd);
                    end
                    UpdateResetButton();
                end);
            end);
        end
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

    return btn;
end

-- Creates the reset button and installs the dropdown hooks exactly once. The
-- dropdown is a plain menu widget (not the talent frame), so the only Blizzard
-- frame we hook is the same chrome the button lives on.
EnsureChrome = function(talentsFrame)
    local loadSystem = talentsFrame and talentsFrame.LoadSystem;
    local dropdown = loadSystem and loadSystem.GetDropdown and loadSystem:GetDropdown();
    if not dropdown then return end

    if not resetButton then
        resetButton = CreateResetButton(talentsFrame, dropdown);
    end

    -- First-paint fix: the talent pane's first population fires no
    -- TRAIT_CONFIG event, and our menu callback sorts too late for the menu it
    -- is already inside. Blizzard explicitly shows the talent pane, so its
    -- OnShow fires on every pane open (the dropdown's own shown flag is set at
    -- creation, so a dropdown OnShow would never fire). Sorting here happens
    -- before the user can open the menu.
    if not paneHooked then
        paneHooked = true;
        if talentsFrame.HookScript then
            talentsFrame:HookScript("OnShow", function()
                ns.Reconcile();
            end);
        end
    end

    -- Visibility is fully derived: menu open AND a non-default saved order exists.
    if not menuCallbacksInstalled and dropdown.RegisterCallback and DropdownButtonMixin and DropdownButtonMixin.Event then
        menuCallbacksInstalled = true;
        pcall(dropdown.RegisterCallback, dropdown, DropdownButtonMixin.Event.OnMenuOpen, function()
            -- Fail-open: this runs inside Blizzard's OpenMenu; a throw here would
            -- abort the dropdown's own open path.
            SafeInvoke("resetOnOpen", UpdateResetButton);
        end);
        pcall(dropdown.RegisterCallback, dropdown, DropdownButtonMixin.Event.OnMenuClose, function()
            -- Hidden next frame: visually instant, but still ordered after the current
            -- input dispatch so a press landing on the button as the menu closes (outside
            -- click) always reaches the button's OnMouseDown first (reset happens on press).
            SafeInvoke("resetOnClose", function()
                if C_Timer and C_Timer.After then
                    -- Fail-open: the hide must not depend on a successful
                    -- schedule; a refused timer would leave the button visible
                    -- next to a closed dropdown until the next refresh.
                    local scheduled = pcall(C_Timer.After, 0, function()
                        if resetButton and not ddOpen(dropdown) then
                            resetButton:Hide();
                        end
                    end);
                    if not scheduled and resetButton then
                        resetButton:Hide();
                    end
                elseif resetButton then
                    resetButton:Hide();
                end
            end);
        end);
    end

    UpdateResetButton();
end

-- ----------------------------------------------------------------------------
-- Talent UI Init
-- ----------------------------------------------------------------------------

local function InitializeTalentHooksInner()
    local talentsFrame = GetTalentsFrame();
    if not talentsFrame or not talentsFrame.LoadSystem then
        return
    end

    OptOutOfCommitCastBar(talentsFrame);

    hooksInstalled = true;

    -- Apply the initial sort if options already exist.
    local loadSystem = talentsFrame.LoadSystem;
    if loadSystem and loadSystem.possibleSelections and #loadSystem.possibleSelections > 1 then
        OnRefreshLoadoutOptions(talentsFrame);
    end

    SafeInvoke("chrome", EnsureChrome, talentsFrame);
end

-- Assign the forward-declared local (captured by OnModifyTalentMenuInner); do not shadow it.
InitializeTalentHooks = function()
    if hooksInstalled then return end

    -- Fail-open: hook installation must never raise into Blizzard's load flow.
    SafeInvoke("initHooks", InitializeTalentHooksInner);
end

ns.InitializeTalentHooks = InitializeTalentHooks;
ns._ResetHookStateForTest = function() -- internal seam: re-run installation
    hooksInstalled = false;
    paneHooked = false;
    menuCallbacksInstalled = false;
    -- Pending timers and once-per-scope error reports must not leak across a
    -- re-installation (a captured timer that never runs would silence later
    -- refresh/reconcile; a consumed error scope would hide a later failure).
    reconcilePending = false;
    wipe(refreshPending);
    wipe(reportedErrors);
end

-- ----------------------------------------------------------------------------
-- Init (WoW 12.x): attempt everything, blindly, on clean chrome
-- ----------------------------------------------------------------------------
-- Midnight restriction flags are the RISK SIGNAL (secrets may be flowing), not
-- the gate: enforcement bites only where secrets flowed into marked objects
-- (unit/combat/aura data). Nothing here can be marked -- plain loadout rows,
-- plain config-ID numbers, own frames -- so setup installs unconditionally. If
-- the engine ever refuses, it errors LOUDLY through SafeInvoke (Bugsack) instead
-- of deferring into a queue nobody reports.

local RegisterAddonEvents; -- forward declaration: assigned after the event frame exists
local eventsRegistered = false;

-- Idempotent setup: (re)registers events and installs talent hooks. Safe to
-- call from any event or menu callback; re-registering is a no-op and hook
-- installs run once.
function ns.EnsureInit()
    if RegisterAddonEvents then RegisterAddonEvents(); end
    InitializeTalentHooks();
    return true;
end

-- ----------------------------------------------------------------------------
-- Core Event Controller Frame
-- ----------------------------------------------------------------------------

local function IsAddOnLoadedSafe(addonName)
    if C_AddOns and C_AddOns.IsAddOnLoaded then
        return C_AddOns.IsAddOnLoaded(addonName);
    end
    -- No bare IsAddOnLoaded fallback: 12.1.5 documents the name only as
    -- C_AddOns.IsAddOnLoaded and the client has no such global (the dump's own
    -- FrameXML never reads one).
    return false;
end

local eventFrame = CreateFrame("Frame", "ReorderTalentLoadoutsEventFrame");

local function OnAddonEvent(self, event, arg1, arg2)
    if event == "ADDON_LOADED" then
        if arg1 == ADDON_NAME then
            if IsAddOnLoadedSafe("Blizzard_PlayerSpells") or IsAddOnLoadedSafe("Blizzard_ClassTalentUI") then
                ns.EnsureInit();
            end
        elseif arg1 == "Blizzard_PlayerSpells" or arg1 == "Blizzard_ClassTalentUI" then
            ns.EnsureInit();
        end
    elseif event == "PLAYER_LOGIN" or event == "PLAYER_ENTERING_WORLD" then
        if IsAddOnLoadedSafe("Blizzard_PlayerSpells") or IsAddOnLoadedSafe("Blizzard_ClassTalentUI") then
            ns.EnsureInit();
        end
        if event == "PLAYER_LOGIN" then
            -- Midnight: talent-UI predicates stay pending right after a reload
            -- until the player's first real input finalizes them. Reconcile at
            -- first movement (below) with bounded fallbacks for players who
            -- never move.
            if C_Timer and C_Timer.After then
                for _, delay in ipairs({ 5, 15, 30 }) do
                    C_Timer.After(delay, ns.Reconcile);
                end
            end
        else
            -- Loading-screen zone change (dungeon/arena/instance entry): the
            -- dropdown's data may have been repopulated across the transition,
            -- so reconcile after Blizzard's own loading-screen handlers.
            ScheduleReconcile();
        end
    elseif event == "ZONE_CHANGED" or event == "ZONE_CHANGED_NEW_AREA" then
        -- Zone change without a loading screen (zone-line crossings, M+/arena
        -- boundary transitions): same data-driven re-sort, no flag checks.
        ScheduleReconcile();
    elseif event == "PLAYER_STARTED_MOVING" then
        if self and self.UnregisterEvent then
            self:UnregisterEvent("PLAYER_STARTED_MOVING");
        end
        ns.Reconcile();
    elseif event == "TRAIT_CONFIG_LIST_UPDATED" or event == "TRAIT_CONFIG_CREATED"
        or event == "TRAIT_CONFIG_DELETED" or event == "ACTIVE_PLAYER_SPECIALIZATION_CHANGED" then
        -- Self-heal for a late-loading talent UI: reinstall idempotently, then
        -- re-sort on the next frame (merge-only, drag-deferred).
        ns.EnsureInit();
        ScheduleReconcile();
    end
end

local function OnAddonUpdate(self, elapsed)
    -- OnUpdate only services click-and-hold drag state; list reconciliation is event-driven.
    -- It exists only while a press or drag is in flight (ArmDragPump attaches it) and
    -- detaches itself once both end: zero per-frame cost outside a drag gesture.
    if not potentialDrag and not isDragging then
        self:SetScript("OnUpdate", nil);
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
        else
            ns.UpdateDrag();
        end
    end
    if not potentialDrag and not isDragging then
        self:SetScript("OnUpdate", nil);
    end
end

ArmDragPump = function()
    if eventFrame then
        eventFrame:SetScript("OnUpdate", OnAddonUpdate);
    end
end

-- All event/script installs funnel through here so any late boot (talent UI
-- loading after us, /reload timing) retries them idempotently.
RegisterAddonEvents = function()
    if eventsRegistered or not eventFrame then return end
    eventsRegistered = true;
    eventFrame:RegisterEvent("ADDON_LOADED");
    eventFrame:RegisterEvent("PLAYER_LOGIN");
    eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD");
    eventFrame:RegisterEvent("ZONE_CHANGED");
    eventFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA");
    eventFrame:RegisterEvent("TRAIT_CONFIG_LIST_UPDATED");
    eventFrame:RegisterEvent("TRAIT_CONFIG_CREATED");
    eventFrame:RegisterEvent("TRAIT_CONFIG_DELETED");
    eventFrame:RegisterEvent("ACTIVE_PLAYER_SPECIALIZATION_CHANGED");
    eventFrame:SetScript("OnEvent", OnAddonEvent);
end

RegisterAddonEvents();
-- First movement after login is a one-shot (unregisters itself on fire), so it is
-- armed once here and never by the idempotent re-registration above.
if eventFrame then
    eventFrame:RegisterEvent("PLAYER_STARTED_MOVING");
end

-- Register with Blizzard Menu framework (available in 11.0+).
if Menu and Menu.ModifyMenu then
    Menu.ModifyMenu("MENU_CLASS_TALENT_PROFILE", OnModifyTalentMenu);
end

-- Boot-time setup: attempt everything at load (clean chrome serves under any
-- restriction state). Late-loading talent UI is picked up by ADDON_LOADED,
-- login, talent events, and the next dropdown open -- all idempotent.
SafeInvoke("bootstrap", function()
    ns.EnsureInit();
end);
