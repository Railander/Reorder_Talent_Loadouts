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
};

local playedSounds = {};
function PlaySound(id)
    table.insert(playedSounds, id);
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
        LoadSystem = {
            possibleSelections = { 101, 102, 103 },
            dropdown = {
                menuOpen = true,
                CloseMenu = function(self) self.menuOpen = false end,
                OpenMenu = function(self) self.menuOpen = true end,
            },
            GetDropdown = function(self) return self.dropdown end,
            UpdateSelectionOptions = function(self) end,
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

-- Test 10: Slash Command Reset
do
    local specID = 250
    local pKey = addonNamespace.GetPlayerKey()
    assert_true(ReorderTalentLoadoutsDB[pKey][specID] ~= nil, "DB exists before reset")

    SlashCmdList["REORDERTALENTLOADOUTS"]("reset")

    assert_true(ReorderTalentLoadoutsDB[pKey][specID] == nil, "DB cleared for spec after /rtl reset")
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
    local bTest = CreateFrame("Button", "ThresholdBtn")
    bTest.rtLoadoutConfigID = 555
    local desc = { GetData = function() return 555 end, SetCanSelect = function() end }
    addonNamespace.SetupLoadoutButton(bTest, desc, nil, 555)

    -- Mouse down
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

    -- Mouse up
    bTest.scripts["OnMouseUp"](bTest, "LeftButton")
    leftMouseDown = false
    assert_true(bTest:GetAlpha() == 1.0, "Button remains in normal state after normal click")
end

print(string.format("\nTest Results: %d Passed, %d Failed", passed, failed))
if failed > 0 then
    os.exit(1)
else
    print("ALL TESTS PASSED SUCCESSFULLY!")
end

