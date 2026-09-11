--[[
    Restriction-discipline suite for Reorder Talent Loadouts on the SHARED harness.

    Straps the addon to shared/wow_test_env.lua (mock client) +
    shared/wow_restriction_sim.lua (12.x enforcement layer: SecretArguments gates,
    dispatch-false query semantics, degraded talent reads, hooksecurefunc taint).

    Run from the addon root: lua5.1 tests/sim_restrictions.lua
    Prints PASS:/FAIL: lines, ends with "Test Results: N passed, M failed",
    os.exit(1) on any failure. Output via env.rawPrint (print is captured).

    Harness adaptations (documented, not worked around):
    - Hidden frames receive no OnUpdate here, so the click-and-hold path drives
      the frame's OnUpdate script directly.
    - Menu.ModifyMenu / DropdownButtonMixin do not exist in the shared env, so the
      menu-callback path is NOT covered here (unit tests + sim_12_1.lua own it).
    - Expected violations are asserted precisely (which APIs, how many): the
      reload-in-combat boot registrations are accepted by design (nothing else
      may touch a gate -- blocked input is fully silent).
]]

local env = dofile("../shared/wow_test_env.lua");
local rs = dofile("../shared/wow_restriction_sim.lua");

local PASS, FAIL = 0, 0;
local function ok(cond, name, extra)
    if cond then PASS = PASS + 1; env.rawPrint("  PASS: " .. name);
    else FAIL = FAIL + 1; env.rawPrint("  FAIL: " .. name .. (extra and (" -- " .. tostring(extra)) or "")); end
end

local function newViolations(base)
    local out = {};
    for i = base + 1, #env.restrictionViolations do
        out[#out + 1] = env.restrictionViolations[i].api;
    end
    return out;
end

local function onlyFrom(list, allowed)
    for _, api in ipairs(list) do
        if not allowed[api] then return false, api; end
    end
    return true;
end

-- Boot under MAX restrictions: the /reload-in-combat trap.
rs.Enable(env, { scenario = "max" });

-- Talent world: ground truth ({11,22,33} per the sim) already populated.
local SPEC_ID = 7;
local dropdown = {
    menuOpen = false,
    IsMenuOpen = function(self) return self.menuOpen end,
    -- Plain-table dropdowns need GetParent (same mock gotcha as the unit suite).
    GetParent = function(self) return nil end,
};
local loadSystem = {
    possibleSelections = { 11, 22, 33 },
    GetDropdown = function(self) return dropdown end,
    SetSelectionOptions = function(self, options)
        self.possibleSelections = { unpack(options) };
    end,
};
local showHooks = {};
PlayerSpellsFrame = {
    TalentsFrame = {
        GetSpecID = function() return SPEC_ID end,
        IsInspecting = function() return false end,
        configIDToName = {},
        configIDs = { 11, 22, 33 },
        HookScript = function(self, script, hook)
            showHooks[#showHooks + 1] = { script = script, hook = hook };
        end,
        LoadSystem = loadSystem,
    },
};

local ns = {};
assert(loadfile("Reorder_Talent_Loadouts.lua"))("Reorder_Talent_Loadouts", ns);
env.rawPrint("Addon loaded under max restrictions.");

local function eventFrame()
    return env:FindFrame("ReorderTalentLoadoutsEventFrame");
end

env.rawPrint("\n== R1: max boot defers gated setup; only init paths touch gates ==");
do
    ok(ns.IsGatedInitDeferred() == true, "gated init deferred while all six types active");
    ok(#showHooks == 0, "talent-pane OnShow hook NOT installed while protected");
    local clean, bad = onlyFrom(newViolations(0), {
        ["Frame:RegisterEvent"] = true,
        ["Frame:SetScript"] = true,
    });
    ok(clean, "boot violations are init-path only (event/script registration)", bad);
    ok(eventFrame() ~= nil, "event frame exists");
end

env.rawPrint("\n== R2: steady-state lock discipline under max (no new violations) ==");
do
    local base = #env.restrictionViolations;
    local b = CreateFrame("Button", "RsRow1", UIParent);
    b.GetRect = function() return 50, 200, 200, 20 end
    b.GetChildren = function() return end
    ns.SetupLoadoutButton(b, { GetData = function() return 11 end, SetCanSelect = function() end }, nil, 11);
    -- While locked: no drag arming installs at all.
    ok(b.dragButtons == nil, "RegisterForDrag skipped while protected");
    local setupFresh = newViolations(base);
    ok(#setupFresh == 0, "button setup while locked logs nothing");
    base = #env.restrictionViolations;
    ns.StartDrag(b);
    ok(b:GetAlpha() == 1.0, "drag refused while protected");
    ok(#newViolations(base) == 0, "refused drag is silent (no chat in combat)");
    base = #env.restrictionViolations;
    ns.StartDrag(b);
    ok(#newViolations(base) == 0, "repeat refusal stays silent");
    base = #env.restrictionViolations;
    ns.Reconcile();
    ok(loadSystem.possibleSelections[1] == 11 and #loadSystem.possibleSelections == 3,
        "reconcile writes nothing while protected");
    ok(#newViolations(base) == 0, "queued reconcile logs nothing (pure Lua + pcall'd queries)");
end

env.rawPrint("\n== R3: lift resumes via EnsureGatedInit; queued order applies ==");
do
    -- A saved order from "yesterday", list currently default.
    ns.SaveOrder(ns.GetPlayerKey(), SPEC_ID, { 33, 11, 22 }, { [11] = "A", [22] = "B", [33] = "C" });
    loadSystem.possibleSelections = { 11, 22, 33 };
    env:DeactivateAllRestrictions();
    env:ClearViolations();
    ok(ns.EnsureGatedInit() == true, "gated init runs once clear");
    ok(#showHooks == 1 and showHooks[1].script == "OnShow", "deferred OnShow hook installed on lift");
    ok(#env.restrictionViolations == 0, "lift install is clean (no gates while inactive)");
    env:FireEvent("PLAYER_ENTERING_WORLD");
    env:Pump(0.5); -- fires the 0.25s scheduled reconcile (5/15/30s backstops stay pending)
    local got = table.concat(loadSystem.possibleSelections, ",");
    ok(got == "33,11,22", "saved order applied after lift", got);
    ok(#env.restrictionViolations == 0, "reconcile-while-clear logs nothing");
end

env.rawPrint("\n== R4: activation mid-drag cancels without writes or gates ==");
do
    local b1 = CreateFrame("Button", "RsRowA", UIParent);
    b1.GetRect = function() return 50, 200, 200, 20 end
    b1.GetChildren = function() return end
    local b2 = CreateFrame("Button", "RsRowB", UIParent);
    b2.GetRect = function() return 50, 180, 200, 20 end
    b2.GetChildren = function() return end
    ns.ClearActiveButtons();
    ns.SetupLoadoutButton(b1, { GetData = function() return 33 end, SetCanSelect = function() end }, nil, 33);
    ns.SetupLoadoutButton(b2, { GetData = function() return 11 end, SetCanSelect = function() end }, nil, 11);
    env:ClearViolations();
    -- Arm + start a drag by hand (hidden frames get no OnUpdate here).
    local ef = eventFrame();
    b1.scripts.OnMouseDown(b1, "LeftButton");
    env.mouseDown = true;
    env.cursorX, env.cursorY = 200, 210; -- >5px from press point
    ef.scripts.OnUpdate(ef, 0.05);
    ok(b1:GetAlpha() == 0.35, "drag in flight before activation");
    env:ClearViolations();
    env:FireRestrictionChange("Combat", 2); -- Activating edge: locks (query lies false, payload rules)
    ok(ns.IsInteractionLocked() == true, "Activating edge locks");
    ok(b1:GetAlpha() == 1.0, "activation cancels the active drag");
    ok(loadSystem.possibleSelections[1] == 33, "cancelled drag writes nothing");
    ok(#env.restrictionViolations == 0, "activation path touches no gates");
    env.mouseDown = false;
    ns.CancelDrag();
    env:DeactivateAllRestrictions();
end

env.rawPrint("\n== R5: zone changes re-check status; lift flushes the queue ==");
do
    loadSystem.possibleSelections = { 11, 22, 33 }; -- scramble back to default
    env:ActivateAllRestrictions();
    env:ClearViolations();
    env:FireEvent("ZONE_CHANGED");
    ok(ns.IsInteractionLocked() == true, "zone change into protection locks");
    env:Pump(0.5); -- scheduled reconcile fires, queues
    ok(loadSystem.possibleSelections[1] == 11, "zone reconcile queues while protected (no writes)");
    ok(#env.restrictionViolations == 0, "locked zone path touches no gates");
    env:DeactivateAllRestrictions();
    env:FireEvent("ZONE_CHANGED_NEW_AREA");
    env:Pump(0.5);
    local got = table.concat(loadSystem.possibleSelections, ",");
    ok(got == "33,11,22", "leaving protection flushes the queued order", got);
    ok(#env.restrictionViolations == 0, "lift zone path touches no gates");
end

env.rawPrint("\n== R6: lift edge via explicit-state dispatch (out-of-dispatch confirm) ==");
do
    loadSystem.possibleSelections = { 11, 22, 33 };
    env:DeactivateAllRestrictions();
    env:SetRestriction("Encounter", rs.ACTIVE);
    env:ClearViolations();
    env:FireRestrictionChange("Encounter", 2);
    ok(ns.IsInteractionLocked() == true, "Encounter activation locks");
    ns.Reconcile();
    ok(loadSystem.possibleSelections[1] == 11, "reconcile queued (no writes)");
    -- Lift edge carries the real client payload (type, Inactive): Inactive is
    -- applied before dispatch, queries read false mid-dispatch, and the
    -- C_Timer.After(0) confirm runs outside it.
    env:FireRestrictionChange("Encounter", 0);
    env:Pump(0.1);
    ok(ns.IsInteractionLocked() == false, "lock lifts after Inactive + out-of-dispatch confirm");
    local got = table.concat(loadSystem.possibleSelections, ",");
    ok(got == "33,11,22", "queued reconcile flushed on confirm", got);
    ok(#env.restrictionViolations == 0, "confirm path touches no gates");
    env:DeactivateAllRestrictions();
end

env.rawPrint("\n== R7: zero hooksecurefunc anywhere (taint rule) ==");
do
    ok(#env.taintedHooks == 0, "addon never hooksecurefunc'd a Blizzard Lua method");
end

env.rawPrint(("\nTest Results: %d passed, %d failed"):format(PASS, FAIL));
if FAIL > 0 then os.exit(1); end
