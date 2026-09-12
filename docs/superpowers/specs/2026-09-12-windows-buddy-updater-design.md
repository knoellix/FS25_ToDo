# Windows buddy updater (.bat)

**Date:** 2026-09-12  
**Status:** implemented  
**Plan:** none (small utility)  
**Mod:** FS25_FieldToDoList  

## Goal

Give Windows playmates a double-click `.bat` that compares their installed `FS25_FieldToDoList.zip` with the latest GitHub Release and replaces the zip when remote is newer.

## Decisions

| Topic | Choice |
|--------|--------|
| Install form | **Zip only** (`FS25_FieldToDoList.zip`) |
| Mods path | Variable at top of `.bat`, default `%USERPROFILE%\Documents\My Games\FarmingSimulator2025\mods` |
| Remote | `https://github.com/knoellix/FS25_ToDo/releases/latest` — asset `FS25_FieldToDoList.zip` |
| Local version | Read `<version>` from `modDesc.xml` inside the local zip |
| Remote version | From release tag / API (`tag_name`, strip leading `v`) or from downloaded zip’s `modDesc` after download |
| Backup | **None** — GitHub release history is enough |
| Runtime | Windows 10/11 single `.bat` (embedded PowerShell payload after `:::PS1`; no separate `.ps1`) |
| Replace | Download to temp, then overwrite target zip |

## Out of scope

- Extracted folder installs  
- `.bak` copies  
- Auto-launch Farming Simulator  
- Updating the `.bat` itself  

## Success

- Same version → message “up to date”, no write  
- Newer remote → zip replaced, versions printed  
- Missing local zip → offer install of latest  
- Editable `MODS_DIR` at top of script  
