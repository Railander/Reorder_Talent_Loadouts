--[[
    Restriction-tripwire suite for Reorder Talent Loadouts on the SHARED harness.

    Straps the addon to shared/wow_test_env.lua (mock client) +
    shared/wow_restriction_sim.lua (12.x enforcement layer: OBJECT-driven
    secret marks, flag-gated C APIs, hooksecurefunc taint).

    Model under test (Move_* philosophy, live-sealed there under all six
    restriction types forced): tainted calls on secret-CLEAN objects succeed
    under any restriction state; only secret-MARKED objects (unit/combat/aura
    data flowed in) refuse. Nothing this addon touches can be marked -- plain
    loadout rows, plain config-ID numbers, own frames -- so every op attempts
    blindly: no flag checks, no queues, no deferred installs. A refusal errors
    LOUDLY live (Bugsack); in-sim it logs a violation, which is exactly what
    the marked sections assert (audibility proof, not failure).

    Sim-conservative notes (sim gates, live unproven):
    - Talent C reads (GetConfigIDsBySpecID/GetConfigInfo) degrade to empty
      under flags WITHOUT logging: an empty ground truth only skips the merge
      (merge-only: nothing is ever removed) while the saved order still applies
      to whatever is present.
    - PlaySound logs a violation under flags: the drop still persists (the
      violation is log-only), and the suite allowlists exactly that one API.

    Run from the addon root: lua5.1 tests/sim_restrictions.lua
    Prints PASS:/FAIL: lines, ends with "Test Results: N passed, M failed",
    os.exit(1) on any failure. Output via env.rawPrint (print is captured).

    Harness adaptations (documented, not worked around):
    - Hidden frames receive no OnUpdate here, so the click-and-hold path drives
      the frame's OnUpdate script directly.
    - Menu.ModifyMenu / DropdownButtonMixin do not exist in the shared env, so the
      menu-callback path is NOT covered here (unit tests + sim_12_1.lua own it).
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

-- Boot under MAX restrictions: the /reload-in-combat trap. Clean objects serve
-- installs at max, so the boot below must behave exactly like a clear boot.
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

env.rawPrint("\n== R1: max boot installs fully on clean objects, zero violations ==");
do
    ok(#showHooks == 1 and showHooks[1].script == "OnShow", "talent-pane OnShow hook installed at max boot");
    ok(#env.restrictionViolations == 0, "flagged boot logs nothing on clean objects");
    local ef = eventFrame();
    ok(ef ~= nil, "event frame exists");
    ok(ef:IsEventRegistered("ADDON_LOADED") and ef:IsEventRegistered("TRAIT_CONFIG_LIST_UPDATED")
        and ef:IsEventRegistered("ZONE_CHANGED") and ef:IsEventRegistered("PLAYER_STARTED_MOVING"),
        "load/talent/zone/movement events registered while flagged");
    ok(not ef:IsEventRegistered("ADDON_RESTRICTION_STATE_CHANGED")
        and not ef:IsEventRegistered("PLAYER_REGEN_DISABLED")
        and not ef:IsEventRegistered("PLAYER_REGEN_ENABLED"),
        "no lock-machinery events registered");
    env:ClearViolations();
    ok(ns.EnsureInit() == true, "idempotent re-init runs");
    ok(#env.restrictionViolations == 0, "re-init logs nothing");
    ok(#env.taintedHooks == 0, "no Blizzard-Lua hooks installed, ever");
end

env.rawPrint("\n== R2: flagged drag lifecycle applies at once; degraded reads tolerated ==");
do
    -- A saved order from "yesterday", list currently default.
    ns.SaveOrder(ns.GetPlayerKey(), SPEC_ID, { 33, 11, 22 }, { [11] = "A", [22] = "B", [33] = "C" });
    loadSystem.possibleSelections = { 11, 22, 33 };
    -- Reconcile under max: the sim degrades ground truth to {} (no violation
    -- logged -- reads just come back empty), so the merge skips while the
    -- saved order still applies to the present entries.
    env:ClearViolations();
    local base = #env.restrictionViolations;
    ns.Reconcile();
    ok(table.concat(loadSystem.possibleSelections, ",") == "33,11,22",
        "saved order applies while flagged", table.concat(loadSystem.possibleSelections, ","));
    ok(#newViolations(base) == 0, "degraded talent reads log nothing");

    -- Full drag lifecycle while flagged: 11 drops to the end and persists.
    local b1 = CreateFrame("Button", "RsRow1", UIParent);
    b1.GetRect = function() return 50, 200, 200, 20 end
    b1.GetChildren = function() return end
    local b2 = CreateFrame("Button", "RsRow2", UIParent);
    b2.GetRect = function() return 50, 180, 200, 20 end
    b2.GetChildren = function() return end
    local b3 = CreateFrame("Button", "RsRow3", UIParent);
    b3.GetRect = function() return 50, 160, 200, 20 end
    b3.GetChildren = function() return end
    ns.ClearActiveButtons();
    ns.SetupLoadoutButton(b1, { GetData = function() return 11 end, SetCanSelect = function() end }, nil, 11);
    ns.SetupLoadoutButton(b2, { GetData = function() return 22 end, SetCanSelect = function() end }, nil, 22);
    ns.SetupLoadoutButton(b3, { GetData = function() return 33 end, SetCanSelect = function() end }, nil, 33);
    ok(#newViolations(base) == 0, "button installs while flagged log nothing");
    loadSystem.possibleSelections = { 11, 22, 33 };
    -- Arm via the press path (hidden frames get no OnUpdate here: drive it).
    local ef = eventFrame();
    env.cursorX, env.cursorY = 100, 210;
    env.mouseDown = true;
    b1.scripts.OnMouseDown(b1, "LeftButton");
    env.cursorX, env.cursorY = 100, 150; -- below every row: drop at the end
    ef.scripts.OnUpdate(ef, 0.05);
    ok(b1:GetAlpha() == 0.35, "drag arms and starts while flagged");
    env.mouseDown = false;
    env:ClearViolations();
    local dbase = #env.restrictionViolations;
    ns.FinishDrag();
    ok(b1:GetAlpha() == 1.0, "flagged drop restores visuals");
    ok(table.concat(loadSystem.possibleSelections, ",") == "22,33,11",
        "flagged drag persists the new order", table.concat(loadSystem.possibleSelections, ","));
    local dv, bad = onlyFrom(newViolations(dbase), { PlaySound = true });
    ok(dv, "flagged drop logs at most the sim-conservative sound gate", bad);
    env.mouseDown = false;
    ns.CancelDrag();
end

env.rawPrint("\n== R3: marked rows: attempts stay blind/audible, gesture degrades gracefully ==");
do
    -- Tripwire section: the addon attempts blindly (no mark checks) so a
    -- refusal surfaces as sim violations -- the Bugsack signal live. With
    -- every row unreadable the gesture must degrade to a no-op: no crash,
    -- no wrong order. (Data writes themselves are plain Lua and cannot
    -- refuse -- unlike a frame mover, there is no "frame waits" half here;
    -- the degrade point is the drop-position math, which needs row rects.)
    local b1 = CreateFrame("Button", "RsM1", UIParent);
    -- The shared mock ships no GetRect, so rows carry a mark-aware stand-in
    -- with the sim's GATED_READS fidelity: clean serves, marked reads nil
    -- (the install violations below are the genuinely-gated audibility proof).
    local function markRect(b, l, btm, w, h)
        b.GetRect = function(self)
            if self._secretMarked then return nil; end
            return l, btm, w, h;
        end
        b.GetChildren = function() return end
    end
    markRect(b1, 50, 200, 200, 20);
    local b2 = CreateFrame("Button", "RsM2", UIParent);
    markRect(b2, 50, 180, 200, 20);
    local b3 = CreateFrame("Button", "RsM3", UIParent);
    markRect(b3, 50, 160, 200, 20);
    env:MarkSecret(b1);
    env:MarkSecret(b2);
    env:MarkSecret(b3);
    env:ClearViolations();
    local base = #env.restrictionViolations;
    ns.ClearActiveButtons();
    ns.SetupLoadoutButton(b1, { GetData = function() return 11 end, SetCanSelect = function() end }, nil, 11);
    ns.SetupLoadoutButton(b2, { GetData = function() return 22 end, SetCanSelect = function() end }, nil, 22);
    ns.SetupLoadoutButton(b3, { GetData = function() return 33 end, SetCanSelect = function() end }, nil, 33);
    ok(#newViolations(base) > 0, "marked installs log violations (blind attempts stay audible)");
    loadSystem.possibleSelections = { 11, 22, 33 };
    ns.StartDrag(b1);
    env.cursorX, env.cursorY = 100, 150;
    ns.UpdateDrag(); -- every GetRect refuses: no line, no target, no crash
    ok(b1:GetAlpha() == 0.35, "marked drag still arms (alpha is ungated)");
    ns.FinishDrag(); -- no target: visuals restored, nothing persisted
    ok(b1:GetAlpha() == 1.0, "marked drop restores visuals");
    ok(table.concat(loadSystem.possibleSelections, ",") == "11,22,33",
        "marked drop writes nothing", table.concat(loadSystem.possibleSelections, ","));
    -- Unmark: the next organic gesture works (no queues -- each input drives
    -- exactly its own apply).
    env:UnmarkSecret(b1);
    env:UnmarkSecret(b2);
    env:UnmarkSecret(b3);
    env:ClearViolations();
    local cbase = #env.restrictionViolations;
    ns.StartDrag(b1);
    env.cursorX, env.cursorY = 100, 150;
    ns.UpdateDrag();
    ns.FinishDrag();
    ok(table.concat(loadSystem.possibleSelections, ",") == "22,33,11",
        "tracked order applies after unmark", table.concat(loadSystem.possibleSelections, ","));
    local cv, bad = onlyFrom(newViolations(cbase), { PlaySound = true });
    ok(cv, "unmarked retry is clean apart from the sound gate", bad);
    ns.CancelDrag();
end

env.rawPrint("\n== R4: zone crossings re-sort immediately while flagged ==");
do
    ns.SaveOrder(ns.GetPlayerKey(), SPEC_ID, { 33, 11, 22 }, { [11] = "A", [22] = "B", [33] = "C" });
    loadSystem.possibleSelections = { 11, 22, 33 }; -- scramble back to default
    env:ClearViolations();
    env:FireEvent("ZONE_CHANGED");
    env:Pump(0.5); -- fires the 0.25s scheduled reconcile
    ok(table.concat(loadSystem.possibleSelections, ",") == "33,11,22",
        "zone change re-sorts while flagged", table.concat(loadSystem.possibleSelections, ","));
    ok(#env.restrictionViolations == 0, "flagged zone path logs nothing");
end

env.rawPrint("\n== R5: zero hooksecurefunc anywhere (taint rule) ==");
do
    ok(#env.taintedHooks == 0, "addon never hooksecurefunc'd a Blizzard Lua method");
end

env.rawPrint("\n== R6: movement + stray events while flagged: reconcile applies, locks absent ==");
do
    ns.SaveOrder(ns.GetPlayerKey(), SPEC_ID, { 33, 11, 22 }, { [11] = "A", [22] = "B", [33] = "C" });
    loadSystem.possibleSelections = { 11, 22, 33 }; -- scramble back to default
    env:ClearViolations();
    env:FireEvent("PLAYER_STARTED_MOVING"); -- first input after reload
    ok(table.concat(loadSystem.possibleSelections, ",") == "33,11,22",
        "first movement reconciles while flagged", table.concat(loadSystem.possibleSelections, ","));
    ok(#env.restrictionViolations == 0, "movement reconcile logs nothing");
    -- Stray lock-machinery events are safe no-ops (nothing registered for them).
    local ef = eventFrame();
    local okRegen = pcall(ef.scripts.OnEvent, ef, "PLAYER_REGEN_DISABLED");
    local okRestr = pcall(ef.scripts.OnEvent, ef, "ADDON_RESTRICTION_STATE_CHANGED", 2, 2);
    ok(okRegen and okRestr, "stray regen/restriction events never raise");
    ok(table.concat(loadSystem.possibleSelections, ",") == "33,11,22",
        "stray events write nothing", table.concat(loadSystem.possibleSelections, ","));
    ok(#env.restrictionViolations == 0, "stray events log nothing");
end

env.rawPrint(("\nTest Results: %d passed, %d failed"):format(PASS, FAIL));
if FAIL > 0 then os.exit(1); end
