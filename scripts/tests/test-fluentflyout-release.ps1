#requires -Version 7.0
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '..' 'lib' 'fluentflyout-release.ps1')

$hash = 'dddad6461b483edd1b74e4c9ec7a840551f2a72e685f93985216b9a38446b8e6'
$cases = @(
    "GitHub Release x64 | $hash",
    "|GitHub Release x64|$hash|",
    "| GitHub Release x64 | $hash |",
    "  GITHUB   RELEASE x64  |  $($hash.ToUpperInvariant())  ",
    "Version | SHA-256 hash`r`n--- | ---`r`nGitHub Release x64 | $hash",
    "## Notes`nSome other checksum: $('a' * 64)`n| GitHub Release x64 | $hash |"
)
foreach ($sample in $cases) {
    $actual = Get-FluentFlyoutPublishedSha256 -ReleaseNotes $sample
    if ($actual -cne $hash) { throw "Checksum parser returned '$actual', expected '$hash'." }
}

function Assert-Rejected {
    param([string] $Notes, [string] $Name)
    $rejected = $false
    try {
        $null = Get-FluentFlyoutPublishedSha256 -ReleaseNotes $Notes
    } catch {
        $rejected = $true
    }
    if (-not $rejected) { throw "Malformed checksum fixture was accepted: $Name" }
}

Assert-Rejected -Name 'empty notes' -Notes ''
Assert-Rejected -Name 'unrelated hash' -Notes "Download x64: $hash"
Assert-Rejected -Name 'wrong label' -Notes "GitHub Release ARM64 | $hash"
Assert-Rejected -Name 'short hash' -Notes "|GitHub Release x64|$($hash.Substring(0, 63))|"
Assert-Rejected -Name 'nonhex character' -Notes "|GitHub Release x64|$('g' + $hash.Substring(1))|"
Assert-Rejected -Name 'additional column' -Notes "|GitHub Release x64|$hash|comment|"
Assert-Rejected -Name 'duplicate rows' -Notes "GitHub Release x64|$hash`n|GitHub Release x64|$hash|"
Assert-Rejected -Name 'conflicting rows' -Notes "GitHub Release x64|$hash`n|GitHub Release x64|$('a' * 64)|"
Assert-Rejected -Name 'malformed plus valid' -Notes "GitHub Release x64|bad`nGitHub Release x64|$hash"
Assert-Rejected -Name 'checksum only in code block' -Notes "``````text`nGitHub Release x64|$hash`n``````"

$release = [pscustomobject]@{
    tag_name = 'v2.16.0'
    draft = $false
    prerelease = $false
    body = "|GitHub Release x64|$hash|"
}
$metadata = Get-FluentFlyoutReleaseMetadata -Release $release
if ($metadata.Version -cne '2.16.0' -or $metadata.Tag -cne 'v2.16.0' -or $metadata.Sha256 -cne $hash) {
    throw 'Release metadata validation produced an incorrect result.'
}

foreach ($change in @(
    @{ Property = 'tag_name'; Value = 'v2.16.0-beta.1' },
    @{ Property = 'tag_name'; Value = 'release-2.16.0' },
    @{ Property = 'draft'; Value = $true },
    @{ Property = 'prerelease'; Value = $true }
)) {
    $copy = [pscustomobject]@{
        tag_name = $release.tag_name
        draft = $release.draft
        prerelease = $release.prerelease
        body = $release.body
    }
    $copy.($change.Property) = $change.Value
    $rejected = $false
    try { $null = Get-FluentFlyoutReleaseMetadata -Release $copy } catch { $rejected = $true }
    if (-not $rejected) { throw "Malformed release metadata was accepted: $($change.Property)=$($change.Value)" }
}
Write-Host 'FluentFlyout release parser: all offline regression cases passed.'
