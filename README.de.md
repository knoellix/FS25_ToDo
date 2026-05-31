# FS25_FieldToDoList

**To-Do- und Feldarbeitsliste** für Farming Simulator 25 — eigene Aufgaben verwalten, nächste Arbeitsschritte je eigenem Feld sehen, optional mit Precision-Farming- und Seasonal-Crop-Stress-Spalten.

**Autor:** Christian Möllmann ([knoellix](https://github.com/knoellix))  
**Lizenz:** [GNU GPL v3](LICENSE)  
**Version:** `0.1.0.5` (Vorabversion)

## Funktionen

- **ESC-Menü** (eigener Tab): manuelle To-Dos links, Feldübersicht mit Kulturstatus und Vorschlägen rechts
- **HUD in der Welt:** `Linke Strg + F5` — kompakte Liste offener Aufgaben (oben rechts, bis zu 5 Einträge)
- **Arbeitsreihenfolge:** Presets (z. B. Pflügen → Kalken → Säen → Düngen) und **abwechselndes Mist/Gülle** für organische Mehrfachgaben
- **Feld-Workflow:** Vorschläge übernehmen, Feld besuchen (Teleport), Auto-Erledigt wenn das Spiel die Arbeit als erledigt erkennt
- **Listenreihenfolge:** `Hoch` / `Runter` Mini-Buttons (`^` / `v`) verschieben die ausgewählte Aufgabe (kein Drag-and-drop in der Giants-UI)
- **Erledigt-Verhalten:** erledigte Aufgaben unter offenen; neu erledigte oben in der Erledigt-Gruppe; max. 10 erledigte (älteste werden entfernt)
- **Auswahl-UX:** nach Verschieben bleibt die Aufgabe ausgewählt; nach Löschen wird die Auswahl entfernt
- **Erntehinweise:** Vorschlagsspalte zeigt Monatsnamen statt missverständlicher Monatsanzahl
- **Speicherstand-Daten:** `fieldToDoList.xml` im Savegame-Ordner (Tasks mit ~2 s Debounce; Einstellungen sofort)
- **Feldstatus:** Live-Boden-/Fruchtdaten aus dem Spiel (kein Laufzeit-Lesen von `fields.xml` — vermeidet Konflikte, solange das Spiel läuft)
- **Graswiesen:** Mähen bei Reife; Hinweise zu Schwaden/Sammeln/Ballen; kein falsches Säen auf Wiesen

## Optionale Mods

| Mod                                                                                         | Status                                                                                           |
| ------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| FS25_precisionFarming                                                                       | Unterstützt — pH-/Stickstoff-Spalten, wenn PF geladen ist                                       |
| [FS25_SeasonalCropStress](https://github.com/TheCodingDad-TisonK/FS25_SeasonalCropStress) | Teilweise/limitiert — Feuchte/Stress können `-` oder „lädt“ anzeigen; keine vollständige Integration |

Funktioniert vollständig auch ohne Zusatzmods nur mit Basegame-Felddaten.

## Installation

1. `FS25_FieldToDoList.zip` aus dem [latest release](https://github.com/knoellix/FS25_FieldToDoList/releases/latest) laden.
2. ZIP (**nicht entpacken**) in den Mods-Ordner kopieren:

| Plattform              | Pfad                                                                                                                            |
| ---------------------- | ------------------------------------------------------------------------------------------------------------------------------- |
| Windows                | `%USERPROFILE%\Documents\My Games\FarmingSimulator2025\mods\`                                                                  |
| macOS                  | `~/Library/Application Support/FarmingSimulator2025/mods/`                                                                      |
| Linux (Steam) | `~/.local/share/Steam/steamapps/compatdata/2300320/pfx/drive_c/users/steamuser/Documents/My Games/FarmingSimulator2025/mods/` |

3. **Field To-Do List** im Spiel aktivieren.
4. Karriere-Spielstand laden — der Mod wird automatisch aktiv.
5. Nach Installation/Update das Spiel **komplett neu starten**.

## Entwicklung

Aus dem Quellcode bauen und direkt in den lokalen Mods-Ordner installieren:

```bash
python3 tools/generate_assets.py   # optional, falls DDS-Assets fehlen
./build.sh
```

Standardziel (Linux Steam):
`~/.local/share/Steam/steamapps/compatdata/2300320/pfx/drive_c/users/steamuser/Documents/My Games/FarmingSimulator2025/mods/FS25_FieldToDoList.zip`

Eigenes Ziel:

```bash
FS25_MODS_DIR=/pfad/zu/mods ./build.sh
```

## Debug (Feldberater)

Funktioniert unter **Windows, macOS und Linux**. Nutzen, wenn ein Feld falsche Kultur, Erntemonat oder Gras-Logistik in der Übersicht zeigt.

| Eingabe | Aktion |
| ------- | ------ |
| **F9** oder **Linke Strg + F9** | Giants-Entwicklerkonsole öffnen, sonst Mod-Dialog |
| `ftdlHelp` | Debug-Befehle anzeigen |
| `ftdlDump 63` | Ein Feld in `log.txt` ausgeben (Feld-ID anpassen) |
| `ftdlFruits` | Fruchtarten und Erntewachstumsstufen |
| `ftdlAll` | Alle eigenen Felder |

**Logdatei** (`log.txt` im FS25-Benutzerordner):

| Plattform | Pfad |
| --------- | ---- |
| Windows | `%USERPROFILE%\Documents\My Games\FarmingSimulator2025\log.txt` |
| macOS | `~/Library/Application Support/FarmingSimulator2025/log.txt` |
| Linux (Steam) | `~/.local/share/Steam/steamapps/compatdata/2300320/pfx/drive_c/users/steamuser/Documents/My Games/FarmingSimulator2025/log.txt` |

Nach `[FS25_FieldToDoList] DUMP` suchen. Wichtig: `meadowPhase`, `grassResidue`, `grassCrossScan`, `heightReader`, `harvestState`.

Beispiel:

```text
ftdlDump 63
```

Kein Auto-Dump beim Menü — nur manuell.

## Mitwirken

Beiträge sind willkommen (Bugfixes, Features, Übersetzungen).

- Einstieg: [`CONTRIBUTING.md`](CONTRIBUTING.md)
- Übersetzungs-Workflow: [Übersetzungs-Issue öffnen](https://github.com/knoellix/FS25_FieldToDoList/issues/new?template=translation.yml)
- Allgemeine Bugs/Features: [GitHub Issues](https://github.com/knoellix/FS25_FieldToDoList/issues)

## Changelog

Siehe [CHANGELOG.md](CHANGELOG.md). **0.1.0.5:** inkrementeller Feld-Scan, Scan-Status-Punkt, gezieltes Zeilen-Update bei Auto-Erledigt, 15 s Rescan, Performance-Caches.

## Bekannte Punkte / WIP

- Gras Schwaden → Sammeln/Ballen wird auf manchen Maps noch nachgeschärft (wenn `DensityMapHeightUtil` zur Laufzeit fehlt — Fallback über Engine-Höhenkarte).
- Auto-Completion ist insgesamt noch in Arbeit und braucht breitere Tests auf realen Spielständen.

## Issues

Bitte die Issue-Templates für Bugs, Features und Übersetzungen nutzen:
[GitHub Issues](https://github.com/knoellix/FS25_FieldToDoList/issues)

## Lizenz

Copyright (C) 2026 Christian Möllmann (knoelliX).  
Veröffentlicht unter der GNU General Public License v3 — siehe [LICENSE](LICENSE).

