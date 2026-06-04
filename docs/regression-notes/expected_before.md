# Golden-Snapshot — vor Konsolidierung

Quelle: `log.txt` Dump, 2026-06-04 08:23, Mod **0.1.0.5**, savegame1, Periode **5 (Juli)**, seasonalGrowth=true, growthMode=1.
Zweck: Referenz für Phase 2. Nach jedem Refactor erneut `ftdlAll` → mit dieser Tabelle vergleichen. Änderung nur dort, wo **absichtlich**.

> Hinweis: `FSDensityMapUtil: GLOBAL MISSING` auf **allen** Feldern. Gras-Rest fällt auf Engine-Höhe zurück (`source=engine_filltype`). `centerMaterial`/`maxMaterial` ~56–84 erscheinen auf **jedem** Feld (auch gepflügt/Acker) → das ist **Terrain-Höhen-Rauschen**, kein Gras-Material. Siehe [Befunde](#kritische-befunde).

## Felder (12)

| Feld | Pos | Frucht | ground | growth | weed (live/dead, label) | meadowPhase | residue | harvestHint | isHarvestReady | Anzeige-Label |
|------|-----|--------|--------|--------|--------------------------|-------------|---------|-------------|----------------|----------------|
| 1 | (-588,578) | SOYBEAN(7) | ROLLER_LINES | 4 | 0/31 'tot' | dormant | – | Okt | false | Sojabohnen |
| 6 | (-415,313) | GRASS(24) | GRASS_CUT | 5 | 0 | cut | **loose** ratio=1.0 | – | false | Gras |
| 9 | (-365,450) | WHEAT(1) | ROLLER_LINES | 6 | 8/23 '26%' needsCombat | dormant | – | Aug | false | Sommerweizen (Weizen) |
| 14 | (-159,816) | – (0) | PLOWED | 0 | 0/31 'tot' | dormant | – | – | – | – |
| 15 | (-339,740) | MAIZE(5) | PLANTED | 4 | 3/28 '10%' needsCombat | dormant | – | Okt | false | Körnermais |
| 16 | (-249,719) | TRITICALE(29) | HARVEST_READY | 11 | 2/29 '6%' needsCombat+Hoe | dormant | – | – | false | Triticale |
| 17 | (-368,664) | – (0) | NONE | 0 | 0/31 'tot' | dormant | – | – | – | – |
| 63 | (188,-70) | CLOVER(38) | GRASS | 3 | 0 | cut | **swath** ratio=1.0 | Jul | false | Klee |
| 71 | (16,-273) | – (0) | PLOWED | 0 | 0/31 'tot' | dormant | – | – | – | – |
| 72 | (111,-293) | PEA(22) | PLOWED | 0 | 1/30 'tot' needsWatch+Hoe | dormant | – | – | false | Erbsen |
| 73 | (97,-115) | – (0) | PLOWED | 0 | 0/31 'tot' | dormant | – | – | – | – |
| 76 | (-40,-160) | ALFALFA(37) | GRASS | 3 | 0 | cut | **swath** ratio=1.0 | Jul | false | Luzerne |

## Frucht-Ernte-Stufen (Auszug, für Tests)

WHEAT 7/7 · MAIZE 7/8 · RYE 8/8 · TRITICALE 8/8 · SOYBEAN 7/7 · PEA 5/5 · GRASS 3/4 · CLOVER 3/5 · ALFALFA 3/5 · MEADOW 3/4

---

## Kritische Befunde (für Phase 1 Audit)

### B1 — Gras-Rest läuft auf Rauschen (Ursache Feld-6-Klasse)
`FSDensityMapUtil` global **nicht verfügbar** → `detectGrassResidue` nutzt Engine-Höhe. `centerMaterial` 56–84 und `maxMaterial`/`liters` (Millionen) erscheinen **identisch** auf Acker, gepflügt UND Gras. D. h. die Unterscheidung loose/swath/none basiert hier auf **Terrain-Höhe**, nicht auf echtem Schwad-Material.
- Feld 6: `state=loose ratio=1.0` → aber kein Schwad-Hit (`swathHits=0 windrowLineEvidence=false`). „loose“ kommt allein aus `occupiedRatio>=0.55 + centerMaterial`. → **unzuverlässig**.
- **Folge für Plan:** `deriveGrassResiduePhase` muss bei fehlendem `FSDensityMapUtil` **ehrlich** „none/unbekannt“ liefern statt loose/swath aus Höhenrauschen. Sonst bleibt Feld 6 instabil, egal wie oft gefixt.

### B2 — Stoppel nicht erkannt (Feld 16)
TRITICALE growth=**11**, maxHarvest=**8**, ground=HARVEST_READY, aber `isCropHarvestReady=false` und `getHarvestWindowHint='-'`. growth (11) > maxHarvest (8) ⇒ **post_harvest/Stoppel**. Im Dump wird Feld weiterhin als „Triticale“ + meadowPhase dormant geführt; Anzeige müsste „Stoppeln“ + Bodenarbeit sein.
- `deriveFieldPhase`-Testfall: growth>maxHarvest ⇒ `post_harvest`.

### B3 — Unkraut-Vorschlag widersprüchlich (Feld 16, 72)
- Feld 16: live=2 (6%), `needsCombat=true` **und** `needsHoe=true`, `centerDeadOrSprayed=true`, doneByCoverage=false. Bei 6% live evtl. nur Striegeln, nicht Spritzen.
- Feld 72: live=1 'tot', doneByCoverage=**true**, trotzdem `needsWatch=true needsHoe=true`. „tot/erledigt“ aber zwei Aktionen → Widerspruch.
- `deriveWeedAdvice`-Testfälle: doneByCoverage=true ⇒ keine Aktion; kleine live-Ratio ⇒ höchstens Hoe.

### B4 — Feld 9 Weizen Unkraut
live=8 (26%), needsCombat=true. Plausibel (echtes Unkraut). Als „soll Spritzen/Striegeln“-Positivfall in Tests behalten.

### B5 — Gras erntbar trotz meadowPhase=cut (Feld 63, 76)
growthFlags(harvestable=true, harvestReady=true) aber meadowPhase=**cut** und residue=swath. Klee/Luzerne frisch gemäht mit Schwad → korrekt **nicht** „mähen“, sondern Schwad-Logistik + Nachwuchs. Als Positivfall behalten (Label bleibt Klee/Luzerne, nicht „Gras (teilw.)“).

---

## Soll-Anzeige (Tests-Erwartung, nach Konsolidierung)

| Feld | Soll-Phase | Soll-Liste (Kurz) |
|------|-----------|-------------------|
| 1 SOYBEAN g4 | standing | Ernte Okt |
| 6 GRASS cut | grass_cut/residue | Nachwuchs **oder** Schwaden/Sammeln — **kein** blindes „Wächst“; bei fehlendem DensityMapUtil ehrliche Aussage |
| 9 WHEAT g6 26% weed | standing | Spritzen/Striegeln + Ernte Aug |
| 14 leer PLOWED | empty | Ansäen |
| 15 MAIZE g4 10% weed | standing | Striegeln(+ggf. Spritzen) + Ernte Okt |
| 16 TRITICALE g11>max8 | post_harvest | Stoppeln → Pflügen/Kalk/**Neu ansäen**; Unkraut höchstens Striegeln |
| 17 leer NONE | empty/unknown | Ansäen / Alles ok |
| 63 CLOVER cut swath | grass_residue(swath) | Sammeln/Ballen; Label **Klee** |
| 71 leer PLOWED | empty | Ansäen |
| 72 PEA g0 weed tot | empty | Ansäen; Unkraut tot → keine Spritzen |
| 73 leer PLOWED | empty | Ansäen |
| 76 ALFALFA cut swath | grass_residue(swath) | Sammeln/Ballen; Label **Luzerne** |
