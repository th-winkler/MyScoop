#requires -Version 7.0
<#
Update the Juxtopposed VLC beta manifest. GitHub /releases/latest excludes
prereleases, so inspect published releases including betas. Download and
verify the Windows ZIP against GitHub's SHA-256 digest and SHA256SUMS.txt.
#>
[CmdletBinding()]
param([string]$ManifestPath = (Join-Path $PSScriptRoot '..' 'bucket' 'juxtopposed-vlc.json'))
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$ManifestPath = [IO.Path]::GetFullPath($ManifestPath)
$headers = @{
    Accept = 'application/vnd.github+json'
    'User-Agent' = 'MyScoop-Juxtopposed-VLC-Updater'
    'X-GitHub-Api-Version' = '2022-11-28'
}
function Get-ReleaseVersion([string]$tag) {
    if ($tag -notmatch '^(?<base>\d+\.\d+\.\d+)(?:-beta\.(?<beta>\d+))?$') { return $null }
    $beta = if ($Matches.ContainsKey('beta') -and $Matches.beta) { [int]$Matches.beta } else { 0 }
    [pscustomobject]@{ Base = [version]$Matches.base; Stable = [int]($beta -eq 0); Beta = $beta; Tag = $tag }
}
$releases = @(Invoke-RestMethod 'https://api.github.com/repos/dsojevic/juxtopposed-vlc/releases?per_page=30' -Headers $headers -TimeoutSec 60)
$candidates = @($releases | Where-Object { -not $_.draft } | ForEach-Object {
    $v = Get-ReleaseVersion ([string]$_.tag_name)
    if ($null -ne $v) { [pscustomobject]@{ Release = $_; Base = $v.Base; Stable = $v.Stable; Beta = $v.Beta; Tag = $v.Tag } }
})
if ($candidates.Count -eq 0) { throw 'No supported Juxtopposed VLC release tag found; manual review needed.' }
$latest = $candidates | Sort-Object -Property @{Expression='Base';Descending=$true}, @{Expression='Stable';Descending=$true}, @{Expression='Beta';Descending=$true} | Select-Object -First 1
$manifest = Get-Content -LiteralPath $ManifestPath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
$current = Get-ReleaseVersion ([string]$manifest.version)
if ($null -eq $current) { throw "Unrecognized current VLC version: $($manifest.version)" }
if (($latest.Base -lt $current.Base) -or
    ($latest.Base -eq $current.Base -and $latest.Stable -lt $current.Stable) -or
    ($latest.Base -eq $current.Base -and $latest.Stable -eq $current.Stable -and $latest.Beta -lt $current.Beta)) {
    throw "Refusing Juxtopposed VLC downgrade $($manifest.version) -> $($latest.Tag)"
}
$tag = $latest.Tag
$name = "vlc-juxtopposed-$tag-win64.zip"
$assets = @($latest.Release.assets | Where-Object { $_.name -ceq $name -and $_.state -eq 'uploaded' })
if ($assets.Count -ne 1) { throw "Expected one official Windows asset $name" }
$asset = $assets[0]
if ([string]$asset.digest -notmatch '^sha256:(?<digest>[a-fA-F0-9]{64})$') { throw "No GitHub release digest for $name" }
$expected = $Matches.digest.ToLowerInvariant()
$url = "https://github.com/dsojevic/juxtopposed-vlc/releases/download/$tag/$name"
if ([string]$asset.browser_download_url -cne $url) { throw "Unexpected release URL $($asset.browser_download_url)" }
if ([string]$manifest.version -eq $tag) {
    if ([string]$manifest.architecture['64bit'].hash -cne $expected -or
        [string]$manifest.architecture['64bit'].url -cne $url) {
        throw 'Already-published version has a different URL/hash. Review upstream before replacing it.'
    }
    Write-Host "Juxtopposed VLC $tag already current."
    return
}
$sumAssets = @($latest.Release.assets | Where-Object { $_.name -ceq 'SHA256SUMS.txt' -and $_.state -eq 'uploaded' })
if ($sumAssets.Count -ne 1) { throw 'Expected SHA256SUMS.txt release asset is missing.' }
$sumLines = (Invoke-WebRequest -Uri $sumAssets[0].browser_download_url -TimeoutSec 60).Content -split '\r?\n'
$sumMatches = @($sumLines | ForEach-Object {
    if ($_ -match '^\s*(?<hash>[a-fA-F0-9]{64})\s+\*?(?<filename>\S+)\s*$' -and $Matches.filename -ceq $name) {
        $Matches.hash.ToLowerInvariant()
    }
})
if ($sumMatches.Count -ne 1 -or $sumMatches[0] -cne $expected) { throw "Upstream SHA256SUMS.txt disagrees with GitHub digest for $name" }
$temp = Join-Path ([IO.Path]::GetTempPath()) ('myscoop-vlc-' + [guid]::NewGuid().ToString('N') + '.zip')
try {
    Write-Host "Downloading and validating $name"
    Invoke-WebRequest -Uri $url -OutFile $temp -TimeoutSec 900
    $actual = (Get-FileHash -LiteralPath $temp -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -cne $expected) { throw "Downloaded VLC archive checksum mismatch for $name" }
    Add-Type -AssemblyName System.IO.Compression
    $zip = [IO.Compression.ZipFile]::OpenRead($temp)
    try {
        if (-not @($zip.Entries | Where-Object { $_.FullName.Replace('\', '/') -ceq 'vlc-win64/vlc.exe' }).Count) {
            throw "VLC release archive is missing vlc-win64/vlc.exe"
        }
    } finally { $zip.Dispose() }
    $manifest.version = $tag
    $manifest.architecture['64bit'].url = $url
    $manifest.architecture['64bit'].hash = $expected
    $staging = "$ManifestPath.tmp"
    try {
        [IO.File]::WriteAllText($staging, (($manifest | ConvertTo-Json -Depth 40) + "`n"), [Text.UTF8Encoding]::new($false))
        $null = Get-Content -LiteralPath $staging -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        Move-Item -LiteralPath $staging -Destination $ManifestPath -Force
    } finally { Remove-Item -LiteralPath $staging -Force -ErrorAction SilentlyContinue }
    Write-Host "Updated Juxtopposed VLC $tag $expected"
} finally { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
