<#
.SYNOPSIS
    Lists the projects in a solution that could be packaged, best candidate first, as JSON.

.DESCRIPTION
    A .sln does not record the startup project - Visual Studio keeps that choice in the binary .suo
    under .vs\ - so it is inferred: every WinExe/Exe project that is not a test project is a candidate.
    WinExe (WPF, WinForms, WinUI) sorts ahead of Exe, then solution order, which is also the order
    Visual Studio falls back to when no startup project was ever chosen.

    Also reports any WiX project already in the solution, because generating a second one would mint
    a new UpgradeCode and break upgrades from whatever the first one shipped. Each entry says whether
    this skill generated it and with which generator version: a generated project that is not Current
    can be brought up to date with New-WixSetup.ps1 -Refresh.

.EXAMPLE
    .\Find-StartupProject.ps1 -Solution C:\src\Contoso\Contoso.sln
#>
[CmdletBinding()]
param(
    # The .sln or .slnx to inspect. When omitted, the single solution in the current directory is used.
    [string]$Solution
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'CustomInstallerWix.psm1') -Force

if (-not $Solution) {
    $found = @(Get-ChildItem -Path . -File | Where-Object { $_.Extension -in '.sln', '.slnx' })
    if ($found.Count -ne 1) {
        throw "Pass -Solution: found $($found.Count) .sln/.slnx files in $((Get-Location).Path)."
    }
    $Solution = $found[0].FullName
}
$Solution = (Resolve-Path -LiteralPath $Solution).ProviderPath
if ([System.IO.Path]::GetExtension($Solution) -notin '.sln', '.slnx') {
    throw "$Solution is not a .sln or .slnx file."
}

$projects = @(Get-SolutionProjects -SolutionPath $Solution)

$existingSetup = @($projects | Where-Object { $_.Path -like '*.wixproj' } | ForEach-Object { Get-SetupProjectInfo -ProjectPath $_.Path })

$infos = @()
foreach ($p in $projects) {
    $ext = [System.IO.Path]::GetExtension($p.Path)
    if ($ext -notin '.csproj', '.vbproj', '.fsproj') { continue }
    if (-not (Test-Path -LiteralPath $p.Path)) { continue }
    $info = Get-ProjectInfo -ProjectPath $p.Path
    $info | Add-Member -NotePropertyName SolutionOrder -NotePropertyValue $infos.Count
    $infos += $info
}

$candidates = @($infos |
    Where-Object { $_.IsExecutable -and -not $_.IsTest } |
    Sort-Object @{ Expression = { if ($_.OutputType -eq 'WinExe') { 0 } else { 1 } } }, @{ Expression = { if ($_.Kind -eq 'web' -or $_.Kind -eq 'worker') { 1 } else { 0 } } }, SolutionOrder)

[pscustomobject]@{
    Solution      = $Solution
    GeneratorVersion = $GeneratorVersion
    ExistingSetup = $existingSetup
    Candidates    = $candidates
    Skipped       = @($infos | Where-Object { -not ($_.IsExecutable -and -not $_.IsTest) } |
            ForEach-Object { [pscustomobject]@{ Name = $_.Name; OutputType = $_.OutputType; IsTest = $_.IsTest } })
} | ConvertTo-Json -Depth 5
