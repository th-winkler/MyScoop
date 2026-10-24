# MyScoop hardening patch — 2026-10-24

This is a **targeted overlay** intended for the MyScoop repository state created from
`MyScoop-Architecture-Spicetify-2026-10-24.zip`. It does not contain a full repository.
Review each changed file before merging; do not blindly overwrite independently
updated scripts or workflows.

## Root cause of the Juxtopposed VLC failure

The original updater did:

```powershell
$releases = @(Invoke-RestMethod 'https://api.github.com/repos/dsojevic/juxtopposed-vlc/releases?per_page=30')
```

PowerShell's `Invoke-RestMethod` emits a top-level JSON array as a **single pipeline object**.
Wrapping that object in `@(...)` can create a nested array. Iterating the outer array
then passes the entire list to each tag parser, causing zero matches and the
misleading `No supported ... release tag` error. Microsoft's `Invoke-RestMethod`
documentation explicitly covers this behavior.

The replacement assigns the response directly, checks that it is an array of release
objects, logs all observed tags, and selects the highest canonical version (e.g.
`4.0.0-beta.5`). Unknown versions fail loudly; `beta-3` is not silently converted
into a guessed semantic version.

## Scope

- `scripts/update-juxtopposed-vlc.ps1`: correct response type, JSON shape checks,
  explicit tags, digest/checksum/ZIP verification, `-DryRun`, staged atomic replace,
  rollback file on post-write failure, GitHub Step Summary.
- `scripts/lib/juxtopposed-release.ps1`: pure parsing/selection helpers.
- `scripts/tests/test-juxtopposed-release.ps1`: offline regression tests, including
  the nested array that produced this failure.
- `scripts/update-spicetify.ps1`: add strict mode, dry-run, atomic update, clearer
  network errors; rename `$matches` variable (case-insensitive shadowing of the
  PowerShell automatic `$Matches` variable) and avoid relying on captures.
- `scripts/update-imhex.ps1`: add strict mode, dry-run, atomic update, clearer
  network errors, avoid reliance on the `$Matches` automatic variable.
- `scripts/validate-bucket.ps1`: strict mode, bucket directory existence check,
  recursive syntax validation for helpers/tests.
- All five Actions workflows: pin checkout/upload-artifact to specific tested
  release tags, preflight/postflight validation, exact changed-path guard, serialized
  writes, transcripts on update failures, failure artifacts and step summaries.
  Spicetify's update workflow now runs on Windows and smoke-tests the executable
  before committing an updated manifest.

**Not included:** the existing `scripts/update-fluentflyout.ps1`, because its full
source is not included in the previous generated overlay available in this chat.
The FluentFlyout workflow has improved safety rails, but its updater's internal
idempotency/dry-run implementation requires a separate review against the actual
file in the repository. This patch does not claim otherwise.

## Apply safely on your Windows workstation (PowerShell 7)

1. Clone or update your repository and create a review branch:

```powershell
git clone https://github.com/th-winkler/MyScoop.git
Set-Location MyScoop
git switch -c fix/ci-release-array-and-guards
```

2. Extract `MyScoop-hardening-v2.zip` somewhere outside the cloned repository and
   copy only its changed paths into the clone:

```powershell
$stage = Join-Path $env:TEMP 'MyScoop-hardening-v2'
Expand-Archive "$env:USERPROFILE\Downloads\MyScoop-hardening-v2.zip" -DestinationPath $stage -Force
robocopy "$stage\MyScoop-hardening-v2" (Get-Location).Path /E /R:1 /W:1
if ($LASTEXITCODE -ge 8) { throw 'Overlay copy failed.' }
```

3. Inspect and run offline checks before any network/download work:

```powershell
git diff --check
git status --short
pwsh -NoProfile -File ./scripts/tests/test-juxtopposed-release.ps1
pwsh -NoProfile -File ./scripts/validate-bucket.ps1
```

4. Exercise Juxtopposed updater without writing any file. Note that this does
   download and verify the full Windows ZIP when a new release is available:

```powershell
pwsh -NoProfile -File ./scripts/update-juxtopposed-vlc.ps1 -DryRun
```

Then review `git diff` and submit a pull request. GitHub's push/PR validation
will run the offline regression tests and the pinned Spicetify Windows smoke test.

## Deployment / operations

- Update jobs run only on `refs/heads/main` and are serialized with
  `myscoop-manifest-writes` (`cancel-in-progress: false`).
- A mutation succeeds only after official digests, checksum files (where provided),
  and required archive members agree; failed runs do not commit any change.
- The commit step refuses to stage any changed file other than the specific
  target manifest. This prevents accidental cross-manifest commits.
- Logs are kept as 14-day failure artifacts. Checksums, versions, and URLs are
  emitted in the update log/step summary.
- `GITHUB_TOKEN` bot commits do not initiate normal push validation workflows;
  pre-commit validation is deliberately included in each update job. Windows
  Spicetify smoke testing is also performed in its updater workflow.
- Branch protection that forbids bot pushes will cause `git push` to fail. If
  using protected main, replace direct pushes with a pull-request creation flow.
- Update workflows **do not install Spotify, Marketplace, or applications on your PC**.
  UniGetUI/Scoop consumes published bucket manifests separately.

## Evidence and verification status

- Checked published Juxtopposed VLC release `4.0.0-beta.5` and its tag/asset name
  on GitHub, October 24, 2026.
- Confirmed `Invoke-RestMethod` JSON-array pipeline semantics in Microsoft docs.
- YAML and patch layout validated with Python locally; PowerShell 7 is **not**
  installed in this execution environment. Offline PowerShell regression tests,
  GitHub Actions jobs, release ZIP validation and actual Scoop installation
  therefore still require execution on your workstation / GitHub runner.
