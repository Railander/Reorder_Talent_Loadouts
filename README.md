# Reorder Talent Loadouts

A lightweight, single-purpose World of Warcraft (Retail) addon that allows reordering talent loadouts by simply click-and-holding them and moving them above or below other loadouts in the talent loadout dropdown.

---

## Features

- **Intuitive Click-and-Hold Drag & Drop**: Click and hold any loadout in the talent dropdown list, drag it up or down, and release.
- **Visual Feedback**:
  - Floating drag thumbnail following your cursor with the loadout name.
  - Glowing insertion indicator line showing the exact drop target boundary.
  - Dimming effect on the item currently being dragged.
- **Zero Interference**:
  - Standard clicks continue to select and apply loadouts normally.
  - Clicking the gear icon to edit, rename, or delete loadouts continues to work untouched.
  - Non-loadout items ("New Loadout", "Import", "Export") remain fixed in their default places.
- **Full State Persistence**:
  - Orders persist across `/reload`, logouts, spec swaps, and client restarts.
  - Saved per-character (via unique player GUID) and per-specialization (SpecID).
- **Dynamic Loadout Handling**:
  - Newly created or imported loadouts automatically appear at the bottom until reordered.
  - Deleted loadouts are automatically pruned from the saved list.
  - Starter Build can be reordered like any other loadout, or left at the bottom.
  - If loadout IDs change (e.g., across server transfers), the addon matches by name to preserve your order.
- **Combat & Taint Safe**:
  - Does not overwrite protected `C_` namespaces.
  - Uses Blizzard's modern `Menu.ModifyMenu` and `hooksecurefunc` APIs.
  - Aborts drag immediately upon entering combat (`PLAYER_REGEN_DISABLED`).
- **Zero Configuration Required**: Works out of the box with no complex options menus or setup.

---

## How to Use

1. Open your Talent tree (default key: `N`).
2. Click the Talent Loadout dropdown menu at the bottom-left of the talent tree.
3. **Click and hold** the left mouse button on any loadout.
4. Move your cursor up or down. A blue insertion line indicates where the loadout will land.
5. **Release** the mouse button. The loadout will now be in that position!

### Optional Commands

- `/rtl` or `/reordertalentloadouts`: Displays brief usage information.
- `/rtl reset`: Resets the loadout order for your current specialization to Blizzard's default.

---

## Compatibility

- **Retail WoW**: The War Within (11.0+) and Midnight (12.0 / 12.1, Interface `120100`). Fully verified against live Blizzard 12.1 FrameXML / Menu APIs.
- **UI & Addon Compatibility**: Designed to be non-intrusive and compatible with popular UI addons such as _ElvUI_, _Talent Tree Tweaks_, _BlizzMove_, and _Talent Loadout Manager_.

---

## Automated Test Suite

An automated test suite is included in `tests/test_reorder.lua` verifying:

- Boundary movements, no-ops, and arbitrary slot reordering.
- DB multi-character and multi-spec isolation.
- Fallback matching for renamed/renumbered loadouts.
- Combat lockdown abort and safety.
- Click vs drag distance threshold detection.

To run the tests:

```bash
lua tests/test_reorder.lua
```

---

## License

GNU General Public License v3.0. See [LICENSE](LICENSE) for details.
