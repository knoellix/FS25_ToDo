# Contributing to FS25_FieldToDoList

Thanks for helping improve this mod.

This project follows the [Code of Conduct](CODE_OF_CONDUCT.md). Security-sensitive reports belong in [SECURITY.md](SECURITY.md), not public issues.

## Quick Start

- Fork the repository and create a feature branch.
- Keep changes focused (one topic per PR if possible).
- Build locally before opening a PR:

```bash
python3 tools/generate_assets.py
./build.sh
```

- Restart FS25 completely after updating the mod ZIP.

## Git identity (optional)

For commits that match CI release builds, you may use:

```fish
git config user.email "knoellix@noreply.codeberg.org"
git config user.name "knoellix"
```

## Shell and copy-paste commands

Examples in this repo (README, release notes, agent hints) often use **bash** syntax. Adapt them to your shell.

| Shell | Note |
| ----- | ---- |
| **fish** (maintainer) | No bash heredocs — `git commit -m "$(cat <<'EOF' …)"` fails. Use `git commit -m "one line"` or a multi-line fish string instead. |
| bash / zsh | Heredocs and `$(cat <<'EOF' …)` work as written in many guides. |
| PowerShell | Use your own quoting; heredocs differ. |

Build/install paths and `git` workflows are the same; only quoting and redirection differ.

## Preferred Workflow

- Use [Codeberg Issues](https://codeberg.org/knoellix/FS25_FieldToDoList/issues) to discuss bugs or features first when scope is unclear.
- Use clear PR titles and explain the "why", not only the "what".
- Include reproduction steps (for bug fixes) or expected behavior (for features).
- If UI changes are involved, add screenshots when possible.

## Code and Project Rules

- Do not bump `modDesc.xml` version unless this is an explicit release step.
- Keep savegame safety in mind:
  - Avoid risky runtime reads from savegame files.
  - Keep startup/runtime behavior stable (no heavy loops in menu/update paths).
- Keep logs clean and user-focused.
- Prefer small, reviewable changes over broad refactors.

## Testing Checklist (Before PR)

- Mod builds without errors.
- ESC menu opens and field overview updates.
- HUD toggle works (`Left Ctrl + F5`).
- To-do actions still work (add/edit/done/delete/move).
- Save/load flow still works in a real savegame.
- Optional mod paths still degrade gracefully (PF/SCS on/off).

## Translation Contributions

Translations are very welcome.

- Open a translation issue using the template:
  - [New translation issue](https://codeberg.org/knoellix/FS25_FieldToDoList/issues/new?template=translation.yml)
- Copy `translations/translation_en.xml` to `translations/translation_<locale>.xml`.
- Keep all `text name="..."` keys present (no missing keys).
- Keep short UI labels compact (buttons, columns, HUD).
- Escape XML entities properly (`&` -> `&amp;` in attributes).
- Optional: add matching `<title>` / `<description>` blocks in `modDesc.xml`.

### Translation PR checklist

- State target language and locale (for example `es`, `fr`, `pl`).
- Mention which mod version you translated.
- Note whether translation is full or partial.
- Mention any wording that needs maintainer review.

## Need Help?

- Open a Codeberg issue and describe what blocks you.
- If you already have a fix, open a PR and link the related issue.
