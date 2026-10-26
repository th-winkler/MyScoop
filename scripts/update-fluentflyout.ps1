#requires -Version 7.0
<#
.SYNOPSIS
    Update the MyScoop FluentFlyout manifest from the upstream stable GitHub release.
.DESCRIPTION
    Authenticates GitHub API access when GITHUB_TOKEN is set; parses the official
    x64 checksum row in release notes; verifies the downloaded archive checksum
    and required ZIP members; then atomically replaces the manifest.
    Never executes downloaded code. Use -DryRun to verify without writing files.
#>
[CmdletBinding()]
param(
    [string] $ManifestPath = (Join-Path $PSScriptRoot '..' 'bucket' 'fluentflyout.json'),
    [switch] $DryRun
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'lib' 'fluentflyout-release.ps1')

function Invoke-FluentFlyoutRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [scriptblock] $Operation,
        [Parameter(Mandatory)] [string] $Description,
        [ValidateRange(1, 5)] [int] $MaxAttempts = 3
    )

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            return & $Operation
        } catch {
            $failure = $_
            $status = $null
            $responseProperty = $failure.Exception.PSObject.Properties['Response']
            if ($null -ne $responseProperty -and $null -ne $responseProperty.Value) {
                $status = [int] $responseProperty.Value.StatusCode
            }
            $details = if ($null -ne $failure.ErrorDetails) { [string] $failure.ErrorDetails.Message } else { '' }
            $message = [string] $failure.Exception.Message
            $rateLimited = ($status -eq 403 -and "$details $message" -match '(?i)rate.?limit|secondary rate|abuse detection')
            $transient = ($status -in @(408, 429, 500, 502, 503, 504)) -or $rateLimited

            if (-not $transient -or $attempt -eq $MaxAttempts) {
                $statusText = if ($null -eq $status) { 'network/IO error' } else { "HTTP $status" }
                throw "$Description failed ($statusText; attempt $attempt/$MaxAttempts): $message"
            }

            $delay = [int] [math]::Min(2 * [math]::Pow(2, $attempt - 1), 8)
            Write-Warning "$Description encountered HTTP $status; retrying in $delay seconds ($attempt/$MaxAttempts)."
            Start-Sleep -Seconds $delay
        }
    }
}

function Write-FluentFlyoutManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $Manifest,
        [Parameter(Mandatory)] [string] $Path
    )

    $json = $Manifest | ConvertTo-Json -Depth 30
    $directory = [System.IO.Path]::GetDirectoryName($Path)
    $staged = Join-Path $directory ('.fluentflyout-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [System.IO.File]::WriteAllText($staged, "$json`n", [System.Text.UTF8Encoding]::new($false))
        [System.IO.File]::Move($staged, $Path, $true)
    } finally {
        Remove-Item -LiteralPath $staged -Force -ErrorAction SilentlyContinue
    }
}

$apiUrl = 'https://api.github.com/repos/unchihugo/FluentFlyout/releases/latest'
$headers = @{
    'Accept'              = 'application/vnd.github+json'
    'User-Agent'           = 'MyScoop-FluentFlyout-Updater'
    'X-GitHub-Api-Version' = '2022-11-28'
}
if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_TOKEN)) {
    $headers['Authorization'] = "Bearer $env:GITHUB_TOKEN"
}

$release = Invoke-FluentFlyoutRequest -Description 'GitHub FluentFlyout latest-release API' -Operation {
    Invoke-RestMethod -Uri $apiUrl -Headers $headers -TimeoutSec 45 -ErrorAction Stop
}
$metadata = Get-FluentFlyoutReleaseMetadata -Release $release
$tag = $metadata.Tag
$version = $metadata.Version
$publishedSha256 = $metadata.Sha256

$archiveName = "FluentFlyout_${version}_x64_Installer.zip"
$downloadUrl = "https://files.fluentflyout.com/$archiveName"
$ManifestPath = [System.IO.Path]::GetFullPath($ManifestPath)
if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
    throw "FluentFlyout manifest does not exist: $ManifestPath"
}
$manifest = Get-Content -LiteralPath $ManifestPath -Raw -Encoding utf8 | ConvertFrom-Json
if ($null -eq $manifest -or [string]::IsNullOrWhiteSpace([string] $manifest.version)) {
    throw 'Existing FluentFlyout manifest is missing a version.'
}
if ([version] $version -lt [version] $manifest.version) {
    throw "Refusing to downgrade manifest from $($manifest.version) to $version."
}

$changelogNote = "Official release notes: https://github.com/unchihugo/FluentFlyout/releases/tag/$tag"
$existingNotes = @($manifest.notes | Where-Object { $null -ne $_ -and $_ -ne '' })
$otherNotes = @($existingNotes | Where-Object {
    $_ -notmatch '^Official release notes: https://github\.com/unchihugo/FluentFlyout/releases/tag/'
})
$desiredNotes = @($changelogNote) + $otherNotes

if ([string] $manifest.version -eq $version) {
    if ([string] $manifest.url -cne $downloadUrl -or [string] $manifest.hash -cne $publishedSha256) {
        throw 'Existing FluentFlyout version has a different URL/hash; refusing silent replacement.'
    }
    if ($changelogNote -notin $existingNotes) {
        if ($DryRun) {
            Write-Host "FluentFlyout ${version}: dry-run; release-note link would be refreshed."
        } else {
            $manifest.notes = $desiredNotes
            Write-FluentFlyoutManifest -Manifest $manifest -Path $ManifestPath
            Write-Host "FluentFlyout ${version}: added upstream release-note link."
        }
    } else {
        Write-Host "FluentFlyout ${version}: already current; no manifest changes."
    }
    return
}

# Before publishing any new version, validate both upstream checksum and ZIP layout.
$tempFile = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N') + '.zip')
try {
    Write-Host "Downloading and verifying $downloadUrl"
    Invoke-FluentFlyoutRequest -Description "FluentFlyout download $archiveName" -Operation {
        # Remove partially written content before another attempt.
        Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
        Invoke-WebRequest -Uri $downloadUrl -OutFile $tempFile -TimeoutSec 600 -MaximumRedirection 5 -ErrorAction Stop
    } | Out-Null

    $actualSha256 = (Get-FileHash -LiteralPath $tempFile -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualSha256 -cne $publishedSha256) {
        throw "SHA-256 mismatch: release notes $publishedSha256; downloaded $actualSha256. Manifest NOT changed."
    }

    Add-Type -AssemblyName System.IO.Compression
    $archive = [System.IO.Compression.ZipFile]::OpenRead($tempFile)
    try {
        $names = @($archive.Entries | ForEach-Object { $_.FullName.Replace('\', '/') })
        foreach ($pattern in @(
            '^SystemFiles/[^/]+\.msixbundle$',
            '^SystemFiles/[^/]+\.cer$',
            '^SystemFiles/Add-AppDevPackage\.ps1$'
        )) {
            if (@($names | Where-Object { $_ -cmatch $pattern }).Count -ne 1) {
                throw "Archive $archiveName does not contain exactly one required member matching $pattern."
            }
        }
    } finally {
        $archive.Dispose()
    }

    if ($DryRun) {
        Write-Host "FluentFlyout ${version}: dry-run verified release, SHA-256 and ZIP layout; manifest unchanged."
        return
    }

    if ($null -eq $manifest.notes) {
        $manifest | Add-Member -NotePropertyName notes -NotePropertyValue $desiredNotes
    } else {
        $manifest.notes = $desiredNotes
    }
    $manifest.version = $version
    $manifest.url = $downloadUrl
    $manifest.hash = $publishedSha256
    Write-FluentFlyoutManifest -Manifest $manifest -Path $ManifestPath
    Write-Host "Updated FluentFlyout manifest to $version ($publishedSha256)"
} finally {
    Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
}

