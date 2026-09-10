# Fallback-Audit — keine Kaskaden mehr

Stand: 2026-09-10  
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

## Bereits bereinigt

| Thema | Früher (Müll) | Jetzt (Kanon) |
|-------|----------------|---------------|
| **Ballen-Zuordnung** | Bbox, Nächstes-Zentrum, Polygon-Fallback-Kette | `resolveBaleOwnerFieldId`: Engine-Feld an Position + Polygon des Owner-Objekts; Hof-Planfrucht aus |
| **Gras lose vs. Schwad** | Nur Liter ⇒ fälschlich `swath` | `classifyGrassMaterialLayout` in `deriveGrassResidueSummary` |
| **Stroh-Schwaden** | Typ/Höhe/Stoppel-Fallbacks | `deriveStrawResidueSummary`: nur `STRAW`-Liter |
| **Gras-Rest (alt)** | Density-Map-Fusion | gelöscht |
| **Unkraut-Vorschläge** | Vier parallele `fieldNeedsWeed*` | `WeedAdvice.deriveWeedAdvice` |
| **Feldgrenzen (P1)** | `OrUnknown` / areaHa | `isSamplePositionOnField` |
| **P2 Engine-Feld-Lookup** | stille Kette | dritter Return `source` + Dump `engineFieldSource=` / `engineFieldLookup:` |
| **P3 Ernte = Center** | representative für Monat | `resolveHarvestFieldState` / `aggregation.harvestState` = Center |
| **P4 Ernte-ETA** | blinder Growth-Walk | nur FruitTypeDesc `getIsHarvestReady` / `minHarvestingGrowthState`, sonst `nil` → `-` |
| **P5 Gras-Frucht-Anzeige** | enrichFieldState-Last-Resort | `resolveGrassFruitTypeIndex`: Aggregation → Probe → State → Field-Probe; kein mutate-enrich |

---

## Bewusst belassen (kein Fallback)

| Muster | Beispiel |
|--------|----------|
| L10n `fallback`-String | nur Übersetzung |
| Cache-TTL | Performance |
| `classifyGrassMaterialLayout` | eine Liter-Quelle + Layout |
| Gras-Meadow: Representative `cut` überschreibt Center `harvestable` | dokumentierte Ausnahme in `getGrassMeadowPhase` |

---

## Arbeitsmodus ab jetzt

1. **Bug:** Zuerst `docs/DECISIONS.md` + diese Datei.
2. **Fix:** Fallback entfernen oder Engine-only in die Kanon-Funktion.
3. **Verify:** `ftdlDump` zeigt Quelle + Ergebnis.
4. **Regression:** `docs/REGRESSION.md` vor Release.
