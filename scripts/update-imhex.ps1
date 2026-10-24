#requires -Version 7.0
<#
Update ImHex portable Windows manifest from a published GitHub stable release.
Requires GitHub's release asset digest and downloads/verifies both Windows
architectures before changing the manifest. Does not execute downloaded code.
#>
[CmdletBinding()]
param([string]$ManifestPath = (Join-Path $PSScriptRoot '..' 'bucket' 'imhex.json'))
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$ManifestPath = [IO.Path]::GetFullPath($ManifestPath)
$headers = @{
    Accept = 'application/vnd.github+json'
    'User-Agent' = 'MyScoop-ImHex-Updater'
    'X-GitHub-Api-Version' = '2022-11-28'
}
$release = Invoke-RestMethod 'https://api.github.com/repos/WerWolv/ImHex/releases/latest' -Headers $headers -TimeoutSec 60
if ($release.draft -or $release.prerelease -or $release.tag_name -notmatch '^v(?<ver>\d+(?:\.\d+){2,3})$') {
    throw "Unexpected ImHex stable release: $($release.tag_name)"
}
$version = $Matches.ver
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
        if ([string]$asset.digest -notmatch '^sha256:(?<digest>[a-fA-F0-9]{64})$') { throw "Missing release digest $name" }
        $expected = $Matches.digest.ToLowerInvariant()
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
            Invoke-WebRequest -Uri $url -OutFile $temp -TimeoutSec 900
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
    $staging = "$ManifestPath.tmp"
    try {
        [IO.File]::WriteAllText($staging, (($manifest | ConvertTo-Json -Depth 40) + "`n"), [Text.UTF8Encoding]::new($false))
        $null = Get-Content -LiteralPath $staging -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        Move-Item -LiteralPath $staging -Destination $ManifestPath -Force
    } finally { Remove-Item -LiteralPath $staging -Force -ErrorAction SilentlyContinue }
    Write-Host "Updated ImHex manifest -> $version"
} finally { foreach ($temp in $tempFiles) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue } }
