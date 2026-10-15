<#
.SYNOPSIS
    End to end: generate the Setup project into scratch copies of the examples, build the setup .exe,
    install, upgrade, check the result, and uninstall.

.DESCRIPTION
    Every build is Debug, as Visual Studio builds by default, and must leave only the setup .exe in
    bin\Debug, with the app's Release build inside it.

    Scenarios:
      install   generate, build, install silently, check files and shortcut, uninstall
      upgrade   generate, build v1, install into a chosen folder with DesktopShortcut=0 and
                StartMenuShortcut=0, bump the app's version, build v2,
                run v2 silently, and check there is one Add/Remove Programs entry at the new version, the
                files are new in the same folder and both shortcut choices were kept
      refresh   the same, starting from tests\fixtures\v1-* (a WiX 5 project from the first generator):
                v1 is built from its two projects as they are, v2 after New-WixSetup.ps1 -Refresh
                has merged them into one

    Needs network access (WiX SDK and, for net8, the runtime packs from nuget.org), MSBuild (Visual
    Studio 2022 or 2026, or Build Tools), the .NET 8+ SDK, and git. Per-machine installs need an elevated
    prompt; without one those scenarios are built but not installed. CI runs everything on windows-latest,
    where the runner is an administrator. -SkipInstall builds only.

    The built installers are copied to <WorkDir>\installers\<scenario>\ (CI uploads them).

    Keep -WorkDir short: Burn's build paths are long, and past Windows' 260-character limit the bundle
    build fails with "wixnative.exe ... The system cannot find the path specified".

.EXAMPLE
    .\tests\Invoke-EndToEnd.ps1 -WorkDir C:\temp\ciw-e2e
#>
[CmdletBinding()]
param(
    [string]$WorkDir = (Join-Path ([System.IO.Path]::GetTempPath()) 'ciw-e2e'),
    [switch]$SkipInstall
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$generator = Join-Path $repo 'skills\custom-installer-wix\scripts\New-WixSetup.ps1'
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

$msbuild = & "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe" -latest -products * -requires Microsoft.Component.MSBuild -find 'MSBuild\**\Bin\MSBuild.exe' | Select-Object -First 1
if (-not $msbuild) { throw 'MSBuild not found (vswhere).' }
Write-Host "MSBuild: $msbuild"

# Source: examples\<Example> or tests\fixtures\<Fixture>. Bump: file (relative to the scenario root), old
# text, new text, and the version Windows should then report.
$scenarios = @(
    @{ Name = 'winforms-permachine'; Kind = 'install'; Example = 'winforms-net48'; Solution = 'ClinicDesk.sln'; Setup = 'ClinicDesk.Setup'
       Args = @('-Manufacturer', 'Northwind Health', '-License', 'LICENSE.txt'); Product = 'Clinic Desk'; Exe = 'ClinicDesk.exe'; PerUser = $false }
    @{ Name = 'wpf-permachine'; Kind = 'install'; Example = 'wpf-net8'; Solution = 'InventoryApp.sln'; Setup = 'src\InventoryApp.Setup'
       Args = @('-Manufacturer', 'Contoso Ltd', '-License', '..\winforms-net48\LICENSE.txt'); Product = 'Contoso Inventory'; Exe = 'InventoryApp.exe'; PerUser = $false }
    # A .NET Framework app whose AssemblyVersion stays put: only the file version moves, which is what
    # the installer's version must follow.
    @{ Name = 'winforms-peruser-upgrade'; Kind = 'upgrade'; Example = 'winforms-net48'; Solution = 'ClinicDesk.sln'; Setup = 'ClinicDesk.Setup'
       Args = @('-Manufacturer', 'Northwind Health', '-Scope', 'perUser'); Product = 'Clinic Desk'; Exe = 'ClinicDesk.exe'; PerUser = $true
       Bump = @('ClinicDesk\Properties\AssemblyInfo.cs', 'AssemblyFileVersion("2.0.1.0")', 'AssemblyFileVersion("2.0.2.0")'); NewVersion = '2.0.2.0' }
    @{ Name = 'wpf-v1-refresh-upgrade'; Kind = 'refresh'; Fixture = 'v1-wpf-net8-peruser-bundle'; Solution = 'InventoryApp.sln'; Setup = 'src\InventoryApp.Setup'
       Product = 'Contoso Inventory'; Exe = 'InventoryApp.exe'; PerUser = $true
       Bump = @('src\InventoryApp\InventoryApp.csproj', '<Version>1.2.0</Version>', '<Version>1.2.1</Version>'); NewVersion = '1.2.1.0' }
    # The Visual Studio 2026 solution format: the generator edits a .slnx instead of a .sln.
    @{ Name = 'wpf-slnx-peruser-upgrade'; Kind = 'upgrade'; Example = 'wpf-net8'; Solution = 'InventoryApp.sln'; Slnx = $true; Setup = 'src\InventoryApp.Setup'
       Args = @('-Manufacturer', 'Contoso Ltd', '-Scope', 'perUser'); Product = 'Contoso Inventory'; Exe = 'InventoryApp.exe'; PerUser = $true
       Bump = @('src\InventoryApp\InventoryApp.csproj', '<Version>1.2.0</Version>', '<Version>1.2.1</Version>'); NewVersion = '1.2.1.0' }
    # A per-machine upgrade: HKLM for the remembered choices, Program Files rights, the all-users Start menu.
    @{ Name = 'winforms-permachine-upgrade'; Kind = 'upgrade'; Example = 'winforms-net48'; Solution = 'ClinicDesk.sln'; Setup = 'ClinicDesk.Setup'
       Args = @('-Manufacturer', 'Northwind Health'); Product = 'Clinic Desk'; Exe = 'ClinicDesk.exe'; PerUser = $false
       Bump = @('ClinicDesk\Properties\AssemblyInfo.cs', 'AssemblyFileVersion("2.0.1.0")', 'AssemblyFileVersion("2.0.2.0")'); NewVersion = '2.0.2.0' }
)

Import-Module (Join-Path $repo 'skills\custom-installer-wix\scripts\CustomInstallerWix.psm1') -Force

function ConvertTo-Slnx([string]$Sln) {
    <# The same projects as a .slnx, as Visual Studio 2026 saves a solution. Returns the new file's name. #>
    # Absolute: .NET resolves a relative path against the process directory, not the PowerShell location.
    $Sln = (Resolve-Path $Sln).ProviderPath
    $dir = Split-Path -Parent $Sln
    $lines = foreach ($p in Get-SolutionProjects -SolutionPath $Sln) {
        "  <Project Path=""$((Get-RelativePath $dir $p.Path).Replace('\', '/'))"" />"
    }
    $slnx = [System.IO.Path]::ChangeExtension($Sln, '.slnx')
    Set-Content -LiteralPath $slnx -Value (@('<Solution>', '  <Configurations>', '    <Platform Name="Any CPU" />', '  </Configurations>') + $lines + '</Solution>')
    Remove-Item -LiteralPath $Sln
    return (Split-Path -Leaf $slnx)
}

function Invoke-Checked([string]$What, [scriptblock]$Command) {
    Write-Host "  $What"
    # To the console, not the pipeline: $build below returns a path, which tool output would bury.
    & $Command | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "$What failed with exit code $LASTEXITCODE." }
}

function Invoke-Installer([string]$What, [string]$File, [string[]]$Arguments) {
    Write-Host "  $What"
    $p = Start-Process $File -ArgumentList $Arguments -Wait -PassThru
    if ($p.ExitCode -ne 0) { throw "$What failed with exit code $($p.ExitCode)." }
}

function Get-ArpEntries([string]$Product) {
    <# Add/Remove Programs entries a user would see (SystemComponent=1 ones are hidden). #>
    $keys = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    @(foreach ($k in $keys) {
            if (-not (Test-Path $k)) { continue }
            Get-ChildItem $k | Get-ItemProperty | Where-Object { $_.PSObject.Properties['DisplayName'] -and $_.DisplayName -eq $Product -and -not ($_.PSObject.Properties['SystemComponent'] -and $_.SystemComponent -eq 1) }
        })
}

if (Test-Path $WorkDir) { Remove-Item -Recurse -Force $WorkDir }
New-Item -ItemType Directory -Path $WorkDir | Out-Null
Copy-Item -Recurse (Join-Path $repo 'examples\*') $WorkDir
$installers = Join-Path $WorkDir 'installers'

$failures = @()
$notInstalled = @()
foreach ($s in $scenarios) {
    Write-Host "== $($s.Name)"
    try {
        $installed = $null
        $root = Join-Path $WorkDir $s.Name
        if ($s.Fixture) { Copy-Item -Recurse (Join-Path $repo "tests\fixtures\$($s.Fixture)") $root }
        else { Copy-Item -Recurse (Join-Path $WorkDir $s.Example) $root }
        Push-Location $root
        try {
            $setupLeaf = Split-Path -Leaf $s.Setup
            $setupProj = Join-Path $root "$($s.Setup)\$setupLeaf.wixproj"
            # Only a fixture from an earlier generator has this second project, until -Refresh merges it.
            $legacyBundleProj = Join-Path $root "$($s.Setup).Bundle\$setupLeaf.Bundle.wixproj"

            $solution = $s.Solution
            if ($s.Slnx) { $solution = ConvertTo-Slnx $solution }
            if ($s.Kind -ne 'refresh') {
                Invoke-Checked 'generate' { powershell -NoProfile -ExecutionPolicy Bypass -File $generator -Solution $solution @($s.Args) }
            }

            $build = {
                param([string]$Label)
                if (Test-Path $legacyBundleProj) {
                    # The earlier generator's layout: .msi project, then the bundle project, Release, x64.
                    Invoke-Checked "build ($Label, two projects)" { & $msbuild $legacyBundleProj -restore -p:Configuration=Release -v:minimal -nologo }
                    $exe = Get-ChildItem (Join-Path $root "$($s.Setup).Bundle\bin\x64\Release") -Filter *.exe | Select-Object -First 1
                }
                else {
                    # Debug, as Visual Studio builds by default: the setup must still package the app's Release
                    # build, and bin\Debug must hold the setup .exe and nothing else.
                    Invoke-Checked "build ($Label)" { & $msbuild $setupProj -restore -p:Configuration=Debug -v:minimal -nologo }
                    $out = @(Get-ChildItem (Join-Path $root "$($s.Setup)\bin\Debug") -Recurse -File)
                    if ($out.Count -ne 1 -or $out[0].Extension -ne '.exe') { throw "bin\Debug should hold only the setup .exe, found: $(($out | ForEach-Object Name) -join ', ')" }
                    if (Test-Path (Join-Path $root "$($s.Setup)\obj\payload\Debug")) { throw 'The setup packaged a Debug build of the app.' }
                    $exe = $out[0]
                }
                if (-not $exe) { throw 'No setup .exe was produced.' }
                $dest = Join-Path $installers "$($s.Name)\$Label"
                New-Item -ItemType Directory -Path $dest -Force | Out-Null
                Copy-Item $exe.FullName $dest
                return (Join-Path $dest $exe.Name)
            }

            $installer = & $build 'v1'
            if ($s.Kind -eq 'install') {
                # A solution build must not build the Setup project.
                Remove-Item -Recurse -Force (Join-Path $root "$($s.Setup)\bin")
                Invoke-Checked 'solution build' { & $msbuild $solution -restore -p:Configuration=Release -v:minimal -nologo }
                if (Test-Path (Join-Path $root "$($s.Setup)\bin")) { throw 'The solution build built the Setup project.' }
            }

            if ($SkipInstall -or (-not $s.PerUser -and -not $isAdmin)) {
                $why = $(if ($SkipInstall) { '-SkipInstall' } else { 'needs an elevated prompt' })
                Write-Host "  (not installed: $why)" -ForegroundColor Yellow
                Write-Host '  OK (v1 built only)'
                $notInstalled += $s.Name
                continue
            }

            if ($s.PerUser) { $installDir = Join-Path $env:LOCALAPPDATA "Programs\$($s.Product)" }
            else { $installDir = Join-Path $env:ProgramFiles $s.Product }
            # The upgrade scenario installs somewhere the user chose, as the wizard's Options page would.
            if ($s.Kind -eq 'upgrade') { $installDir = Join-Path $WorkDir "chosen folder\$($s.Product)" }
            $installedExe = Join-Path $installDir $s.Exe
            $desktopLink = Join-Path ([Environment]::GetFolderPath('Desktop')) "$($s.Product).lnk"
            $log = Join-Path $root 'install.log'
            $installed = $installer
            $first = @('/quiet', '/log', "`"$log`"")
            if ($s.Kind -ne 'install') { $first += 'DesktopShortcut=0' }
            if ($s.Kind -eq 'upgrade') { $first += "InstallFolder=`"$installDir`"", 'StartMenuShortcut=0' }
            Invoke-Installer 'install' $installer $first
            if (-not (Test-Path $installedExe)) { throw "$($s.Exe) is not in $installDir after install." }
            $shortcutRoot = $(if ($s.PerUser) { [Environment]::GetFolderPath('Programs') } else { [Environment]::GetFolderPath('CommonPrograms') })
            $startMenuLink = Join-Path $shortcutRoot "$($s.Product).lnk"
            $wantStartMenu = ($s.Kind -ne 'upgrade')
            if ((Test-Path $startMenuLink) -ne $wantStartMenu) { throw "Start menu shortcut present: $(Test-Path $startMenuLink), expected $wantStartMenu." }

            if ($s.Kind -ne 'install') {
                if ($s.Kind -eq 'refresh') {
                    Get-ChildItem $root -Recurse -Directory -Include bin, obj | Remove-Item -Recurse -Force
                    Invoke-Checked 'refresh' { powershell -NoProfile -ExecutionPolicy Bypass -File $generator -Solution $solution -Refresh -Force }
                }
                $file = Join-Path $root $s.Bump[0]
                $text = [System.IO.File]::ReadAllText($file)
                if (-not $text.Contains($s.Bump[1])) { throw "$($s.Bump[0]) has no '$($s.Bump[1])' to bump." }
                [System.IO.File]::WriteAllText($file, $text.Replace($s.Bump[1], $s.Bump[2]))
                # No clean: an incremental build must still pick up the new version (payload.stamp, bundle.stamp).

                $installer = & $build 'v2'
                # No arguments: the new version must find the user's earlier choices on its own.
                Invoke-Installer 'upgrade' $installer @('/quiet', '/log', "`"$log.upgrade`"")
                $installed = $installer

                $entries = @(Get-ArpEntries $s.Product)
                if ($entries.Count -ne 1) { throw "Expected one Add/Remove Programs entry after the upgrade, found $($entries.Count)." }
                if ($entries[0].DisplayVersion -ne $s.NewVersion) { throw "Add/Remove Programs shows $($entries[0].DisplayVersion), expected $($s.NewVersion)." }
                $fileVersion = (Get-Item $installedExe).VersionInfo.FileVersion
                if ($fileVersion -ne $s.NewVersion) { throw "The installed $($s.Exe) is $fileVersion, expected $($s.NewVersion)." }
                if (Test-Path $desktopLink) { throw 'The upgrade created a desktop shortcut the user had declined.' }
                if ((Test-Path $startMenuLink) -ne $wantStartMenu) { throw 'The upgrade changed the Start menu shortcut choice.' }
            }

            Invoke-Installer 'uninstall' $installer @('/uninstall', '/quiet')
            $installed = $null
            if (Test-Path $installedExe) { throw "$installDir still has $($s.Exe) after uninstall." }
            if ($s.Kind -eq 'upgrade' -and (Test-Path $installDir)) { throw "The chosen folder $installDir is left after uninstall." }
            if (@(Get-ArpEntries $s.Product).Count) { throw 'An Add/Remove Programs entry is left after uninstall.' }
            Write-Host '  OK'
        }
        finally { Pop-Location }
    }
    catch {
        Write-Host "  FAILED: $($_.Exception.Message)" -ForegroundColor Red
        # Leave the machine as it was, so the next scenario (or run) starts clean.
        if ($installed) { Start-Process $installed -ArgumentList '/uninstall', '/quiet' -Wait | Out-Null }
        $failures += $s.Name
    }
}

if ($failures) { throw "End-to-end failures: $($failures -join ', ')" }
if ($notInstalled) {
    Write-Host "Passed, but built without installing: $($notInstalled -join ', '). Run elevated, without -SkipInstall, to cover them." -ForegroundColor Yellow
}
else { Write-Host 'All scenarios passed.' }
