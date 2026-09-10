# FS25_FieldToDoList

**To-Do- und Feldarbeitsliste** für Farming Simulator 25 — eigene Aufgaben verwalten, nächste Arbeitsschritte je eigenem Feld sehen, optional mit Precision-Farming- und Seasonal-Crop-Stress-Spalten.

**Autor:** Christian Möllmann ([knoellix](https://github.com/knoellix))  
**Lizenz:** [GNU GPL v3](LICENSE)  
**Version:** `0.1.0.9`  
**Repository:** [github.com/knoellix/FS25_ToDo](https://github.com/knoellix/FS25_ToDo)

## Funktionen

- **ESC-Menü** (eigener Tab): manuelle To-Dos links, Feldübersicht mit Kulturstatus und Vorschlägen rechts
- **HUD in der Welt:** `Linke Strg + F5` — kompakte Liste offener Aufgaben (oben rechts, bis zu 5 Einträge)
- **Arbeitsreihenfolge:** Presets (z. B. Pflügen → Kalken → Säen → Düngen) und **abwechselndes Mist/Gülle** für organische Mehrfachgaben
- **Feld-Workflow:** Vorschläge übernehmen, Feld besuchen (Teleport), Auto-Erledigt wenn das Spiel die Arbeit als erledigt erkennt
- **Listenreihenfolge:** `Hoch` / `Runter` Mini-Buttons (`^` / `v`) verschieben die ausgewählte Aufgabe (kein Drag-and-drop in der Giants-UI)
- **Erledigt-Verhalten:** erledigte Aufgaben unter offenen; neu erledigte oben in der Erledigt-Gruppe; max. 10 erledigte (älteste werden entfernt)
- **Auswahl-UX:** nach Verschieben bleibt die Aufgabe ausgewählt; nach Löschen wird die Auswahl entfernt
- **Planfrucht:** pro Feld manuell setzen (Spalte **Plan** / **Planfrucht**) — Säen-Vorschläge mit Frucht und Sä-Monat; **Hof** für Nicht-Acker (kein Scan)
- **Ernte-Spalte:** nur Status (Wächst, Nachwuchs, Mähen …); **Ernte-Monat** in der Vorschlags-Spalte
- **Strohballen:** pressen/einsammeln auf Getreide-Stoppeln (Auto-Erledigen typ-bewusst)
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

1. `FS25_FieldToDoList.zip` aus dem [latest release](https://github.com/knoellix/FS25_ToDo/releases/latest) laden.
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

Nach `[FS25_FieldToDoList] DUMP` suchen. Wichtig: `meadowPhase`, `grassResidue`, `baleCoverage`, `weedCoverage`, `harvestState`.

Beispiel:

```text
ftdlDump 63
```

Kein Auto-Dump beim Menü — nur manuell.

## Releases

Getaggte Versionen erzeugen `FS25_FieldToDoList.zip` über GitHub Actions. Anleitung: [`docs/RELEASE.md`](docs/RELEASE.md).

## Mitwirken

Beiträge sind willkommen (Bugfixes, Features, Übersetzungen).

- Einstieg: [`CONTRIBUTING.md`](CONTRIBUTING.md)
- Übersetzungs-Workflow: [Übersetzungs-Issue öffnen](https://github.com/knoellix/FS25_ToDo/issues/new?template=translation.yml)
- Allgemeine Bugs/Features: [GitHub Issues](https://github.com/knoellix/FS25_ToDo/issues)

## Changelog

Siehe [CHANGELOG.md](CHANGELOG.md). **0.1.0.9:** Live-Sync für Farm-To-Dos + Bearbeitungsrechte. Davor: Vanilla-Grün, farm-scoped Tasks.

## Bekannte Grenzen (LIMITATIONS)

Vollständige Regression: [`docs/REGRESSION.md`](docs/REGRESSION.md). Architektur: [`docs/FIELD_PHASE.md`](docs/FIELD_PHASE.md).

| Bereich | Was funktioniert | Was nicht / manuell |
| ------- | ---------------- | ------------------- |
| **Gras nach Mähen** | Ballen pressen/einsammeln (Auto-Erledigen über Feld-Ballen) | Lose Schwaden/Heu am Boden nicht lesbar → Schwaden/Ladewagen nur als manuelle Erinnerung |
| **Stroh nach Ernte** | Strohballen erkennen, pressen/einsammeln (Auto über STRAW-Ballen) | Loses Stroh am Boden nicht lesbar → „Stroh pressen" schließt nur bei neuen Ballen ab |
| **Mulchen** | Vorschlag nach Ernte (optional, Schalter im Menü) | Kein lesbarer „gemulcht"-Zustand → nie Auto-Erledigt |
| **Unkraut** | Striegeln/Spritzen, erledigt bei totem Unkraut (Coverage) | — |
| **Custom-Felder** | Eigene bearbeitete Grundstücke ohne Engine-Feld-ID (Pseudo-Felder) | Nur wenn Feldmitte Feld-Boden zeigt |
| **Planfrucht / Hof** | Sä-Frucht + Sä-Monat in Vorschlägen; Hof = kein Feld-Scan | Planfrucht ersetzt nicht die aktuelle Kultur-Spalte |
| **Multiplayer** | Live-Sync für Farm-To-Dos, Einstellungen und Planfrucht; Bearbeitungs-Gate (Manager immer, Arbeiter per Einstellung); Auto-Erledigen für alle Farm-Mitglieder | Vanilla-Farm-Berechtigungs-UI außerhalb des Scopes |

Debug: `ftdlDump <FeldId>` — Zeile `baleCoverage: total/straw/grass/other` für Ballen-Diagnose.

## Issues

Bitte die Issue-Templates für Bugs, Features und Übersetzungen nutzen:
[GitHub Issues](https://github.com/knoellix/FS25_ToDo/issues)

## Lizenz

Copyright (C) 2026 Christian Möllmann (knoelliX).  
Veröffentlicht unter der GNU General Public License v3 — siehe [LICENSE](LICENSE).

