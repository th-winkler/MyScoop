# MyScoop

Personal Scoop bucket with automated, integrity-checked manifest updates.

## Add and use this bucket

```powershell
scoop bucket add myscoop https://github.com/th-winkler/MyScoop
scoop update
scoop install myscoop/spicetify-cli
spicetify -v
```

Spicetify CLI is **not** Spotify or Marketplace. Install Spotify separately, sign in and let Spotify create its preferences before running Spicetify. Install the official Marketplace separately after patching Spicetify. Changes to Spotify require reapplying the CLI (`spicetify restore backup apply`). The Scoop bucket should not edit Spotify's installation or run remote installation scripts in package hooks.

If Spicetify CLI is already installed from `main` rather than this bucket, preserve your Spicetify configuration, then run `scoop uninstall spicetify-cli` and `scoop install myscoop/spicetify-cli`. Scoop resolves versions from the installed application's **owning bucket**, not whichever manifest is newest on GitHub.

## Manifests

| App | Distribution | Update source |
| --- | --- | --- |
| FluentFlyout | Verified upstream MSIX installer ZIP | Stable GitHub release with published release-note checksum |
| ImHex | Official Windows portable ZIPs (x64, ARM64) | Latest stable release; published asset SHA-256 digests |
| Juxtopposed VLC | Official experimental Windows portable ZIP | Latest published beta (including prereleases); release digest and `SHA256SUMS.txt` |
| Spicetify CLI | Official Windows ZIPs (x64, x86, ARM64) | Latest stable GitHub release; published asset SHA-256 digests |

## Automation

Each app has a scheduled and manually dispatchable workflow in `.github/workflows/`, staggered across 07:17–08:47 UTC. Failures are isolated per application, and workflows serialize Git writes using the same concurrency group. Every updater checks all manifests before and after its update; each only commits its own JSON file.

`bin/checkver.ps1` now resolves the repository root correctly (`../bucket`) rather than looking for a nonexistent `bin/bucket` directory.

`.github/workflows/validate.yml` runs read-only JSON/schema checks and PowerShell syntax checks on pushes and pull requests. A Windows runner also downloads the pinned Spicetify x64 ZIP, verifies its SHA-256, checks the wrapper/CSS map, and runs `spicetify.exe -v`. Auto-commits using `GITHUB_TOKEN` do not trigger `push` workflows on GitHub; this is why update workflows run their own validation before committing.

For local dry inspection from the repository root:

```powershell
pwsh -NoProfile -File ./scripts/validate-bucket.ps1
```

To run an update script manually from a clean local clone:

```powershell
pwsh -NoProfile -File ./scripts/update-spicetify.ps1
pwsh -NoProfile -File ./scripts/update-imhex.ps1
pwsh -NoProfile -File ./scripts/update-juxtopposed-vlc.ps1
pwsh -NoProfile -File ./scripts/update-fluentflyout.ps1
```

These scripts **modify manifests only** after validating upstream artifacts; they never install or execute the downloaded application.

## Permissions and limitations

Automated pushes require repository Actions to allow write permissions to contents and for the branch to permit bot pushes. Workflows request `contents: write` explicitly. Branch protection may require switching from direct commits to pull requests.

UniGetUI consumes Scoop's installed applications and bucket metadata; it does **not** schedule or fix upstream GitHub Actions. Refresh the bucket with `scoop update` to receive newly committed versions before running upgrades in Scoop or UniGetUI.

FluentFlyout's installer can prompt to trust a developer certificate; review the certificate carefully. These workflows validate archives but do not execute a live Windows installation test. Juxtopposed VLC is experimental, not a stable VLC replacement.
