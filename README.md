# FluentFlyout for `th-winkler/MyScoop`

Source: **Official FluentFlyout GitHub (fully featured) edition**, not the Microsoft Store release.

## Copy these files into `https://github.com/th-winkler/MyScoop`

```
bucket/fluentflyout.json
scripts/update-fluentflyout.ps1
.github/workflows/update-fluentflyout.yml
```

The provided manifest starts at **2.16.0** (published October 17, 2026). Its
SHA-256 comes from the official GitHub release notes. The release's ZIP is
served by `files.fluentflyout.com`, NOT as a GitHub release asset.

## Install from Scoop / UniGetUI

1. Add the bucket in a **normal (not elevated) PowerShell session**:
   ```powershell
   scoop bucket add MyScoop https://github.com/th-winkler/MyScoop
   scoop update
   scoop install MyScoop/fluentflyout
   ```
2. On first installation, the official `Add-AppDevPackage.ps1` may request
   administrator privileges to import the self-signed developer certificate.
   Inspect and consent only if you trust its identity. **Trusted Root** trust
   is broad; never suppress the prompt automatically.
3. In UniGetUI, refresh package sources, choose **Scoop / MyScoop**, then
   find `fluentflyout`. Future upgrades can run through UniGetUI or:
   ```powershell
   scoop update
   scoop update fluentflyout
   ```

The script directly calls `Add-AppxPackage` when the bundled signing certificate
is already trusted. Otherwise, it falls back to the developer's official
interactive MSIX setup, which handles certificate requirements and dependencies.
This requires the upstream archive layout (`SystemFiles/`).

**UniGetUI does not convert an existing `WinGet: msstore` entry into a Scoop
installation.** You must install the new `MyScoop/fluentflyout` entry. Avoid
mixing Store updates with the GitHub edition.

## Automated bucket updates

The GitHub Actions workflow runs daily and can also be triggered via
**Actions > Update FluentFlyout Scoop manifest > Run workflow**.

It reads the latest stable tag and developer-published SHA-256 from the official
GitHub release notes; constructs the exact matching installer ZIP URL on the
official file host; downloads the ZIP; verifies the hash; verifies it includes
one `.msixbundle`, one `.cer`, and `Add-AppDevPackage.ps1` under `SystemFiles`;
then commits the updated manifest. It NEVER executes upstream content on the
GitHub Actions runner. If any check fails, it stops without committing.

Requirements: GitHub Actions must be enabled for your repository and the
repository's **Settings > Actions > General > Workflow permissions** must
permit GitHub Actions to write repository contents. Protected branches may
require changing the workflow to create a pull request instead of pushing.

## Caveats and manual checks

- This package is an MSIX registration. Scoop tracks the install version, while
  Windows installs and manages the actual app. It is not a portable app.
- The self-signed signing certificate may change between releases. If it does,
  an interactive UAC/certificate approval may be required on upgrades.
- Back up FluentFlyout preferences before uninstalling or switching channels.
  Developer and Store editions may use compatible package identities.
- Only x64 installer artifacts are provided here. Windows ARM64 may run this
  edition via x64 emulation as indicated by the upstream release instructions.
- If the developer changes archive structure or checksum formatting, the
  workflow intentionally stops. Review upstream changes rather than guessing.
- This package is statically validated but **not tested on a Windows client**,
  and the downloadable archive could not be independently fetched here.
