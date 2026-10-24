#requires -Version 7.0
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '..' 'lib' 'juxtopposed-release.ps1')
function Assert([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "Regression test failed: $Message" }
}
$releases = @(
    [pscustomobject]@{ tag_name = 'beta-3'; draft = $false; prerelease = $true; assets = @() },
    [pscustomobject]@{ tag_name = '4.0.0-beta.4'; draft = $false; prerelease = $true; assets = @() },
    [pscustomobject]@{ tag_name = '4.0.0-beta.5'; draft = $false; prerelease = $true; assets = @() }
)
$validated = Assert-JuxtopposedReleaseArray -Payload $releases
Assert ($validated.Length -eq 3) 'Top-level GitHub JSON array must preserve 3 releases.'
$nested = ,$releases
$nestedFailed = $false
try { $null = Assert-JuxtopposedReleaseArray -Payload $nested } catch { $nestedFailed = $true }
Assert $nestedFailed 'Reject @(Invoke-RestMethod) nested array shape rather than silently dropping tags.'
$selected = Select-JuxtopposedPublishedRelease -Releases $validated
Assert ($selected.Tag -ceq '4.0.0-beta.5') 'Select beta.5 rather than unsupported legacy tags or beta.4.'
Assert ((Compare-JuxtopposedVersions -Left $selected -Right (ConvertTo-JuxtopposedReleaseVersion '4.0.0-beta.4')) -gt 0) 'Upgrade ordering.'
Assert ((Compare-JuxtopposedVersions -Left (ConvertTo-JuxtopposedReleaseVersion '4.0.0') -Right $selected) -gt 0) 'Stable outranks prerelease.'
$invalid = $false
try { $null = Assert-JuxtopposedReleaseArray -Payload ([pscustomobject]@{ message='rate limit' }) } catch { $invalid = $true }
Assert $invalid 'Reject API error objects, not treat them as releases.'
$invalid = $false
try { $null = Select-JuxtopposedPublishedRelease -Releases @([pscustomobject]@{tag_name='beta-3';draft=$false;prerelease=$true;assets=@()}) } catch { $invalid = $true }
Assert $invalid 'Reject legacy-only unversioned releases without guessing version.'
$invalid = $false
try { $null = Assert-JuxtopposedReleaseArray -Payload @([pscustomobject]@{ tag_name='4.0.0-beta.5';draft=$false;prerelease=$true }) } catch { $invalid=$true }
Assert $invalid 'Reject missing assets key.'
Write-Host 'PASS: release API array shape, prerelease tags, ordering, malformed metadata, legacy-only case.'
