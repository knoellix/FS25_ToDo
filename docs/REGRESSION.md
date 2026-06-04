# 5-Feld-Regression (nach Phase 2)

Vollständiger FS25-Neustart nach jedem Build. Details: `CONSOLIDATION_AND_NAMING_PLAN.md` Phase 0/3.

| # | Feld-Nr. | Situation | Erwartung | OK | Notiz / ftdlDump |
|---|----------|-----------|-----------|----|------------------|
| 1 | 16 | Geerntet (Triticale growth 11>8) | Stoppeln/post_harvest, nicht „Wächst“ | [x] | Dump 08:45: deriveFieldPhase=post_harvest, vom User als geerntet bestätigt |
| 2 | 14/71/73 | Frisch gepflügt, leer | empty, kein Gras | [x] | Dump 08:45: empty korrekt |
| 3 | 6 | Gras nach Schwaden | Volle Logistik-Kette (Schwaden→Sammeln→Ballen→Silage), kein blindes „Wächst“ | [~] | Schwad/lose NICHT sensierbar (Dump 09:17 bewiesen). Neu: cut→ganze Kette anbieten, Ballen→einsammeln. **In-Game-Verify nötig** |
| 4 | 9 | Weizen wächst, Unkraut | wächst; Unkraut separat | [x] | Dump 08:45: standing korrekt |
| 5 | 63 | Klee schnittreif (growth=minHarvest) | „mähen“ (grass_harvestable) | [x] | Dump 09:17: grass_harvestable ✓ |
| 6 | 76 | Luzerne schnittreif + partial soil work | „mähen“ (grass_harvestable) | [x] | Dump 09:17: grass_harvestable ✓ (partial-Aufschlag-Fix bestätigt) |
