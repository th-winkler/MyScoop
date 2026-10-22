# FluentFlyout metadata and changelog patch

Merge the included `scripts/` and `.github/` folders into your existing MyScoop checkout.
This patch deliberately DOES NOT include or overwrite `bucket/fluentflyout.json`, because
you have already edited that manifest.

Run `pwsh -NoProfile -File ./scripts/update-fluentflyout.ps1` from the repository root.
It preserves your existing manifest fields and adds a version-specific upstream release
notes URL to the `notes` array. Future verified version updates refresh the link.
It does not copy arbitrary release text into a Scoop manifest, nor does it alter the
published hash verification and ZIP checks.

The workflow remains scheduled daily, commits only the manifest, and can also be
run manually in GitHub Actions. Review the resulting diff before pushing.

## UniGetUI metadata

Scoop's standard manifest has no reliable `publisher`, `author`, `icon`,
`screenshots`, or display-name fields for UniGetUI. Do not invent JSON keys.
The correct upstream attribution is `unchihugo` (project maintainer); for
the publisher, inspect the actual MSIX AppxManifest.xml Identity Publisher and
the signing certificate rather than guessing.

Use the package details' **Become a contributor** link to follow UniGetUI's
current public metadata contribution process. Supply package manager Scoop,
source MyScoop, package ID `fluentflyout`, preferred display name `FluentFlyout`,
the official homepage, and approved upstream icon/screenshots.

If you have the original MSIX bundle, extract its assets or use an official
upstream icon. An EXE icon is an option only if its provenance is confirmed.
The original icon file is NOT included in this patch because no original
binary or licensed icon was provided.

A refresh of UniGetUI's metadata/media cache or restart may be required
after upstream metadata changes propagate. This patch alone does not make
UniGetUI display new artwork or author/publisher fields.
