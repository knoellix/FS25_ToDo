# Fallback-Audit — keine Kaskaden mehr

Stand: 2026-06-07  
Zweck: Transparent machen, **wo noch Heuristiken** laufen — und **was verboten** ist, damit nicht „Fallback auf Fallback“ entsteht.

---

## Grundsatz (verbindlich)

1. **Eine Entscheidung = eine Funktion** — siehe `CONSOLIDATION_AND_NAMING_PLAN.md`.
2. **Kein Fallback auf Fallback:** Wenn Signal A fehlt, wird **nicht** heuristisch B/C/D probiert, um die Anzeige trotzdem zu füllen.
3. **Erlaubt:** direkte **Giants-Engine-API** an der Messposition (Feld-ID, Polygon, FillLevel, FruitTypeDesc, Bale.getFillType).
4. **Verboten:** Bbox-Schätzung, „nächstes Feldzentrum“, `unknown ⇒ inside`, areaHa-Raten, stillschweigende API-Ketten ohne Dump-Zeile.
5. **Wenn die Engine nichts liefert:** UI zeigt **kein** falsches Ergebnis (`-`, keine Aktion, `total=0`) — und `ftdlDump` zeigt **warum**.

**Mantra:** Lieber leer als falsch. Debug muss die **eine** Entscheidungsfunktion und ihre **eine** Datenquelle benennen.

---

## Bereits bereinigt (2026-06-07)

| Thema | Früher (Müll) | Jetzt (Kanon) |
|-------|----------------|---------------|
| **Ballen-Zuordnung** | Bbox, Nächstes-Zentrum, Polygon-Fallback-Kette | `resolveBaleOwnerFieldId`: Engine-Feld an Position + Polygon des Owner-Objekts; Hof-Planfrucht aus |
| **Gras lose vs. Schwad** | Nur Liter ⇒ fälschlich `swath` | `classifyGrassMaterialLayout` in `deriveGrassResidueSummary` (Layout, keine zweite Rest-Heuristik) |
| **Stroh-Schwaden** | Typ/Höhe/Stoppel-Fallbacks | `deriveStrawResidueSummary`: nur `STRAW`-Liter via `callFillLevelAtArea` |
| **Gras-Rest (alt)** | `detectGrassResidue`, `fuseGrassResidueSignals`, … | **gelöscht** (~1380 Zeilen) |
| **Unkraut-Vorschläge** | Vier parallele `fieldNeedsWeed*` | `WeedAdvice.deriveWeedAdvice` + dünne Wrapper |

---

## Noch offen — Priorität zum Abbau

### P1 — Feldgrenzen (`isPositionInsideFieldOrUnknown`)

**Problem:** `nil` vom Polygon-Test wird als **inside** gewertet → Proben außerhalb des Feldes, unscharfe Aggregation, verwaschene Logs.

| Aufrufer | Datei | Zweck |
|----------|-------|--------|
| `aggregateFieldProbes` / Probe-Gitter | FieldAdvisor | Übersichts-Scan |
| `deriveGrassResidueSummary` / `deriveStrawResidueSummary` Kreuzproben | FieldAdvisor | Windrow-Liter |
| `measureFieldAxisHalfExtent` | FieldAdvisor | Feldgröße (areaHa-Raten wenn Walk = 0) |
| `sampleWeedCoverage` / Completion-Proben | FieldTaskCompletion | Unkraut / Auto-Erledigen |

**Ziel:** Nur `isPositionInsideField` (strict: `false` oder `true`, `nil` ⇒ Probe **überspringen**). Kein areaHa-Raten in `measureFieldAxisHalfExtent` für Entscheidungen.

**Entscheidende künftige Funktion:** `isProbePositionOnField(field, x, z)` — ein Gate für alle Scan-Pfade.

---

### P2 — Engine-Feld-Lookup als stille Kette

**`resolveEngineFieldAtWorldPosition`** probiert nacheinander:

1. `getFieldAtWorldPosition`
2. `getFieldIdAtWorldPosition`
3. `resolveFarmlandFieldIdAtWorldPosition`

Das ist **keine Heuristik**, aber **ohne Dump unsichtbar**. Ziel: eine Funktion, im Dump pro Ballen/Probe `engineFieldSource=getFieldAtWorldPosition|getFieldId|farmland|none` loggen; bei `none` nicht raten.

---

### P3 — Representative vs. Center (Ernte-Anzeige)

| Signal | Funktion | Risiko |
|--------|----------|--------|
| `representativeState` (max growth) vs. `centerState` / `harvestState` | `resolveRepresentativeStateForAggregation`, `resolveHarvestFieldState` | Ernte-Monat/Fenster von Randprobe statt Mitte |

**Regel (bereits in Project Memory):** Ernte-Spalte / Harvest-Monat nutzt **center/harvestState**, nicht representative. Audit: alle `getHarvestWindowHint`-Aufrufer prüfen.

---

### P4 — Ernte-ETA / Perioden

`estimatePeriodsUntilHarvest` — „walk growth states until ripe“ als Fallback wenn API-Lücke. Ziel: nur `FruitTypeDesc`-Growth-API; sonst `-`.

---

### P5 — Frucht-Anzeige / classifyProbe-Kaskade

Mehrstufige Auflösung (`resolveFruitTypeIndex`, `inferGrassFruitTypeIndexFromField`, generic grass names). Kein neuer Fallback; bestehende Kette in Phase-2-Rest einklappen (`AUDIT_INVENTORY.md` A).

---

## Was **kein** Fallback ist (nicht anfassen)

| Muster | Beispiel |
|--------|----------|
| L10n `fallback`-String | `FieldToDoL10n.getText(key, "Grubbern")` — nur Übersetzung |
| Cache-TTL | `getCoverageCache` — Performance, ändert keine Regel |
| `classifyGrassMaterialLayout` | Entscheidung aus **einer** Liter-Quelle + Layout-Statistik — keine zweite Rest-Quelle |
| Phase-Pipeline | `FieldPhase.deriveFieldPhase(facts)` — eine Wahrheit |

---

## Arbeitsmodus ab jetzt

1. **Bug:** Zuerst `docs/DECISIONS.md` + diese Datei — welche Entscheidungsfunktion? Welcher Fallback greift?
2. **Fix:** Fallback **entfernen** oder in die **eine** Kanon-Funktion **Engine-only** ziehen — **nicht** neuen Wrapper daneben.
3. **Verify:** `ftdlDump` muss Quelle + Ergebnis zeigen (`engineField`, `grassResidue.state`, `baleCoverage.straw`, …).
4. **Regression:** `docs/REGRESSION.md` 5-Feld-Check vor Release.

---

## Nächster konkreter Schritt (Vorschlag)

**P1:** `isPositionInsideFieldOrUnknown` aus Probe-/Residue-Pfaden entfernen (strict only) — ein Commit, ein Testlauf, `ftdlDump` aller Felder diffen gegen `expected_before`.

Kein neues Feature, bis P1+P2 im Log nachvollziehbar sind.
