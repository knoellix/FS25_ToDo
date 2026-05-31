# Security Policy

## Supported versions

Security fixes are provided for the **latest release** on the default branch (`main`).

| Version   | Supported |
| --------- | --------- |
| Latest    | Yes       |
| Older tags| No        |

Pre-release builds between tags are supported only on `main` until the next release.

## Reporting a vulnerability

**Please do not open a public issue** for security-sensitive reports (savegame corruption, data loss, malicious behavior, credential leaks in tooling).

Preferred channels:

1. **[GitHub private security advisory](https://github.com/knoellix/FS25_FieldToDoList/security/advisories/new)** (recommended)
2. Contact the maintainer via **[GitHub profile](https://github.com/knoellix)** (private message)

Include when possible:

- Affected mod version / git tag
- FS25 game version and platform (Windows, macOS, Linux)
- Steps to reproduce
- Impact (e.g. savegame damaged, unintended file writes, crash)
- Relevant `log.txt` excerpts (redact personal paths if needed)

You should receive an acknowledgment within a reasonable time. Fixes may ship as a patch release depending on severity.

## In scope

- Crashes or hangs caused by this mod
- **Savegame or user-file corruption** (including risky read/write of save data)
- Unauthorized or unexpected filesystem access from mod scripts
- Supply-chain issues in release/build workflow (`.github/workflows`, release assets)

## Out of scope

- Bugs in Giants Engine / base game (report to GIANTS)
- Conflicts with other mods without evidence this mod is the root cause
- Gameplay balance or field-advisor suggestion accuracy (use normal [bug reports](https://github.com/knoellix/FS25_FieldToDoList/issues/new?template=bug_report.yml))
- Issues in unsupported old releases when a fix exists in a newer release

## Project safety notes

This mod intentionally **does not read `fields.xml` at runtime** (avoids file conflicts while the game owns the save). If you find code paths that bypass that policy, please report them.
