#requires -Version 7.0
[CmdletBinding()]
param(
    [string]$App = '*',
    [switch]$Update
)
$ErrorActionPreference = 'Stop'
$bucket = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' 'bucket'))
if (-not (Test-Path -LiteralPath $bucket -PathType Container)) {
    throw "Bucket directory not found: $bucket"
}
$scoopCheckver = Join-Path $env:USERPROFILE 'scoop/apps/scoop/current/bin/checkver.ps1'
if (-not (Test-Path -LiteralPath $scoopCheckver -PathType Leaf)) {
    throw "Scoop checkver.ps1 not found: $scoopCheckver"
}
& $scoopCheckver -App $App -Dir $bucket -Update:$Update
if (-not $?) { throw 'Scoop checkver failed' }
