#requires -Version 7.0
<#
Update only bucket/juxtopposed-vlc.json from published upstream release assets.
- JSON array API response must be validated as an array, not wrapped with @(IRM).
- Downloads and verifies asset digests, upstream SHA256SUMS and ZIP members.
- A dry run exercises the same validation but never writes a manifest.
- Fail closed on missing/changed metadata; no downgrades or silent repairs.
#>
[CmdletBinding()]
param(
    [string]$ManifestPath = (Join-Path $PSScriptRoot '..' 'bucket' 'juxtopposed-vlc.json'),
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ProgressPreference = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'lib' 'juxtopposed-release.ps1')

function Write-UpdateSummary([string]$status, [string]$tag, [string]$url, [string]$hash) {
    Write-Host "Juxtopposed VLC: $status; tag=$tag; URL=$url; SHA256=$hash"
    if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_STEP_SUMMARY)) {
        Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value @(
            '### Juxtopposed VLC',
            "- Result: $status",
            "- Release: ``$tag``",
            "- URL: $url",
            "- SHA-256: ``$hash``"
        )
    }
}

$ManifestPath = [IO.Path]::GetFullPath($ManifestPath)
if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
    throw "Manifest not found: $ManifestPath"
}
$manifest = Get-Content -LiteralPath $ManifestPath -Raw -Encoding utf8 |
    ConvertFrom-Json -AsHashtable -Depth 30
foreach ($key in @('version', 'architecture')) {
    if (-not $manifest.ContainsKey($key)) { throw "Manifest missing $key" }
}
if (-not $manifest.architecture.ContainsKey('64bit')) {
    throw 'Manifest missing 64bit architecture'
}
foreach ($key in @('url','hash')) {
    if (-not $manifest.architecture['64bit'].ContainsKey($key)) { throw "Manifest 64bit missing $key" }
}
$current = ConvertTo-JuxtopposedReleaseVersion -Tag ([string]$manifest.version)
if ($null -eq $current) { throw "Unsupported current VLC version: $($manifest.version)" }

$apiUrl = 'https://api.github.com/repos/dsojevic/juxtopposed-vlc/releases?per_page=30'

$headers = @{
    'Accept'               = 'application/vnd.github+json'
    'User-Agent'            = 'MyScoop-Juxtopposed-VLC-Updater'
    'X-GitHub-Api-Version'  = '2022-11-28'
}

if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_TOKEN)) {
    $headers['Authorization'] = "Bearer $env:GITHUB_TOKEN"
}

try {
    $payload = Invoke-RestMethod -Uri $apiUrl -Headers $headers -TimeoutSec 60 -ErrorAction Stop
} catch {
    throw "GitHub releases API request failed ($apiUrl): $($_.Exception.Message)"
}
# IMPORTANT: Invoke-RestMethod returns a top-level JSON array as one pipeline
# object. Do not use @(Invoke-RestMethod ...), which can nest the array.
$releases = Assert-JuxtopposedReleaseArray -Payload $payload
Write-Host "GitHub returned $($releases.Length) release(s): $(($releases | ForEach-Object { $_.tag_name }) -join ', ')"
$latest = Select-JuxtopposedPublishedRelease -Releases $releases
if ((Compare-JuxtopposedVersions -Left $latest -Right $current) -lt 0) {
    throw "Upstream response would downgrade VLC $($manifest.version) -> $($latest.Tag). Review API freshness."
}

$tag = [string]$latest.Tag
$name = "vlc-juxtopposed-$tag-win64.zip"
$assets = @($latest.Release.assets | Where-Object { $_.name -ceq $name -and $_.state -eq 'uploaded' })
if ($assets.Count -ne 1) { throw "Expected exactly one published Windows ZIP named $name" }
$asset = $assets[0]
$digestMatch = [regex]::Match([string]$asset.digest, '^sha256:(?<digest>[a-fA-F0-9]{64})$')
if (-not $digestMatch.Success) { throw "Missing/invalid upstream SHA-256 digest for $name" }
$expected = $digestMatch.Groups['digest'].Value.ToLowerInvariant()
$url = "https://github.com/dsojevic/juxtopposed-vlc/releases/download/$tag/$name"
if ([string]$asset.browser_download_url -cne $url) {
    throw "Upstream release asset URL differs from expected value for $name"
}
if ($manifest.version -eq $tag) {
    if ($manifest.architecture['64bit'].hash -cne $expected -or
        $manifest.architecture['64bit'].url -cne $url) {
        throw "Published $tag asset hash/URL changed; manual review required."
    }
    Write-UpdateSummary -status 'already current' -tag $tag -url $url -hash $expected
    return
}

$sumAssets = @($latest.Release.assets | Where-Object { $_.name -ceq 'SHA256SUMS.txt' -and $_.state -eq 'uploaded' })
if ($sumAssets.Count -ne 1) { throw 'Required upstream SHA256SUMS.txt asset is missing/duplicated.' }
$expectedSumURL = "https://github.com/dsojevic/juxtopposed-vlc/releases/download/$tag/SHA256SUMS.txt"
if ([string]$sumAssets[0].browser_download_url -cne $expectedSumURL) {
    throw 'Unexpected SHA256SUMS.txt URL from GitHub releases API.'
}
try {
    $sumBytes = (Invoke-WebRequest -Uri $expectedSumURL -TimeoutSec 90).Content
    $sumText = if ($sumBytes -is [byte[]]) {
        [Text.Encoding]::UTF8.GetString($sumBytes)
    } else {
        [string]$sumBytes
    }
} catch {
    throw "Failed to fetch SHA256SUMS.txt: $($_.Exception.Message)"
}
$sumHashes = [Collections.Generic.List[string]]::new()
foreach ($line in ($sumText -split '\r?\n')) {
    $sumMatch = [regex]::Match($line, '^\s*(?<hash>[a-fA-F0-9]{64})\s+\*?(?<filename>\S+)\s*$')
    if ($sumMatch.Success -and $sumMatch.Groups['filename'].Value -ceq $name) {
        $sumHashes.Add($sumMatch.Groups['hash'].Value.ToLowerInvariant())
    }
}
if ($sumHashes.Count -ne 1 -or $sumHashes[0] -cne $expected) {
    throw "SHA256SUMS.txt does not match official GitHub asset digest for $name"
}

$temp = Join-Path ([IO.Path]::GetTempPath()) ("myscoop-juxtoposed-$([guid]::NewGuid().ToString('N')).zip")
try {
    Write-Host "Downloading $name and verifying SHA-256 and ZIP members..."
    try {
        Invoke-WebRequest -Uri $url -OutFile $temp -TimeoutSec 900
    } catch {
        throw "VLC archive download failed ($url): $($_.Exception.Message)"
    }
    $actual = (Get-FileHash -LiteralPath $temp -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -cne $expected) { throw "VLC archive checksum mismatch ($name)" }
    Add-Type -AssemblyName System.IO.Compression
    $zip = [IO.Compression.ZipFile]::OpenRead($temp)
    try {
        $memberNames = @($zip.Entries | ForEach-Object { $_.FullName.Replace('\', '/') })
        if ('vlc-win64/vlc.exe' -cnotin $memberNames) {
            throw "VLC archive does not contain vlc-win64/vlc.exe ($name)"
        }
    } finally { $zip.Dispose() }
    $manifest.version = $tag
    $manifest.architecture['64bit'].url = $url
    $manifest.architecture['64bit'].hash = $expected
    $json = ($manifest | ConvertTo-Json -Depth 40) + "`n"
    $roundTrip = $json | ConvertFrom-Json -AsHashtable -Depth 40
    if ($roundTrip.version -cne $tag -or $roundTrip.architecture['64bit'].hash -cne $expected) {
        throw 'Candidate manifest failed round-trip validation.'
    }
    if ($DryRun) {
        Write-UpdateSummary -status 'dry-run verified; no files changed' -tag $tag -url $url -hash $expected
        return
    }

    # Same-directory staging. File.Replace atomically replaces the old manifest,
    # maintaining a rollback copy until post-write verification succeeds.
    $nonce = [guid]::NewGuid().ToString('N')
    $staging = "$ManifestPath.$nonce.tmp"
    $rollback = "$ManifestPath.$nonce.rollback"
    try {
        [IO.File]::WriteAllText($staging, $json, [Text.UTF8Encoding]::new($false))
        $null = Get-Content -LiteralPath $staging -Raw -Encoding utf8 |
            ConvertFrom-Json -AsHashtable -Depth 40
        [IO.File]::Replace($staging, $ManifestPath, $rollback, $true)
        $committed = Get-Content -LiteralPath $ManifestPath -Raw -Encoding utf8 |
            ConvertFrom-Json -AsHashtable -Depth 40
        if ($committed.version -cne $tag -or $committed.architecture['64bit'].hash -cne $expected) {
            throw "Post-write verification failed. Rollback retained at $rollback"
        }
        Remove-Item -LiteralPath $rollback -Force
    } finally {
        Remove-Item -LiteralPath $staging -Force -ErrorAction SilentlyContinue
    }
    Write-UpdateSummary -status 'updated' -tag $tag -url $url -hash $expected
} finally {
    Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
}
