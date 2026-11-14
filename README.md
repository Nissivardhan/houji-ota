# houji-ota

Update feed for unofficial PixelOS builds for the Xiaomi 14 (houji).
The Updater in these builds reads `API/updater/houji.json`; the zips are hosted on SourceForge.

| Path | What it is |
|---|---|
| `API/updater/houji.json` | Feed the phone's Updater checks (full zip + incremental) |
| `API/updater/changelogs/houji.md` | Changelog shown in the Updater for the current build |
| `API/updater/changelogs/houji-history.md` | Changelogs of older builds |
| `CHANGELOG.md` | Device changelog, newest first |
| `scripts/` | Release tools (below) |

## Scripts

All scripts run on the Mac and reach the build server over SSH. Credentials are read
from `~/custom-rom/.env` and are never printed:

```
SERVER_HOST=  SERVER_PORT=  SERVER_USER=  SERVER_PASS=   # build server
SF_USER=  SF_PASS=                                       # SourceForge (houji-builds)
```

Requirements: `bash`, `expect`, `python3`, `curl`, `gh` (logged in as the repo owner),
and the release keys in `~/custom-rom/keys`.

### release.sh: publish a build as an OTA

Run after `mka bacon` has finished on the build server:

```bash
bash scripts/release.sh notes.md [serverhive-link]
```

- `notes.md`: changelog for this build, starting with `## PixelOS 17.0 · <date>`
- `serverhive-link` (optional): the Download link from ServerHive Bot's
  "Build Completed" message (`https://artifacts.serverhive.in/?id=...`), or set
  `SERVERHIVE_URL`. Used only for the Telegram Download button.

Steps:

1. Copies the release keys to the server (removed again when the script ends, even on errors).
2. Reads the build version and checks the zip is signed with the release key.
3. On the server: names the full zip, builds the incremental from the build currently
   in the feed, zips the target files, writes the feed entries.
4. Uploads the full zip, incremental and target files to SourceForge and checks the links.
5. Moves the current changelog into `houji-history.md`, puts `notes.md` in its place,
   updates `houji.json`, and asks `[y/N]` before pushing to GitHub.
6. Writes the Channel Help button layout to `posts/<build>-buttons.txt`
   (Download = ServerHive link if given, else SourceForge).

The feed always points at SourceForge: the Updater needs a direct file link.

### pixelos_feed.py: feed entries

```bash
python3 scripts/pixelos_feed.py generate-ota <ota.zip> --url <download-url> --version 17.0 [--output entry.json]
python3 scripts/pixelos_feed.py validate-ota entry.json [--artifact <ota.zip>]
```

`generate-ota` reads the zip's size, SHA256, patch level and `ota_property_files`
and writes one Updater entry. `validate-ota` checks a generated entry (and, with
`--artifact`, that it matches the zip). It doesn't know the `incremental` field, so
run it on single entries, not on the merged `houji.json`.

### upload-sf-file.sh: server → SourceForge

```bash
bash scripts/upload-sf-file.sh <file in ~ on the server> <SourceForge folder>
# e.g.
bash scripts/upload-sf-file.sh PixelOS_houji-17.0-20261110-2013.zip PixelOS
bash scripts/upload-sf-file.sh incremental_houji_A_to_B.zip PixelOS/incremental
bash scripts/upload-sf-file.sh houji-target_files-20261110-2013.zip target_files
```

Prints `SF_UPLOAD_OK` on success. New SourceForge files can take 5–10 minutes before
the download link works.
