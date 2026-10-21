param([String]$app = '*', [Switch]$u)
& "$env:USERPROFILE\scoop\apps\scoop\current\bin\checkver.ps1" -App $app -Dir "$PSScriptRoot\bucket" -Update:$u
