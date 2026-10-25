#requires -Version 7.0
<#
Refresh Spicetify CLI from the latest non-prerelease official GitHub release.
Requires a published SHA-256 digest for every Windows architecture; downloads
and verifies every archive before atomically updating the Scoop manifest.
No code from the downloaded packages is executed.
#>
[CmdletBinding()]
param(
    [string]$ManifestPath = (Join-Path $PSScriptRoot '..' 'bucket' 'spicetify-cli.json'),
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ProgressPreference = 'SilentlyContinue'
$apiUrl = 'https://api.github.com/repos/spicetify/cli/releases/latest'

$headers = @{
    'Accept'               = 'application/vnd.github+json'
    'User-Agent'            = 'MyScoop-Spicetify-Updater'
    'X-GitHub-Api-Version'  = '2022-11-28'
}

if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_TOKEN)) {
    $headers['Authorization'] = "Bearer $env:GITHUB_TOKEN"
}

$ManifestPath = [IO.Path]::GetFullPath($ManifestPath)
if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) { throw "Manifest not found: $ManifestPath" }

try {
    $release = Invoke-RestMethod -Uri $apiUrl -Headers $headers -TimeoutSec 60 -ErrorAction Stop
} catch {
    throw "GitHub stable release API failed: $($_.Exception.Message)"
}
if ($release.draft -or $release.prerelease -or [string]$release.tag_name -notmatch '^v\d+(?:\.\d+){2,3}$') {
    throw "Unexpected stable Spicetify release tag: $($release.tag_name)"
}
$version = ([string]$release.tag_name).Substring(1)
$manifest = Get-Content -LiteralPath $ManifestPath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
if ([version]$version -lt [version]$manifest.version) {
    throw "Refusing Spicetify downgrade $($manifest.version) -> $version"
}
$targets = [ordered]@{ '64bit' = 'x64'; '32bit' = 'x32'; 'arm64' = 'arm64' }
$tempFiles = [Collections.Generic.List[string]]::new()
try {
    foreach ($arch in $targets.Keys) {
        $suffix = $targets[$arch]
        $name = "spicetify-$version-windows-$suffix.zip"
        $matchingAssets = @($release.assets | Where-Object { $_.name -ceq $name -and $_.state -eq 'uploaded' })
        if ($matchingAssets.Count -ne 1) { throw "Expected exactly one published release asset $name" }
        $asset = $matchingAssets[0]
        if ([string]$asset.digest -notmatch '^sha256:[a-fA-F0-9]{64}$') {
            throw "Missing published GitHub SHA-256 digest: $name"
        }
        $expected = ([string]$asset.digest).Substring(7).ToLowerInvariant()
        $url = "https://github.com/spicetify/cli/releases/download/v$version/$name"
        if ([string]$asset.browser_download_url -cne $url) { throw "Unexpected release asset URL: $($asset.browser_download_url)" }
        if ([string]$manifest.version -eq $version) {
            if ([string]$manifest.architecture[$arch].hash -cne $expected -or
                [string]$manifest.architecture[$arch].url -cne $url) {
                throw "Existing Spicetify $version $arch URL/hash differs from current official release; manual review required."
            }
        } else {
            $temp = Join-Path ([IO.Path]::GetTempPath()) ("myscoop-spicetify-" + [guid]::NewGuid().ToString('N') + '.zip')
            $tempFiles.Add($temp)
            Write-Host "Downloading and validating $name"
            try {
                Invoke-WebRequest -Uri $url -OutFile $temp -TimeoutSec 600
            } catch {
                throw "Download failed for $name ($url): $($_.Exception.Message)"
            }
            $actual = (Get-FileHash -LiteralPath $temp -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($actual -cne $expected) { throw "SHA-256 mismatch for $name" }
            Add-Type -AssemblyName System.IO.Compression
            $zip = [IO.Compression.ZipFile]::OpenRead($temp)
            try {
                $names = @($zip.Entries | ForEach-Object { $_.FullName.Replace('\', '/') })
                foreach ($required in @('spicetify.exe', 'css-map.json', 'jsHelper/spicetifyWrapper.js')) {
                    if ($required -cnotin $names) { throw "Required Spicetify package member missing ($name): $required" }
                }
            } finally { $zip.Dispose() }
            $manifest.architecture[$arch].url = $url
            $manifest.architecture[$arch].hash = $expected
        }
        Write-Host "Verified $name $expected"
    }
    if ([string]$manifest.version -eq $version) { Write-Host "Spicetify $version is current."; return }
    $manifest.version = $version
    if ($DryRun) {
        Write-Host "DRY RUN: would change $ManifestPath to $version; checksums and ZIP members verified; no files changed."
        return
    }
    $nonce = [guid]::NewGuid().ToString('N')
    $staging = "$ManifestPath.$nonce.tmp"
    $rollback = "$ManifestPath.$nonce.rollback"
    try {
        $json = ($manifest | ConvertTo-Json -Depth 40) + "`n"
        [IO.File]::WriteAllText($staging, $json, [Text.UTF8Encoding]::new($false))
        $candidate = Get-Content -LiteralPath $staging -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable -Depth 40
        if ($candidate.version -cne $version) { throw 'Candidate version mismatch.' }
        [IO.File]::Replace($staging, $ManifestPath, $rollback, $true)
        $committed = Get-Content -LiteralPath $ManifestPath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable -Depth 40
        if ($committed.version -cne $version) { throw "Post-write validation failed. Rollback retained: $rollback" }
        Remove-Item -LiteralPath $rollback -Force
    } finally {
        Remove-Item -LiteralPath $staging -Force -ErrorAction SilentlyContinue
    }
    Write-Host "Updated Spicetify CLI manifest -> $version"
} finally {
    foreach ($temp in $tempFiles) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
}
