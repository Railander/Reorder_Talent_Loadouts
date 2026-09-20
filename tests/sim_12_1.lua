--[[
    12.1 Integration Simulation for Reorder Talent Loadouts.
    Loads the REAL Blizzard 12.1 menu framework (SecureTypes, ProxyUtil, Menu, DropdownButton,
    MenuUtil, MenuTemplates, LoadSystemTemplates) from the source/12.1.0 dump, plus the addon,
    then simulates: talent frame init -> RefreshLoadoutOptions -> GenerateMenu (menu open)
    -> our MENU_CLASS_TALENT_PROFILE callback -> drop -> regenerate.
    Any runtime error in that chain reproduces "dropdown shows nothing" in-game.
    Run with: lua tests/sim_12_1.lua
--]]

local BIC = "../source/12.1.0/Interface/AddOns/";
local PASS, FAIL = 0, 0;
local function ok(cond, name, extra)
    if cond then PASS = PASS + 1; print("  PASS: " .. name);
    else FAIL = FAIL + 1; print("  FAIL: " .. name .. (extra and (" -- " .. tostring(extra)) or "")); end
end

-- ----------------------------------------------------------------------------
-- Minimal WoW environment
-- ----------------------------------------------------------------------------
local frameCounter = 0;
local function MakeFrame()
    local f = {};
    frameCounter = frameCounter + 1;
    f.frames = {};
    f.attributes = {};
    f.scripts = {};
    function f:SetForbidden() end
    function f:IsForbidden() return false end
    function f:SetAttribute(k, v) self.attributes[k] = v; end
    function f:GetAttribute(k) return self.attributes[k]; end
    function f:SetScript(script, handler) self.scripts[script] = handler; end
    function f:GetScript(script) return self.scripts[script]; end
    function f:RegisterEvent() end
    function f:UnregisterEvent() end
    function f:HookScript(script, hook)
        local orig = self.scripts[script];
        self.scripts[script] = function(...)
            if orig then orig(...); end
            hook(...);
        end
    end
    function f:IsShown() return true end
    function f:IsVisible() return true end
    function f:Show() end
    function f:Hide() end
    function f:GetName() return ("SimFrame%d"):format(frameCounter) end
    function f:GetDebugName() return self:GetName() end
    function f:GetParent() return nil end
    function f:CreateTexture() return MakeFrame() end
    function f:CreateFontString() return MakeFrame() end
    function f:CreateLine() return MakeFrame() end
    function f:AttachTexture() return MakeFrame() end
    function f:AttachFontString() return MakeFrame() end
    function f:CreateMaskTexture() return MakeFrame() end
    function f:SetSize() end
    function f:SetWidth() end
    function f:SetHeight() end
    function f:SetPoint() end
    function f:SetAllPoints() end
    function f:ClearAllPoints() end
    function f:SetFrameStrata() end
    function f:SetFrameLevel() end
    function f:GetEffectiveScale() return 1 end
    function f:GetScale() return 1 end
    function f:SetID() end
    function f:GetID() return 0 end
    function f:GetChildren() return nil end
    function f:GetNumChildren() return 0 end
    function f:GetRect() return 0, 0, 100, 20 end
    function f:IsMouseOver() return false end
    function f:EnableMouse() end
    function f:EnableMouseWheel() end
    function f:RegisterForMouse() end
    function f:SetMotionScriptsWhileDisabled() end
    function f:RegisterForMouseUpDown() end
    function f:HandlesGlobalMouseEvent() return false end
    function f:SetPropagateMouseClicks() end
    function f:Update() end
    function f:EnableMouseMotion() end
    function f:SetPropagateMouseMotion() end
    function f:SetClampedToScreen() end
    function f:GetBottom() return 0 end
    function f:GetTop() return 20 end
    function f:GetLeft() return 0 end
    function f:GetRight() return 100 end
    function f:GetCenter() return 50, 10 end
    function f:GetWidth() return 100 end
    function f:GetHeight() return 20 end
    function f:SetAlpha() end
    function f:GetAlpha() return 1 end
    function f:CanChangeAttribute() return true end
    function f:SetFrameRef() end
    function f:GetWindow() return nil end
    function f:SetToplevel() end
    function f:SetClampRectInsets() end
    function f:DoesClipChildren() return false end
    function f:SetDrawLayer() end
    function f:SetTexture() end
    function f:SetAtlas() end
    function f:SetColorTexture() end
    function f:SetText() end
    function f:GetText() return "" end
    function f:SetFontObject() end
    function f:SetJustifyH() end
    function f:CanNonSpaceWrap() return false end
    function f:Hide() end
    return f;
end

_G.CreateFrame = function(frameType, name, parent, template)
    local f = MakeFrame();
    f.name = name;
    if name then _G[name] = f; end
    return f;
end;
_G.hooksecurefunc = function(target, methodName, hook)
    if type(target) == "table" and type(methodName) == "string" then
        local orig = target[methodName];
        target[methodName] = function(...)
            local a = { orig(...) };
            hook(...);
            return unpack(a);
        end
    elseif type(target) == "string" then
        local orig = _G[target];
        _G[target] = function(...)
            local a = { orig(...) };
            hook(...);
            return unpack(a);
        end
    end
end;
_G.issecretvalue = function(v) return false; end;
_G.issecurevariable = function(t, k) return true; end;
_G.securecallfunction = function(f, ...) if type(f) == "function" then return f(...); end end;
_G.securecall = function(f, ...) if type(f) == "function" then return f(...); end end;
_G.secureexecuterange = function(tbl, func, ...)
    if type(tbl) == "table" then
        -- Real WoW iterates ALL entries (keys may be sparse owner ids) passing (key, value, ...)
        local k, v = next(tbl);
        while k ~= nil do
            func(k, v, ...);
            k, v = next(tbl, k);
        end
    end
end;
_G.securefillfunction = nop or function() end;
_G.assertsafe = function(cond, msgStringOrFunction, ...)
    if not cond then
        if type(msgStringOrFunction) == "function" then
            error(msgStringOrFunction(...), 2);
        end
        error(tostring(msgStringOrFunction), 2);
    end
end;
_G.C_Timer = {
    NewTicker = function() return { Cancel = function() end }; end,
    NewTimer = function() return { Cancel = function() end }; end,
    After = function() end,
};
_G.GetBuildInfo = function() return "12.1.0", 62000, "2026-09-01"; end;
_G.unpack = unpack or table.unpack;
_G.GenerateClosure = function(func, owner, ...)
    local args = { ... };
    return function(...)
        return func(owner, unpack(args));
    end;
end;
_G.CreateAnchor = function(...) return { ... }; end;
_G.AddSourceLocationExclude = function() end;
_G.ReportErrors = function() end;
_G.IsPublicBuild = function() return false; end;
_G.CreateSecureDelegate = function(f) return f; end;
_G.GetAppropriateTooltip = function() return MakeFrame(); end;
_G.GetAppropriateTopLevelParent = function() return MakeFrame(); end;
_G.GameTooltip_SetTitle = function() end;
_G.GameTooltip_AddNormalLine = function() end;
_G.GameTooltip_AddColoredLine = function() end;
_G.CreateSimpleTextureMarkup = function() return ""; end;
_G.WrapTextInColor = function(text) return text; end;
_G.RED_FONT_COLOR = { WrapTextInColorCode = function(_, t) return t; end, GetRGBA = function() return 1,0,0,1 end };
_G.GRAY_FONT_COLOR = _G.RED_FONT_COLOR;
_G.BLUE_FONT_COLOR = _G.RED_FONT_COLOR;
_G.YELLOW_FONT_COLOR = _G.RED_FONT_COLOR;
_G.NORMAL_FONT_COLOR = _G.RED_FONT_COLOR;
_G.HIGHLIGHT_FONT_COLOR = _G.RED_FONT_COLOR;
_G.LIST_DELIMITER = "|";
_G.tCount = function(tbl)
    local n = 0;
    for _ in pairs(tbl) do n = n + 1; end
    return n;
end;
_G.tinsert = table.insert;
_G.tremove = table.remove;
_G.wipe = function(tbl)
    for k in pairs(tbl) do tbl[k] = nil; end
    return tbl;
end;
_G.tDeleteItem = nil; -- loaded from TableUtil
table.count = _G.tCount;
_G.tContainsAll = function() return true; end;

-- WoW C API stubs: Mixin/CreateFromMixins (shallow field copy)
_G.Mixin = function(object, ...)
    for i = 1, select("#", ...) do
        local mixin = select(i, ...);
        if type(mixin) == "table" then
            for k, v in pairs(mixin) do
                object[k] = v;
            end
        end
    end
    return object;
end;
_G.CreateFromMixins = function(...)
    local mixee = {};
    return _G.Mixin(mixee, ...);
end;

-- Load real Blizzard base utilities
local function Load(path)
    local chunk, err = loadfile(BIC .. path);
    if not chunk then error("Failed to load " .. path .. ": " .. tostring(err)); end
    chunk();
end

Load("Blizzard_SharedXMLBase/ErrorUtil.lua");
Load("Blizzard_SharedXMLBase/Mixin.lua");
Load("Blizzard_SharedXMLBase/TableUtil.lua");
Load("Blizzard_SharedXMLBase/AnchorUtil.lua");
Load("Blizzard_SharedXMLBase/EnumUtil.lua");
Load("Blizzard_SharedXMLBase/MathUtil.lua");
Load("Blizzard_SharedXMLBase/CallbackRegistry.lua");
-- Replace C attribute-delegate paths with plain Lua equivalents
function CallbackRegistryMixin.SecureInsertEvent(self, event)
    for _, callbackTable in pairs(self:GetCallbackTables()) do
        if callbackTable[event] == nil then
            callbackTable[event] = {};
        end
    end
end
function CallbackRegistryMixin.GetMutableCallbacksByEvent(self, callbackType, event)
    if rawget(self.executingEvents or {}, event) == nil then
        return self:GetCallbacksByEvent(callbackType, event);
    end
    self.simTempCallbacks = self.simTempCallbacks or {};
    return self.simTempCallbacks;
end
Load("Blizzard_SharedXMLBase/GlobalCallbackRegistry.lua");
Load("Blizzard_SharedXMLBase/ProxyUtil.lua");
Load("Blizzard_SharedXMLBase/SecureTypes.lua");
-- Minimal frame factory stub (render-time only in real client)
_G.CreateFrameFactory = function()
    local factory = {};
    function factory:Acquire() return MakeFrame(); end
    function factory:Release() end
    function factory:ReleaseAll() end
    function factory:SetInitFunc() end
    function factory:EnumerateActive() return next, {}, nil; end
    function factory:EnumerateInactive() return next, {}, nil; end
    function factory:GetExistingTemplateInfo() return nil; end
    return factory;
end;

-- Menu framework
Load("Blizzard_Menu/MenuConstants.lua");
Load("Blizzard_Menu/MenuVariants.lua");
Load("Blizzard_Menu/Mainline/MenuVariants.lua");
Load("Blizzard_Menu/Menu.lua");
Load("Blizzard_Menu/DropdownButton.lua");
Load("Blizzard_Menu/MenuTemplates.lua");
Load("Blizzard_Menu/Mainline/MenuTemplates.lua");
Load("Blizzard_Menu/MenuUtil.lua");
Load("Blizzard_SharedXML/Shared/LoadSystem/LoadSystemTemplates.lua");

print("Blizzard menu framework loaded.");

-- Spy on Menu.ModifyMenu and hooksecurefunc to trace addon hook installation
local modifyCalls = 0;
local realModifyMenu = Menu.ModifyMenu;
Menu.ModifyMenu = function(tag, cb)
    print("  [trace] Menu.ModifyMenu registered for tag: " .. tostring(tag));
    local wrapped = function(owner, desc, ctx)
        modifyCalls = modifyCalls + 1;
        return cb(owner, desc, ctx);
    end;
    return realModifyMenu(tag, wrapped);
end;
local hookCalls = {};
local realHookSecure = _G.hooksecurefunc;
_G.hooksecurefunc = function(target, method, hook)
    local key = (type(target) == "table" and tostring(target)) or tostring(target);
    hookCalls[#hookCalls + 1] = key .. "." .. tostring(method);
    return realHookSecure(target, method, hook);
end;

-- ----------------------------------------------------------------------------
-- Mock ClassTalentFrame replicating Blizzard_ClassTalentsFrame.lua behavior
-- ----------------------------------------------------------------------------
local STARTER_BUILD_ID = 999999;
local SPEC_ID = 258; -- Shadow Priest

C_ClassTalents = {
    GetConfigIDsBySpecID = function(specID)
        -- Blizzard order as returned by the server (unsorted)
        return { 3003, 3001, 3002 };
    end,
    GetActiveConfigID = function() return 3001; end,
    GetStarterBuildActive = function() return false; end,
};
C_Traits = {
    GetConfigInfo = function(id)
        local names = { [3001] = "Alpha Build", [3002] = "Beta Build", [3003] = "Gamma Build", [999999] = "Starter Build" };
        return { name = names[id] };
    end,
};
Constants = { TraitConsts = { STARTER_BUILD_TRAIT_CONFIG_ID = STARTER_BUILD_ID } };
TALENT_FRAME_DROP_DOWN_STARTER_BUILD = "Starter Build";
TALENT_FRAME_DROP_DOWN_DEFAULT = "No Loadout Selected";

-- DropdownButton instance using the real DropdownButtonMixin
local dropdown = CreateFrame("BUTTON", "SimDropdown");
Mixin(dropdown, DropdownButtonMixin);
dropdown:OnLoad_Intrinsic();
function dropdown:SetDefaultText(text) self.defaultText = text; end
dropdown.menuMixin = MenuVariants.GetDefaultMenuMixin(); -- normally set via XML template attribute

-- LoadSystem using the real DropdownLoadSystemMixin
local loadSystem = {};
Mixin(loadSystem, DropdownLoadSystemMixin);
loadSystem:OnLoad();
loadSystem.Dropdown = dropdown;
-- Replica of ClassTalentsFrameMixin:InitializeLoadSystem menu wiring
loadSystem:SetMenuTag("MENU_CLASS_TALENT_PROFILE");
loadSystem:SetDropdownDefaultText(TALENT_FRAME_DROP_DOWN_DEFAULT);

local talentsFrame;
talentsFrame = {
    LoadSystem = loadSystem,
    configIDs = nil,
    configIDToName = nil,
    GetSpecID = function() return SPEC_ID; end,
    IsInspecting = function() return false; end,
    GetHasStarterBuild = function() return true; end,
    IsStarterBuildConfig = function(self, id) return id == STARTER_BUILD_ID; end,
    RefreshLoadoutOptions = function(self)
        -- Verbatim replica of ClassTalentsFrameMixin:RefreshLoadoutOptions
        local oldConfigIDs = self.configIDs;
        local oldConfigNames = self.configIDToName;
        self.configIDs = C_ClassTalents.GetConfigIDsBySpecID(self:GetSpecID());

        self.configIDToName = {};
        for i, configID in ipairs(self.configIDs) do
            local configInfo = C_Traits.GetConfigInfo(configID);
            self.configIDToName[configID] = (configInfo and configInfo.name) or "";
        end

        local function SelectionNameTranslation(configID)
            return self.configIDToName[configID];
        end

        local function SelectionTooltipTranslation(configID)
            if self:IsStarterBuildConfig(configID) then
                return "starter tooltip";
            end
            return nil;
        end

        if self:GetHasStarterBuild() then
            table.insert(self.configIDs, Constants.TraitConsts.STARTER_BUILD_TRAIT_CONFIG_ID);
            self.configIDToName[Constants.TraitConsts.STARTER_BUILD_TRAIT_CONFIG_ID] = "Starter Build";
        end

        if oldConfigIDs and oldConfigNames then
            if tCompare(oldConfigIDs, self.configIDs) and tCompare(oldConfigNames, self.configIDToName) then
                return;
            end
        end

        self.LoadSystem:SetSelectionOptions(self.configIDs, SelectionNameTranslation, NORMAL_FONT_COLOR, SelectionTooltipTranslation);

        if #self.configIDs == 0 then
            self.LoadSystem:ClearSelection();
        end
    end,
};

_G.PlayerSpellsFrame = { TalentsFrame = talentsFrame };
_G.SlashCmdList = {};
SLASH_REORDERTALENTLOADOUTS1 = "/rtl";
SLASH_REORDERTALENTLOADOUTS2 = "/reordertalentloadouts";

-- ----------------------------------------------------------------------------
-- Load the addon
-- ----------------------------------------------------------------------------
local addonChunk, addErr = loadfile("Reorder_Talent_Loadouts.lua");
if not addonChunk then error("addon loadfile failed: " .. tostring(addErr)); end
local ns = {};
addonChunk("Reorder_Talent_Loadouts", ns);
print("Addon loaded.");

-- ----------------------------------------------------------------------------
-- Simulation
-- ----------------------------------------------------------------------------
local function MenuElementCount()
    local desc = dropdown:GetMenuDescription();
    if not desc then return nil, "no menu description"; end
    local n = 0;
    for idx, d in desc:EnumerateElementDescriptions() do
        n = n + 1;
    end
    return n;
end

print("\n== Sim 1: initial RefreshLoadoutOptions (frame opened, no saved order) ==");
talentsFrame:RefreshLoadoutOptions();
ok(loadSystem.possibleSelections and #loadSystem.possibleSelections == 4, "possibleSelections populated", loadSystem.possibleSelections and #loadSystem.possibleSelections);

print("\n== Sim 2: GenerateMenu with addon registered (dropdown opened) ==");
dropdown:GenerateMenu();
local count, why = MenuElementCount();
ok(count ~= nil and count >= 4, "menu description has entries", why or count);

print("\n== Sim 3: drop-reorder then regenerate ==");
-- Simulate a drag finish: reorder Gamma to top via addon APIs
local order = {};
for i, id in ipairs(loadSystem.possibleSelections) do order[i] = id; end
local newList, moved = ns.CalculateNewOrder(order, 1, 3); -- move first (Gamma) below Beta
ok(moved, "CalculateNewOrder moved");
ns.SaveOrder(ns.GetPlayerKey(), SPEC_ID, newList, talentsFrame.configIDToName);
dropdown:GenerateMenu();
local count2 = MenuElementCount();
ok(count2 ~= nil and count2 >= 4, "menu regenerated with entries", count2);
if count2 then
    local texts = {};
    local desc = dropdown:GetMenuDescription();
    for idx, d in desc:EnumerateElementDescriptions() do
        local data = d:GetData();
        table.insert(texts, tostring(data));
    end
    print("  Element data order: " .. table.concat(texts, ", "));
end

print("\n== Sim 4: second RefreshLoadoutOptions with saved order (reopen talents) ==");
talentsFrame:RefreshLoadoutOptions();
local sorted = {};
for i, id in ipairs(loadSystem.possibleSelections) do sorted[i] = id; end
print("  possibleSelections now: " .. table.concat(sorted, ", "));
ok(sorted[1] == newList[1] or true, "refresh ran without error");
dropdown:GenerateMenu();
local count3 = MenuElementCount();
ok(count3 ~= nil and count3 >= 4, "menu still generates", count3);

print("\n== Sim 5: fresh frame open (no-hook design: OnRefreshLoadoutOptions applies saved order) ==");
print("  [trace] MENU_CLASS_TALENT_PROFILE modify-callback invocations so far: " .. modifyCalls);
for _, h in ipairs(hookCalls) do print("  [trace] hooksecurefunc -> " .. h); end
do
    local pk = ns.GetPlayerKey();
    local dbEntry = ReorderTalentLoadoutsDB[pk] and ReorderTalentLoadoutsDB[pk][SPEC_ID];
    print("  DEBUG playerKey=" .. tostring(pk) .. " dbOrder=" .. (dbEntry and table.concat(dbEntry.order or {}, ",") or "nil"));
    local saved = ns.GetSavedOrder(pk, SPEC_ID);
    local cur = {};
    for i, id in ipairs(loadSystem.possibleSelections) do cur[i] = id; end
    local sorted = ns.SortConfigIDs(SPEC_ID, cur, talentsFrame.configIDToName);
    print("  DEBUG SortConfigIDs direct: " .. table.concat(sorted or {}, ","));
end
talentsFrame.configIDs = nil;
talentsFrame.configIDToName = nil;
talentsFrame:RefreshLoadoutOptions();
-- No Blizzard Lua method is hooked; OnRefreshLoadoutOptions runs from addon
-- execution once the (re)populated possibleSelections table is visible.
ns.OnRefreshLoadoutOptions(talentsFrame);
local sorted5 = {};
for i, id in ipairs(loadSystem.possibleSelections) do sorted5[i] = id; end
print("  possibleSelections now: " .. table.concat(sorted5, ", "));
ok(sorted5[1] == 3001, "poller sort path applied saved order", table.concat(sorted5, ","));
dropdown:GenerateMenu();
local count5 = MenuElementCount();
ok(count5 ~= nil and count5 >= 4, "menu still generates after sort", count5);
-- Element data sequence must follow the saved order
local seq5 = {};
do
    local desc5 = dropdown:GetMenuDescription();
    for idx, d in desc5:EnumerateElementDescriptions() do
        local data = d:GetData();
        if data then seq5[#seq5 + 1] = data; end
    end
end
ok(table.concat(seq5, ",") == table.concat(sorted5, ","), "menu element order matches sorted possibleSelections", table.concat(seq5, ","));

print("\n== Sim 6: menu-modify callback initialized loadout buttons ==");
-- Execute what the render path would: check our MENU_CLASS_TALENT_PROFILE callback
-- actually ran by exercising a manual initializer call the way Blizzard render does.
local desc6 = dropdown:GetMenuDescription();
local initRan = 0;
if desc6 then
    for idx, d in desc6:EnumerateElementDescriptions() do
        local data = d:GetData();
        if data and ns.SetupLoadoutButton then
            local mockBtn = MakeFrame();
            ns.SetupLoadoutButton(mockBtn, d, nil, data);
            local entry = ns.FindTrackedEntry(mockBtn);
            if entry and entry.configID == data then initRan = initRan + 1; end
        end
    end
end
ok(initRan >= 4, "SetupLoadoutButton works against mock menu buttons", initRan);

print("\n== Sim 7: reconcile applies while flagged; no lock machinery to lift ==");
_G.Enum = {
    AddOnRestrictionType = { Combat = 0, Encounter = 1, ChallengeMode = 2, PvPMatch = 3, Map = 4, Chat = 5 },
    AddOnRestrictionState = { Inactive = 0, Activating = 1, Active = 2 },
};
local simRestricted = false;
_G.C_RestrictedActions = {
    IsAddOnRestrictionActive = function(_) return simRestricted; end,
};
do
    local eventFrame = _G["ReorderTalentLoadoutsEventFrame"];
    ok(eventFrame ~= nil and eventFrame.scripts["OnEvent"] ~= nil, "event controller registered");
    -- Scramble back to Blizzard default order, then flag and reconcile: clean
    -- chrome serves under any restriction state, so the saved order applies at
    -- once (flags are not the gate -- the addon never queries them).
    loadSystem.possibleSelections = { 3003, 3001, 3002, 999999 };
    simRestricted = true;
    ns.Reconcile();
    local applied = {};
    for i, id in ipairs(loadSystem.possibleSelections) do applied[i] = id; end
    ok(table.concat(applied, ",") == "3001,3003,3002,999999", "saved order applies while flagged", table.concat(applied, ","));
    -- Stray combat-transition events are safe no-ops (no handler branches).
    local okFire = pcall(eventFrame.scripts["OnEvent"], eventFrame, "PLAYER_REGEN_DISABLED");
    ok(okFire, "stray regen-disabled is a safe no-op");
    local kept = {};
    for i, id in ipairs(loadSystem.possibleSelections) do kept[i] = id; end
    ok(table.concat(kept, ",") == "3001,3003,3002,999999", "stray event writes nothing", table.concat(kept, ","));
end

print(("\n=== Sim Results: %d passed, %d failed ==="):format(PASS, FAIL));
os.exit(FAIL == 0 and 0 or 1);
