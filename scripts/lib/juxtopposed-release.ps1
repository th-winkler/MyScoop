#requires -Version 7.0
# Pure parsing and selection helpers. No network or filesystem side effects.
Set-StrictMode -Version Latest

function Assert-JuxtopposedReleaseArray {
    [CmdletBinding()]
    param([AllowNull()][object]$Payload)
    if ($null -eq $Payload -or $Payload -isnot [array]) {
        $typeName = if ($null -eq $Payload) { '<null>' } else { $Payload.GetType().FullName }
        throw "GitHub releases API must return a JSON array; received $typeName"
    }
    $items = [object[]]$Payload
    if ($items.Length -eq 0) { throw 'GitHub releases API returned an empty array.' }
    foreach ($release in $items) {
        if ($null -eq $release -or $release -isnot [pscustomobject]) {
            throw 'GitHub releases API returned a non-object element.'
        }
        foreach ($name in @('tag_name', 'draft', 'prerelease', 'assets')) {
            if ($release.PSObject.Properties.Name -cnotcontains $name) {
                throw "GitHub releases API object is missing '$name'."
            }
        }
        if ([string]::IsNullOrWhiteSpace([string]$release.tag_name)) {
            throw 'GitHub releases API contains a blank tag_name.'
        }
        if ($null -eq $release.assets -or $release.assets -isnot [array]) {
            throw "Release $($release.tag_name) has missing/malformed assets array."
        }
    }
    # Unary comma preserves the collection instead of accidentally streaming elements.
    return ,$items
}

function ConvertTo-JuxtopposedReleaseVersion {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Tag)
    # Legacy beta-1/beta-2/beta-3 tags are deliberately not mapped to
    # an invented semantic version; only canonical tags can be published.
    $m = [regex]::Match($Tag, '^(?:v)?(?<base>\d+\.\d+\.\d+)(?:-beta\.(?<beta>\d+))?$')
    if (-not $m.Success) { return $null }
    $isBeta = $m.Groups['beta'].Success
    return [pscustomobject]@{
        Base   = [version]$m.Groups['base'].Value
        Stable = [int](-not $isBeta)
        Beta   = if ($isBeta) { [int]$m.Groups['beta'].Value } else { 0 }
        Tag    = $Tag
    }
}

function Select-JuxtopposedPublishedRelease {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$Releases)
    $candidates = [Collections.Generic.List[object]]::new()
    foreach ($release in $Releases) {
        if ([bool]$release.draft) { continue }
        $parsed = ConvertTo-JuxtopposedReleaseVersion -Tag ([string]$release.tag_name)
        if ($null -ne $parsed) {
            $candidates.Add([pscustomobject]@{
                Release = $release
                Base    = $parsed.Base
                Stable  = $parsed.Stable
                Beta    = $parsed.Beta
                Tag     = $parsed.Tag
            })
        }
    }
    if ($candidates.Count -eq 0) {
        $observed = ($Releases | ForEach-Object { [string]$_.tag_name }) -join ', '
        throw "No supported Juxtopposed VLC release tag. Observed $($Releases.Length) release(s): $observed"
    }
    return $candidates | Sort-Object -Property `
        @{ Expression = 'Base'; Descending = $true }, `
        @{ Expression = 'Stable'; Descending = $true }, `
        @{ Expression = 'Beta'; Descending = $true } | Select-Object -First 1
}

function Compare-JuxtopposedVersions {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Left, [Parameter(Mandatory)][object]$Right)
    $base = $Left.Base.CompareTo($Right.Base)
    if ($base -ne 0) { return [Math]::Sign($base) }
    if ($Left.Stable -ne $Right.Stable) { return [Math]::Sign($Left.Stable - $Right.Stable) }
    return [Math]::Sign($Left.Beta - $Right.Beta)
}
