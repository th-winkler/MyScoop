#requires -Version 7.0
<#
Refresh Spicetify CLI from the latest non-prerelease official GitHub release.
Requires a published SHA-256 digest for every Windows architecture; downloads
and verifies every archive before atomically updating the Scoop manifest.
No code from the downloaded packages is executed.
#>
[CmdletBinding()]
param([string]$ManifestPath = (Join-Path $PSScriptRoot '..' 'bucket' 'spicetify-cli.json'))
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$ManifestPath = [IO.Path]::GetFullPath($ManifestPath)
$headers = @{
    Accept = 'application/vnd.github+json'
    'User-Agent' = 'MyScoop-Spicetify-Updater'
    'X-GitHub-Api-Version' = '2022-11-28'
}
$release = Invoke-RestMethod 'https://api.github.com/repos/spicetify/cli/releases/latest' -Headers $headers -TimeoutSec 60
if ($release.draft -or $release.prerelease -or $release.tag_name -notmatch '^v(?<ver>\d+(?:\.\d+){2,3})$') {
    throw "Unexpected stable Spicetify release tag: $($release.tag_name)"
}
$version = $Matches.ver
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
        $matches = @($release.assets | Where-Object { $_.name -ceq $name -and $_.state -eq 'uploaded' })
        if ($matches.Count -ne 1) { throw "Expected exactly one published release asset $name" }
        $asset = $matches[0]
        if ($asset.digest -notmatch '^sha256:(?<digest>[a-fA-F0-9]{64})$') {
            throw "Missing published GitHub SHA-256 digest: $name"
        }
        $expected = $Matches.digest.ToLowerInvariant()
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
            Invoke-WebRequest -Uri $url -OutFile $temp -TimeoutSec 600
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
    $staging = "$ManifestPath.tmp"
    try {
        [IO.File]::WriteAllText($staging, (($manifest | ConvertTo-Json -Depth 40) + "`n"), [Text.UTF8Encoding]::new($false))
        $null = Get-Content -LiteralPath $staging -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        Move-Item -LiteralPath $staging -Destination $ManifestPath -Force
    } finally { Remove-Item -LiteralPath $staging -Force -ErrorAction SilentlyContinue }
    Write-Host "Updated Spicetify CLI manifest -> $version"
} finally {
    foreach ($temp in $tempFiles) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
}
