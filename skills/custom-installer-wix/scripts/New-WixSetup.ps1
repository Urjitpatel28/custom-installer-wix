<#
.SYNOPSIS
    Adds one WiX Setup project, which builds a branded setup .exe for a .NET app, to its solution, or
    brings one it generated earlier up to date (-Refresh).

.DESCRIPTION
    Creates, next to the app's project folder, <App>.Setup\ with:

        <App>.Setup.wixproj, CustomInstallerWix.targets   the project and its build logic
        Package.wxs                                        the .msi, built internally and embedded
        Bundle.wxs, Assets\                                the setup .exe and its wizard
        License.rtf                                        with -License

    and adds it to the .sln or .slnx so that no solution build (or CI) builds it. Building it puts only
    <Product>Setup.exe in bin\<Configuration>\.

    Without -Refresh it refuses to run when the solution already has a WiX project or the folder already
    exists: a second generation mints a new UpgradeCode, and installers built from it would not upgrade
    the ones already shipped.

    -Refresh rewrites the generated files of the existing Setup project from the current templates
    (WiX version, build logic, wizard theme), keeping what ties new installers to the ones already shipped:
    both UpgradeCodes, product name, manufacturer, scope, install folder and registry key. Changing
    any of those is refused, because the next installer would no longer upgrade the installed one
    cleanly. A setup from an earlier generator that has a separate <App>.Setup.Bundle project is merged
    into <App>.Setup: the bundle project is removed from the solution and its folder deleted. -Refresh
    refuses when the project folders have uncommitted changes (it overwrites hand edits, so the result
    must be a reviewable diff), or are not in git at all, unless -Force.

.EXAMPLE
    .\New-WixSetup.ps1 -Solution .\Contoso.sln -Manufacturer "Contoso Ltd"

.EXAMPLE
    .\New-WixSetup.ps1 -Solution .\Contoso.slnx -Project Contoso.Desktop -Manufacturer "Contoso Ltd" `
        -Scope perUser -License .\LICENSE

.EXAMPLE
    .\New-WixSetup.ps1 -Solution .\Contoso.sln -Refresh
#>
[CmdletBinding()]
param(
    # The .sln or .slnx.
    [Parameter(Mandatory)] [string]$Solution,
    # Name or path of the project to package. Optional when the solution has exactly one candidate.
    [string]$Project,
    [string]$ProductName,
    # Required for a new Setup project; read from the existing one with -Refresh.
    [string]$Manufacturer,
    [string]$Description,
    # perMachine (default for a new project) or perUser. Fixed once installers have shipped.
    [ValidateSet('perMachine', 'perUser')] [string]$Scope,
    # .ico or .png. Defaults to the project's <ApplicationIcon> (or, with -Refresh, the current one).
    [string]$Icon,
    # Build without any icon even if the project has one.
    [switch]$NoIcon,
    # .rtf, or a plain-text licence (LICENSE, .txt, .md) which is converted to RTF.
    [string]$License,
    # Leave the desktop shortcut off unless the installer is told otherwise (DESKTOPSHORTCUT=1, or the
    # bundle's checkbox). A Start menu shortcut is always created.
    [switch]$NoDesktopShortcut,
    [string]$Url,
    # Accepted for compatibility and ignored: the setup .exe is always built now.
    [switch]$Bundle,
    # Update the Setup projects this script generated earlier, keeping their identity.
    [switch]$Refresh,
    # With -Refresh: proceed although the project folders have uncommitted changes or are not in git.
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'CustomInstallerWix.psm1') -Force
$templates = Join-Path (Split-Path -Parent $PSScriptRoot) 'templates'
$generatorVersion = (Get-Module CustomInstallerWix).SessionState.PSVariable.GetValue('GeneratorVersion')
$wixVersion = (Get-Module CustomInstallerWix).SessionState.PSVariable.GetValue('WixVersion')

function ConvertTo-Rtf([string]$Text) {
    <#
      Plain text as a minimal RTF document: escapes, one \par per line, non-ASCII as \u. Licence files
      are usually hard-wrapped at ~80 columns, which breaks up badly in the narrower wizard box, so a
      line break inside a paragraph becomes a space - unless the next line is indented or a list item.
    #>
    $Text = $Text.Replace("`r`n", "`n")
    # \u2022 (a bullet) rather than the character itself: Windows PowerShell reads this BOM-less file as
    # ANSI, which would turn a literal bullet into three other characters.
    $Text = [regex]::Replace($Text, '(?<=\S)[ \t]*\n(?=[^\s\-\*\u2022\d])', ' ')
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('{\rtf1\ansi\ansicpg1252\deff0{\fonttbl{\f0\fswiss Segoe UI;}}\fs18 ')
    foreach ($ch in $Text.ToCharArray()) {
        switch ($ch) {
            '\' { [void]$sb.Append('\\') }
            '{' { [void]$sb.Append('\{') }
            '}' { [void]$sb.Append('\}') }
            "`r" { }
            "`n" { [void]$sb.Append("\par`r`n") }
            default {
                $code = [int]$ch
                if ($code -le 127) { [void]$sb.Append($ch) }
                else {
                    # \u takes a signed 16-bit value.
                    if ($code -gt 32767) { $code -= 65536 }
                    [void]$sb.Append('\u' + $code + '?')
                }
            }
        }
    }
    [void]$sb.Append('}')
    return $sb.ToString()
}

function Get-NetFxRelease([version]$Version) {
    <#
      The lowest NDP\v4\Full "Release" value of a .NET Framework version (learn.microsoft.com, "How to
      determine which .NET Framework versions are installed"), or $null below 4.5, which has no Release
      value to check.
    #>
    if (-not $Version -or $Version.Major -ne 4) { return $null }
    $table = [ordered]@{
        '4.8.1' = 533320; '4.8' = 528040; '4.7.2' = 461808; '4.7.1' = 461308; '4.7' = 460798
        '4.6.2' = 394802; '4.6.1' = 394254; '4.6' = 393295; '4.5.2' = 379893; '4.5.1' = 378675; '4.5' = 378389
    }
    foreach ($k in $table.Keys) { if ($Version -ge [version]$k) { return $table[$k] } }
    return $null
}

function Get-SafeName([string]$Name, [string]$Invalid) {
    $result = $Name
    foreach ($c in $Invalid.ToCharArray()) { $result = $result.Replace([string]$c, '') }
    return $result.Trim()
}

function Get-Attr($Xml, [string]$XPath, [string]$Attribute) {
    <# An attribute of the first element matching $XPath (namespaces ignored via local-name()), or $null. #>
    $node = $Xml.SelectSingleNode($XPath)
    if ($node -and $node.HasAttribute($Attribute)) { return $node.GetAttribute($Attribute) }
    return $null
}

function Read-PreviousSetup([string]$SetupDir, [string]$LegacyBundleDir) {
    <#
      The identity of a generated Setup project, read back from its Package.wxs, .wixproj and Bundle.wxs.
      Bundle.wxs is beside Package.wxs since generator version 3, and in <App>.Setup.Bundle\ before that.
    #>
    $wxsPath = Join-Path $SetupDir 'Package.wxs'
    if (-not (Test-Path -LiteralPath $wxsPath)) { throw "$wxsPath is missing; -Refresh needs it to recover the product's identity." }
    [xml]$wxs = [System.IO.File]::ReadAllText($wxsPath)
    $pkg = $wxs.SelectSingleNode("//*[local-name()='Package']")
    if (-not $pkg) { throw "$wxsPath has no <Package> element." }

    $prev = @{
        ProductName    = $pkg.GetAttribute('Name')
        Manufacturer   = $pkg.GetAttribute('Manufacturer')
        UpgradeCode    = $pkg.GetAttribute('UpgradeCode')
        Scope          = $pkg.GetAttribute('Scope')
        Description    = Get-Attr $wxs "//*[local-name()='Shortcut'][@Id='StartMenuShortcut']" 'Description'
        DesktopDefault = Get-Attr $wxs "//*[local-name()='SetProperty'][@Action='SetDesktopShortcutDefault']" 'Value'
        Url            = Get-Attr $wxs "//*[local-name()='Property'][@Id='ARPURLINFOABOUT']" 'Value'
        InstallDirName = Get-Attr $wxs "//*[local-name()='Directory'][@Id='INSTALLFOLDER']" 'Name'
        RegKey         = Get-Attr $wxs "//*[local-name()='RegistryValue'][@Name='DesktopShortcut']" 'Key'
        Icon           = $null
        License        = $null
        AppProject     = $null
        BundleUpgradeCode = $null
    }
    if (-not $prev.Scope) { $prev.Scope = 'perMachine' }
    foreach ($k in 'ProductName', 'Manufacturer', 'UpgradeCode') {
        if (-not $prev[$k]) { throw "Could not read $k from $wxsPath." }
    }

    $iconFile = Get-Attr $wxs "//*[local-name()='Icon']" 'SourceFile'
    if ($iconFile) {
        $iconPath = [System.IO.Path]::GetFullPath((Join-Path $SetupDir ($iconFile -replace '^\$\(sys\.SOURCEFILEDIR\)', '')))
        if (Test-Path -LiteralPath $iconPath) { $prev.Icon = $iconPath }
    }
    $licensePath = Join-Path $SetupDir 'License.rtf'
    if (Test-Path -LiteralPath $licensePath) { $prev.License = $licensePath }

    $wixproj = Get-ChildItem -LiteralPath $SetupDir -Filter *.wixproj | Select-Object -First 1
    $m = [regex]::Match([System.IO.File]::ReadAllText($wixproj.FullName), "\`$\(MSBuildThisFileDirectory\)(?<rel>[^']+)'")
    if ($m.Success) { $prev.AppProject = [System.IO.Path]::GetFullPath((Join-Path $SetupDir $m.Groups['rel'].Value)) }

    foreach ($bundleWxs in @((Join-Path $SetupDir 'Bundle.wxs'), $(if ($LegacyBundleDir) { Join-Path $LegacyBundleDir 'Bundle.wxs' }))) {
        if (-not $bundleWxs -or -not (Test-Path -LiteralPath $bundleWxs)) { continue }
        [xml]$bxml = [System.IO.File]::ReadAllText($bundleWxs)
        $prev.BundleUpgradeCode = Get-Attr $bxml "//*[local-name()='Bundle']" 'UpgradeCode'
        if (-not $prev.BundleUpgradeCode) { throw "Could not read the bundle's UpgradeCode from $bundleWxs." }
        break
    }
    return $prev
}

function Assert-SafeToOverwrite([string[]]$Dirs) {
    <# -Refresh rewrites files in place; only do it where git can show and undo the result. #>
    $Dirs = @($Dirs | Where-Object { $_ -and (Test-Path -LiteralPath $_) })
    if ($Force -or -not $Dirs.Count) { return }
    $git = Get-Command git -ErrorAction SilentlyContinue
    $inRepo = $false
    $dirty = $null
    if ($git) {
        # Windows PowerShell turns a native command's stderr into an error record, which 'Stop' makes fatal.
        $ErrorActionPreference = 'Continue'
        $null = & git -C $Dirs[0] rev-parse --show-toplevel 2>$null
        $inRepo = ($LASTEXITCODE -eq 0)
        if ($inRepo) { $dirty = & git -C $Dirs[0] status --porcelain -- @Dirs 2>$null }
        $ErrorActionPreference = 'Stop'
    }
    if (-not $inRepo) { throw "$($Dirs -join ', ') is not in a git repository. -Refresh overwrites generated files in place; back them up and pass -Force." }
    if ($dirty) { throw "Uncommitted changes in files the refresh rewrites:`n$($dirty -join "`n")`nCommit or stash them first, so the refresh shows as its own diff (or pass -Force)." }
}

# --- The solution and the app ---------------------------------------------------------------------

$Solution = (Resolve-Path -LiteralPath $Solution).ProviderPath
if ([System.IO.Path]::GetExtension($Solution) -notin '.sln', '.slnx') { throw "$Solution is not a .sln or .slnx file." }
$solutionDir = Split-Path -Parent $Solution
$projects = @(Get-SolutionProjects -SolutionPath $Solution)

$infos = @()
foreach ($p in $projects) {
    if ([System.IO.Path]::GetExtension($p.Path) -notin '.csproj', '.vbproj', '.fsproj') { continue }
    if (-not (Test-Path -LiteralPath $p.Path)) { continue }
    $infos += Get-ProjectInfo -ProjectPath $p.Path
}

$existingWix = @($projects | Where-Object { $_.Path -like '*.wixproj' } | ForEach-Object { Get-SetupProjectInfo -ProjectPath $_.Path })
$prev = $null
$previousVersion = $null
$legacyBundle = $null

if ($Refresh) {
    if (-not $existingWix.Count) { throw "$Solution has no WiX project to refresh. Run without -Refresh to create one." }
    $foreign = @($existingWix | Where-Object { -not $_.Generated })
    if ($foreign.Count) { throw "$($foreign[0].Path) was not generated by custom-installer-wix, so -Refresh cannot tell what to keep. Edit it by hand." }
    # The Setup project is the one with Package.wxs beside it; an earlier generator's separate
    # <App>.Setup.Bundle project is merged into it.
    $setups = @($existingWix | Where-Object { Test-Path -LiteralPath (Join-Path (Split-Path -Parent $_.Path) 'Package.wxs') })
    if ($setups.Count -ne 1) { throw "Expected one generated Setup project (with Package.wxs) in $Solution, found $($setups.Count)." }
    $others = @($existingWix | Where-Object { $_.Path -ne $setups[0].Path })
    if (@($others | Where-Object { $_.Kind -ne 'Bundle' }).Count -or $others.Count -gt 1) {
        throw "Unexpected WiX projects in $Solution besides $($setups[0].Path): $(($others | ForEach-Object Path) -join ', '). Edit them by hand."
    }
    if ($others.Count) { $legacyBundle = $others[0] }

    $setupDir = Split-Path -Parent $setups[0].Path
    $setupName = [System.IO.Path]::GetFileNameWithoutExtension($setups[0].Path)
    $legacyBundleDir = $(if ($legacyBundle) { Split-Path -Parent $legacyBundle.Path } else { $null })
    $previousVersion = ($existingWix | Measure-Object -Property GeneratorVersion -Minimum).Minimum

    $prev = Read-PreviousSetup $setupDir $legacyBundleDir

    # Identity is what makes the next installer an upgrade of the installed one.
    $guards = @(
        @('ProductName', $ProductName, 'it names the install folder and the Add/Remove Programs entry'),
        @('Manufacturer', $Manufacturer, 'it is part of the registry key that remembers the user''s choices'),
        @('Scope', $Scope, 'a per-user and a per-machine install never upgrade each other; both would stay installed')
    )
    foreach ($g in $guards) {
        if ($g[1] -and $g[1] -ne $prev[$g[0]]) {
            throw "-Refresh keeps $($g[0]) '$($prev[$g[0]])'; refusing to change it to '$($g[1])': $($g[2]). If that is really intended, edit Package.wxs by hand."
        }
    }
    $ProductName = $prev.ProductName
    $Manufacturer = $prev.Manufacturer
    $Scope = $prev.Scope
    if (-not $Description) { $Description = $prev.Description }
    if (-not $Url) { $Url = $prev.Url }

    $app = $null
    if ($Project) { $app = $infos | Where-Object { $_.Name -eq $Project } | Select-Object -First 1 }
    elseif ($prev.AppProject) { $app = $infos | Where-Object { $_.Path -eq $prev.AppProject } | Select-Object -First 1 }
    if (-not $app) { throw "Could not find the packaged app project ($($prev.AppProject)) in $Solution. Pass -Project." }

    # Merging an earlier generator's bundle project edits the solution file too.
    Assert-SafeToOverwrite @($setupDir, $legacyBundleDir, $(if ($legacyBundle) { $Solution }))
}
else {
    if ($existingWix.Count) {
        throw "The solution already has a WiX project ($($existingWix[0].Path)). Generating another would mint a new UpgradeCode, and its installers would not upgrade the ones already shipped. To bring a project this skill generated up to date, run again with -Refresh; otherwise edit it by hand."
    }
    if (-not $Manufacturer) { throw "-Manufacturer is required." }
    if (-not $Scope) { $Scope = 'perMachine' }

    if ($Project) {
        $app = $infos | Where-Object { $_.Name -eq $Project -or $_.Path -eq [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $Project)) } | Select-Object -First 1
        if (-not $app) { throw "No project named or at '$Project' in $Solution." }
    }
    else {
        $candidates = @($infos | Where-Object { $_.IsExecutable -and -not $_.IsTest })
        if ($candidates.Count -eq 0) { throw "No WinExe/Exe project in $Solution." }
        if ($candidates.Count -gt 1) { throw "Several apps could be packaged: $(($candidates | ForEach-Object Name) -join ', '). Pass -Project." }
        $app = $candidates[0]
    }

    $appDir = Split-Path -Parent $app.Path
    $parentDir = Split-Path -Parent $appDir
    if ($appDir -eq $solutionDir -or -not $parentDir.StartsWith($solutionDir, [StringComparison]::OrdinalIgnoreCase)) { $parentDir = $solutionDir }

    $setupName = "$($app.Name).Setup"
    $setupDir = Join-Path $parentDir $setupName
    if (Test-Path -LiteralPath $setupDir) { throw "$setupDir already exists. Remove it first if it is a leftover; if it is a real Setup project, edit it instead." }
}
if (-not $app.IsExecutable) { throw "$($app.Name) is a $($app.OutputType) project; only WinExe/Exe projects can be packaged." }
if ($app.IsMsixPackaged) {
    throw "$($app.Name) is packaged as MSIX (it has no <WindowsPackageType>None</WindowsPackageType>). A packaged app runs only from its .msix, which an .msi cannot install: ship the .msix itself, or make the app unpackaged and run this again."
}
if ($app.IsModernDotNet -and $app.RuntimeIdentifier -notin 'win-x64', 'win-x86') {
    throw "$($app.Name) is built for $($app.RuntimeIdentifier). The Setup project packages x64 and x86 apps only."
}

if (-not $ProductName) {
    $ProductName = $app.Product
    if (-not $ProductName) { $ProductName = $app.Title }
    if (-not $ProductName) { $ProductName = $app.AssemblyName }
}
if (-not $Description) {
    $Description = $app.Description
    if (-not $Description) { $Description = $ProductName }
}

# --- Icon and licence ----------------------------------------------------------------------------

$iconSource = $null
if (-not $NoIcon) {
    if ($Icon) {
        if (-not (Test-Path -LiteralPath $Icon)) { throw "Icon not found: $Icon" }
        $iconSource = (Resolve-Path -LiteralPath $Icon).ProviderPath
    }
    elseif ($prev -and $prev.Icon) { $iconSource = $prev.Icon }
    elseif ($app.IconExists) { $iconSource = $app.ApplicationIcon }
}

$licenseText = $null
$writeLicense = $false
if ($License) {
    if (-not (Test-Path -LiteralPath $License)) { throw "License not found: $License" }
    $License = (Resolve-Path -LiteralPath $License).ProviderPath
    if ([System.IO.Path]::GetExtension($License) -eq '.rtf') { $licenseText = [System.IO.File]::ReadAllText($License) }
    else { $licenseText = ConvertTo-Rtf ([System.IO.File]::ReadAllText($License)) }
    $writeLicense = $true
}
elseif ($prev -and $prev.License) { $licenseText = [System.IO.File]::ReadAllText($prev.License) }
elseif (-not $prev) {
    # A new project always has a licence page. Until the developer puts their agreement in License.rtf,
    # it says only this; a refreshed project that shipped without a licence stays without one.
    $licenseText = ConvertTo-Rtf 'LICENSE'
    $writeLicense = $true
}

# --- Values --------------------------------------------------------------------------------------

$outputName = (Get-SafeName $ProductName (-join [System.IO.Path]::GetInvalidFileNameChars())) -replace '\s+', ''
$installDirName = Get-SafeName $ProductName (-join [System.IO.Path]::GetInvalidFileNameChars())
$regKey = 'Software\' + (Get-SafeName $Manufacturer '\') + '\' + (Get-SafeName $ProductName '\')
$desktopDefault = $(if ($NoDesktopShortcut) { '0' } else { '1' })
$upgradeCode = [guid]::NewGuid().ToString().ToUpperInvariant()
$bundleUpgradeCode = [guid]::NewGuid().ToString().ToUpperInvariant()
if ($prev) {
    if ($prev.InstallDirName) { $installDirName = $prev.InstallDirName }
    if ($prev.RegKey) { $regKey = $prev.RegKey }
    if ($prev.DesktopDefault -and -not $NoDesktopShortcut) { $desktopDefault = $prev.DesktopDefault }
    $upgradeCode = $prev.UpgradeCode
    if ($prev.BundleUpgradeCode) { $bundleUpgradeCode = $prev.BundleUpgradeCode }
}
$exeName = "$($app.AssemblyName).exe"
$perMachine = ($Scope -eq 'perMachine')
$netFxRelease = $null
if (-not $app.IsModernDotNet) { $netFxRelease = Get-NetFxRelease $app.NetFxVersion }

$values = @{
    WIX_VERSION         = $wixVersion
    GENERATOR_VERSION   = $generatorVersion
    PRODUCT_NAME        = ConvertTo-XmlText $ProductName
    MANUFACTURER        = ConvertTo-XmlText $Manufacturer
    DESCRIPTION         = ConvertTo-XmlText $Description
    UPGRADE_CODE        = $upgradeCode
    BUNDLE_UPGRADE_CODE = $bundleUpgradeCode
    SCOPE               = $Scope
    PER_MACHINE         = $perMachine
    PER_USER            = -not $perMachine
    MODERN              = $app.IsModernDotNet
    APP_PROJECT_NAME    = $app.Name
    APP_PROJECT_REL     = Get-RelativePath $setupDir $app.Path
    APP_ASSEMBLY_NAME   = ConvertTo-XmlText $app.AssemblyName
    APP_PLATFORM        = $(if ($app.Platform) { $app.Platform } else { 'AnyCPU' })
    APP_RUNTIME_IDENTIFIER = $app.RuntimeIdentifier
    APP_RUNTIME_PLATFORM = $(if ($app.RuntimeIdentifier) { $app.RuntimeIdentifier -replace '^win-', '' } else { '' })
    HAS_APP_TARGET_FRAMEWORK = [bool]$app.PackageTargetFramework
    APP_TARGET_FRAMEWORK = $app.PackageTargetFramework
    WINUI               = ($app.Kind -eq 'winui')
    HAS_NETFX           = [bool]$netFxRelease
    NETFX_RELEASE       = $netFxRelease
    NETFX_VERSION       = $(if ($app.NetFxVersion) { $app.NetFxVersion.ToString() } else { '' })
    EXE_NAME            = ConvertTo-XmlText $exeName
    SETUP_NAME          = $setupName
    OUTPUT_NAME         = $outputName
    BUNDLE_OUTPUT_NAME  = "$($outputName)Setup"
    INSTALL_DIR_NAME    = ConvertTo-XmlText $installDirName
    REG_KEY             = ConvertTo-XmlText $regKey
    REG_ROOT            = $(if ($perMachine) { 'HKLM' } else { 'HKCU' })
    DESKTOP_DEFAULT     = $desktopDefault
    HAS_ICON            = [bool]$iconSource
    HAS_LICENSE         = [bool]$licenseText
    HAS_URL             = [bool]$Url
    URL                 = ConvertTo-XmlText $Url
    ICON_REL            = ''
    INSTALL_MESSAGE     = $(if ($perMachine) { 'Installs for all users of this computer. Windows will ask for administrator permission.' } else { 'Installs for you only, under your user profile. No administrator rights needed.' })
    INSTALL_FOLDER_DEFAULT = ConvertTo-XmlText $(if ($perMachine) { "[ProgramFiles64Folder]$installDirName" } else { "[LocalAppDataFolder]Programs\$installDirName" })
    # A per-user install runs without administrator rights, so a folder like Program Files would fail.
    INSTALL_FOLDER_HINT = $(if ($perMachine) { 'The folder is created if it does not exist.' } else { 'Choose a folder you can write to, such as one under your user profile.' })
}

function Write-Template([string]$TemplatePath, [string]$Destination, [hashtable]$Values) {
    Write-TextFile $Destination (Expand-Template ([System.IO.File]::ReadAllText($TemplatePath)) $Values)
}

# --- The Setup project ---------------------------------------------------------------------------

New-Item -ItemType Directory -Path $setupDir -Force | Out-Null
$assets = Join-Path $setupDir 'Assets'

if ($iconSource) {
    if ([System.IO.Path]::GetExtension($iconSource) -eq '.ico') {
        # Referenced where it is, so a new app icon reaches the installer on the next build.
        $values.ICON_REL = Get-RelativePath $setupDir $iconSource
    }
    else {
        $converted = Join-Path $setupDir 'AppIcon.ico'
        & (Join-Path $PSScriptRoot 'ConvertTo-SetupAssets.ps1') -Kind Ico -Source $iconSource -IcoOut $converted | Out-Null
        $values.ICON_REL = 'AppIcon.ico'
        $iconSource = $converted
    }
    # Banner.bmp and Dialog.bmp, for the .msi's own dialogs when it is run on its own.
    & (Join-Path $PSScriptRoot 'ConvertTo-SetupAssets.ps1') -Kind Msi -Source $iconSource -OutDir $assets -ProductName $ProductName | Out-Null
}
# The wizard's images.
$assetArgs = @{ Kind = 'Bundle'; OutDir = $assets; ProductName = $ProductName; Manufacturer = $Manufacturer }
if ($iconSource) { $assetArgs.Source = $iconSource }
& (Join-Path $PSScriptRoot 'ConvertTo-SetupAssets.ps1') @assetArgs | Out-Null

if ($licenseText -and ($writeLicense -or -not (Test-Path -LiteralPath (Join-Path $setupDir 'License.rtf')))) {
    Write-TextFile (Join-Path $setupDir 'License.rtf') $licenseText
}

$setupProjectPath = Join-Path $setupDir "$setupName.wixproj"
Write-Template (Join-Path $templates 'msi\Setup.wixproj') $setupProjectPath $values
Write-Template (Join-Path $templates 'msi\Package.wxs') (Join-Path $setupDir 'Package.wxs') $values
Write-TextFile (Join-Path $setupDir 'CustomInstallerWix.targets') ([System.IO.File]::ReadAllText((Join-Path $templates 'msi\CustomInstallerWix.targets')))
Write-Template (Join-Path $templates 'bundle\Bundle.wxs') (Join-Path $setupDir 'Bundle.wxs') $values
Write-Template (Join-Path $templates 'bundle\Theme.xml') (Join-Path $assets 'Theme.xml') $values
Write-Template (Join-Path $templates 'bundle\Theme.wxl') (Join-Path $assets 'Theme.wxl') $values

if (-not ($projects | Where-Object { $_.Path -eq $setupProjectPath })) {
    Add-SolutionProject -SolutionPath $Solution -ProjectName $setupName `
        -ProjectRelativePath (Get-RelativePath $solutionDir $setupProjectPath) -DependsOn @($app.Path)
}

# An earlier generator's separate bundle project: its UpgradeCode now lives in Bundle.wxs above.
$merged = $null
if ($legacyBundle) {
    Remove-SolutionProject -SolutionPath $Solution -ProjectPath $legacyBundle.Path
    Remove-Item -LiteralPath (Split-Path -Parent $legacyBundle.Path) -Recurse -Force
    $merged = Split-Path -Parent $legacyBundle.Path
}

# --- Report --------------------------------------------------------------------------------------

[pscustomobject]@{
    App               = $app.Name
    Payload           = $(if ($app.IsModernDotNet) { "dotnet publish, self-contained $($app.RuntimeIdentifier), Release" } else { "build output ($($values.APP_PLATFORM)), Release" }) + $(if ($app.PackageTargetFramework) { ", $($app.PackageTargetFramework)" } else { '' })
    NetFxRequired     = $(if ($netFxRelease) { $values.NETFX_VERSION } else { $null })
    ProductName       = $ProductName
    Manufacturer      = $Manufacturer
    Scope             = $Scope
    Icon              = $iconSource
    License           = [bool]$licenseText
    UpgradeCode       = $values.UPGRADE_CODE
    BundleUpgradeCode = $values.BUNDLE_UPGRADE_CODE
    WixVersion        = $wixVersion
    Refreshed         = [bool]$Refresh
    PreviousGeneratorVersion = $previousVersion
    MergedBundleProject = $merged
    SetupProject      = $setupProjectPath
    Output            = Join-Path $setupDir "bin\<Configuration>\$($outputName)Setup.exe"
    Build             = "msbuild `"$setupProjectPath`" -restore -p:Configuration=Release"
    Review            = $(if ($Refresh) { "git status; git diff -- `"$setupDir`"" } else { $null })
    Created           = @(Get-ChildItem -LiteralPath $setupDir -Recurse -File | Where-Object { $_.FullName -notmatch '\\(bin|obj)\\' } | ForEach-Object FullName)
} | ConvertTo-Json -Depth 4
