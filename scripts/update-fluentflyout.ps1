#requires -Version 7.0
<#
.SYNOPSIS
    Update the MyScoop FluentFlyout manifest from the upstream stable GitHub release.
.DESCRIPTION
    Fetches the GitHub release tag and the developer-published x64 SHA-256,
    downloads the matching archive from the official file host, and requires
    both SHA-256 values to match before writing the manifest.
    Does not execute any downloaded content.
#>
[CmdletBinding()]
param(
    [string] $ManifestPath = (Join-Path $PSScriptRoot '..' 'bucket' 'fluentflyout.json')
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$apiUrl = 'https://api.github.com/repos/unchihugo/FluentFlyout/releases/latest'
$headers = @{
    'Accept' = 'application/vnd.github+json'
    'User-Agent' = 'MyScoop-FluentFlyout-Updater'
    'X-GitHub-Api-Version' = '2022-11-28'
}

$release = Invoke-RestMethod -Uri $apiUrl -Headers $headers -TimeoutSec 45
$tag = [string] $release.tag_name
if ($tag -cmatch '^v(?<version>\d+(?:\.\d+){1,3})$') {
    $version = $Matches.version
} else {
    throw "Unexpected GitHub release tag: $tag"
}

# Do not accept an arbitrary checksum somewhere else in the release notes.
$checksumMatches = [regex]::Matches(
    [string] $release.body,
    '(?im)^\s*GitHub Release x64\s*\|\s*([a-f0-9]{64})\s*$'
)
if ($checksumMatches.Count -ne 1) {
    throw "Expected one published 'GitHub Release x64' SHA-256 in release notes for $tag; found $($checksumMatches.Count)."
}
$publishedSha256 = $checksumMatches[0].Groups[1].Value.ToLowerInvariant()

$archiveName = "FluentFlyout_${version}_x64_Installer.zip"
$downloadUrl = "https://files.fluentflyout.com/$archiveName"
$ManifestPath = [System.IO.Path]::GetFullPath($ManifestPath)
$manifest = Get-Content -LiteralPath $ManifestPath -Raw -Encoding utf8 | ConvertFrom-Json
if ([version] $version -lt [version] $manifest.version) {
    throw "Refusing to downgrade manifest from $($manifest.version) to $version."
}

if ([string] $manifest.version -eq $version) {
    if ($manifest.url -ne $downloadUrl -or $manifest.hash -ne $publishedSha256) {
        throw 'Existing version has different URL/hash; review upstream release before modifying the manifest.'
    }
    $changelogNote = "Official release notes: https://github.com/unchihugo/FluentFlyout/releases/tag/$tag"
    $existingNotes = @($manifest.notes)
    if ($changelogNote -notin $existingNotes) {
        $otherNotes = @($existingNotes | Where-Object {
            $_ -notmatch '^Official release notes: https://github\.com/unchihugo/FluentFlyout/releases/tag/'
        })
        $manifest.notes = @($changelogNote) + $otherNotes
        $json = $manifest | ConvertTo-Json -Depth 30
        [System.IO.File]::WriteAllText($ManifestPath, "$json`n", [System.Text.UTF8Encoding]::new($false))
        Write-Host "Added upstream changelog link for $tag."
    }
    Write-Host "FluentFlyout $version is already current. No download needed."
    return
}

# Validate the complete artifact, not only the GitHub release-note text.
$tempFile = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N') + '.zip')
try {
    Write-Host "Downloading $downloadUrl"
    Invoke-WebRequest -Uri $downloadUrl -OutFile $tempFile -TimeoutSec 600 -MaximumRedirection 5
    $actualSha256 = (Get-FileHash -LiteralPath $tempFile -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualSha256 -ne $publishedSha256) {
        throw "SHA-256 mismatch: expected $publishedSha256; downloaded $actualSha256. Manifest NOT changed."
    }
    # Ensure the expected installation components exist in the archive.
    Add-Type -AssemblyName System.IO.Compression
    $archive = [System.IO.Compression.ZipFile]::OpenRead($tempFile)
    try {
        $names = @($archive.Entries | ForEach-Object { $_.FullName.Replace('\', '/') })
        foreach ($pattern in @('^SystemFiles/[^/]+\.msixbundle$', '^SystemFiles/[^/]+\.cer$', '^SystemFiles/Add-AppDevPackage\.ps1$')) {
            if (@($names | Where-Object { $_ -match $pattern }).Count -ne 1) {
                throw "Archive $archiveName does not contain exactly one expected entry matching $pattern."
            }
        }
    } finally {
        $archive.Dispose()
    }

    # Keep a direct link to the actual upstream changelog, not installer instructions.
    $changelogNote = "Official release notes: https://github.com/unchihugo/FluentFlyout/releases/tag/$tag"
    if ($null -eq $manifest.notes) {
        $manifest | Add-Member -NotePropertyName notes -NotePropertyValue @($changelogNote)
    } else {
        $otherNotes = @($manifest.notes | Where-Object {
            $_ -notmatch '^Official release notes: https://github\.com/unchihugo/FluentFlyout/releases/tag/'
        })
        $manifest.notes = @($changelogNote) + $otherNotes
    }

    $manifest.version = $version
    $manifest.url = $downloadUrl
    $manifest.hash = $publishedSha256
    $json = $manifest | ConvertTo-Json -Depth 30
    [System.IO.File]::WriteAllText($ManifestPath, "$json`n", [System.Text.UTF8Encoding]::new($false))
    Write-Host "Updated FluentFlyout manifest to $version ($publishedSha256)"
} finally {
    Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
}
