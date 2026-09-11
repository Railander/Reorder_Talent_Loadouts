# Reorder Talent Loadouts — Changelog

## Unreleased
- Removed the "unavailable while protected" chat notice: blocked input in combat, Mythic+, or PvP is now fully silent (notices never rendered there anyway).

## v1.7.0
- Fixed drag-and-drop reordering and saved loadout order not being applied — dragging works again and your saved order is used on every open.
- Reordering now pauses automatically while protected (combat, Mythic+, PvP encounters) with a single chat notice, and resumes by itself afterwards — including if you reload mid-combat.
- The reset button hides while protected instead of taking clicks that cannot apply.
- Previously saved orders carry over untouched; damaged saved data is safely ignored instead of causing errors.

## v1.6.0
- Maintenance release: packaging cleanup, no player-facing changes.
