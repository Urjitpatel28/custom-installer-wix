<#
.SYNOPSIS
    Regenerates samples\ from examples\ with the current generator.

.DESCRIPTION
    Each sample is one of the examples after New-WixSetup.ps1 ran on it with the arguments below. Run this
    after changing a template or script; CustomInstallerWix.Tests.ps1 fails while samples\ is out of date.
    UpgradeCodes and solution GUIDs are new on every run (the test ignores them).

    Installers are not committed: CI builds them and uploads them as workflow artifacts.

.EXAMPLE
    .\tests\Update-Samples.ps1
#>
[CmdletBinding()]
param(
    # Where to write the samples. The test points this at a scratch folder.
    [string]$OutDir
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
if (-not $OutDir) { $OutDir = Join-Path $repo 'samples' }
$generator = Join-Path $repo 'skills\custom-installer-wix\scripts\New-WixSetup.ps1'

# Name, example, solution, generator arguments. Paths in the arguments are relative to the sample.
$samples = @(
    @{ Name = 'wpf-net8-peruser'; Example = 'wpf-net8'; Solution = 'InventoryApp.sln'
       Args = @('-Manufacturer', 'Contoso Ltd', '-Scope', 'perUser', '-License', 'LICENSE.txt', '-Url', 'https://contoso.example')
       Extra = @{ 'LICENSE.txt' = 'examples\winforms-net48\LICENSE.txt' } }
    @{ Name = 'winforms-net48-permachine'; Example = 'winforms-net48'; Solution = 'ClinicDesk.sln'
       Args = @('-Manufacturer', 'Northwind Health', '-License', 'LICENSE.txt', '-NoDesktopShortcut') }
    @{ Name = 'winforms-net48-peruser-nolicense'; Example = 'winforms-net48'; Solution = 'ClinicDesk.sln'
       Args = @('-Manufacturer', 'Northwind Health', '-Scope', 'perUser') }
)

if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir | Out-Null }
# Folders from earlier sample names go, so samples\ holds exactly what this script makes.
$names = @($samples | ForEach-Object { $_.Name })
Get-ChildItem -LiteralPath $OutDir -Directory | Where-Object { $names -notcontains $_.Name } | Remove-Item -Recurse -Force
foreach ($s in $samples) {
    $dest = Join-Path $OutDir $s.Name
    if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
    Copy-Item -Recurse (Join-Path $repo "examples\$($s.Example)") $dest
    if ($s.Extra) { foreach ($k in $s.Extra.Keys) { Copy-Item (Join-Path $repo $s.Extra[$k]) (Join-Path $dest $k) } }

    Push-Location $dest
    try {
        $output = & powershell -NoProfile -ExecutionPolicy Bypass -File $generator -Solution $s.Solution @($s.Args) 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Generating $($s.Name) failed:`n$($output | Out-String)" }
    }
    finally { Pop-Location }
    Write-Host "  $dest"
}
