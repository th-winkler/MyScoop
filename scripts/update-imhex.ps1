#requires -Version 7.0
<#
Update ImHex portable Windows manifest from a published GitHub stable release.
Requires GitHub's release asset digest and downloads/verifies both Windows
architectures before changing the manifest. Does not execute downloaded code.
#>
[CmdletBinding()]
param(
    [string]$ManifestPath = (Join-Path $PSScriptRoot '..' 'bucket' 'imhex.json'),
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ProgressPreference = 'SilentlyContinue'
$ManifestPath = [IO.Path]::GetFullPath($ManifestPath)
if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) { throw "Manifest not found: $ManifestPath" }
$headers = @{
    Accept = 'application/vnd.github+json'
    'User-Agent' = 'MyScoop-ImHex-Updater'
    'X-GitHub-Api-Version' = '2022-11-28'
}
try {
    $release = Invoke-RestMethod 'https://api.github.com/repos/WerWolv/ImHex/releases/latest' -Headers $headers -TimeoutSec 60
} catch {
    throw "GitHub stable release API failed: $($_.Exception.Message)"
}
if ($release.draft -or $release.prerelease -or [string]$release.tag_name -notmatch '^v\d+(?:\.\d+){2,3}$') {
    throw "Unexpected ImHex stable release: $($release.tag_name)"
}
$version = ([string]$release.tag_name).Substring(1)
$manifest = Get-Content -LiteralPath $ManifestPath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
if ([version]$version -lt [version]$manifest.version) { throw "Refusing ImHex downgrade $($manifest.version) -> $version" }
$targets = [ordered]@{ '64bit' = 'x86_64'; 'arm64' = 'arm64' }
$tempFiles = [Collections.Generic.List[string]]::new()
try {
    foreach ($arch in $targets.Keys) {
        $name = "imhex-$version-Windows-Portable-$($targets[$arch]).zip"
        $assets = @($release.assets | Where-Object { $_.name -ceq $name -and $_.state -eq 'uploaded' })
        if ($assets.Count -ne 1) { throw "Official ImHex asset missing: $name" }
        $asset = $assets[0]
        if ([string]$asset.digest -notmatch '^sha256:[a-fA-F0-9]{64}$') { throw "Missing release digest $name" }
        $expected = ([string]$asset.digest).Substring(7).ToLowerInvariant()
        $url = "https://github.com/WerWolv/ImHex/releases/download/v$version/$name"
        if ([string]$asset.browser_download_url -cne $url) { throw "Unexpected asset URL for $name" }
        if ([string]$manifest.version -eq $version) {
            if ([string]$manifest.architecture[$arch].url -cne $url -or [string]$manifest.architecture[$arch].hash -cne $expected) {
                throw "Published ImHex $version differs from existing manifest ($arch). Review upstream manually."
            }
        } else {
            $temp = Join-Path ([IO.Path]::GetTempPath()) ('myscoop-imhex-' + [guid]::NewGuid().ToString('N') + '.zip')
            $tempFiles.Add($temp)
            Write-Host "Downloading $name"
            try {
                Invoke-WebRequest -Uri $url -OutFile $temp -TimeoutSec 900
            } catch {
                throw "Download failed for $name ($url): $($_.Exception.Message)"
            }
            $actual = (Get-FileHash -LiteralPath $temp -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($actual -cne $expected) { throw "ImHex checksum mismatch for $name" }
            Add-Type -AssemblyName System.IO.Compression
            $zip = [IO.Compression.ZipFile]::OpenRead($temp)
            try {
                if (-not @($zip.Entries | Where-Object { $_.FullName.Replace('\', '/') -match '(^|/)ImHex\.exe$' }).Count) {
                    throw "No ImHex.exe in archive $name"
                }
            } finally { $zip.Dispose() }
            $manifest.architecture[$arch].url = $url
            $manifest.architecture[$arch].hash = $expected
        }
        Write-Host "Verified $name $expected"
    }
    if ([string]$manifest.version -eq $version) { Write-Host "ImHex $version is current."; return }
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
    Write-Host "Updated ImHex manifest -> $version"
} finally { foreach ($temp in $tempFiles) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue } }
