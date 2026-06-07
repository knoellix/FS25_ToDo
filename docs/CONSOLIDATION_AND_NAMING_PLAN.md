# FS25_FieldToDoList — Konsolidierungs- und Naming-Plan

Stand: 2026-05-29  
Zweck: Nach Audit+Fix-Tag **keine neuen Parallel-Funktionen** mehr; Advisor-Logik **zusammenführen**, dann **Kommentare und Bezeichner** inhaltlich prüfen (lesen, nicht nur Muster-Suche).

---

## Ausgangslage

- Zwei intensive Tage (Audit + Fixes) haben viele Einzelkorrekturen erzeugt.
- Symptom: **mehrere Funktionen für dieselbe Spielentscheidung** (`hasActiveCrop`, `isFieldSown`, `getCropPhase`, Gras-Rest, Unkraut, …).
- Nächster Schritt ist **kein weiterer Feature-Fix**, sondern **Struktur + Verständlichkeit** vor dem nächsten Release.

---

## Grundregeln (für Mensch und KI, verbindlich)

1. **Eine Wahrheit pro Entscheidung:** Jede Spielfrage (Phase, Ernte, Gras-Rest, Unkraut erledigt) hat **genau eine** entscheidende Funktion.
2. **Neue Funktionen sind erlaubt — aber konsolidierend, nicht parallel.**
   - **Gut:** eine neue Funktion, die **alle** Regeln einer Entscheidung bündelt (z. B. **eine** `deriveGrassResiduePhase` statt 4 Gras-Helfer) → besserer Überblick.
   - **Schlecht:** eine zusätzliche `is*`/`has*`/`should*` **neben** einer, die schon dieselbe Frage beantwortet.
   - Faustregel: Wird die neue Funktion die alten **ersetzen** (Aufrufer umstellen, Alte löschen)? → ok. Kommt sie **obendrauf**? → nein.
3. **Anpassen vor Anhängen:** Bug = die **eine** zuständige Funktion korrigieren (oder sauber durch eine bündelnde ersetzen), **nicht** Wrapper Nr. 2 daneben.
4. **Sinnvoll platziert:** neue Logik gehört in die zuständige Entscheidungsfunktion / Pipeline-Stufe — nicht als Sonderzweig in `buildFieldContext` / `resolveActionCandidates`, der die eigentliche Funktion umgeht.
5. **Freeze für Features:** keine neuen Spiel-Features während der Konsolidierung; Aufräumen ja, Funktionsumfang erweitern nein.
6. **Fertig** = Konsolidierung + Tests grün + 5-Feld-Check + Kommentar/Naming-Phase für betroffene Dateien abgeschlossen.
7. **Kein „Roman“-Pflicht für den User:** Bug-Meldung reicht in der [Bug-Vorlage](#bug-meldung-kurz) unten.

---

## Übersicht Phasen

| Phase | Inhalt | Dauer (Richtwert) | Ergebnis |
|-------|--------|-------------------|----------|
| **0** | Freeze, Branch, Baseline, Golden-Snapshot | 0,5 h | `consolidation/…` Branch, Tag `pre-consolidation`, `expected_before` |
| **1** | Audit (Duplikate, Widersprüche, Aufrufgraph) | 1 Tag | `docs/AUDIT_INVENTORY.md` |
| **1.5** | Phase-Enum + Test-Harness + Fixtures | 0,5–1 Tag | `docs/FIELD_PHASE.md`, `tests/` laufen headless |
| **2** | Zusammenfassen & entfernen | 1–2 Tage | Weniger Funktionen, eine Phase-Pipeline |
| **3** | Regression im Spiel | 0,5 Tag | `docs/REGRESSION.md` abgehakt |
| **4** | Kommentare (durchlesen) | 1–2 Tage | Kein irreführender Kommentar in Kern-Dateien |
| **5** | Namen (Funktionen, Variablen) | 0,5–1 Tag | Technisch treffende Bezeichner |
| **6** | Release-Hülle | 0,5 h | README + Version nur wenn 3+5 grün |

**Gesamt:** ca. 5–7 Arbeitstage, **strikt in dieser Reihenfolge**. Phase 4/5 **nicht** parallel zu offenen Widersprüchen in Phase 2.

**Laufend mitgeführt:** `docs/DECISIONS.md` — jede festgelegte Spielregel als eine Zeile (gegen „dieselbe Sache 4× gefixt“).

---

## Phase 0 — Vorbereitung (halber Tag)

- [ ] Branch: `consolidation/advisor-single-truth` von aktuellem `main`.
- [ ] Git-Tag: `pre-consolidation-YYYYMMDD` (Rollback-Punkt).
- [ ] `modDesc.xml` / Version **nicht** bumpen bis Phase 6.
- [ ] **Golden-Snapshot:** im Spiel `ftdlAll` / `ftdlDump <n>` für **alle** eigenen Felder → roh als `docs/regression-notes/expected_before.txt` sichern. Dient als Vergleich: nach jedem Refactor-Schritt erneut dumpen, **diffen** — ungewollte Änderungen fallen sofort auf.
- [ ] **Datei-Checkliste (vollständig)** — jede Zeile mit `[ ]` → `[x]` wenn Phase 1+4+5 für die Datei fertig:

  **scripts/** (alle):  
  `FieldAdvisor.lua` → `FieldTaskCompletion.lua` → `FieldWorkCatalog.lua` → `FieldScanner.lua` → `ToDoManager.lua` → `InGameMenuIntegration.lua` → `FieldToDoHudOverlay.lua` → `FieldToDoHudInput.lua` → `FieldActionPicker.lua` → `FieldAdvisorSettings.lua` → `FieldGameRules.lua` → `FieldVisit.lua` → `FieldDebugDump.lua` → `FieldDebugConsole.lua` → `FieldDebugConsoleInput.lua` → `FieldToDoLog.lua` → `FieldToDoL10n.lua` → `FieldSavegameReader.lua` → `PrecisionFarmingReader.lua` → `PrecisionFarmingBridge.lua` → `SeasonalCropStressReader.lua`  

  **gui/** (alle): `FieldToDoMenuFrame.lua` (+ weitere falls vorhanden)  

  **translations/**: `translation_de.xml`, `translation_en.xml` (fachlich falsche / tote Keys)  

  **Projekt:** `modDesc.xml`, `build.sh`, `tools/generate_assets.py` (nur wo Verhalten/Kommentare)

- [ ] **5-Feld-Referenz** für alle folgenden Phasen festhalten (Nummern + erwartete Anzeige):

  | # | Situation | Erwartung Liste (Kurz) |
  |---|-----------|-------------------------|
  | 1 | Frisch geerntet (z. B. Roggen) | Stoppeln, nicht „Wächst“; Bodenarbeit vor Säen |
  | 2 | Frisch gepflügt, leer | Ansäen / Brache, kein Gras-Label |
  | 3 | Gras nach Schwaden | Sammeln/Ballen-Kette, kein blindes „Wächst“ |
  | 4 | Unkraut tot / leicht nachgewachsen | kein Spritzen wenn erledigt; leichtes Unkraut ggf. Striegeln |
  | 5 | Erntbereit (z. B. Weizen) | Ernten, nicht Stoppel |

---

## Phase 1 — Audit (ein Tag, nur inventarisieren)

**Ziel:** Karte der **doppelten und widersprüchlichen** Logik — **noch nicht** groß refactoren.

### 1.1 Entscheidungs-Matrix (Pflicht-Tabelle in `docs/AUDIT_INVENTORY.md`)

Für jede Zeile: *Welche Funktionen behaupten aktuell dasselbe?* → *Welche wird Kanon?* → *Welche wird entfernt?*

| Spielentscheidung | Kandidaten-Funktionen (alle auflisten) | Kanon (Ziel) | Zu löschen / umbiegen |
|-------------------|--------------------------------------|--------------|------------------------|
| Feldphase (wachsend / erntbereit / Stoppel / leer / Gras) | `getCropPhase`, `hasActiveCrop`, `isFieldSown`, `isArableHarvestedStubble`, `isPostHarvestSoilWorkPhase`, … | **`deriveFieldPhase`** (neu, einmalig) | alle Parallel-Entscheider |
| Erntbereit Acker | `isCropHarvestReady`, `isCropHarvestReadyByGrowth`, `isHarvestReady`, … | **eine** | Rest |
| Stoppel / nach Ernte | `isArableHarvestedStubble`, `hasActiveCrop`, `isFieldSown`, … | in `deriveFieldPhase` | Rest |
| Gras-Feld vs. Acker | `classifyProbe`, `isGrassFieldState`, `isGrassCropFieldContext`, `isArableFieldContext`, … | **`classifyFieldKind`** (ein Enum) | redundante Checks |
| Gras nach Mähen | `getGrassMeadowPhase`, `isGrassPostMowState`, `isGrassStandingCropPhase`, … | **`deriveGrassMeadowPhase`** | Rest |
| Gras-Rest (los/Swad/Ballen) | `fuseGrassResidueSignals`, `refineGrassResidueSummary`, `isGrassCollectEffectivelyDone`, `hasGrassSwathMaterialRemaining`, `shouldTreatGrassResidueAsSwath`, … | **`deriveGrassResiduePhase`** oder Feature streichen | Rest |
| Unkraut sichtbar / erledigt | `isWeedProbeLive`, `isWeedProbeDead`, `isWeedTaskDoneByCoverage`, `fieldNeedsWeedHoe`, … | **`deriveWeedAdvice`** | Rest |
| Vorschlagsspalte | `resolveActionCandidates`, `addGrassWorkActions`, `formatSuggestionColumn`, `selectPrimaryAction`, … | nur von Phase ableiten | versteckte Sonderpfade |
| Auto-Erledigen | `FieldTaskCompletion.*` vs. `FieldAdvisor.isGrassSwathWorkComplete`, … | Completion nur aus **Kontext-Phase** | doppelte Heuristiken |

### 1.2 Aufruf-Inventar

- Pro Kandidaten-Funktion: **Wer ruft sie auf?** (Datei + Zeile, ripgrep).
- Markieren: **nur 1 Aufrufer** → Kandidat zum Inline; **5+ Aufrufer** → Kanon-Kandidat.

### 1.3 Widerspruchs-Liste

Konkrete Paare, die in der Vergangenheit gegeneinander liefen (aus Chat/Spiel):

- Stoppel mit `growthState > 0` vs. `hasActiveCrop` / `isFieldSown`
- `buildFieldContext` Reihenfolge: collect-done vor swath-erkennung
- `isUniformCutFieldIdleResidue` vs. volles Feld nach Schwaden
- Unkraut tot vs. `liveRatio`-Schwellen
- `dominantSituation` BARE_SOIL vs. center ARABLE Stoppel

Jeder Eintrag: **Symptom → zwei Funktionen → gewünschtes Verhalten → welche Funktion bleibt**.

### 1.4 Vollständigkeit vs. Feature-Umfang (wichtig)

**Vollständigkeit = immer 100 %** (keine Entscheidung nötig):

| Was | Umfang |
|-----|--------|
| Audit Inventar | **Alle** Lua unter `scripts/`, **alle** `gui/*.lua`, L10n `translations/*.xml` (Keys/Strings), Build `tools/` + `build.sh` wenn Logik |
| Duplikat-Suche | Jede Datei, jede `function` — FieldAdvisor zuerst, dann Rest in fester Reihenfolge |
| Kommentar-Phase | **Jeden** Kommentar in diesen Dateien **durchlesen** (siehe Phase 4), protokollieren in `COMMENT_PASS_LOG.md` |
| Naming-Phase | **Alle** exportierten / Modul-Funktionen + irreführende Variablen im gleichen Umfang |

**Nicht** „nur Gras“, **nicht** nur Advisor — nur **Reihenfolge** (größte Datei zuerst).

**Feature-Umfang:** **A — alles bleibt.** Konsolidierung = Code aufräumen, **nicht** Funktion streichen.

**Stop Phase 1:** `AUDIT_INVENTORY.md` vollständig (alle Dateien in [Datei-Checkliste](#datei-checkliste-vollständig)).

---

## Phase 1.5 — Phase-Enum + Test-Harness (0,5–1 Tag)

**Ziel:** Bevor irgendwas zusammengelegt wird, gibt es (a) eine **feste Phasen-Definition** und (b) eine **schnelle Prüfung ohne Spielstart**. Das ist die eigentliche Anti-Kreislauf-Maßnahme: Bricht ein Fix etwas anderes, schlägt ein Test in Sekunden fehl statt Tage später im Spiel.

### 1.5.1 Phase-Enum festschreiben

- `docs/FIELD_PHASE.md` füllen: **welche** Phasen es gibt + **eine** Definition je Phase (welche `FieldState`-/`FruitTypeDesc`-Werte sie auslösen).
- `deriveFieldPhase` (Phase 2) muss exakt diese Enum liefern — kein Freitext, keine Zwischenzustände.

### 1.5.2 Reine Entscheidungsfunktionen

- Ziel-Funktionen (`deriveFieldPhase`, `deriveGrassResiduePhase`, `deriveWeedAdvice`, …) sind **rein**: Eingabe = eine `fieldState`-Tabelle (+ Frucht-Infos als Tabelle/Stub), Ausgabe = Enum/Struktur.
- **Keine** Engine-Calls (`FieldState.new`, `DensityMapHeightUtil`, `g_fruitTypeManager`) **in** diesen Funktionen — Engine-Zugriff bleibt in den Sammel-/Probe-Funktionen davor. Nur so sind sie testbar.

### 1.5.3 Fixtures aus echten Dumps

- Pro Problemfeld einen `ftdlDump` als Fixture ablegen: `tests/fixtures/<fall>.lua` mit den Roh-Zahlen (growth, ground, fruit, weed, residue …).
- Pflicht-Fälle (= die 5-Feld-Referenz + alte Bugs):
  - `field_rye_harvested` (Stoppel, nicht „Wächst“)
  - `field_plowed_empty` (Ansäen/Brache)
  - `field_grass_swathed` (Heu sammeln/Ballen)
  - `field_weed_dead` (kein Spritzen)
  - `field_wheat_ready` (Ernten)

### 1.5.4 Headless-Test

- Plain-Lua-Runner (oder `busted`, falls vorhanden): lädt Fixture → ruft `deriveFieldPhase` etc. → prüft erwartete Phase/Vorschlag.
- Start: `lua tests/run.lua` (oder `busted`) — **ohne** FS25.
- Ergebnis: jeder alte Bug = ein Test. Neuer Fix bricht alten → roter Test sofort.

**Stop Phase 1.5:** `FIELD_PHASE.md` Enum steht; mindestens die 5 Pflicht-Fixtures laufen (dürfen anfangs **rot** sein — sie definieren das Soll für Phase 2).

---

## Phase 2 — Zusammenfassen (1–2 Tage)

**Ziel:** Weniger Funktionen, **keine** neuen Parallel-Regeln. Nach jedem Schritt: **Tests grün** + **Golden-Diff** geprüft.

### 2.1 Reihenfolge der Implementierung

1. ✅ **`deriveFieldPhase(field, aggregation)`** — einzige Quelle für `getCropPhase`-Ergebnis.
2. ✅ **Meadow-Phase verifiziert** — `getGrassMeadowPhase` ist der einzige Entscheider; `isGrassHarvestable`/`isGrassCut` sind Readouts, `isGenericGrassStandingCrop` bewusst getrennt (Rekursion). Kein Merge (würde brechen), Rollen per Kommentar fixiert.
3. ✅ **Bewusster Schnitt** statt `deriveGrassResiduePhase`: alte Density-Map-Fusion gelöscht (~1380 Zeilen); Kanon = `deriveGrassResidueSummary` (Liter + Ballen, 2026-06-06).
4. ✅ **`deriveWeedAdvice`** — eine Stelle für Spritzen/Striegeln/keins.
5. ✅ **`buildFieldContext`** — geprüft: füllt nur Proben/State/Strukturen, trifft **keine** Phasenentscheidung (Gras-Gate nur als Ballen-Sampling-Gate). Schlank seit Residue-Schnitt.
6. ✅ **`resolveActionCandidates`** — Phase einmal ableiten, dann `PHASE_ACTION_BUILDERS[phase]`-Dispatch; keine `elseif`-Ketten für dieselbe Phase.
7. ✅ **`FieldTaskCompletion`** — Completion pro Aktion (FieldState/Ballen), keine Phasen-Heuristik; `grass_swath`/`grass_collect` raus (manuell).

### 2.2 Lösch-Regel pro Commit

Jeder Commit enthält:

- **Entfernte** Funktionen (Namen in Commit-Message).
- **Ersetzt durch** (eine Zeile).
- Kein Commit nur „neue Hilfsfunktion hinzugefügt“.

### 2.3 Metrik (vor/nach)

| Metrik | Vorher | Ziel nachher |
|--------|--------|--------------|
| `function FieldAdvisor.*` Anzahl | ~200 | −30 % mindestens |
| Entscheider für „nach Ernte“ | ≥3 | 1 (`deriveFieldPhase`) |
| Gras-Rest-Entscheider | ≥8 | ✅ 1 (`deriveGrassResidueSummary`, Detektion entfernt) |

### 2.4 Build & Spiel

Nach jedem halben Tag: `python3 tools/generate_assets.py && ./build.sh`  
Nach Tag 2 Ende: **5-Feld-Check** komplett.

**Stop Phase 2:** Metrik erreicht **und** alle Tests (Phase 1.5) grün **und** Golden-Diff nur erwartete Änderungen **und** 5 Felder grün **und** keine toten Funktionen (ripgrep findet keine Aufrufe auf gelöschte Namen).

---

## Phase 3 — Regression (halber Tag)

- [ ] `docs/REGRESSION.md` anlegen (Checkliste der 5 Felder + „Schwaden auto“, „Ernte auto“ optional).
- [ ] FS25 **Voll-Neustart** nach Build.
- [ ] Screenshots oder `ftdlDump <n>` für jedes Feld in `docs/regression-notes/` (kurz).
- [ ] Bekannte Rest-Macken als **LIMITATIONS** in README, nicht als versteckte `if`.

**Stop Phase 3:** Alle Pflichtzeilen abgehakt oder explizit als LIMITATIONS dokumentiert.

---

## Phase 4 — Kommentare durchlesen (1–2 Tage)

**Nicht:** Kommentare per Regex ersetzen („stale“, „TODO“, „fix“).  
**Sondern:** Datei **von oben nach unten** lesen; jeder Kommentar wird geprüft.

### 4.1 Methode pro Datei

1. Datei in **logische Blöcke** teilen (siehe Phase 0 Reihenfolge).
2. Pro Block (~100–200 Zeilen):
   - Kommentar **weglassen**, wenn Code selbsterklärend.
   - Kommentar **korrigieren**, wenn er eine **falsche** Regel beschreibt (z. B. „herbicide always means dead“).
   - Kommentar **ergänzen**, nur bei **nicht-offensichtlicher** Engine-/Spiel-Logik (Giants-API, Proton-Hinweis nur wenn technisch nötig).
3. Entfernte Funktionen: **keine** Kommentar-Friedhöfe — Kommentar mit Funktion löschen.
4. Am Block-Ende: 1 Satz **Invariant** (was hier *immer* gelten soll) — nur wenn Block komplex bleibt.

### 4.2 Kommentar-Qualitätskriterien

| Schlecht | Gut |
|----------|-----|
| „Fix for field 6“ | „Swath complete when residue phase is SWATH and liters remain.“ |
| „Do not use goto“ (in Business-Code) | (nur in Projekt-Regeln, nicht im Advisor) |
| Widerspricht zum Code darunter | Beschreibt **warum** die Bedingung so ist (1 Zeile) |
| Duplikat des Funktionsnamens | Weggelassen |

### 4.3 Reihenfolge

Gleiche Datei-Reihenfolge wie Phase 0; **FieldAdvisor.lua** in **mehrere Sessions** (z. B. 4× ~400 Zeilen), damit wirklich gelesen wird.

**Datei-abgeschlossen-Prinzip:** Eine Datei wird **komplett** fertig gemacht (Logik stabil → Tests grün → Kommentare → Namen) und dann in der [Datei-Checkliste](#datei-checkliste-vollständig) abgehakt — **nicht** wieder angefasst. So gibt es sichtbaren Fortschritt statt „überall ein bisschen“.

### 4.4 Protokoll

In `docs/COMMENT_PASS_LOG.md` pro Datei:

```text
## FieldAdvisor.lua (Block 2/4, Zeilen 800–1200)
- Geändert: 3 Kommentare (Zeile …)
- Entfernt: 7 redundante
- Offen: keine
```

**Stop Phase 4:** Alle Kern-Dateien im Log; keine „TODO: audit later“ ohne Ticket.

---

## Phase 5 — Namen prüfen (0,5–1 Tag)

**Nach** Phase 2+4, damit Namen zur **einen** Logik passen.

### 5.1 Funktionen

| Muster | Aktion |
|--------|--------|
| `is*` liefert Phase/Enum | umbenennen → `derive*` / `classify*` |
| `has*` für „Arbeit erledigt“ | → `isWorkComplete` oder in Phase-Enum |
| `should*` | → in `derive*Advice` integrieren oder löschen |
| Drei Namen für dasselbe | einer bleibt, zwei weg |

Umbenennung: **alle** Aufrufer in einem Commit (kein Alias-Wrapper dauerhaft).

### 5.2 Variablen

- `probeState` / `harvestState` / `fieldState` — **ein** Begriff pro Scope (Glossar in `AUDIT_INVENTORY.md`).
- Keine Abkürzungen ohne Kontext (`scs`, `pf` nur wenn Mod-Name).
- Booleans: `needsPlowing`, nicht `plowFlag` / `doPlow`.

### 5.3 Öffentliche API (Mod-Grenze)

- Nur `FieldAdvisor.deriveFieldPhase` etc. dokumentieren in `docs/FIELD_PHASE.md`.
- Interne Helfer: `local` wo Lua-Struktur es erlaubt, oder Präfix `private_` vermeiden — stattdessen klarer Modul-Block.

**Stop Phase 5:** Glossar steht; ripgrep findet keine alten Namen der gelöschten Funktionen.

---

## Phase 6 — Release-Hülle (optional, halber Tag)

Nur wenn Phase 3 grün:

- [ ] README: Was Advisor **kann / nicht kann** (LIMITATIONS).
- [ ] `REGRESSION.md` verlinken.
- [ ] Version bump nur auf Wunsch.
- [ ] Kein Publish wenn `AUDIT_INVENTORY.md` Scope „reduziert“ aber README volle Kette verspricht.

---

## Bug-Meldung (kurz)

```text
Feld-Nr:
Zeigt:
Soll:
Vermutete Funktion (eine):
Keine neue Funktion — nur diese anpassen / in deriveFieldPhase.
```

---

## Was KI bei Umsetzung dieses Plans darf / nicht darf

| Erlaubt | Verboten |
|---------|----------|
| **Eine** bündelnde Funktion einführen, die mehrere alte ersetzt (Aufrufer umstellen, alte löschen) | Zusätzliche `isGrass…2` **neben** vorhandener Logik |
| Funktion **löschen** und Aufrufer umstellen | Neue Funktion, die nur das Gleiche nochmal entscheidet |
| Kommentar **kürzen/korrigieren** beim Lesen | Mass-Replace ohne Block-Lesen |
| `deriveFieldPhase` **einmal** einführen | Zweite Phase-Funktion „temporär“ |
| LIMITATIONS dokumentieren | „Quick fix“ außerhalb des Plans |

**Merksatz:** *Eine Funktion, die alle Regeln einer Entscheidung kennt — nicht vier, die sich widersprechen.*

---

## Erfolg = publishable

- [ ] Eine Phase-Pipeline, nachvollziehbar in `docs/FIELD_PHASE.md`.
- [ ] Deutlich weniger Advisor-Funktionen (Metrik Phase 2).
- [ ] 5-Feld-Regression grün oder als LIMITATIONS ehrlich.
- [ ] Kommentare in Kern-Dateien **inhaltlich** geprüft (Log vorhanden).
- [ ] Namen passen zu einer Logik (Glossar).
- [ ] Kein schlechtes Gewissen beim ZIP hochladen — weil Scope und Grenzen **ehrlich** in README stehen.

---

## Nächster Schritt (nach Freigabe dieses Plans)

1. Phase 0 + leeres `docs/AUDIT_INVENTORY.md` anlegen.  
2. Tag 1 nur Inventar (kein Refactor).  
3. Scope-Entscheid dokumentieren, dann Phase 2 starten.

*Dieses Dokument ist die verbindliche Reihenfolge; Einzel-Fixes außerhalb des Plans → Backlog „nach Konsolidierung“.*
