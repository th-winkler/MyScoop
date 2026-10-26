#requires -Version 7.0
# Pure release metadata helpers. Safe to dot-source in offline tests.
Set-StrictMode -Version Latest

function Get-FluentFlyoutPublishedSha256 {
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [string] $ReleaseNotes
    )

    if ([string]::IsNullOrWhiteSpace($ReleaseNotes)) {
        throw 'FluentFlyout release notes are empty; cannot establish a published x64 SHA-256.'
    }

    $foundHashes = [System.Collections.Generic.List[string]]::new()
    $lines = [regex]::Split($ReleaseNotes, '\r\n|\n|\r')
    $fence = $null

    for ($index = 0; $index -lt $lines.Count; $index++) {
        $line = $lines[$index].Trim()

        # Checksums shown in fenced examples are not an authoritative release table.
        if ($line -match '^(`{3,}|~{3,})') {
            $marker = $Matches[1].Substring(0, 1)
            if ($null -eq $fence) {
                $fence = $marker
            } elseif ($fence -eq $marker) {
                $fence = $null
            }
            continue
        }
        if ($null -ne $fence -or -not $line.Contains('|')) { continue }

        # Both `GitHub Release x64 | HASH` and `| GitHub Release x64 | HASH |`.
        # Remove at most one framing pipe on each side; extra columns are invalid.
        if ($line.StartsWith('|')) { $line = $line.Substring(1) }
        if ($line.EndsWith('|')) { $line = $line.Substring(0, $line.Length - 1) }
        $columns = @($line.Split('|'))
        if ($columns.Count -lt 2 -or $columns[0].Trim() -cnotmatch '(?i:^GitHub\s+Release\s+x64$)') {
            continue
        }
        if ($columns.Count -ne 2) {
            throw "Malformed FluentFlyout x64 checksum row on line $($index + 1): expected two columns."
        }

        $rawHash = $columns[1].Trim()
        if ($rawHash -cnotmatch '^[a-fA-F0-9]{64}$') {
            throw "Malformed FluentFlyout x64 checksum on line $($index + 1): expected exactly 64 hexadecimal characters."
        }
        $foundHashes.Add($rawHash.ToLowerInvariant())
    }

    if ($foundHashes.Count -ne 1) {
        throw "Expected exactly one published 'GitHub Release x64' SHA-256 row; found $($foundHashes.Count). Release notes require review."
    }
    return $foundHashes[0]
}

function Get-FluentFlyoutReleaseMetadata {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Release
    )

    if ($null -eq $Release) { throw 'GitHub returned a null FluentFlyout release.' }
    if ($Release.draft -eq $true -or $Release.prerelease -eq $true) {
        throw 'Refusing to publish a draft or prerelease FluentFlyout build.'
    }

    $tag = [string] $Release.tag_name
    $tagMatch = [regex]::Match($tag, '^v(?<version>\d+(?:\.\d+){1,3})$')
    if (-not $tagMatch.Success) {
        throw "Unexpected FluentFlyout GitHub release tag: '$tag'."
    }
    $version = $tagMatch.Groups['version'].Value
    try {
        $null = [version] $version
    } catch {
        throw "Invalid FluentFlyout release version: '$version'."
    }

    $sha256 = Get-FluentFlyoutPublishedSha256 -ReleaseNotes ([string] $Release.body)
    return [pscustomobject]@{
        Tag     = $tag
        Version = $version
        Sha256  = $sha256
    }
}
