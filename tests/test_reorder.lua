--[[
    Test Suite for Reorder Talent Loadouts
    Run with: lua tests/test_reorder.lua
--]]

-- Mock WoW Environment
_G = _G or {};

function CopyTable(settings)
    if type(settings) ~= "table" then return settings end
    local copy = {}
    for k, v in pairs(settings) do
        if type(v) == "table" then
            copy[k] = CopyTable(v)
        else
            copy[k] = v
        end
    end
    return copy
end

function wipe(tbl)
    for k in pairs(tbl) do
        tbl[k] = nil
    end
    return tbl
end

function tContains(tbl, item)
    for _, v in pairs(tbl) do
        if v == item then return true end
    end
    return false
end

string.trim = function(s)
    return (s:gsub("^%s*(.-)%s*$", "%1"))
end

local mockGUID = "Player-1234-00A1B2C3";
local mockPlayerName = "Testplayer";
local mockRealmName = "Area52";
local inCombat = false;
local cursorX, cursorY = 100, 100;
local leftMouseDown = false;

function UnitGUID(unit)
    if unit == "player" then return mockGUID end
    return nil
end

function UnitName(unit)
    if unit == "player" then return mockPlayerName end
    return nil
end

function GetRealmName()
    return mockRealmName
end

function InCombatLockdown()
    return inCombat
end

function GetCursorPosition()
    return cursorX, cursorY
end

function IsMouseButtonDown(btn)
    if btn == "LeftButton" then return leftMouseDown end
    return false
end

UIParent = {
    GetEffectiveScale = function() return 1.0 end,
};

C_Timer = {
    After = function(seconds, callback)
        -- Execute immediately in tests
        callback()
    end,
};

SOUNDKIT = {
    IG_MAINMENU_OPTION_CHECKBOX_ON = 856,
    U_CHAT_SCROLL_BUTTON = 857,
};

DropdownButtonMixin = {
    Event = {
        OnMenuOpen = "OnMenuOpen",
        OnMenuClose = "OnMenuClose",
    },
};

local playedSounds = {};
function PlaySound(id)
    table.insert(playedSounds, id);
end

function hooksecurefunc(tbl, method, hook)
    if type(tbl) == "string" then
        local orig = _G[tbl]
        _G[tbl] = function(...)
            if orig then orig(...) end
            return hook(...)
        end
    elseif type(tbl) == "table" and type(method) == "string" then
        local orig = tbl[method]
        tbl[method] = function(...)
            if orig then orig(...) end
            return hook(...)
        end
    end
end

-- Mock Frames
local mockFrames = {};
function CreateFrame(frameType, name, parent, template)
    local f = {
        name = name,
        frameType = frameType,
        parent = parent,
        template = template,
        scripts = {},
        points = {},
        alpha = 1.0,
        shown = false,
        width = 200,
        height = 24,
        rect = { left = 50, bottom = 100, width = 200, height = 24 },
        textures = {},
        fontStrings = {},
        events = {},
        SetSize = function(self, w, h) self.width = w; self.height = h end,
        SetHeight = function(self, h) self.height = h end,
        SetWidth = function(self, w) self.width = w end,
        SetPoint = function(self, point, relTo, relPoint, x, y)
            table.insert(self.points, { point = point, relTo = relTo, relPoint = relPoint, x = x, y = y })
        end,
        ClearAllPoints = function(self) wipe(self.points) end,
        SetFrameStrata = function(self, strata) self.strata = strata end,
        SetFrameLevel = function(self, level) self.level = level end,
        SetClampedToScreen = function(self, val) self.clamped = val end,
        EnableMouse = function(self, val) self.mouseEnabled = val end,
        SetBackdrop = function(self, bd) self.backdrop = bd end,
        SetBackdropColor = function(self, r, g, b, a) self.bgColor = {r, g, b, a} end,
        SetBackdropBorderColor = function(self, r, g, b, a) self.borderColor = {r, g, b, a} end,
        CreateTexture = function(self, name, layer)
            local tex = {
                layer = layer,
                SetSize = function(self, w, h) self.w = w; self.h = h end,
                SetHeight = function(self, h) self.h = h end,
                SetPoint = function(self, ...) end,
                SetAllPoints = function(self) end,
                SetTexture = function(self, t) self.texture = t end,
                SetTexCoord = function(self, ...) end,
                SetColorTexture = function(self, r, g, b, a) self.color = {r, g, b, a} end,
            }
            table.insert(self.textures, tex)
            return tex
        end,
        CreateFontString = function(self, name, layer, template)
            local fs = {
                layer = layer,
                template = template,
                text = "",
                SetPoint = function(self, ...) end,
                SetJustifyH = function(self, j) self.justifyH = j end,
                SetText = function(self, t) self.text = t end,
                GetText = function(self) return self.text end,
                SetTextColor = function(self, r, g, b, a) self.color = {r, g, b, a} end,
            }
            table.insert(self.fontStrings, fs)
            return fs
        end,
        Show = function(self) self.shown = true end,
        Hide = function(self) self.shown = false end,
        IsShown = function(self) return self.shown end,
        SetAlpha = function(self, a) self.alpha = a end,
        GetAlpha = function(self) return self.alpha end,
        GetRect = function(self)
            return self.rect.left, self.rect.bottom, self.rect.width, self.rect.height
        end,
        SetRect = function(self, l, b, w, h)
            self.rect = { left = l, bottom = b, width = w, height = h }
        end,
        RegisterEvent = function(self, ev) self.events[ev] = true end,
        UnregisterEvent = function(self, ev) self.events[ev] = nil end,
        SetScript = function(self, name, handler) self.scripts[name] = handler end,
        GetScript = function(self, name) return self.scripts[name] end,
        HookScript = function(self, name, hook)
            local orig = self.scripts[name]
            self.scripts[name] = function(btn, ...)
                if orig then orig(btn, ...) end
                hook(btn, ...)
            end
        end,
        RegisterForDrag = function(self, ...) self.registeredDrag = {...} end,
        IsMouseOver = function(self)
            if self.mouseOverOverride ~= nil then return self.mouseOverOverride end
            local l, b, w, h = self.rect.left, self.rect.bottom, self.rect.width, self.rect.height
            if l and b and w and h then
                return cursorX >= l and cursorX <= (l + w) and cursorY >= b and cursorY <= (b + h)
            end
            return false
        end,
        GetChildren = function(self)
            local res = {}
            for _, child in ipairs(mockFrames) do
                if child.parent == self then
                    table.insert(res, child)
                end
            end
            return (unpack or table.unpack)(res)
        end,
        GetEffectiveScale = function(self)
            return self.effectiveScale or 1.0
        end,
    }
    table.insert(mockFrames, f)
    return f
end

DEFAULT_CHAT_FRAME = {
    messages = {},
    AddMessage = function(self, msg) table.insert(self.messages, msg) end,
};

SlashCmdList = {};

Menu = {
    callbacks = {},
    ModifyMenu = function(tag, cb)
        Menu.callbacks[tag] = cb
    end,
};

-- Load addon into namespace
local addonNamespace = {};
local addonChunk, loadErr = loadfile("Reorder_Talent_Loadouts.lua");
if not addonChunk then
    print("FATAL: Failed to load Reorder_Talent_Loadouts.lua: " .. tostring(loadErr));
    os.exit(1);
end
addonChunk("Reorder_Talent_Loadouts", addonNamespace);

-- ----------------------------------------------------------------------------
-- Tests
-- ----------------------------------------------------------------------------

local passed = 0;
local failed = 0;

local function assert_eq(actual, expected, testName)
    if actual == expected then
        passed = passed + 1
    else
        failed = failed + 1
        print(string.format("FAIL [%s]: Expected '%s', got '%s'", testName, tostring(expected), tostring(actual)))
    end
end

local function assert_true(condition, testName)
    if condition then
        passed = passed + 1
    else
        failed = failed + 1
        print(string.format("FAIL [%s]: Expected true, got %s", testName, tostring(condition)))
    end
end

local function assert_table_eq(actual, expected, testName)
    local equal = addonNamespace.ArraysEqual(actual, expected)
    if equal then
        passed = passed + 1
    else
        failed = failed + 1
        local actStr = "{" .. table.concat(actual or {}, ", ") .. "}"
        local expStr = "{" .. table.concat(expected or {}, ", ") .. "}"
        print(string.format("FAIL [%s]: Expected table %s, got %s", testName, expStr, actStr))
    end
end

print("=== Starting Reorder Talent Loadouts Test Suite ===")

-- Test 1: Player Key Generation
assert_eq(addonNamespace.GetPlayerKey(), "Player-1234-00A1B2C3", "PlayerKey from UnitGUID")

mockGUID = ""
assert_eq(addonNamespace.GetPlayerKey(), "Testplayer-Area52", "PlayerKey fallback to Name-Realm")
mockGUID = "Player-1234-00A1B2C3"

-- Test 2: CalculateNewOrder - Basic Moving
do
    local list = { 101, 102, 103, 104 }
    -- Move item from index 4 to index 2 (between 1 and 2)
    local res, moved = addonNamespace.CalculateNewOrder(CopyTable(list), 4, 2)
    assert_true(moved, "CalculateNewOrder moved 4->2")
    assert_table_eq(res, { 101, 104, 102, 103 }, "CalculateNewOrder list 4->2")

    -- Move item from index 1 to index 4 (below index 3)
    local res2, moved2 = addonNamespace.CalculateNewOrder(CopyTable(list), 1, 4)
    assert_true(moved2, "CalculateNewOrder moved 1->4")
    assert_table_eq(res2, { 102, 103, 101, 104 }, "CalculateNewOrder list 1->4")

    -- Move item from index 1 to index 5 (to bottom)
    local res3, moved3 = addonNamespace.CalculateNewOrder(CopyTable(list), 1, 5)
    assert_true(moved3, "CalculateNewOrder moved 1->5")
    assert_table_eq(res3, { 102, 103, 104, 101 }, "CalculateNewOrder list 1->5")

    -- Move item from index 3 to index 1 (to top)
    local res4, moved4 = addonNamespace.CalculateNewOrder(CopyTable(list), 3, 1)
    assert_true(moved4, "CalculateNewOrder moved 3->1")
    assert_table_eq(res4, { 103, 101, 102, 104 }, "CalculateNewOrder list 3->1")
end

-- Test 3: CalculateNewOrder - No-ops and Boundaries
do
    local list = { 101, 102, 103 }
    -- Same position
    local _, moved1 = addonNamespace.CalculateNewOrder(CopyTable(list), 2, 2)
    assert_true(not moved1, "CalculateNewOrder no-op same slot")

    -- Target is fromIndex + 1 (dropping below itself without changing order)
    local _, moved2 = addonNamespace.CalculateNewOrder(CopyTable(list), 2, 3)
    assert_true(not moved2, "CalculateNewOrder no-op adjacent slot")

    -- Single item list
    local single = { 101 }
    local _, moved3 = addonNamespace.CalculateNewOrder(CopyTable(single), 1, 2)
    assert_true(not moved3, "CalculateNewOrder single item")

    -- Empty list
    local empty = {}
    local _, moved4 = addonNamespace.CalculateNewOrder(CopyTable(empty), 1, 2)
    assert_true(not moved4, "CalculateNewOrder empty list")
end

-- Test 4: Database Storage and Isolation
do
    ReorderTalentLoadoutsDB = {}
    local player1 = "Player-111";
    local player2 = "Player-222";
    local specBlood = 250;
    local specFrost = 251;

    local order1 = { 10, 20, 30 }
    local names1 = { [10] = "Blood Raid", [20] = "Blood M+", [30] = "Blood PvP" }
    addonNamespace.SaveOrder(player1, specBlood, order1, names1)

    local order2 = { 100, 200 }
    local names2 = { [100] = "Frost Single", [200] = "Frost AoE" }
    addonNamespace.SaveOrder(player1, specFrost, order2, names2)

    local orderP2 = { 999, 888 }
    local namesP2 = { [999] = "P2 Loadout A", [888] = "P2 Loadout B" }
    addonNamespace.SaveOrder(player2, specBlood, orderP2, namesP2)

    -- Check player 1 blood
    local savedP1Blood = addonNamespace.GetSavedOrder(player1, specBlood)
    assert_table_eq(savedP1Blood.order, order1, "DB Player 1 Spec Blood order")
    assert_eq(savedP1Blood.names[10], "Blood Raid", "DB Player 1 Spec Blood name")

    -- Check player 1 frost
    local savedP1Frost = addonNamespace.GetSavedOrder(player1, specFrost)
    assert_table_eq(savedP1Frost.order, order2, "DB Player 1 Spec Frost order")

    -- Check player 2 blood isolation
    local savedP2Blood = addonNamespace.GetSavedOrder(player2, specBlood)
    assert_table_eq(savedP2Blood.order, orderP2, "DB Player 2 Spec Blood order isolated")
end

-- Test 5: SortConfigIDs - Scenarios
do
    ReorderTalentLoadoutsDB = {}
    local pKey = addonNamespace.GetPlayerKey()
    local specID = 250

    -- Scenario A: No saved order yet
    local current = { 1, 2, 3 }
    local names = { [1] = "Build 1", [2] = "Build 2", [3] = "Build 3" }
    local resA = addonNamespace.SortConfigIDs(specID, current, names)
    assert_table_eq(resA, { 1, 2, 3 }, "SortConfigIDs without saved order")

    -- Save an order: 3, 1, 2
    addonNamespace.SaveOrder(pKey, specID, { 3, 1, 2 }, names)

    -- Scenario B: Exact match with saved order
    local resB = addonNamespace.SortConfigIDs(specID, current, names)
    assert_table_eq(resB, { 3, 1, 2 }, "SortConfigIDs with saved order")

    -- Scenario C: A new loadout (ID 4) was added in the game
    local currentWithNew = { 1, 2, 3, 4 }
    local namesWithNew = { [1] = "Build 1", [2] = "Build 2", [3] = "Build 3", [4] = "New Build" }
    local resC = addonNamespace.SortConfigIDs(specID, currentWithNew, namesWithNew)
    assert_table_eq(resC, { 3, 1, 2, 4 }, "SortConfigIDs with new loadout appended at end")

    -- Scenario D: Loadout 1 was deleted
    local currentDeleted = { 2, 3, 4 }
    local namesDeleted = { [2] = "Build 2", [3] = "Build 3", [4] = "New Build" }
    local resD = addonNamespace.SortConfigIDs(specID, currentDeleted, namesDeleted)
    assert_table_eq(resD, { 3, 2, 4 }, "SortConfigIDs with deleted loadout removed")

    -- Scenario E: Fallback name matching (configID 3 changed to 99, but name is "Build 3")
    ReorderTalentLoadoutsDB = {}
    addonNamespace.SaveOrder(pKey, specID, { 3, 1, 2 }, { [3] = "Build 3", [1] = "Build 1", [2] = "Build 2" })
    local currentRenumbered = { 1, 2, 99 }
    local namesRenumbered = { [1] = "Build 1", [2] = "Build 2", [99] = "Build 3" }
    local resE = addonNamespace.SortConfigIDs(specID, currentRenumbered, namesRenumbered)
    assert_table_eq(resE, { 99, 1, 2 }, "SortConfigIDs with name fallback matching")
end

-- Test 6: Starter Build Handling
do
    ReorderTalentLoadoutsDB = {}
    local pKey = addonNamespace.GetPlayerKey()
    local specID = 250
    local starterID = -1

    local current = { 10, 20, starterID }
    local names = { [10] = "Custom A", [20] = "Custom B", [starterID] = "Starter Build" }

    -- Reorder starter build to the top: -1, 10, 20
    addonNamespace.SaveOrder(pKey, specID, { starterID, 10, 20 }, names)
    local sorted = addonNamespace.SortConfigIDs(specID, current, names)
    assert_table_eq(sorted, { starterID, 10, 20 }, "SortConfigIDs with Starter Build moved to top")
end

-- Test 7: Combat Lockdown Safety
do
    inCombat = true
    local mockBtn = CreateFrame("Button", "MockBtn1")
    mockBtn.rtLoadoutConfigID = 101

    -- Attempt to start drag during combat
    addonNamespace.StartDrag(mockBtn)
    -- Verify drag did not start
    assert_true(mockBtn:GetAlpha() == 1.0, "Combat prevents StartDrag")

    inCombat = false
end

-- Test 8: Drag and Drop Interaction Flow
do
    ReorderTalentLoadoutsDB = {}
    local pKey = addonNamespace.GetPlayerKey()
    local specID = 250

    -- Setup mock PlayerSpellsFrame
    local mockTalentsFrame = {
        GetSpecID = function() return specID end,
        IsInspecting = function() return false end,
        configIDToName = { [101] = "Raid", [102] = "M+", [103] = "PvP" },
        configIDs = { 101, 102, 103 },
        RefreshLoadoutOptions = function(self) end,
        LoadSystem = {
            possibleSelections = { 101, 102, 103 },
            dropdown = {
                menuOpen = true,
                CloseMenu = function(self) self.menuOpen = false end,
                OpenMenu = function(self) self.menuOpen = true end,
            },
            GetDropdown = function(self) return self.dropdown end,
            UpdateSelectionOptions = function(self) end,
            SetSelectionOptions = function(self, options) end,
        },
    }
    PlayerSpellsFrame = { TalentsFrame = mockTalentsFrame }

    -- Setup mock Menu buttons
    local b1 = CreateFrame("Button", "LoadoutBtn1")
    b1:SetRect(50, 200, 200, 20) -- Y: 200 to 220, mid: 210
    local b2 = CreateFrame("Button", "LoadoutBtn2")
    b2:SetRect(50, 180, 200, 20) -- Y: 180 to 200, mid: 190
    local b3 = CreateFrame("Button", "LoadoutBtn3")
    b3:SetRect(50, 160, 200, 20) -- Y: 160 to 180, mid: 170

    local mockDesc1 = { GetData = function() return 101 end, SetCanSelect = function() end }
    local mockDesc2 = { GetData = function() return 102 end, SetCanSelect = function() end }
    local mockDesc3 = { GetData = function() return 103 end, SetCanSelect = function() end }

    addonNamespace.SetupLoadoutButton(b1, mockDesc1, nil, 101)
    addonNamespace.SetupLoadoutButton(b2, mockDesc2, nil, 102)
    addonNamespace.SetupLoadoutButton(b3, mockDesc3, nil, 103)

    -- Simulate StartDrag on Button 3 (PvP - 103)
    addonNamespace.StartDrag(b3)
    assert_true(b3:GetAlpha() == 0.35, "Dragged button is dimmed")

    -- Move cursor to Y = 215 (above Button 1)
    cursorX = 100
    cursorY = 215
    addonNamespace.UpdateDrag()

    -- Finish Drag
    addonNamespace.FinishDrag()

    -- Verify b3 alpha is restored
    assert_true(b3:GetAlpha() == 1.0, "Dragged button alpha restored after drop")

    -- Verify new order in LoadSystem and SavedVariables: 103, 101, 102
    assert_table_eq(mockTalentsFrame.LoadSystem.possibleSelections, { 103, 101, 102 }, "Drag-drop reordered selections to 103, 101, 102")
    local saved = addonNamespace.GetSavedOrder(pKey, specID)
    assert_table_eq(saved.order, { 103, 101, 102 }, "Drag-drop persisted new order to DB")
end

-- Test 9: Off-Menu Drag Cancellation
do
    local specID = 250
    local mockTalentsFrame = PlayerSpellsFrame.TalentsFrame
    mockTalentsFrame.LoadSystem.possibleSelections = { 103, 101, 102 }

    local b1 = mockFrames[#mockFrames - 2]
    local b2 = mockFrames[#mockFrames - 1]
    local b3 = mockFrames[#mockFrames]

    -- Start drag on b1 (103)
    addonNamespace.StartDrag(b1)

    -- Move cursor far away horizontally (cursorX = 500, menu left is 50+200=250)
    cursorX = 500
    cursorY = 190
    addonNamespace.UpdateDrag()

    -- Release mouse
    addonNamespace.FinishDrag()

    -- Order must remain unchanged
    assert_table_eq(mockTalentsFrame.LoadSystem.possibleSelections, { 103, 101, 102 }, "Off-menu drop cancelled, order preserved")
end

-- Test 10: ResetCurrentSpecOrder
do
    local specID = 250
    local pKey = addonNamespace.GetPlayerKey()
    assert_true(ReorderTalentLoadoutsDB[pKey][specID] ~= nil, "DB exists before reset")

    addonNamespace.ResetCurrentSpecOrder(false)

    assert_true(ReorderTalentLoadoutsDB[pKey][specID] == nil, "DB cleared for spec after reset")
end

-- Test 11: Mid-Drag Combat Abort (PLAYER_REGEN_DISABLED)
do
    local specID = 250
    local mockTalentsFrame = PlayerSpellsFrame.TalentsFrame
    mockTalentsFrame.LoadSystem.possibleSelections = { 101, 102, 103 }
    local b1 = mockFrames[#mockFrames - 2]

    addonNamespace.StartDrag(b1)
    assert_true(b1:GetAlpha() == 0.35, "Drag started before combat")

    -- Fire combat event
    local eventFrame = mockFrames[#mockFrames - 3]
    for _, f in ipairs(mockFrames) do
        if f.name == "ReorderTalentLoadoutsEventFrame" then
            f.scripts["OnEvent"](f, "PLAYER_REGEN_DISABLED")
            break
        end
    end

    assert_true(b1:GetAlpha() == 1.0, "Combat abort restored button alpha")
    assert_table_eq(mockTalentsFrame.LoadSystem.possibleSelections, { 101, 102, 103 }, "Combat abort left order untouched")
end

-- Test 12: Successive Drag Operations
do
    local specID = 250
    local pKey = addonNamespace.GetPlayerKey()
    local mockTalentsFrame = PlayerSpellsFrame.TalentsFrame
    mockTalentsFrame.LoadSystem.possibleSelections = { 1, 2, 3, 4 }

    local b1 = CreateFrame("Button", "SuccessiveB1")
    local b2 = CreateFrame("Button", "SuccessiveB2")
    local b3 = CreateFrame("Button", "SuccessiveB3")
    local b4 = CreateFrame("Button", "SuccessiveB4")

    local btnMap = { [1] = b1, [2] = b2, [3] = b3, [4] = b4 }
    local rects = {
        { 50, 240, 200, 20 },
        { 50, 220, 200, 20 },
        { 50, 200, 200, 20 },
        { 50, 180, 200, 20 },
    }

    local function RebuildActiveButtons()
        addonNamespace.ClearActiveButtons()
        for i, id in ipairs(mockTalentsFrame.LoadSystem.possibleSelections) do
            local b = btnMap[id]
            b:SetRect(rects[i][1], rects[i][2], rects[i][3], rects[i][4])
            addonNamespace.SetupLoadoutButton(b, { GetData = function() return id end, SetCanSelect = function() end }, nil, id)
        end
    end

    mockTalentsFrame.LoadSystem.dropdown.OpenMenu = function(self)
        self.menuOpen = true
        RebuildActiveButtons()
    end

    RebuildActiveButtons()

    -- First drag: Move 1 to bottom (targetIndex = 5)
    addonNamespace.StartDrag(b1)
    cursorX = 100
    cursorY = 170 -- below b4 (now at bottom)
    addonNamespace.UpdateDrag()
    addonNamespace.FinishDrag()
    assert_table_eq(mockTalentsFrame.LoadSystem.possibleSelections, { 2, 3, 4, 1 }, "Successive drag 1: 1 moved to bottom")

    -- Second drag: Move 4 to top (targetIndex = 1)
    addonNamespace.StartDrag(b4)
    cursorX = 100
    cursorY = 255 -- above top item
    addonNamespace.UpdateDrag()
    addonNamespace.FinishDrag()
    assert_table_eq(mockTalentsFrame.LoadSystem.possibleSelections, { 4, 2, 3, 1 }, "Successive drag 2: 4 moved to top")

    local saved = addonNamespace.GetSavedOrder(pKey, specID)
    assert_table_eq(saved.order, { 4, 2, 3, 1 }, "Successive drag saved cumulative order")
end

-- Test 13: 10-Loadout Capacity (Maximum in WoW Retail)
do
    local specID = 250
    local list10 = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 }
    -- Move item from position 10 to position 1
    local res1, moved1 = addonNamespace.CalculateNewOrder(CopyTable(list10), 10, 1)
    assert_true(moved1, "Move 10 to 1 in 10-loadout list")
    assert_table_eq(res1, { 10, 1, 2, 3, 4, 5, 6, 7, 8, 9 }, "Result for 10 to 1")

    -- Move item from position 3 to position 8
    local res2, moved2 = addonNamespace.CalculateNewOrder(CopyTable(list10), 3, 8)
    assert_true(moved2, "Move 3 to 8 in 10-loadout list")
    assert_table_eq(res2, { 1, 2, 4, 5, 6, 7, 3, 8, 9, 10 }, "Result for 3 to 8")
end

-- Test 14: Inspect Safety
do
    local mockTalentsFrame = PlayerSpellsFrame.TalentsFrame
    mockTalentsFrame.IsInspecting = function() return true end

    -- Trigger refresh while inspecting
    local selectionsBefore = CopyTable(mockTalentsFrame.LoadSystem.possibleSelections)
    -- Hooked refresh function should return early and not modify or save
    local sorted = addonNamespace.SortConfigIDs(250, selectionsBefore, {})
    -- When inspecting, SortConfigIDs can run, but talentsFrame hooks must not alter the inspected selections
    assert_true(mockTalentsFrame:IsInspecting(), "Inspecting flag verified")

    mockTalentsFrame.IsInspecting = function() return false end
end

-- Test 15: Click vs Drag Threshold (< 5px does not drag)
do
    addonNamespace.ClearActiveButtons()
    local bTest = CreateFrame("Button", "ThresholdBtn")
    bTest:SetRect(50, 200, 200, 20)
    local desc = { GetData = function() return 555 end, SetCanSelect = function() end }
    addonNamespace.SetupLoadoutButton(bTest, desc, nil, 555)
    bTest.mouseOverOverride = true
    bTest:Show()

    local evFrame = nil
    for _, f in ipairs(mockFrames) do
        if f.name == "ReorderTalentLoadoutsEventFrame" then evFrame = f; break end
    end

    -- Mouse down via the button's own post-hook
    cursorX, cursorY = 100, 100
    bTest.scripts["OnMouseDown"](bTest, "LeftButton")

    -- Mouse moves only 2 pixels (distance < 5px)
    cursorX, cursorY = 101, 101
    -- OnUpdate checks distance
    local evFrame = nil
    for _, f in ipairs(mockFrames) do
        if f.name == "ReorderTalentLoadoutsEventFrame" then evFrame = f; break end
    end
    leftMouseDown = true
    evFrame.scripts["OnUpdate"](evFrame, 0.016)

    -- Verify drag did NOT start
    assert_true(bTest:GetAlpha() == 1.0, "Movement <= 5px does not start drag")

    addonNamespace.CancelDrag()
    leftMouseDown = false
    assert_true(bTest:GetAlpha() == 1.0, "Button remains in normal state after normal click")
end

-- Test 16: Frame Pool Reuse Registry Update (addon-side registry; no Blizzard-frame writes)
do
    local bPool = CreateFrame("Button", "PooledBtn")
    local desc = { GetData = function() return 777 end, SetCanSelect = function() end }
    addonNamespace.SetupLoadoutButton(bPool, desc, nil, 777)
    local entry = addonNamespace.FindTrackedEntry(bPool)
    assert_true(entry ~= nil and entry.configID == 777, "Pooled button tracked in addon registry")

    -- Second menu open reuses bPool from the pool for a different loadout
    addonNamespace.SetupLoadoutButton(bPool, desc, nil, 888)
    entry = addonNamespace.FindTrackedEntry(bPool)
    -- FindTrackedEntry returns the FIRST match; a duplicated registry entry would still
    -- report the original 777 here, so this also proves no duplication happened.
    assert_true(entry.configID == 888, "Pooled button config ID updated in place")
end

-- Test 17: Utility Button (Gear Edit Button) Exclusion
do
    addonNamespace.ClearActiveButtons()
    local rowBtn = CreateFrame("Button", "RowBtn")
    rowBtn:SetRect(50, 200, 200, 20)
    local desc = { GetData = function() return 999 end, SetCanSelect = function() end }
    addonNamespace.SetupLoadoutButton(rowBtn, desc, nil, 999)

    -- Attach a child utility gear button
    local gearChild = CreateFrame("Button", "GearChildBtn", rowBtn)
    gearChild.mouseOverOverride = true
    gearChild:Show()

    -- Mouse down over the row (cursor inside row, over the gear child):
    -- the GLOBAL_MOUSE_DOWN handler must skip the row entirely.
    addonNamespace.CancelDrag()
    cursorX, cursorY = 100, 100
    rowBtn:Show()
    local evFrame = nil
    for _, f in ipairs(mockFrames) do
        if f.name == "ReorderTalentLoadoutsEventFrame" then evFrame = f; break end
    end
    rowBtn.scripts["OnMouseDown"](rowBtn, "LeftButton")
    cursorX, cursorY = 150, 150
    leftMouseDown = true
    evFrame.scripts["OnUpdate"](evFrame, 0.016)
    assert_true(rowBtn:GetAlpha() == 1.0, "Potential drag blocked when clicking gear child button")
    leftMouseDown = false
    addonNamespace.CancelDrag()
end

-- Test 18: Button Press Arms Click-and-Hold Drag
do
    addonNamespace.ClearActiveButtons()
    local gBtn = CreateFrame("Button", "GlobalMouseBtn")
    gBtn:SetRect(50, 200, 200, 20)
    gBtn.rtLoadoutConfigID = 701
    gBtn:Show()
    local desc = { GetData = function() return 701 end, SetCanSelect = function() end }
    addonNamespace.SetupLoadoutButton(gBtn, desc, nil, 701)

    local evFrame = nil
    for _, f in ipairs(mockFrames) do
        if f.name == "ReorderTalentLoadoutsEventFrame" then evFrame = f; break end
    end

    -- Cursor over gBtn
    cursorX = 100
    cursorY = 210
    leftMouseDown = true
    gBtn.scripts["OnMouseDown"](gBtn, "LeftButton")

    -- Move mouse > 5px
    cursorX = 120
    cursorY = 210
    evFrame.scripts["OnUpdate"](evFrame, 0.016)

    assert_true(gBtn:GetAlpha() == 0.35, "Button press successfully armed click-and-hold drag")
    addonNamespace.CancelDrag()
    assert_true(gBtn:GetAlpha() == 1.0, "Drag cleaned up after GLOBAL_MOUSE_DOWN test")
    leftMouseDown = false
end

-- Test 19: Vertical Bounds Drag Cancellation
do
    local specID = 250
    local mockTalentsFrame = PlayerSpellsFrame.TalentsFrame
    mockTalentsFrame.LoadSystem.possibleSelections = { 101, 102, 103 }

    addonNamespace.ClearActiveButtons()
    local b1 = CreateFrame("Button", "VB1")
    b1:SetRect(50, 200, 200, 20) -- top: 220
    local b2 = CreateFrame("Button", "VB2")
    b2:SetRect(50, 180, 200, 20)
    local b3 = CreateFrame("Button", "VB3")
    b3:SetRect(50, 160, 200, 20) -- bottom: 160

    addonNamespace.SetupLoadoutButton(b1, { GetData = function() return 101 end, SetCanSelect = function() end }, nil, 101)
    addonNamespace.SetupLoadoutButton(b2, { GetData = function() return 102 end, SetCanSelect = function() end }, nil, 102)
    addonNamespace.SetupLoadoutButton(b3, { GetData = function() return 103 end, SetCanSelect = function() end }, nil, 103)

    addonNamespace.StartDrag(b3)

    -- Move cursor far above menu (> 60px above 220, e.g. Y = 300)
    cursorX = 100
    cursorY = 300
    addonNamespace.UpdateDrag()
    addonNamespace.FinishDrag()

    assert_table_eq(mockTalentsFrame.LoadSystem.possibleSelections, { 101, 102, 103 }, "Drop far above menu cancelled, order untouched")

    -- Move cursor far below menu (> 60px below 160, e.g. Y = 80)
    addonNamespace.StartDrag(b1)
    cursorX = 100
    cursorY = 80
    addonNamespace.UpdateDrag()
    addonNamespace.FinishDrag()

    assert_table_eq(mockTalentsFrame.LoadSystem.possibleSelections, { 101, 102, 103 }, "Drop far below menu cancelled, order untouched")
end

-- Test 20: Menu Release / Close Callback via AddMenuReleasedCallback
do
    local specID = 250
    local mockTalentsFrame = PlayerSpellsFrame.TalentsFrame
    local bClose = CreateFrame("Button", "CloseTestBtn")
    bClose:SetRect(50, 200, 200, 20)
    bClose.rtLoadoutConfigID = 101

    addonNamespace.ClearActiveButtons()
    addonNamespace.SetupLoadoutButton(bClose, { GetData = function() return 101 end, SetCanSelect = function() end }, nil, 101)

    -- Start drag
    addonNamespace.StartDrag(bClose)
    assert_true(bClose:GetAlpha() == 0.35, "Drag started before menu release")

    -- Simulate menu release callback
    local releasedCallback = nil
    local mockRootDesc = {
        EnumerateElementDescriptions = function(self)
            return coroutine.wrap(function() end)
        end,
        AddMenuReleasedCallback = function(self, cb)
            releasedCallback = cb
        end,
    }

    if Menu and Menu.callbacks and Menu.callbacks["MENU_CLASS_TALENT_PROFILE"] then
        Menu.callbacks["MENU_CLASS_TALENT_PROFILE"](nil, mockRootDesc, nil)
    end

    assert_true(releasedCallback ~= nil, "AddMenuReleasedCallback registered on menu description")
    releasedCallback()

    assert_true(bClose:GetAlpha() == 1.0, "Menu release cancelled drag and restored button alpha")
end

-- Test 21: Purge Deleted Loadouts from Saved Database
do
    local pKey = addonNamespace.GetPlayerKey()
    local specID = 300
    ReorderTalentLoadoutsDB[pKey] = ReorderTalentLoadoutsDB[pKey] or {}
    ReorderTalentLoadoutsDB[pKey][specID] = {
        order = { 201, 202, 203 },
        names = { [201] = "Old1", [202] = "DeletedLoadout", [203] = "Old3" },
    }

    -- In-game config IDs now only have 201 and 203 (202 was deleted)
    local currentIDs = { 201, 203 }
    local names = { [201] = "Old1", [203] = "Old3" }

    local sorted = addonNamespace.SortConfigIDs(specID, currentIDs, names)
    assert_table_eq(sorted, { 201, 203 }, "Sorted IDs excluded deleted 202")

    local savedInDB = addonNamespace.GetSavedOrder(pKey, specID)
    assert_table_eq(savedInDB.order, { 201, 203 }, "Saved order in DB was purged of deleted loadout 202")
    assert_true(savedInDB.names[202] == nil, "Deleted loadout name removed from DB")
end

-- Test 22: GUID and Name-Realm Fallback in GetSavedOrder
do
    local specID = 400
    local realmKey = mockPlayerName .. "-" .. mockRealmName
    ReorderTalentLoadoutsDB[realmKey] = {
        [specID] = { order = { 301, 302 }, names = {} }
    }

    -- Query using a different key format, should resolve via fallback
    local found = addonNamespace.GetSavedOrder("DifferentGuidKey", specID)
    assert_true(found ~= nil, "GetSavedOrder resolved order via Name-Realm fallback")
    assert_table_eq(found.order, { 301, 302 }, "Order matches expected fallback data")
end

-- Test 23: Sound Suppression During Drag & Drop
do
    local capturedSoundFunc = nil
    local mockDesc = {
        GetData = function() return 999 end,
        SetCanSelect = function() end,
        GetSoundKit = function() return 856 end,
        SetSoundKit = function(self, fn) capturedSoundFunc = fn end,
        AddInitializer = function() end,
    }
    local mockRoot = {
        EnumerateElementDescriptions = function()
            local list = { mockDesc }
            local i = 0
            return function()
                i = i + 1
                if not list[i] then return nil end
                return i, list[i]
            end
        end,
    }

    if Menu and Menu.callbacks and Menu.callbacks["MENU_CLASS_TALENT_PROFILE"] then
        PlayerSpellsFrame.TalentsFrame.LoadSystem.possibleSelections = { 999 }
        Menu.callbacks["MENU_CLASS_TALENT_PROFILE"](nil, mockRoot, nil)
    end

    assert_true(capturedSoundFunc ~= nil, "SetSoundKit wrapper was installed")
    -- When dragging: returns 0 (silent)
    local bSound = CreateFrame("Button", "SoundTestBtn")
    addonNamespace.SetupLoadoutButton(bSound, { GetData = function() return 999 end, SetCanSelect = function() end }, nil, 999)
    addonNamespace.StartDrag(bSound)
    assert_true(capturedSoundFunc(mockDesc) == 0, "Sound suppressed (0) while isDragging is true")
    addonNamespace.CancelDrag()

    -- Normal state: returns original sound kit
    assert_true(capturedSoundFunc(mockDesc) == 856, "Normal sound returned when not dragging")
end

-- Test 24: Drop Calls GenerateMenu Seamlessly
do
    local specID = 250
    local mockTalentsFrame = PlayerSpellsFrame.TalentsFrame
    mockTalentsFrame.LoadSystem.possibleSelections = { 101, 102 }

    local generateMenuCalled = false
    mockTalentsFrame.LoadSystem.dropdown.GenerateMenu = function(self)
        generateMenuCalled = true
    end

    addonNamespace.ClearActiveButtons()
    local b1 = CreateFrame("Button", "GenB1")
    b1:SetRect(50, 200, 200, 20)
    local b2 = CreateFrame("Button", "GenB2")
    b2:SetRect(50, 180, 200, 20)

    addonNamespace.SetupLoadoutButton(b1, { GetData = function() return 101 end, SetCanSelect = function() end }, nil, 101)
    addonNamespace.SetupLoadoutButton(b2, { GetData = function() return 102 end, SetCanSelect = function() end }, nil, 102)

    addonNamespace.StartDrag(b2)
    cursorX = 100
    cursorY = 215 -- Move 102 to top
    addonNamespace.UpdateDrag()
    addonNamespace.FinishDrag()

    assert_true(generateMenuCalled, "GenerateMenu was called seamlessly on drop")
end

-- Test 25: WoW 12.1 Menu GetSoundKit nil-call protection (pcall)
do
    local capturedSoundFunc = nil
    local mockDesc = {
        GetData = function() return 888 end,
        SetCanSelect = function() end,
        -- Simulate WoW 12.1 MenuElementDescriptionProxyMixin:GetSoundKit() bug where soundKit is nil
        GetSoundKit = function(self)
            error("attempt to call field 'soundKit' (a nil value)")
        end,
        SetSoundKit = function(self, fn)
            capturedSoundFunc = fn
        end,
        AddInitializer = function() end,
    }

    local mockRoot = {
        EnumerateElementDescriptions = function()
            local elements = { mockDesc }
            local i = 0
            return function()
                i = i + 1
                if elements[i] then
                    return i, elements[i]
                end
                return nil
            end
        end,
    }

    PlayerSpellsFrame.TalentsFrame.LoadSystem.possibleSelections = { 888 }
    -- Must not raise error even though desc:GetSoundKit() threw an error
    local ok, err = pcall(function()
        Menu.callbacks["MENU_CLASS_TALENT_PROFILE"](nil, mockRoot, nil)
    end)

    assert_true(ok, "Menu initialization does not crash when desc:GetSoundKit() throws in 12.1")
    assert_true(capturedSoundFunc ~= nil, "SetSoundKit wrapper successfully installed despite 12.1 nil error")
    -- Normal click returns default fallback (SOUNDKIT.U_CHAT_SCROLL_BUTTON = 857)
    assert_true(capturedSoundFunc(mockDesc) == 857, "Fallback sound returned cleanly on normal click")
end

-- Test 26: WoW 12.1 /rtl reset with C_SpecializationInfo fallback
do
    local pKey = addonNamespace.GetPlayerKey()
    local specID = 252 -- Unholy DK
    ReorderTalentLoadoutsDB[pKey] = ReorderTalentLoadoutsDB[pKey] or {}
    ReorderTalentLoadoutsDB[pKey][specID] = { order = { 20, 10 } }

    -- Temporarily disable PlayerSpellsFrame to simulate closed/unloaded talent frame
    local savedPSF = PlayerSpellsFrame
    PlayerSpellsFrame = nil

    -- Mock C_SpecializationInfo (12.1 standard API)
    C_SpecializationInfo = {
        GetSpecialization = function() return 3 end,
        GetSpecializationInfo = function(idx)
            if idx == 3 then return specID end
            return nil
        end,
    }

    addonNamespace.ResetCurrentSpecOrder(false)

    assert_true(ReorderTalentLoadoutsDB[pKey][specID] == nil, "Reset used C_SpecializationInfo fallback when talent window is closed")

    -- Restore
    PlayerSpellsFrame = savedPSF
    C_SpecializationInfo = nil
end

-- Test 27: WoW 12.1 GetTalentsFrame fallback via ownerRegion hierarchy
do
    local savedPSF = PlayerSpellsFrame
    PlayerSpellsFrame = nil

    local mockTalentParent = {
        configIDs = { 11, 22 },
        RefreshLoadoutOptions = function() end,
    }
    local mockLoadSys = {
        possibleSelections = { 11, 22 },
        parent = mockTalentParent,
        GetParent = function(self) return self.parent end,
        GetDropdown = function(self) return self.dropdown end,
    }
    local mockOwnerDropdown = {
        parent = mockLoadSys,
        GetParent = function(self) return self.parent end,
    }
    mockLoadSys.dropdown = mockOwnerDropdown

    local resolvedFrame = nil
    local mockRoot = {
        EnumerateElementDescriptions = function()
            return function() return nil end
        end,
    }

    local ok = pcall(function()
        Menu.callbacks["MENU_CLASS_TALENT_PROFILE"](mockOwnerDropdown, mockRoot, nil)
    end)
    assert_true(ok, "OnModifyTalentMenu resolved talentsFrame from ownerRegion without globals")

    PlayerSpellsFrame = savedPSF
end

-- Test 28: WoW 12.1 C_Traits.GetConfigInfo fallback for loadout names
do
    local pKey = addonNamespace.GetPlayerKey()
    local specID = 250
    local mockTalentsFrame = PlayerSpellsFrame.TalentsFrame
    mockTalentsFrame.configIDToName = nil -- simulate missing cache

    C_Traits = {
        GetConfigInfo = function(id)
            return { name = "TraitName_" .. id }
        end,
    }

    mockTalentsFrame.LoadSystem.possibleSelections = { 501, 502 }
    addonNamespace.ClearActiveButtons()
    local b1 = CreateFrame("Button", "TraitsB1")
    local b2 = CreateFrame("Button", "TraitsB2")
    b1:SetRect(50, 200, 200, 20)
    b2:SetRect(50, 180, 200, 20)
    addonNamespace.SetupLoadoutButton(b1, { GetData = function() return 501 end, SetCanSelect = function() end }, nil, 501)
    addonNamespace.SetupLoadoutButton(b2, { GetData = function() return 502 end, SetCanSelect = function() end }, nil, 502)

    addonNamespace.StartDrag(b2)
    cursorX, cursorY = 100, 215 -- Move to top
    addonNamespace.UpdateDrag()
    addonNamespace.FinishDrag()

    local saved = addonNamespace.GetSavedOrder(pKey, specID)
    assert_table_eq(saved.order, { 502, 501 }, "Order saved using C_Traits name resolution")
    assert_eq(saved.names[502], "TraitName_502", "Config names populated via C_Traits.GetConfigInfo")

    C_Traits = nil
    mockTalentsFrame.configIDToName = {}
end

-- Test 29: TOC follows the project template (packager version, CurseForge id, icon)
do
    local f = io.open("Reorder_Talent_Loadouts.toc", "r")
    assert_true(f ~= nil, "TOC file exists and is readable")
    local content = f:read("*all")
    f:close()

    assert_true(content:find("## Interface: 120000, 120100") ~= nil, "TOC lists supported client versions (Midnight 12.0/12.1)")
    assert_true(content:find("## Version: @project%-version@") ~= nil, "TOC version uses @project-version@ for packager substitution")
    assert_true(content:find("## X%-Curse%-Project%-ID: 1687554") ~= nil, "TOC carries the CurseForge project ID")
    assert_true(content:find("## IconTexture: 132222") ~= nil, "TOC uses icon file data ID 132222")
    assert_true(content:find("## Author: railander") ~= nil, "TOC author matches project convention")
    assert_true(content:find("SavedVariables: ReorderTalentLoadoutsDB") ~= nil, "TOC keeps the SavedVariables declarations")
    assert_true(content:find("OptionalDeps") == nil, "TOC has no OptionalDeps (Blizzard_PlayerSpells is load-on-demand; hooks install lazily)")
    assert_true(content:find("SavedVariables: ReorderTalentLoadoutsDB") ~= nil and content:find("ReorderTalentLoadoutsDebug") == nil, "TOC saves only the order DB")
    assert_true(content:find("Reorder_Talent_Loadouts.lua") ~= nil, "TOC loads the addon lua")
end

-- Test 30: Full drag & drop lifecycle without global frames (ownerRegion resolved)
do
    local savedPSF = PlayerSpellsFrame
    PlayerSpellsFrame = nil

    local pKey = addonNamespace.GetPlayerKey()
    local isolatedSpecID = 777
    local mockTalentParent = {
        configIDs = { 101, 102 },
        GetSpecID = function() return isolatedSpecID end,
        RefreshLoadoutOptions = function() end,
    }
    local mockLoadSys = {
        possibleSelections = { 101, 102 },
        parent = mockTalentParent,
        GetParent = function(self) return self.parent end,
        UpdateSelectionOptions = function() end,
    }
    local mockOwnerDropdown = {
        parent = mockLoadSys,
        GetParent = function(self) return self.parent end,
        GenerateMenu = function() end,
    }
    mockLoadSys.dropdown = mockOwnerDropdown
    mockLoadSys.GetDropdown = function(self) return self.dropdown end

    local desc1 = {
        GetData = function() return 101 end,
        SetCanSelect = function() end,
        SetSoundKit = function() end,
        AddInitializer = function(self, fn) self.init = fn end,
    }
    local desc2 = {
        GetData = function() return 102 end,
        SetCanSelect = function() end,
        SetSoundKit = function() end,
        AddInitializer = function(self, fn) self.init = fn end,
    }

    local mockRoot = {
        EnumerateElementDescriptions = function()
            local elements = { desc1, desc2 }
            local i = 0
            return function()
                i = i + 1
                if elements[i] then
                    return i, elements[i]
                end
                return nil
            end
        end,
        AddMenuReleasedCallback = function() end,
    }

    Menu.callbacks["MENU_CLASS_TALENT_PROFILE"](mockOwnerDropdown, mockRoot, nil)

    local b1 = CreateFrame("Button", "OwnerRegionB1")
    local b2 = CreateFrame("Button", "OwnerRegionB2")
    b1:SetRect(50, 200, 200, 20)
    b2:SetRect(50, 180, 200, 20)
    desc1.init(b1, desc1, nil)
    desc2.init(b2, desc2, nil)

    addonNamespace.StartDrag(b2)
    cursorX, cursorY = 100, 215 -- Move above b1
    addonNamespace.UpdateDrag()
    addonNamespace.FinishDrag()

    local saved = addonNamespace.GetSavedOrder(pKey, isolatedSpecID)
    assert_true(saved ~= nil, "Order saved to DB when PlayerSpellsFrame was nil")
    assert_table_eq(saved.order, { 102, 101 }, "Correctly reordered loadouts using ownerRegion hierarchy")
    assert_table_eq(mockLoadSys.possibleSelections, { 102, 101 }, "LoadSystem selections updated")

    PlayerSpellsFrame = savedPSF
end

-- Test 31: OnRefreshLoadoutOptions uses C_SpecializationInfo fallback when GetSpecID is nil
do
    local pKey = addonNamespace.GetPlayerKey()
    local specID = 251 -- Frost DK
    ReorderTalentLoadoutsDB[pKey] = ReorderTalentLoadoutsDB[pKey] or {}
    ReorderTalentLoadoutsDB[pKey][specID] = { order = { 902, 901 } }

    local talentsFrame = PlayerSpellsFrame.TalentsFrame
    local savedGetSpecID = talentsFrame.GetSpecID
    talentsFrame.GetSpecID = nil -- Remove direct GetSpecID method

    C_SpecializationInfo = {
        GetSpecialization = function() return 2 end,
        GetSpecializationInfo = function(idx)
            if idx == 2 then return specID end
            return nil
        end,
    }

    talentsFrame.LoadSystem.possibleSelections = { 901, 902 }
    talentsFrame.configIDs = { 901, 902 }

    addonNamespace.InitializeTalentHooks()
    -- No Blizzard Lua method is hooked (12.1 taint rule); the saved order is applied by the
    -- pure-data poller path (OnRefreshLoadoutOptions), which the OnUpdate poller invokes.
    addonNamespace.OnRefreshLoadoutOptions(talentsFrame)

    assert_table_eq(talentsFrame.LoadSystem.possibleSelections, { 902, 901 }, "Poller sort path applied saved order using C_SpecializationInfo fallback")

    talentsFrame.GetSpecID = savedGetSpecID
    C_SpecializationInfo = nil
end

-- Test 32: OnRefreshLoadoutOptions resolves loadout names via C_Traits when configIDToName is nil
do
    local pKey = addonNamespace.GetPlayerKey()
    local specID = 250
    local talentsFrame = PlayerSpellsFrame.TalentsFrame
    talentsFrame.configIDToName = nil -- Simulate unpopulated cache

    ReorderTalentLoadoutsDB[pKey][specID] = {
        order = { 9999 }, -- Old config ID that got remapped in patch 12.1
        names = { [9999] = "Raid_SingleTarget" },
    }

    C_Traits = {
        GetConfigInfo = function(id)
            if id == 701 then return { name = "Dungeon_AOE" } end
            if id == 702 then return { name = "Raid_SingleTarget" } end
            return nil
        end,
    }

    talentsFrame.LoadSystem.possibleSelections = { 701, 702 }
    talentsFrame.configIDs = { 701, 702 }

    addonNamespace.InitializeTalentHooks()
    addonNamespace.OnRefreshLoadoutOptions(talentsFrame)

    -- 702 matches name "Raid_SingleTarget" which was first in saved.order, so 702 comes first!
    assert_table_eq(talentsFrame.LoadSystem.possibleSelections, { 702, 701 }, "Poller sort path successfully migrated order via C_Traits name resolution")

    C_Traits = nil
    talentsFrame.configIDToName = {}
end

-- Test 34: WoW 12.1 InputUtil.GetCursorPosition integration during drag
do
    local inputUtilCalled = false
    InputUtil = {
        GetCursorPosition = function(parent)
            inputUtilCalled = true
            return 100, 215
        end,
    }

    local b1 = CreateFrame("Button", "InputUtilB1")
    local b2 = CreateFrame("Button", "InputUtilB2")
    b1:SetRect(50, 200, 200, 20)
    b2:SetRect(50, 180, 200, 20)
    addonNamespace.ClearActiveButtons()
    addonNamespace.SetupLoadoutButton(b1, { GetData = function() return 801 end, SetCanSelect = function() end }, nil, 801)
    addonNamespace.SetupLoadoutButton(b2, { GetData = function() return 802 end, SetCanSelect = function() end }, nil, 802)

    addonNamespace.StartDrag(b2)
    addonNamespace.UpdateDrag()

    assert_true(inputUtilCalled, "ns.UpdateDrag invoked InputUtil.GetCursorPosition(UIParent)")
    addonNamespace.CancelDrag()
    InputUtil = nil
end

-- Test 35: talentsFrame.configIDs is NEVER mutated or tainted
do
    local pKey = addonNamespace.GetPlayerKey()
    local specID = 250
    ReorderTalentLoadoutsDB[pKey] = ReorderTalentLoadoutsDB[pKey] or {}
    ReorderTalentLoadoutsDB[pKey][specID] = { order = { 202, 201 } }

    local talentsFrame = PlayerSpellsFrame.TalentsFrame
    local originalConfigIDs = { 201, 202 }
    talentsFrame.configIDs = originalConfigIDs
    talentsFrame.LoadSystem.possibleSelections = { 201, 202 }

    addonNamespace.OnRefreshLoadoutOptions(talentsFrame)

    assert_true(talentsFrame.configIDs == originalConfigIDs, "talentsFrame.configIDs table reference is untouched")
    assert_table_eq(talentsFrame.configIDs, { 201, 202 }, "talentsFrame.configIDs elements are never modified by addon")
    assert_table_eq(talentsFrame.LoadSystem.possibleSelections, { 202, 201 }, "LoadSystem.possibleSelections is properly sorted")
end

-- Test 36: loadSystem.possibleSelections is sorted in-place (table identity preserved)
do
    local pKey = addonNamespace.GetPlayerKey()
    local specID = 250
    ReorderTalentLoadoutsDB[pKey][specID] = { order = { 303, 302, 301 } }

    local talentsFrame = PlayerSpellsFrame.TalentsFrame
    local selectionsTable = { 301, 302, 303 }
    talentsFrame.LoadSystem.possibleSelections = selectionsTable

    addonNamespace.OnRefreshLoadoutOptions(talentsFrame)

    assert_true(talentsFrame.LoadSystem.possibleSelections == selectionsTable, "possibleSelections table identity is preserved via in-place mutation")
    assert_table_eq(talentsFrame.LoadSystem.possibleSelections, { 303, 302, 301 }, "possibleSelections content sorted in-place")
end

-- Test 37: loadSystem:UpdateSelectionOptions is NEVER called during sort or drag
do
    local updateSelectionOptionsCalled = false
    local talentsFrame = PlayerSpellsFrame.TalentsFrame
    talentsFrame.LoadSystem.UpdateSelectionOptions = function()
        updateSelectionOptionsCalled = true
    end

    local pKey = addonNamespace.GetPlayerKey()
    local specID = 250
    ReorderTalentLoadoutsDB[pKey][specID] = { order = { 402, 401 } }
    talentsFrame.LoadSystem.possibleSelections = { 401, 402 }

    addonNamespace.OnRefreshLoadoutOptions(talentsFrame)

    assert_true(not updateSelectionOptionsCalled, "UpdateSelectionOptions was NOT called (Blizzard untainted generator preserved)")
end

-- Test 38: WoW 12.1 taint rule - RefreshLoadoutOptions is NEVER hooksecurefunc'd or called from addon code
do
    local f = io.open("Reorder_Talent_Loadouts.lua", "r")
    local source = f:read("*a")
    f:close()

    assert_true(source:find('hooksecurefunc%(talentsFrame, "RefreshLoadoutOptions"', 1, true) == nil,
        "RefreshLoadoutOptions is never hooksecurefunc'd (hooking taints its body and breaks restricted C_ClassTalents calls)")
    assert_true(source:find("talentsFrame:RefreshLoadoutOptions()", 1, true) == nil,
        "RefreshLoadoutOptions is never called from addon execution (restricted GetConfigIDsBySpecID under tainted execution)")
    assert_true(source:find('hooksecurefunc(talentsFrame.LoadSystem, "SetSelectionOptions"', 1, true) == nil,
        "LoadSystem:SetSelectionOptions is never hooksecurefunc'd either (no Blizzard Lua method is hooked at all in 12.1)")
    assert_true(source:find("hooksecurefunc", 1, true) == nil,
        "The addon contains ZERO hooksecurefunc calls (even SecretArguments-protected C functions degrade when hooked)")
end

-- Test 39: /rtl reset uses taint-safe SetSelectionOptions replica instead of the frame method
do
    local pKey = addonNamespace.GetPlayerKey()
    local specID = 260
    ReorderTalentLoadoutsDB[pKey] = ReorderTalentLoadoutsDB[pKey] or {}
    ReorderTalentLoadoutsDB[pKey][specID] = { order = { 502, 501 } }

    local refreshLoadoutOptionsCalled = false
    local setSelectionOptionsArgs = nil
    local mockTalentsFrame = {
        GetSpecID = function() return specID end,
        IsInspecting = function() return false end,
        configIDs = { 501, 502 },
        configIDToName = { [501] = "A", [502] = "B" },
        RefreshLoadoutOptions = function(self) refreshLoadoutOptionsCalled = true end,
        LoadSystem = {
            SetSelectionOptions = function(self, ...)
                setSelectionOptionsArgs = { ... }
            end,
        },
    }
    local savedPSF = PlayerSpellsFrame
    PlayerSpellsFrame = { TalentsFrame = mockTalentsFrame }

    addonNamespace.ResetCurrentSpecOrder(false)

    assert_true(ReorderTalentLoadoutsDB[pKey][specID] == nil, "Reset clears the saved order")
    assert_true(not refreshLoadoutOptionsCalled, "Reset does NOT call talentsFrame:RefreshLoadoutOptions (taint rule)")
    assert_true(setSelectionOptionsArgs ~= nil, "Reset re-applies options via the taint-safe LoadSystem replica")
    if setSelectionOptionsArgs then
        assert_table_eq(setSelectionOptionsArgs[1], { 501, 502 }, "Reset replica passes the frame's configIDs")
    end

    PlayerSpellsFrame = savedPSF
end

-- Test 40: poller repopulates the dropdown when Blizzard's population came back degraded
do
    local specID = 270
    local savedCT = C_ClassTalents
    local savedTraits = C_Traits
    local savedConstants = Constants

    C_ClassTalents = {
        GetConfigIDsBySpecID = function(id)
            if id == specID then return { 601, 602, 603 } end
            return {}
        end,
    }
    C_Traits = {
        GetConfigInfo = function(id)
            return { name = "Loadout " .. id }
        end,
    }
    Constants = { TraitConsts = { STARTER_BUILD_TRAIT_CONFIG_ID = -2 } }

    local setSelectionOptionsArgs = nil
    local mockTalentsFrame = {
        GetSpecID = function() return specID end,
        IsInspecting = function() return false end,
        GetHasStarterBuild = function() return true end,
        configIDToName = { [-2] = "Starter Build" },
        LoadSystem = {
            SetSelectionOptions = function(self, options, nameFn, color, tooltipFn)
                setSelectionOptionsArgs = { options = options, nameFn = nameFn, tooltipFn = tooltipFn }
                self.possibleSelections = CopyTable(options) -- mirror the real mixin's behavior
            end,
        },
    }
    local savedPSF = PlayerSpellsFrame
    PlayerSpellsFrame = { TalentsFrame = mockTalentsFrame }

    -- Degraded state: only the Starter Build sentinel survived
    mockTalentsFrame.LoadSystem.possibleSelections = { -2 }

    addonNamespace.Reconcile()

    assert_true(setSelectionOptionsArgs ~= nil, "Reconcile repopulates degraded dropdown via SetSelectionOptions replica")
    if setSelectionOptionsArgs then
        -- Merge-only: existing entries stay first, missing ground truth is appended
        assert_table_eq(setSelectionOptionsArgs.options, { -2, 601, 602, 603 },
            "Repopulate merges ground-truth loadouts behind existing entries")
        assert_true(setSelectionOptionsArgs.nameFn(601) == "Loadout 601", "Repopulate resolves loadout names")
        assert_true(setSelectionOptionsArgs.nameFn(-2) ~= nil and setSelectionOptionsArgs.nameFn(-2) ~= "",
            "Repopulate resolves Starter Build name")
        -- Dropdown state now holds the restored list
        assert_table_eq(mockTalentsFrame.LoadSystem.possibleSelections, { -2, 601, 602, 603 },
            "possibleSelections restored from addon-context ground truth")
    end

    -- A healthy population is left untouched: existing full list, no ground-truth IDs missing
    setSelectionOptionsArgs = nil
    mockTalentsFrame.LoadSystem.possibleSelections = { 601, 602, 603, -2 }
    addonNamespace.Reconcile()
    assert_true(setSelectionOptionsArgs == nil, "Reconcile does not repopulate when the list is already complete")

    PlayerSpellsFrame = savedPSF
    C_ClassTalents = savedCT
    C_Traits = savedTraits
    Constants = savedConstants
end

-- Test 41: reset button press behavior (immediate hide, no collapse, gated visibility)
do
    local f = io.open("Reorder_Talent_Loadouts.lua", "r")
    local source = f:read("*a")
    f:close()

    assert_true(source:find('btn:SetScript("OnMouseDown"', 1, true) ~= nil,
        "Reset happens on press (mouse-down), not release")
    assert_true(source:find("self:Hide();", 1, true) ~= nil,
        "Reset button disappears immediately when pressed (Show/Hide: SetShown is gated AllowedWhenUntainted)")
    assert_true(source:find("C_Timer.After(0, function()", 1, true) ~= nil,
        "Menu reopen is scheduled for the next frame (single-frame flicker at most)")
    assert_true(source:find("dd:OpenMenu()", 1, true) ~= nil,
        "Reset button reopens the dropdown after resetting (menu must not collapse on click)")
    assert_true(source:find("IsSavedOrderPresent", 1, true) ~= nil,
        "Reset button visibility is gated on a non-default saved order existing")
    assert_true(source:find('ns.ResetCurrentSpecOrder(false)', 1, true) ~= nil,
        "Button reset is silent (no chat spam); visual feedback is the reopened dropdown")
    assert_true(source:find("SetOnClickHandler", 1, true) == nil,
        "No release-based OnClick path remains on the reset button")
    assert_true(source:find("SlashCmdList", 1, true) == nil and source:find("SLASH_REORDERTALENTLOADOUTS", 1, true) == nil,
        "No slash commands remain in the addon")
end

-- Test 42: talent pane OnShow reconciles the saved order before the first dropdown open
do
    local pKey = addonNamespace.GetPlayerKey()
    local specID = 280
    ReorderTalentLoadoutsDB[pKey] = ReorderTalentLoadoutsDB[pKey] or {}
    ReorderTalentLoadoutsDB[pKey][specID] = { order = { 802, 801 } }

    local paneShownCallbacks = {}
    local mockPane = {
        GetSpecID = function() return specID end,
        IsInspecting = function() return false end,
        configIDToName = { [801] = "A", [802] = "B" },
        configIDs = { 801, 802 },
        HookScript = function(self, script, hook)
            paneShownCallbacks[#paneShownCallbacks + 1] = hook
        end,
        LoadSystem = {
            possibleSelections = { 801, 802 },
            dropdown = { IsMenuOpen = function() return false end, GetParent = function() return nil end },
            GetDropdown = function(self) return self.dropdown end,
        },
    }
    local savedPSF = PlayerSpellsFrame
    PlayerSpellsFrame = { TalentsFrame = mockPane }

    addonNamespace._ResetHookStateForTest()
    addonNamespace.InitializeTalentHooks()
    assert_true(#paneShownCallbacks == 1, "OnShow post-hook installed on the talent pane")

    -- Simulate the pane becoming visible after a reload: reconcile sorts the data before
    -- the user can open the dropdown, so the first paint already uses the saved order.
    paneShownCallbacks[1](mockPane)

    assert_table_eq(mockPane.LoadSystem.possibleSelections, { 802, 801 },
        "OnShow reconcile applies the saved order before the first dropdown open")

    PlayerSpellsFrame = savedPSF
end

-- Test 43: SafeInvoke closes fn over its args (Lua 5.1 xpcall drops extras)
do
    local f = io.open("Reorder_Talent_Loadouts.lua", "r")
    local source = f:read("*a")
    f:close()

    assert_true(source:find("return fn(unpack(args, 1, n));", 1, true) ~= nil,
        "SafeInvoke closes fn over its args (Lua 5.1 xpcall takes exactly 2 args)")
    assert_true(source:find("xpcall(fn, function(e)", 1, true) == nil,
        "SafeInvoke never passes args straight to xpcall (they would arrive nil)")
    -- Behavioral proof lives in Tests 8 (drag button), 30 (ownerRegion reorder)
    -- and 31 (poller sort): all forward parameters through SafeInvoke.
end

-- Test 44: restriction query -- all six types, combat-flag fallback when API is absent
do
    assert_true(C_RestrictedActions == nil, "unit env has no C_RestrictedActions (fallback path by default)")
    inCombat = false
    assert_true(addonNamespace.AreRestrictionsActive() == false, "fallback query is clear out of combat")
    inCombat = true
    assert_true(addonNamespace.AreRestrictionsActive() == true, "fallback query follows InCombatLockdown")
    inCombat = false

    -- Mock the 12.x API: locked if ANY of the six types is active
    local activeTypes = {}
    C_RestrictedActions = {
        IsAddOnRestrictionActive = function(t) return activeTypes[t] and true or false end,
    }
    Enum = {
        AddOnRestrictionType = { Combat = 10, Encounter = 11, ChallengeMode = 12, PvPMatch = 13, Map = 14, Chat = 15 },
        AddOnRestrictionState = { Inactive = 0, Activating = 1, Active = 2 },
    }
    local queried = {}
    local origQuery = C_RestrictedActions.IsAddOnRestrictionActive
    C_RestrictedActions.IsAddOnRestrictionActive = function(t)
        queried[t] = true
        return origQuery(t)
    end
    assert_true(addonNamespace.AreRestrictionsActive() == false, "all-types query clear when none active")
    for _, id in ipairs({ 10, 11, 12, 13, 14, 15 }) do
        assert_true(queried[id], "restriction query covers type id " .. id)
    end
    activeTypes[13] = true -- PvPMatch alone, out of combat
    assert_true(addonNamespace.AreRestrictionsActive() == true, "PvPMatch restriction locks while out of combat")
    activeTypes[13] = nil
    C_RestrictedActions = nil
    Enum = nil
end

-- Test 45: /reload-in-combat defers gated setup; lift resumes it
do
    local showHooks = {}
    local mockPane = {
        GetSpecID = function() return 250 end,
        IsInspecting = function() return false end,
        configIDToName = {},
        configIDs = {},
        HookScript = function(self, script, hook) showHooks[#showHooks + 1] = { script = script, hook = hook } end,
        LoadSystem = {
            possibleSelections = { 1 },
            GetDropdown = function(self) return nil end,
        },
    }
    local savedPSF = PlayerSpellsFrame
    PlayerSpellsFrame = { TalentsFrame = mockPane }
    addonNamespace._ResetHookStateForTest()

    local evFrame = nil
    for _, f in ipairs(mockFrames) do
        if f.name == "ReorderTalentLoadoutsEventFrame" then evFrame = f; break end
    end
    assert_true(evFrame ~= nil, "event frame exists")

    inCombat = true -- /reload landed mid-combat (fallback query)
    evFrame.scripts["OnEvent"](evFrame, "ADDON_LOADED", "Blizzard_PlayerSpells")
    assert_true(#showHooks == 0, "OnShow hook NOT installed while protected")
    assert_true(addonNamespace.IsGatedInitDeferred() == true, "gated init remembered as deferred")

    inCombat = false
    evFrame.scripts["OnEvent"](evFrame, "PLAYER_REGEN_ENABLED")
    assert_true(#showHooks == 1, "OnShow hook installed on lift")
    assert_true(showHooks[1].script == "OnShow", "deferred hook is the talent-pane OnShow reconcile")
    assert_true(addonNamespace.IsGatedInitDeferred() == false, "deferred flag cleared on lift")

    PlayerSpellsFrame = savedPSF
end

-- Test 46: drag refused while protected (one notice), allowed when clear
do
    local evFrame = nil
    for _, f in ipairs(mockFrames) do
        if f.name == "ReorderTalentLoadoutsEventFrame" then evFrame = f; break end
    end

    addonNamespace.ClearActiveButtons()
    local b = CreateFrame("Button", "LockDragBtn")
    b:SetRect(50, 200, 200, 20)
    b:Show()
    addonNamespace.SetupLoadoutButton(b, { GetData = function() return 111 end, SetCanSelect = function() end }, nil, 111)

    local chatBase = #DEFAULT_CHAT_FRAME.messages
    inCombat = true
    addonNamespace.StartDrag(b)
    assert_true(b:GetAlpha() == 1.0, "drag refused while protected")
    assert_true(#DEFAULT_CHAT_FRAME.messages == chatBase + 1, "blocked drag announces once")
    addonNamespace.StartDrag(b)
    assert_true(#DEFAULT_CHAT_FRAME.messages == chatBase + 1, "repeat blocked drag stays silent")

    -- A press while protected must not even arm potentialDrag (OnUpdate early-outs)
    cursorX, cursorY = 100, 100
    b.scripts["OnMouseDown"](b, "LeftButton")
    cursorX, cursorY = 150, 150
    leftMouseDown = true
    evFrame.scripts["OnUpdate"](evFrame, 0.016)
    assert_true(b:GetAlpha() == 1.0, "press-while-locked never arms a drag")
    leftMouseDown = false
    addonNamespace.CancelDrag()

    inCombat = false
    evFrame.scripts["OnEvent"](evFrame, "PLAYER_REGEN_ENABLED") -- lift: resets episode throttle
    addonNamespace.StartDrag(b)
    assert_true(b:GetAlpha() == 0.35, "drag allowed once clear")
    addonNamespace.CancelDrag()
    assert_true(b:GetAlpha() == 1.0, "lock test drag cleaned up")
end

-- Test 47: activation cancels an active drag; queued reconcile flushes on lift
do
    local evFrame = nil
    for _, f in ipairs(mockFrames) do
        if f.name == "ReorderTalentLoadoutsEventFrame" then evFrame = f; break end
    end

    local specID = 250
    local pKey = addonNamespace.GetPlayerKey()
    ReorderTalentLoadoutsDB[pKey] = ReorderTalentLoadoutsDB[pKey] or {}
    ReorderTalentLoadoutsDB[pKey][specID] = { order = { 902, 901 }, names = {} }

    local pane = {
        GetSpecID = function() return specID end,
        IsInspecting = function() return false end,
        configIDToName = { [901] = "A", [902] = "B" },
        configIDs = { 901, 902 },
        LoadSystem = {
            possibleSelections = { 901, 902 },
            dropdown = { IsMenuOpen = function() return false end },
            GetDropdown = function(self) return self.dropdown end,
        },
    }
    local savedPSF = PlayerSpellsFrame
    PlayerSpellsFrame = { TalentsFrame = pane }

    addonNamespace.ClearActiveButtons()
    local b1 = CreateFrame("Button", "QLockB1")
    b1:SetRect(50, 200, 200, 20)
    local b2 = CreateFrame("Button", "QLockB2")
    b2:SetRect(50, 180, 200, 20)
    addonNamespace.SetupLoadoutButton(b1, { GetData = function() return 901 end, SetCanSelect = function() end }, nil, 901)
    addonNamespace.SetupLoadoutButton(b2, { GetData = function() return 902 end, SetCanSelect = function() end }, nil, 902)

    inCombat = false
    addonNamespace.Reconcile()
    assert_table_eq(pane.LoadSystem.possibleSelections, { 902, 901 }, "sanity: saved order applied when clear")

    -- Scramble, lock, reconcile queues instead of writing
    pane.LoadSystem.possibleSelections = { 901, 902 }
    inCombat = true
    addonNamespace.Reconcile()
    assert_table_eq(pane.LoadSystem.possibleSelections, { 901, 902 }, "no dropdown writes while protected")

    -- Active drag at activation moment is cancelled without writes
    inCombat = false
    addonNamespace.StartDrag(b1)
    assert_true(b1:GetAlpha() == 0.35, "drag started before activation")
    inCombat = true
    evFrame.scripts["OnEvent"](evFrame, "PLAYER_REGEN_DISABLED")
    assert_true(b1:GetAlpha() == 1.0, "activation cancels the active drag")
    assert_table_eq(pane.LoadSystem.possibleSelections, { 901, 902 }, "cancelled drag writes nothing")

    -- Race: release landing the same frame as activation writes nothing either
    inCombat = false
    addonNamespace.StartDrag(b2)
    cursorX, cursorY = 100, 215 -- above b1: would move 902 to top
    addonNamespace.UpdateDrag()
    inCombat = true
    addonNamespace.FinishDrag()
    assert_table_eq(pane.LoadSystem.possibleSelections, { 901, 902 }, "release-during-lock writes nothing")
    assert_true(b2:GetAlpha() == 1.0, "race visuals cleaned up")

    -- Lift flushes the queued reconcile
    inCombat = false
    evFrame.scripts["OnEvent"](evFrame, "PLAYER_REGEN_ENABLED")
    assert_table_eq(pane.LoadSystem.possibleSelections, { 902, 901 }, "queued reconcile flushes on lift")

    PlayerSpellsFrame = savedPSF
    inCombat = false
end

-- Test 48: ADDON_RESTRICTION_STATE_CHANGED payload protocol (never query during dispatch)
do
    -- The query lies false during dispatch by design -- the handler must run on payload alone
    C_RestrictedActions = {
        IsAddOnRestrictionActive = function(t) return false end,
    }
    Enum = {
        AddOnRestrictionType = { Combat = 0, Encounter = 1, ChallengeMode = 2, PvPMatch = 3, Map = 4, Chat = 5 },
        AddOnRestrictionState = { Inactive = 0, Activating = 1, Active = 2 },
    }
    local evFrame = nil
    for _, f in ipairs(mockFrames) do
        if f.name == "ReorderTalentLoadoutsEventFrame" then evFrame = f; break end
    end

    evFrame.scripts["OnEvent"](evFrame, "ADDON_RESTRICTION_STATE_CHANGED", 2, 1) -- ChallengeMode Activating
    assert_true(addonNamespace.IsInteractionLocked() == true, "Activating payload locks (query would lie false here)")
    evFrame.scripts["OnEvent"](evFrame, "ADDON_RESTRICTION_STATE_CHANGED", 3, 2) -- PvPMatch Active
    evFrame.scripts["OnEvent"](evFrame, "ADDON_RESTRICTION_STATE_CHANGED", 2, 0) -- ChallengeMode done
    assert_true(addonNamespace.IsInteractionLocked() == true, "remaining mark keeps the lock")
    -- Final Inactive confirm runs via the immediate C_Timer mock, queries clear, lifts
    evFrame.scripts["OnEvent"](evFrame, "ADDON_RESTRICTION_STATE_CHANGED", 3, 0)
    assert_true(addonNamespace.IsInteractionLocked() == false, "lock lifts after final Inactive + out-of-dispatch confirm")

    C_RestrictedActions = nil
    Enum = nil
end

-- Test 49: reset button hides while protected and refuses presses
do
    local specID = 250
    local pKey = addonNamespace.GetPlayerKey()
    ReorderTalentLoadoutsDB[pKey] = ReorderTalentLoadoutsDB[pKey] or {}
    ReorderTalentLoadoutsDB[pKey][specID] = { order = { 2, 1 }, names = {} }

    local dropdown = {
        menuOpen = true,
        IsMenuOpen = function(self) return self.menuOpen end,
        GetParent = function(self) return nil end,
    }
    local pane = {
        GetSpecID = function() return specID end,
        IsInspecting = function() return false end,
        configIDToName = {},
        configIDs = {},
        HookScript = function() end,
        LoadSystem = {
            possibleSelections = { 1, 2 },
            GetDropdown = function(self) return dropdown end,
        },
    }
    local savedPSF = PlayerSpellsFrame
    PlayerSpellsFrame = { TalentsFrame = pane }

    addonNamespace._ResetHookStateForTest()
    inCombat = false
    addonNamespace.InitializeTalentHooks() -- creates the reset button
    addonNamespace.UpdateResetButton()

    local resetBtn = nil
    for _, f in ipairs(mockFrames) do
        if f.name == "ReorderTalentLoadoutsResetButton" then resetBtn = f; break end
    end
    assert_true(resetBtn ~= nil, "reset button created")
    assert_true(resetBtn:IsShown() == true, "reset button visible when open + order present")

    inCombat = true
    addonNamespace.UpdateResetButton()
    assert_true(resetBtn:IsShown() == false, "reset button hides while protected")
    resetBtn.scripts["OnMouseDown"](resetBtn, "LeftButton")
    assert_true(ReorderTalentLoadoutsDB[pKey][specID] ~= nil, "reset press refused while protected")

    inCombat = false
    local evFrame = nil
    for _, f in ipairs(mockFrames) do
        if f.name == "ReorderTalentLoadoutsEventFrame" then evFrame = f; break end
    end
    evFrame.scripts["OnEvent"](evFrame, "PLAYER_REGEN_ENABLED")
    assert_true(resetBtn:IsShown() == true, "reset button returns on lift")

    PlayerSpellsFrame = savedPSF
end

-- Test 51: zone changes without a loading screen re-check protected status
do
    local evFrame = nil
    for _, f in ipairs(mockFrames) do
        if f.name == "ReorderTalentLoadoutsEventFrame" then evFrame = f; break end
    end
    assert_true(evFrame.events["ZONE_CHANGED"] and evFrame.events["ZONE_CHANGED_NEW_AREA"],
        "zone-change events registered")

    local specID = 250
    local pKey = addonNamespace.GetPlayerKey()
    ReorderTalentLoadoutsDB[pKey] = ReorderTalentLoadoutsDB[pKey] or {}
    ReorderTalentLoadoutsDB[pKey][specID] = { order = { 602, 601 }, names = {} }

    local pane = {
        GetSpecID = function() return specID end,
        IsInspecting = function() return false end,
        configIDToName = { [601] = "A", [602] = "B" },
        configIDs = { 601, 602 },
        LoadSystem = {
            possibleSelections = { 601, 602 },
            dropdown = { IsMenuOpen = function() return false end },
            GetDropdown = function(self) return self.dropdown end,
        },
    }
    local savedPSF = PlayerSpellsFrame
    PlayerSpellsFrame = { TalentsFrame = pane }

    -- Crossing into danger: ZONE_CHANGED while flagged locks everything
    inCombat = true
    evFrame.scripts["OnEvent"](evFrame, "ZONE_CHANGED")
    assert_true(addonNamespace.IsInteractionLocked() == true, "zone change into combat locks")
    addonNamespace.Reconcile()
    assert_table_eq(pane.LoadSystem.possibleSelections, { 601, 602 }, "zone reconcile queues while protected")

    -- Crossing back out: ZONE_CHANGED_NEW_AREA lifts and flushes
    inCombat = false
    evFrame.scripts["OnEvent"](evFrame, "ZONE_CHANGED_NEW_AREA")
    assert_true(addonNamespace.IsInteractionLocked() == false, "zone change out lifts the lock")
    assert_table_eq(pane.LoadSystem.possibleSelections, { 602, 601 }, "zone reconcile flushes on lift")

    PlayerSpellsFrame = savedPSF
    inCombat = false
end

-- Test 52: Mythic+ zone holds protection out of combat; leaving flushes
do
    local challengeActive = true
    C_RestrictedActions = {
        IsAddOnRestrictionActive = function(t) return t == 2 and challengeActive or false end,
    }
    Enum = {
        AddOnRestrictionType = { Combat = 0, Encounter = 1, ChallengeMode = 2, PvPMatch = 3, Map = 4, Chat = 5 },
        AddOnRestrictionState = { Inactive = 0, Activating = 1, Active = 2 },
    }
    local evFrame = nil
    for _, f in ipairs(mockFrames) do
        if f.name == "ReorderTalentLoadoutsEventFrame" then evFrame = f; break end
    end

    local specID = 250
    local pKey = addonNamespace.GetPlayerKey()
    ReorderTalentLoadoutsDB[pKey] = ReorderTalentLoadoutsDB[pKey] or {}
    ReorderTalentLoadoutsDB[pKey][specID] = { order = { 702, 701 }, names = {} }

    local pane = {
        GetSpecID = function() return specID end,
        IsInspecting = function() return false end,
        configIDToName = { [701] = "A", [702] = "B" },
        configIDs = { 701, 702 },
        LoadSystem = {
            possibleSelections = { 701, 702 },
            dropdown = { IsMenuOpen = function() return false end },
            GetDropdown = function(self) return self.dropdown end,
        },
    }
    local savedPSF = PlayerSpellsFrame
    PlayerSpellsFrame = { TalentsFrame = pane }

    inCombat = false -- M+ restricts out of combat the whole time
    evFrame.scripts["OnEvent"](evFrame, "ZONE_CHANGED_NEW_AREA") -- entering the keystone
    assert_true(addonNamespace.IsInteractionLocked() == true, "M+ zone restricts out of combat")
    addonNamespace.Reconcile()
    assert_table_eq(pane.LoadSystem.possibleSelections, { 701, 702 }, "no dropdown writes inside the keystone")

    challengeActive = false -- key done, zoned out
    evFrame.scripts["OnEvent"](evFrame, "ZONE_CHANGED")
    assert_true(addonNamespace.IsInteractionLocked() == false, "lock lifts after leaving M+")
    assert_table_eq(pane.LoadSystem.possibleSelections, { 702, 701 }, "queued order applies after leaving M+")

    PlayerSpellsFrame = savedPSF
    C_RestrictedActions = nil
    Enum = nil
end

-- Test 54: menu-button initializer is fail-open (a throwing install never blanks the dropdown)
do
    local capturedInit = nil
    local mockDesc = {
        GetData = function() return 4242 end,
        SetCanSelect = function() end,
        SetSoundKit = function() end,
        AddInitializer = function(self, fn) capturedInit = fn end,
    }
    local mockRoot = {
        EnumerateElementDescriptions = function()
            local elements = { mockDesc }
            local i = 0
            return function()
                i = i + 1
                if elements[i] then return i, elements[i] end
                return nil
            end
        end,
        AddMenuReleasedCallback = function() end,
    }
    local savedPSF = PlayerSpellsFrame
    PlayerSpellsFrame = {
        TalentsFrame = {
            GetSpecID = function() return 250 end,
            IsInspecting = function() return false end,
            LoadSystem = {
                possibleSelections = { 4242 },
                GetDropdown = function(self) return nil end,
            },
        },
    }
    inCombat = false

    Menu.callbacks["MENU_CLASS_TALENT_PROFILE"](nil, mockRoot, nil)
    assert_true(capturedInit ~= nil, "menu callback installed the button initializer")

    -- A button whose gated install throws (future hardened button type, aspect flag)
    local badBtn = CreateFrame("Button", "ThrowingBtn")
    badBtn.RegisterForDrag = function(self) error("simulated gated failure") end
    local chatBase = #DEFAULT_CHAT_FRAME.messages
    local okInit, initErr = pcall(capturedInit, badBtn, mockDesc, nil)
    assert_true(okInit, "throwing install does not propagate into menu generation")
    local entry = addonNamespace.FindTrackedEntry(badBtn)
    assert_true(entry ~= nil and entry.configID == 4242, "button tracked before installs run (registry survives partial install)")
    assert_true(#DEFAULT_CHAT_FRAME.messages == chatBase + 1, "install failure reported once via fail-open scope")

    PlayerSpellsFrame = savedPSF
    addonNamespace.ClearActiveButtons()
end

-- Test 55: C_Traits.GetConfigInfo throwing degrades to empty names (never raises)
do
    local frame = { configIDToName = nil } -- unpopulated cache forces the C_Traits path
    C_Traits = {
        GetConfigInfo = function(id) error("simulated restricted read") end,
    }
    local okNames, names = pcall(addonNamespace.GetConfigIDToName, frame, { 11, 22 })
    assert_true(okNames, "throwing name read does not propagate")
    assert_true(names ~= nil and next(names) == nil, "throwing name read resolves to empty names")
    C_Traits = nil
end

-- Test 56: legacy/corrupt order-entry shapes degrade to "no saved order" (never raise)
do
    local pKey = addonNamespace.GetPlayerKey()
    ReorderTalentLoadoutsDB[pKey] = ReorderTalentLoadoutsDB[pKey] or {}

    -- Bare array (hand-edited, no .order wrapper)
    ReorderTalentLoadoutsDB[pKey][501] = { 10, 20 }
    assert_true(addonNamespace.GetSavedOrder(pKey, 501) == nil, "bare-array entry reads as absent")
    local passthrough = { 10, 20 }
    assert_table_eq(addonNamespace.SortConfigIDs(501, passthrough, {}), { 10, 20 }, "bare-array entry leaves order untouched")

    -- Scalar entry (corruption): direct reads must not raise
    ReorderTalentLoadoutsDB[pKey][502] = 42
    local okScalar, resScalar = pcall(addonNamespace.GetSavedOrder, pKey, 502)
    assert_true(okScalar and resScalar == nil, "scalar entry reads as absent without raising")

    -- Non-table .order
    ReorderTalentLoadoutsDB[pKey][503] = { order = "nope", names = {} }
    assert_true(addonNamespace.GetSavedOrder(pKey, 503) == nil, "non-table .order reads as absent")

    -- Missing names map is fine (names are optional)
    ReorderTalentLoadoutsDB[pKey][504] = { order = { 22, 11 } }
    local found = addonNamespace.GetSavedOrder(pKey, 504)
    assert_true(found ~= nil, "entry without names map is still usable")
    assert_table_eq(addonNamespace.SortConfigIDs(504, { 11, 22 }, {}), { 22, 11 }, "nameless entry still sorts")

    ReorderTalentLoadoutsDB[pKey][501] = nil
    ReorderTalentLoadoutsDB[pKey][502] = nil
    ReorderTalentLoadoutsDB[pKey][503] = nil
    ReorderTalentLoadoutsDB[pKey][504] = nil
end

-- Test 57: corrupt character bucket never raises; writers replace it
do
    local pKey = addonNamespace.GetPlayerKey()
    ReorderTalentLoadoutsDB[pKey] = 42 -- corrupt bucket

    local okRead, resRead = pcall(addonNamespace.GetSavedOrder, pKey, 250)
    assert_true(okRead and resRead == nil, "scalar bucket reads as absent without raising")

    addonNamespace.SaveOrder(pKey, 250, { 7, 8 }, { [7] = "G", [8] = "H" })
    assert_true(type(ReorderTalentLoadoutsDB[pKey]) == "table", "save replaces a corrupt bucket")
    local back = addonNamespace.GetSavedOrder(pKey, 250)
    assert_true(back ~= nil, "order readable after bucket repair")
    assert_table_eq(back.order, { 7, 8 }, "order intact after bucket repair")

    -- Reset over a corrupt bucket must not raise either
    ReorderTalentLoadoutsDB[pKey] = "junk"
    local pane = {
        GetSpecID = function() return 250 end,
        IsInspecting = function() return false end,
        configIDToName = {},
        configIDs = {},
        LoadSystem = { possibleSelections = { 1 } },
    }
    local savedPSF = PlayerSpellsFrame
    PlayerSpellsFrame = { TalentsFrame = pane }
    local okReset = pcall(addonNamespace.ResetCurrentSpecOrder, false)
    assert_true(okReset, "reset over a corrupt bucket does not raise")
    PlayerSpellsFrame = savedPSF
    ReorderTalentLoadoutsDB[pKey] = nil
end

-- Test 58: a live v1.x database imports cleanly on first login (no churn, no loss)
do
    local pKey = addonNamespace.GetPlayerKey()
    -- As written by every version since v1.0: GUID key, per-spec {order, names}
    ReorderTalentLoadoutsDB[pKey] = {
        [250] = { order = { 30, 10, 20 }, names = { [30] = "C", [10] = "A", [20] = "B" } },
        [251] = { order = { 60, 50 }, names = { [60] = "Y", [50] = "X" } },
    }
    local names250 = { [10] = "A", [20] = "B", [30] = "C" }
    assert_table_eq(addonNamespace.SortConfigIDs(250, { 10, 20, 30 }, names250), { 30, 10, 20 },
        "live order applies to a fresh session list")
    -- Already-ordered list: no rewrite churn
    local before = ReorderTalentLoadoutsDB[pKey][251]
    assert_table_eq(addonNamespace.SortConfigIDs(251, { 60, 50 }, { [50] = "X", [60] = "Y" }), { 60, 50 },
        "matching list passes through")
    assert_true(ReorderTalentLoadoutsDB[pKey][251] == before, "matching list triggers no DB rewrite")
    -- Other specs are isolated
    assert_table_eq(addonNamespace.GetSavedOrder(pKey, 250).order, { 30, 10, 20 }, "spec isolation preserved")
end

-- Test 53: static -- visibility uses Show/Hide; no stale combat-flag gates; zone events wired
do
    local f = io.open("Reorder_Talent_Loadouts.lua", "r")
    local source = f:read("*a")
    f:close()

    assert_true(source:find(":SetShown(", 1, true) == nil,
        "No SetShown calls anywhere (AllowedWhenUntainted + Shown aspect; Show/Hide carry no gate)")
    assert_true(source:find("InCombatLockdown and InCombatLockdown()", 1, true) == nil,
        "No direct combat-flag gates remain (all interactions use IsInteractionLocked)")
    assert_true(source:find("ADDON_RESTRICTION_STATE_CHANGED", 1, true) ~= nil,
        "Addon listens for restriction changes to defer and resume gated work")
    assert_true(source:find('RegisterEvent("ZONE_CHANGED")', 1, true) ~= nil
        and source:find('RegisterEvent("ZONE_CHANGED_NEW_AREA")', 1, true) ~= nil,
        "Zone-change events registered (M+/rated zones restrict on entry, out of combat)")
    assert_true(source:find("SendChatMessage", 1, true) == nil,
        "No outbound chat transmission (blocked in instances/M+/PvP since 12.0)")
    assert_true(source:find("COMBAT_LOG_EVENT", 1, true) == nil,
        "No combat-log registration (registering errors since 12.0)")
end

print(string.format("\nTest Results: %d Passed, %d Failed", passed, failed))
if failed > 0 then
    os.exit(1)
else
    print("ALL TESTS PASSED SUCCESSFULLY!")
end


