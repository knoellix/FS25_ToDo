# Feld-Phasen (Kontrakt für `deriveFieldPhase`)

Eine **einzige** Quelle für „in welchem Arbeitszustand ist das Feld?“. Vorschläge, Anzeige und Auto-Erledigen leiten **nur** hieraus ab.

Status: **festgelegt** (Phase 1.5). Phase 2 implementiert genau diesen Kontrakt in `scripts/FieldPhase.lua`.

---

## Designprinzip: rein + testbar

`deriveFieldPhase` ist eine **reine** Funktion:

- **Eingabe:** eine normalisierte `facts`-Tabelle (siehe unten) — **keine** Engine-Globals (`FieldState`, `g_fruitTypeManager`, `DensityMapHeightUtil`).
- **Ausgabe:** genau **ein** Phasen-String.
- Engine-Zugriff passiert **davor** (Proben/Sammeln) und füllt `facts`. Nur so ist die Entscheidung ohne FS25 testbar.

`scripts/FieldPhase.lua` gibt am Ende seine Tabelle zurück (`return FieldPhase`), damit Tests es per `dofile`/`require` laden können und FS25 es als Global nutzt.

---

## `facts`-Eingabe (von der Sammelschicht befüllt)

| Feld | Typ | Quelle (heute) |
|------|-----|----------------|
| `dominant` | `"arable"`/`"grass"`/`"bare_soil"`/`"unknown"` | `aggregateFieldProbes().dominantSituation` |
| `isGrassCrop` | bool | `isGrassCrop(fruitTypeIndex)` |
| `hasFruit` | bool | `fruitTypeIndex > 0` und nicht UNKNOWN |
| `growth` | number | `getEffectiveGrowthState` |
| `maxHarvest` | number | `fruitDesc.maxHarvestingGrowthState` (0 wenn unbekannt) |
| `ground` | string | `getGroundTypeName` (z. B. `HARVEST_READY`, `PLOWED`, `GRASS_CUT`) |
| `flags` | table | `evaluateFruitGrowth`: `{cut, harvestable, harvestReady, withered}` |
| `shred` | number | `stubbleShredLevel` (>0 ⇒ frisch gemäht/gehäckselt) |
| `residue` | `"none"`/`"baled"` (Gras) | `deriveGrassResidueSummary` — ballen-basiert; loose/swath **nicht** sensierbar (B1) |
| `residueReliable` | bool | immer `false` für loose/swath; Ballen-Zählung separat über `sampleBaleCoverage` |

---

## Phasen-Enum (Ausgabe)

| Phase | Bedeutung | Folge (Vorschläge) |
|-------|-----------|--------------------|
| `standing` | Acker, aktive Frucht, wächst | Erntefenster, Unkraut, Dünger |
| `harvest_ready` | Acker, erntereif | Ernten |
| `withered` | verdorrt | Grubbern/Pflügen, neu ansäen |
| `post_harvest` | Acker-Stoppel nach Ernte | Pflügen/Grubbern, Kalk, **Neu ansäen**, Walzen |
| `empty` | unbestellt / leerer bearb. Boden | Ansäen / Brache, Kalk, pH |
| `grass_standing` | Gras, wächst | Erntefenster |
| `grass_harvestable` | Gras, mähbar | Mähen |
| `grass_cut` | Gras gemäht, Rest unklar/`none` | Nachwuchs-Hinweis |
| `grass_residue` | Gras-Rest (nur Ballen zuverlässig) | Ballen holen; sonst manuelle Kette (Schwaden/Sammeln/Ballen) |
| `unknown` | nicht klassifizierbar | „Alles ok“ |

---

## Entscheidungsregeln (verbindlich, in dieser Reihenfolge)

### Acker / bare_soil (`dominant ~= "grass"` und nicht `isGrassCrop`)

1. `flags.withered` → **`withered`**
2. `hasFruit` und `flags.harvestReady` und `growth <= maxHarvest` (oder `maxHarvest == 0`) → **`harvest_ready`**
3. **Stoppel** → **`post_harvest`**, wenn eine davon:
   - `growth > maxHarvest` und `maxHarvest > 0`
   - `flags.cut`
   - `ground ∈ {STUBBLE, HARVEST_READY}` **und nicht** (`flags.harvestable` oder `flags.harvestReady`)
4. `hasFruit` und `growth > 0` → **`standing`**
5. sonst → **`empty`**

> W1/W6: Regel 3 schlägt Regel 4 — Stoppel **vor** „standing/empty“. growth>maxHarvest gewinnt über „growth>0 ⇒ aktiv“.

### Gras (`dominant == "grass"` oder `isGrassCrop`)

1. `flags.withered` → **`withered`**
2. `residue ∈ {loose, swath, baled}` und `residueReliable` → **`grass_residue`** (Sub = `residue`)
3. `flags.cut` oder `ground == GRASS_CUT` → **`grass_cut`** (eindeutige Schnitt-Signale)
4. `flags.harvestable` oder `flags.harvestReady` → **`grass_harvestable`**
5. `shred > 0` → **`grass_cut`** (Rest-Shred **ohne** Nachwuchs ⇒ kürzlich gemäht)
6. `growth > 0` → **`grass_standing`**
7. sonst → **`unknown`**

> `flags` kommen aus **`getGrassMeadowPhase`** (dem einen Gras-Entscheider), nicht roh aus `evaluateFruitGrowth`: `cut = meadowPhase=="cut"`, `harvestable/harvestReady = meadowPhase=="harvestable"`. Kein zusätzliches `postMow`/`fieldHasPartialSoilWork` aufschlagen (sonst Feld-76-Bug).
> W2/W3: Bei `residueReliable == false` (Dichtekarte fehlt) **kein** `grass_residue` aus Höhen-Rauschen → Feld 6 landet ehrlich bei `grass_cut` (Nachwuchs-Hinweis) statt erfundenem loose/swath.
> **Regel 4 vor 5 (wichtig):** Ein wieder mähreif **nachgewachsener** Bestand (Klee/Luzerne, `growth=minHarvest`, `harvestReady`) ist `grass_harvestable` → „mähen", **auch wenn** noch `shred > 0` vom letzten Schnitt liegt. `isGrassPostMowState` setzt `meadowPhase` in diesem Fall **nicht** auf `cut`. Nur frisch geschnitten (`GRASS_CUT`/`isCut`/Shred ohne Nachwuchs) bleibt `grass_cut`.

---

## Erwartete Phasen je Golden-Feld (Test-Soll)

| Feld | facts (Kern) | Erwartet |
|------|--------------|----------|
| 1 SOYBEAN | arable, g4, max7, ROLLER_LINES, flags alle false | `standing` |
| 6 GRASS | grass, g5, GRASS_CUT, cut=true, residue=loose **unreliable** | `grass_cut` |
| 9 WHEAT | arable, g6, max7, flags false | `standing` |
| 14 leer | bare_soil, g0, PLOWED, kein Fruit | `empty` |
| 15 MAIZE | arable, g4, max8, PLANTED | `standing` |
| 16 TRITICALE | arable, g11, max8, HARVEST_READY, flags false | `post_harvest` |
| 17 leer | unknown, g0, NONE | `empty`/`unknown` |
| 63 CLOVER | grass, g3, GRASS, **harvestable/ready=true** (nachgewachsen), shred=1 | `grass_harvestable` |
| 71 leer | bare_soil, g0, PLOWED | `empty` |
| 72 PEA | arable/bare, g0, PLOWED, kein lebender Crop | `empty` |
| 73 leer | bare_soil, g0, PLOWED | `empty` |
| 76 ALFALFA | grass, g3, GRASS, **harvestable/ready=true** (nachgewachsen), shred=1 | `grass_harvestable` |

> Feld 63/76 (Stand 2026-06-04, im Spiel verifiziert): Klee/Luzerne stehen schnittreif nachgewachsen → `grass_harvestable` („mähen"), trotz Shred-Rest. **Sobald** `FSDensityMapUtil` echte Schwad-Daten liefert (`residueReliable=true`) und das Feld tatsächlich gemäht ist, greift Regel 2 → `grass_residue(swath)`.

---

## Verbindlich

- Keine zweite Funktion, die „Phase“ anders bestimmt.
- Neue Regel → hier anpassen **und** `DECISIONS.md` ergänzen **und** nur in `deriveFieldPhase`.
- Jede Phase mindestens einmal in `tests/fixtures.lua`.

---

## Unkraut-Advice (`WeedAdvice.deriveWeedAdvice`)

Eine reine Funktion (`scripts/WeedAdvice.lua`), Eingabe = normalisierte `facts` (aus `FieldAdvisor.buildWeedAdviceFacts`), Ausgabe = `{ done, hoe, watch, needsCombat, spray }`. Aufrufer (`fieldNeedsWeedHoe`, `fieldShouldSuggestWeedSpray`, `fieldNeedsWeedWatch`, `fieldNeedsWeedCombat`) sind dünne Wrapper, die genau ein Feld zurückgeben. Vorschläge: `weed_hoe` bei `hoe`, `weed_combat` bei `spray`.

**Facts:** `enabled`, `hasSummary` (weedSummary vorhanden), `hasCoverage` (Proben>0), `live`, `classified`, `liveRatio`, `doneByCoverage`, `deadOrSprayed` (State-Fallback), `pressure` (State-Fallback), `weedState`.

**Schwellen** (= `WeedAdvice.*`, synchron zu `FieldAdvisor.WEED_*`): combat/actionable `0.05`, clean `< 0.02`, spray-Druck `>= 0.10`, spray-State `>= 3`, sprayed-live-State `1..2`.

**Regeln (Reihenfolge):**
1. `enabled == false` → alles `false`.
2. **Coverage gewinnt:** `hasCoverage && doneByCoverage` → `done=true`, **keine** Aktion (W4: totes Feld schlägt nichts mehr vor).
3. Sonst:
   - `needsCombat`: Coverage `liveRatio >= 0.05` (sonst State-Druck `>= 0.05`, außer `deadOrSprayed`).
   - `watch`: `liveRatio`/Druck in `(0.02, 0.05)`.
   - `spray`: `needsCombat` **und** nicht `deadOrSprayed` **und** (`weedState >= 3` **oder** Druck `>= 0.10`). → kleiner Live-Anteil ohne hohe Stufe = **kein** Spritzen (W5).
   - `hoe`: jedes aktionable Live-Unkraut — `watch`, oder `needsCombat` mit `spray`/State `1..2`.

Tests: `tests/weed_fixtures.lua` (inkl. W4/W5). Auto-Erledigen weiter über `isWeedTaskDoneByCoverage` (Coverage), konsistent mit `done`.
