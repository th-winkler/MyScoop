#requires -Version 7.0
[CmdletBinding()]
param([string]$BucketPath = (Join-Path $PSScriptRoot '..' 'bucket'))
$ErrorActionPreference = 'Stop'
$BucketPath = [IO.Path]::GetFullPath($BucketPath)
$files = @(Get-ChildItem -LiteralPath $BucketPath -Filter '*.json' -File)
if ($files.Count -eq 0) { throw "No Scoop manifests in $BucketPath" }
$failures = [Collections.Generic.List[string]]::new()
foreach ($file in $files) {
    try {
        $manifest = Get-Content -LiteralPath $file.FullName -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        foreach ($property in @('version', 'description', 'homepage', 'license')) {
            if ([string]::IsNullOrWhiteSpace([string]$manifest[$property])) { throw "Missing $property" }
        }
        $releases = @()
        if ($manifest.ContainsKey('architecture')) {
            foreach ($arch in $manifest.architecture.Keys) {
                if ($arch -notin @('64bit', '32bit', 'arm64')) { throw "Unknown architecture: $arch" }
                $releases += [pscustomobject]@{ Key = $arch; Entry = $manifest.architecture[$arch] }
            }
        } else {
            $releases += [pscustomobject]@{ Key = 'default'; Entry = $manifest }
        }
        foreach ($candidate in $releases) {
            if ([string]$candidate.Entry.url -notmatch '^https://') { throw "Missing HTTPS release URL for $($candidate.Key)" }
            if ([string]$candidate.Entry.hash -cnotmatch '^[a-fA-F0-9]{64}$') {
                throw "Missing or invalid SHA-256 for $($candidate.Key)"
            }
        }
        if ($manifest.ContainsKey('checkver') -and -not $manifest.ContainsKey('autoupdate')) {
            throw 'checkver exists without autoupdate'
        }
        Write-Host "VALID $($file.Name) v$($manifest.version) ($($releases.Count) target(s))"
    } catch {
        $failures.Add("$($file.Name): $($_.Exception.Message)")
        Write-Error "INVALID $($file.Name): $($_.Exception.Message)" -ErrorAction Continue
    }
}
# Parser validation is offline; downloaded scripts are never executed by this test.
$scripts = @(Get-ChildItem -LiteralPath (Join-Path $BucketPath '..' 'scripts') -Filter '*.ps1' -File -ErrorAction SilentlyContinue)
foreach ($script in $scripts) {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($script.FullName, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count -gt 0) {
        $failures.Add("$($script.Name): $($errors[0].Message)")
    } else {
        Write-Host "PARSE OK $($script.Name)"
    }
}
if ($failures.Count -gt 0) { throw "Bucket validation failed: $($failures -join '; ')" }
Write-Host "Bucket validation passed: $($files.Count) manifests, $($scripts.Count) scripts."
