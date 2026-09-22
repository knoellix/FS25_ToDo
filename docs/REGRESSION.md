# 5-Feld-Regression (nach Phase 2)

Vollständiger FS25-Neustart nach jedem Build. Details: `CONSOLIDATION_AND_NAMING_PLAN.md` Phase 0/3.

| # | Feld-Nr. | Situation | Erwartung | OK | Notiz / ftdlDump |
|---|----------|-----------|-----------|----|------------------|
| 1 | 16 | Geerntet (Triticale growth 11>8) | Stoppeln/post_harvest, nicht „Wächst“ | [x] | Dump 08:45: deriveFieldPhase=post_harvest, vom User als geerntet bestätigt |
| 2 | 14/71/73 | Frisch gepflügt, leer | empty, kein Gras | [x] | Dump 08:45: empty korrekt |
| 3 | 5/6 | Gras nach Mähen / Schwaden | **loose** (nur gemäht) → Schwaden in Kette; **swath** → Ladewagen/Ballen; Ballen → einsammeln | [ ] | `ftdlDump` → `state=loose` + `ewAbove` hoch, oder `state=swath` + `ewTrans≥2` |
| 4 | 9 | Weizen wächst, Unkraut | wächst; Unkraut separat | [x] | Dump 08:45: standing korrekt |
| 5 | 63 | Klee schnittreif (growth=minHarvest) | „mähen“ (grass_harvestable) | [x] | Dump 09:17: grass_harvestable ✓ |
| 6 | 76 | Luzerne schnittreif + partial soil work | „mähen“ (grass_harvestable) | [x] | Dump 09:17: grass_harvestable ✓ (partial-Aufschlag-Fix bestätigt) |
| 7 | — | Getreide-Stoppel + Strohballen | „Strohballen einsammeln“ (auto wenn weg); ohne Ballen „Stroh pressen/bergen“ | [ ] | Neu 2026-06-04: `ftdlDump` → `baleCoverage: straw=N`; In-Game-Verify ausstehend |
| 8 | 17 | Wiese GRASS (stehend / halb gemäht) | Kultur **Gras** (nicht Luzerne); `grass_mow` erst bei ≥98% Cut | [ ] | 2026-09-22: generic meadow index + Score-Bias + Cut-Ratio; In-Game-Verify |
| 9 | — | MP ohne `manageContracts` | Planfrucht/add denied; Auto-complete ok | [ ] | 2026-09-22: Hofverwaltung Verträge; Sync v5 |
