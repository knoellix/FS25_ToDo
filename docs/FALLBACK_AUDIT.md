# Fallback-Audit — keine Kaskaden mehr

Stand: 2026-09-24  
Zweck: Transparent machen, **wo Heuristiken / Mehrfach-Quellen** waren oder noch sind — und **was verboten** ist.  
Wenn etwas nicht geht: **hier** nachsehen, was schon probiert wurde, Ursache finden, **einen** Kanon-Pfad festlegen — **nicht** einen weiteren Fallback stapeln.

---

## Grundsatz (verbindlich)

1. **Eine Entscheidung = eine Funktion** — siehe `CONSOLIDATION_AND_NAMING_PLAN.md`.
2. **Kein Fallback auf Fallback:** Wenn Signal A fehlt, wird **nicht** heuristisch B/C/D probiert, um die Anzeige trotzdem zu füllen.
3. **Erlaubt:** direkte **Giants-Engine-API** an der Messposition (Feld-ID, Polygon, FillLevel, FruitTypeDesc, Bale.getFillType).
4. **Verboten:** Bbox-Schätzung, „nächstes Feldzentrum“, `unknown ⇒ inside`, areaHa-Raten, stillschweigende API-Ketten ohne Dump-Zeile.
5. **Wenn die Engine nichts liefert:** UI zeigt **kein** falsches Ergebnis (`-`, keine Aktion, `total=0`) — und `ftdlDump` / `ftdlSync` zeigt **warum**.
6. **Bei unsicherer Engine-API:** erst **eine** Vanilla-Referenz finden (z. B. `MissionStartEvent`), loggen, messen — **nicht** 3 parallele Reader „zur Sicherheit“.

**Mantra:** Lieber leer/deny als falsch. Debug muss die **eine** Entscheidungsfunktion und ihre **eine** Datenquelle benennen.

---

## Arbeitsmodus bei Bugs

1. **Bug** → zuerst `docs/DECISIONS.md` + diese Datei (Abschnitt „Probiert / verworfen“).
2. **Nicht** neue Quelle anhängen. Ursache: API falsch, Timing, Client/Server, Soft-Disable, Cache, …
3. **Fix:** einen Kanon-Pfad setzen oder Fehlanzeige/Deny belassen + Dump-Zeile.
4. **Hier dokumentieren:** was probiert wurde, was Vanilla macht, was jetzt Kanon ist.
5. **Verify:** `ftdlDump` / `ftdlSync` + `docs/REGRESSION.md`.

---

## MP / Permissions (2026-09-24)

### Edit-Recht (manageContracts)

| | |
|--|--|
| **Symptom** | Spieler mit Hofverwaltung „Aufträge/Verträge“ konnte To-Dos nicht anlegen; C zeigte Deny, Klick tat nichts. |
| **Ursache (teilweise)** | Soft-disabled Buttons schluckten Clicks (kein `requireEditPermission`/InfoDialog). Parallel: Permission-Reader stapelte mehrere Farm-APIs → undurchsichtig, teils `nil` → fail-closed. |
| **Vanilla-Referenz** | `MissionStartEvent`: `g_currentMission:getHasPlayerPermission("manageContracts", connection, farmId)` |
| **Kanon jetzt** | Nur dieser eine Call in `FieldToDoPermissions.hasFarmTodoEditPermission`. MP-Edit = `== true`. API fehlt/`nil` → **deny** (kein Raten). SP: immer edit bei Membership. |
| **Debug** | F9 `ftdlSync` → Zeile `manageContracts=` / `canEdit=` |

#### Probiert / verworfen (nicht wieder anlegen)

| Quelle | Warum probiert | Warum verworfen |
|--------|----------------|-----------------|
| `farm:getUserPermission(userId, key)` | ältere Farm-API | nicht der Vanilla-Vertrags-Pfad; redundant zu Mission |
| `farm:hasUserPermission(...)` | Variante | wie oben |
| `farm:getUserPermissions(userId)` Map | Plural-API in GDN | Mission wrapped das intern; Parallel-Read = Raten |
| `farm.users[]` / `userIdToPlayer[].permissions` | Rohdaten | Struktur je Build unterschiedlich; stilles Raten |
| `Farm.PERMISSION.MANAGE_CONTRACTS` vs Hardcode `"manageContracts"` | „Konstante wenn da“ | MissionStartEvent nutzt den String; eine Quelle reicht |
| Manager-Bypass `isFarmManager` → edit | „Manager hat oft keine Bits“ | **kein Design** — entweder `manageContracts` oder deny |
| ESC-Grants / `ftdlEditTodos` / `defaultAllow` | ältere MP-Edit-Modelle | retired Schema **v5**; Edit-Gate liest sie **nicht** |
| Soft-disable Edit-Buttons wenn `!canEdit` | UX „grau“ | schluckt Click → kein Deny-Dialog; Buttons bleiben klickbar, Handler zeigt InfoDialog |

#### Zugehörige Resolver (ebenfalls auf einen Pfad reduziert)

| Thema | Früher (Kaskade) | Kanon jetzt | Fail wenn fehlt |
|-------|------------------|-------------|-----------------|
| Local `userId` | `playerUserId` → `g_localPlayer.userId` | `g_currentMission.playerUserId` | `nil` → deny |
| Local `farmId` | `getFarmId` → `g_localPlayer.farmId` → `mission.player.farmId` → `getFarmByUserId` | `mission:getFarmId()` | `nil` → deny |
| Connection | `getConnectionByUserId` → `user:getConnection()` | `userManager:getConnectionByUserId` | `nil` Connection an Mission durchreichen (Vanilla erlaubt nil für Local) |
| Membership | `getFarmByUserId` → `isUserInFarm` → `getUsers`/`getActiveUsers`-Scan | nur `g_farmManager:getFarmByUserId` | unbekannt → **deny** (kein fail-open `return true`) |
| UniqueUserId | `getUniqueUserIdByUserId` → `user:getUniqueUserId()` | nur `getUniqueUserIdByUserId` | `nil` (Edit braucht UniqueId nicht mehr) |

**Noch im Repo, aber tot für Edit:** `FieldAdvisorSettings.todoEditDefaultAllow` / `workersMayEditTodos` + XML — Legacy-Lesen/Schreiben. Nicht wieder als Edit-Gate verdrahten; Aufräumen = eigener Cleanup-Schritt.

---

### Deny-Dialog nur bei Hotkey, nicht bei Mausklick (2026-09-24)

| | |
|--|--|
| **Symptom** | Footer-Hotkey (z. B. MENU_ACTIVATE) zeigt InfoDialog; Maus auf Mini-Buttons → nichts. |
| **Ursachen** | (1) Soft-`setDisabled(true)` schluckt Clicks. (2) Feld-Buttons: Label-`Text` + voll transparente Hit-`Button` (`imageColor 0 0 0 0`) — FS25 trifft oft den Text (kein onClick) oder ignoriert voll transparente Buttons. |
| **Kanon** | Edit-Buttons nie soft-disablen; `requireEditPermission` → InfoDialog. Hit-Button `imageColor` mit min. Alpha (`0.01`). Deko-Text `disabled=true` damit er keine Clicks stiehlt. |

---

### F9 Debug-Konsole tot (2026-09-24)

| | |
|--|--|
| **Symptom** | Strg+F9 / F9 öffnet nichts (Shift+F9 war nie gebunden). |
| **Probiert / verworfen** | Nur `PlayerInputComponent` / `Vehicle` Registrierung → tot im ESC-Menü und nach Context-Wechsel (`lastEventId` Early-Return). Native-Console-Kaskade (`g_gui.toggleConsole` / `g_console` / …) konnte „Erfolg“ melden ohne UI → Dialog nie geöffnet. |
| **Kanon** | `addModEventListener` + `registerActionEvents` / `onRegisterActionEvents` (Engine rebindet). Immer `FieldDebugConsole.openCommandDialog()` (TextInputDialog). Bindings: **F9** und **LCtrl+F9** (`modDesc`). |

---

### Feldverkauf / Overview-Sync (Ownership)

| | |
|--|--|
| **Symptom** | Nach Feldverkauf blieb Parcel auf Client in der Feldübersicht. |
| **Probiert / falsch** | `MessageType.FARMLAND_OWNER_CHANGED` — **existiert in FS25 nicht** (Hook feuerte nie). |
| **Vanilla** | `g_farmlandManager:addStateChangeListener` → `onFarmlandStateChanged(farmlandId, farmId)` |
| **Kanon** | Listener in `onStartMission` + `markOwnedFieldsOverviewStale`: Cache sofort droppen (auch bei geschlossenem Menü), Rescan wenn Tab offen. |
| **Zusatz-Bug** | Stale-Flag ohne Cache-Invalidate → bis `OWNED_FIELDS_CACHE_MS` (4 s) alter Snapshot bei Reopen. |

---

## Bereits bereinigt (Feld-/Advisor — älter)

| Thema | Früher (Müll) | Jetzt (Kanon) |
|-------|----------------|---------------|
| **Ballen-Zuordnung** | Bbox, Nächstes-Zentrum, Polygon-Fallback-Kette | `resolveBaleOwnerFieldId`: Engine-Feld an Position + Polygon; Hof aus |
| **Gras lose vs. Schwad** | Nur Liter ⇒ fälschlich `swath` | `classifyGrassMaterialLayout` in `deriveGrassResidueSummary` |
| **Stroh-Schwaden** | Typ/Höhe/Stoppel-Fallbacks | `deriveStrawResidueSummary`: nur `STRAW`-Liter |
| **Gras-Rest (alt)** | Density-Map-Fusion | gelöscht |
| **Unkraut-Vorschläge** | Vier parallele `fieldNeedsWeed*` | `WeedAdvice.deriveWeedAdvice` |
| **Feldgrenzen (P1)** | `OrUnknown` / areaHa | `isSamplePositionOnField` |
| **P2 Engine-Feld-Lookup** | stille Kette | dritter Return `source` + Dump `engineFieldSource=` |
| **P3 Ernte = Center** | representative für Monat | `aggregation.harvestState` = Center |
| **P4 Ernte-ETA** | blinder Growth-Walk | FruitTypeDesc Harvest-API, sonst `nil` → `-` |
| **P5 Gras-Frucht-Anzeige** | enrichFieldState-Last-Resort | `resolveGrassFruitTypeIndex` ohne mutate-enrich |

---

## Noch Mehrfach-Quellen (offen — nicht erweitern)

Bei Touch: **eine** Quelle wählen und hier eintragen, nicht dritte anhängen.

| Ort | Was | Status |
|-----|-----|--------|
| `FieldScanner:getOwnedFarmlandIds` | `getOwnedFarmlandIdsByFarmId`, sonst Scan `farmlands` + `farmlandBelongsToFarm` | offen — dokumentieren welcher Pfad live greift (`ftdlOwned`) |
| `farmlandBelongsToFarm` | `farmland.farmId` / `ownerFarmId` / Manager-Entry | Daten-Shape, kein Permission-Raten — bei Bug Engine-Owner-Feld klären |
| `extractUserIdFromFarmUserEntry` | id vs `getUserId` vs `.userId` | User-Objekt-Shape von Farm-Listen — kein zweites Membership-API |
| `resolveSprayLevelMax` | Map-Max, sonst Konstante 2 | bewusst (Mods senken Max); siehe DECISIONS Düngen |
| Soft-UI `editControlsEnabled` | Flag noch gesetzt | nur Hinweis; Disable nicht mehr für Edit-Buttons |

---

## Bewusst belassen (kein API-Fallback)

| Muster | Beispiel |
|--------|----------|
| L10n `fallback`-String | nur Übersetzung |
| Cache-TTL | Performance |
| `classifyGrassMaterialLayout` | eine Liter-Quelle + Layout |
| Gras-Meadow: Representative `cut` überschreibt Center `harvestable` | dokumentierte Ausnahme in `getGrassMeadowPhase` |

---

## Kurzcheck vor neuem Reader

- [ ] Vanilla-Referenz gefunden (Datei/Event)?
- [ ] Ein Call dokumentiert in DECISIONS + hier?
- [ ] Fail-closed wenn `nil`?
- [ ] Dump/Log zeigt Wert + Quelle?
- [ ] Kein „sonst noch Y“ ohne diesen Eintrag zu aktualisieren?
