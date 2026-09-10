# Releases and CI on GitHub

This project publishes mod ZIPs from version tags. The workflow lives in [`.github/workflows/release.yml`](../.github/workflows/release.yml).

## How release CI works

1. Push a tag matching `modDesc.xml` (e.g. tag `v0.1.0.6` ↔ `<version>0.1.0.6</version>`).
2. GitHub Actions runs on `ubuntu-latest`.
3. The job builds `.build/FS25_FieldToDoList.zip`, creates a GitHub Release, and uploads the ZIP.

No extra runner setup is required. Ensure **Actions** is enabled for the repository (Settings → Actions → General → Allow all actions).

## Automated release

```bash
# after bumping modDesc.xml + CHANGELOG.md and committing on main:
git tag v0.1.0.8
git push origin v0.1.0.8
```

Then open the **Actions** tab and confirm the “Release Mod” workflow succeeded. The ZIP appears under **Releases**.

## Manual release (fallback)

If CI is unavailable:

```bash
python3 tools/generate_assets.py
SKIP_INSTALL=1 ./build.sh
```

On GitHub: **Releases → Draft a new release** → choose the tag → upload `.build/FS25_FieldToDoList.zip`.

## Maintainer checklist before tagging

- [ ] `modDesc.xml` version equals the tag (without `v` prefix).
- [ ] `CHANGELOG.md` has a section for this version.
- [ ] `python3 tools/generate_assets.py && ./build.sh` succeeds locally.
- [ ] `lua tests/run.lua` passes (if Lua is installed).
- [ ] Full FS25 restart after installing the new ZIP for in-game checks.

## Repository

- **GitHub:** https://github.com/knoellix/FS25_ToDo
- **Mod package name** (inside the ZIP / game): `FS25_FieldToDoList`
