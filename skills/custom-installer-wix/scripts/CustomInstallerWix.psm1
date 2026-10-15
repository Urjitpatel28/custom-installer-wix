# Shared helpers for Find-StartupProject.ps1 and New-WixSetup.ps1.
# Windows PowerShell 5.1 compatible: no ternaries, no ?? and no pipeline-chain operators.

Set-StrictMode -Version 2.0

# Project type GUIDs as they appear in a .sln. Only the WiX one is written; the others are matched.
$script:WixProjectTypeGuid = '{B7DD6F7E-DEF8-4E67-B5B7-07EF123DB6F0}'
$script:SolutionFolderTypeGuid = '{2150E333-8FDC-42A3-9474-1A3956D46DE8}'

# Stamped into every generated .wixproj as <CustomInstallerWixVersion>. Bump it whenever the templates
# change in a way an existing project should pick up with New-WixSetup.ps1 -Refresh. Projects from
# before the stamp (WiX 5.0.2) count as version 1. Version 2 had a separate <App>.Setup.Bundle project;
# version 3 builds the .msi and the setup .exe from one <App>.Setup project; version 4 adds the install
# folder choice, the Start menu checkbox and the always-present licence page; version 5 adds the
# .NET Framework check, opt-in code signing and the publish target framework/runtime.
$script:GeneratorVersion = 5

# Every WixToolset.* package the templates reference. They must all match, or the build fails with WIX6101.
$script:WixVersion = '6.0.2'

function Test-SlnxPath([string]$SolutionPath) {
    return [System.IO.Path]::GetExtension($SolutionPath) -eq '.slnx'
}

function Get-SolutionProjects {
    <#
      Every project entry in a .sln or .slnx: name, absolute path, project GUID (.sln only; $null for
      .slnx, which has none), type GUID. Solution folders are skipped.
    #>
    param([Parameter(Mandatory)] [string]$SolutionPath)

    $solutionDir = Split-Path -Parent (Resolve-Path -LiteralPath $SolutionPath).ProviderPath
    if (Test-SlnxPath $SolutionPath) {
        [xml]$xml = [System.IO.File]::ReadAllText($SolutionPath)
        foreach ($node in $xml.SelectNodes('//Project')) {
            $type = $node.GetAttribute('Type')
            if ($type -and -not $type.StartsWith('{')) { $type = '{' + $type + '}' }
            $path = $node.GetAttribute('Path')
            [pscustomobject]@{
                Name     = [System.IO.Path]::GetFileNameWithoutExtension($path)
                Path     = [System.IO.Path]::GetFullPath((Join-Path $solutionDir $path.Replace('/', '\')))
                Guid     = $null
                TypeGuid = $type.ToUpperInvariant()
            }
        }
        return
    }

    $pattern = '^Project\("(?<type>\{[^}]+\})"\)\s*=\s*"(?<name>[^"]+)",\s*"(?<path>[^"]+)",\s*"(?<guid>\{[^}]+\})"'
    foreach ($line in [System.IO.File]::ReadAllLines($SolutionPath)) {
        $m = [regex]::Match($line, $pattern)
        if (-not $m.Success) { continue }
        if ($m.Groups['type'].Value -eq $script:SolutionFolderTypeGuid) { continue }
        [pscustomobject]@{
            Name     = $m.Groups['name'].Value
            Path     = [System.IO.Path]::GetFullPath((Join-Path $solutionDir $m.Groups['path'].Value))
            Guid     = $m.Groups['guid'].Value.ToUpperInvariant()
            TypeGuid = $m.Groups['type'].Value.ToUpperInvariant()
        }
    }
}

function Get-XmlValue {
    <# First non-empty value of a property element anywhere in a project file, ignoring the MSBuild namespace. #>
    param([xml]$Xml, [string]$Name)
    $node = $Xml.SelectNodes("//*[local-name()='$Name']") | Where-Object { $_.InnerText.Trim() } | Select-Object -First 1
    if ($node) { return $node.InnerText.Trim() }
    return $null
}

function Get-PlatformValue {
    <#
      A property that decides what the app is built for (PlatformTarget, RuntimeIdentifier). An unconditional
      one is what every build gets. Otherwise the conditional values count only when they all agree:
      Visual Studio writes one per configuration|platform, and the Setup project builds AnyCPU Release.
    #>
    param([xml]$Xml, [string]$Name)
    $unconditional = $Xml.SelectNodes("//*[local-name()='PropertyGroup'][not(@Condition)]/*[local-name()='$Name'][not(@Condition)]") |
        Where-Object { $_.InnerText.Trim() } | Select-Object -First 1
    if ($unconditional) { return $unconditional.InnerText.Trim() }
    $values = @($Xml.SelectNodes("//*[local-name()='$Name']") | ForEach-Object { $_.InnerText.Trim() } | Where-Object { $_ } |
        ForEach-Object { $_.ToLowerInvariant() } | Sort-Object -Unique)
    if ($values.Count -eq 1) { return $values[0] }
    return $null
}

function Get-TfmVersion([string]$Tfm) {
    <# net8.0-windows -> 8.0, net48 -> 4.8, net472 -> 4.7.2; $null for anything else (netstandard, $(Prop)). #>
    if ($Tfm -match '^net(\d+)\.(\d+)') { return [version]"$($Matches[1]).$($Matches[2])" }
    if ($Tfm -match '^net(\d)(\d)(\d)?$') {
        if ($Matches[3]) { return [version]"$($Matches[1]).$($Matches[2]).$($Matches[3])" }
        return [version]"$($Matches[1]).$($Matches[2])"
    }
    return $null
}

function Get-AssemblyInfoValue {
    <# Reads [assembly: Name("value")] from Properties\AssemblyInfo.cs (or My Project\AssemblyInfo.vb) of a legacy project. #>
    param([string]$ProjectDir, [string]$Attribute)
    foreach ($candidate in @('Properties\AssemblyInfo.cs', 'My Project\AssemblyInfo.vb', 'AssemblyInfo.cs')) {
        $file = Join-Path $ProjectDir $candidate
        if (-not (Test-Path -LiteralPath $file)) { continue }
        $m = [regex]::Match([System.IO.File]::ReadAllText($file), "(?m)^\s*[\[<]\s*[Aa]ssembly\s*:\s*$Attribute\s*\(\s*""(?<v>[^""]*)""")
        if ($m.Success -and $m.Groups['v'].Value) { return $m.Groups['v'].Value }
    }
    return $null
}

function Get-ProjectInfo {
    <#
      Everything the generator needs to know about one .csproj/.vbproj/.fsproj. Static reading only -
      nothing is built - so values that come from Directory.Build.props or are computed by MSBuild are
      missed; the Setup project reads the real version from the built assembly instead.
    #>
    param([Parameter(Mandatory)] [string]$ProjectPath)

    $ProjectPath = [System.IO.Path]::GetFullPath($ProjectPath)
    $projectDir = Split-Path -Parent $ProjectPath
    [xml]$xml = [System.IO.File]::ReadAllText($ProjectPath)
    $root = $xml.DocumentElement

    $sdk = $root.GetAttribute('Sdk')
    if (-not $sdk) {
        $sdkImport = $xml.SelectNodes("//*[local-name()='Import'][@Sdk]") | Select-Object -First 1
        if ($sdkImport) { $sdk = $sdkImport.GetAttribute('Sdk') }
    }
    $isSdkStyle = [bool]$sdk

    $outputType = Get-XmlValue $xml 'OutputType'
    if (-not $outputType) { $outputType = 'Library' }

    $assemblyName = Get-XmlValue $xml 'AssemblyName'
    if (-not $assemblyName) { $assemblyName = [System.IO.Path]::GetFileNameWithoutExtension($ProjectPath) }

    $targetFrameworks = Get-XmlValue $xml 'TargetFrameworks'
    if (-not $targetFrameworks) { $targetFrameworks = Get-XmlValue $xml 'TargetFramework' }
    if (-not $targetFrameworks) {
        $tfv = Get-XmlValue $xml 'TargetFrameworkVersion'
        if ($tfv) { $targetFrameworks = 'net' + ($tfv.TrimStart('v') -replace '\.', '') }
    }

    # A modern .NET target (net5.0+, including net8.0-windows) is published self-contained; anything
    # else is .NET Framework and shipped from its build output.
    $tfms = @()
    if ($targetFrameworks) {
        $tfms = @($targetFrameworks -split ';' | ForEach-Object { $_.Trim() } | Where-Object { Get-TfmVersion $_ })
    }
    $modernTfms = @($tfms | Where-Object { (Get-TfmVersion $_).Major -ge 5 })
    $isModernDotNet = ($isSdkStyle -and $modernTfms.Count -gt 0)

    # A project with several target frameworks has to be told which one to package (dotnet publish fails
    # without -f): the newest of the kind that is packaged. $null for a single-target project, so a later
    # retarget of the app needs no edit in the Setup project.
    $packageTfm = $null
    if ($isSdkStyle -and $tfms.Count -gt 1) {
        $pool = $tfms
        if ($isModernDotNet) { $pool = $modernTfms }
        $packageTfm = $pool | Sort-Object { Get-TfmVersion $_ } | Select-Object -Last 1
    }
    # The .NET Framework version the app needs, for the setup's check on the target machine.
    $netFxVersion = $null
    if (-not $isModernDotNet) {
        $fxTfm = $packageTfm
        if (-not $fxTfm -and $tfms.Count) { $fxTfm = $tfms[0] }
        if ($fxTfm) { $netFxVersion = Get-TfmVersion $fxTfm }
    }

    $icon = Get-XmlValue $xml 'ApplicationIcon'
    $iconPath = $null
    if ($icon) { $iconPath = [System.IO.Path]::GetFullPath((Join-Path $projectDir $icon)) }

    $referenceNames = @($xml.SelectNodes("//*[local-name()='PackageReference' or local-name()='Reference']") |
        ForEach-Object { $_.GetAttribute('Include') })
    $isTest = [bool](Get-XmlValue $xml 'IsTestProject' | Where-Object { $_ -eq 'true' })
    foreach ($ref in $referenceNames) {
        if ($ref -match '^(xunit|nunit|MSTest|Microsoft\.NET\.Test\.Sdk|Microsoft\.VisualStudio\.(QualityTools\.)?UnitTestFramework)') { $isTest = $true }
    }

    $kind = 'other'
    # WinUI first: its project files carry <Page> items too.
    if ((Get-XmlValue $xml 'UseWinUI') -eq 'true') { $kind = 'winui' }
    elseif ((Get-XmlValue $xml 'UseWPF') -eq 'true' -or $xml.SelectNodes("//*[local-name()='Page' or local-name()='ApplicationDefinition']").Count -gt 0 -or $referenceNames -contains 'PresentationFramework') { $kind = 'wpf' }
    elseif ((Get-XmlValue $xml 'UseWindowsForms') -eq 'true' -or $referenceNames -contains 'System.Windows.Forms') { $kind = 'winforms' }
    elseif ($sdk -like 'Microsoft.NET.Sdk.Web*') { $kind = 'web' }
    elseif ($sdk -like 'Microsoft.NET.Sdk.Worker*') { $kind = 'worker' }
    elseif ($outputType -eq 'Exe') { $kind = 'console' }

    # Legacy projects only build for the platforms they declare a PropertyGroup for. The Setup
    # project builds the app with this one, so an AnyCPU-only project is never asked for x64.
    $platform = $null
    if (-not $isSdkStyle) {
        $conditions = @($xml.SelectNodes("//*[local-name()='PropertyGroup'][@Condition]") | ForEach-Object { $_.GetAttribute('Condition') })
        if ($conditions | Where-Object { $_ -match '\|\s*x64' }) { $platform = 'x64' }
        elseif ($conditions | Where-Object { $_ -match '\|\s*AnyCPU' }) { $platform = 'AnyCPU' }
        elseif ($conditions | Where-Object { $_ -match '\|\s*x86' }) { $platform = 'x86' }
        else { $platform = 'AnyCPU' }
    }

    # The runtime a modern app is published for. An explicit win-* RuntimeIdentifier wins; otherwise
    # PlatformTarget decides (publishing an x86 app for win-x64 fails with NETSDK1032).
    $runtimeIdentifier = $null
    if ($isModernDotNet) {
        $rid = Get-PlatformValue $xml 'RuntimeIdentifier'
        if ($rid -and $rid -like 'win-*') { $runtimeIdentifier = $rid.ToLowerInvariant() }
        else {
            switch (Get-PlatformValue $xml 'PlatformTarget') {
                'x86' { $runtimeIdentifier = 'win-x86' }
                'arm64' { $runtimeIdentifier = 'win-arm64' }
                default { $runtimeIdentifier = 'win-x64' }
            }
        }
    }

    # WinUI 3 apps are MSIX-packaged unless <WindowsPackageType>None</WindowsPackageType>. A packaged app
    # runs only from its MSIX, which an .msi cannot install.
    $windowsPackageType = Get-XmlValue $xml 'WindowsPackageType'
    $isMsixPackaged = (($kind -eq 'winui' -and $windowsPackageType -ne 'None') -or $windowsPackageType -eq 'MSIX')

    $company = Get-XmlValue $xml 'Company'
    $product = Get-XmlValue $xml 'Product'
    $title = Get-XmlValue $xml 'AssemblyTitle'
    $description = Get-XmlValue $xml 'Description'
    $version = Get-XmlValue $xml 'Version'
    if (-not $isSdkStyle) {
        if (-not $company) { $company = Get-AssemblyInfoValue $projectDir 'AssemblyCompany' }
        if (-not $product) { $product = Get-AssemblyInfoValue $projectDir 'AssemblyProduct' }
        if (-not $title) { $title = Get-AssemblyInfoValue $projectDir 'AssemblyTitle' }
        if (-not $description) { $description = Get-AssemblyInfoValue $projectDir 'AssemblyDescription' }
        if (-not $version) { $version = Get-AssemblyInfoValue $projectDir 'AssemblyVersion' }
    }

    [pscustomobject]@{
        Name             = [System.IO.Path]::GetFileNameWithoutExtension($ProjectPath)
        Path             = $ProjectPath
        Sdk              = $sdk
        IsSdkStyle       = $isSdkStyle
        IsModernDotNet   = $isModernDotNet
        OutputType       = $outputType
        IsExecutable     = ($outputType -eq 'WinExe' -or $outputType -eq 'Exe')
        Kind             = $kind
        IsTest           = $isTest
        TargetFrameworks = $targetFrameworks
        PackageTargetFramework = $packageTfm
        NetFxVersion     = $netFxVersion
        RuntimeIdentifier = $runtimeIdentifier
        IsMsixPackaged   = $isMsixPackaged
        Platform         = $platform
        AssemblyName     = $assemblyName
        ApplicationIcon  = $iconPath
        IconExists       = [bool]($iconPath -and (Test-Path -LiteralPath $iconPath))
        Company          = $company
        Product          = $product
        Title            = $title
        Description      = $description
        Version          = $version
    }
}

function Expand-Template {
    <#
      Fills a template. {{NAME}} is replaced by $Values.NAME; {{#FLAG}}...{{/FLAG}} is kept only when
      $Values.FLAG is truthy and {{^FLAG}}...{{/FLAG}} only when it is not. Sections may nest but a flag
      may not nest inside itself. An unknown {{NAME}} is an error rather than a silent blank.
    #>
    param([Parameter(Mandatory)] [string]$Text, [Parameter(Mandatory)] [hashtable]$Values)

    # A section tag alone on its line takes the line with it, so sections leave no blank lines behind.
    $Text = [regex]::Replace($Text, '(?m)^[ \t]*(\{\{[#^/][A-Z0-9_]+\}\})[ \t]*\r?\n', '$1')

    $sectionPattern = '(?s)\{\{(?<op>[#^])(?<flag>[A-Z0-9_]+)\}\}(?<body>.*?)\{\{/\k<flag>\}\}'
    do {
        $before = $Text
        $Text = [regex]::Replace($Text, $sectionPattern, {
                param($m)
                $on = [bool]$Values[$m.Groups['flag'].Value]
                if ($m.Groups['op'].Value -eq '^') { $on = -not $on }
                if ($on) { return $m.Groups['body'].Value }
                return ''
            })
    } while ($Text -ne $before)

    $missing = New-Object System.Collections.Generic.List[string]
    $Text = [regex]::Replace($Text, '\{\{(?<name>[A-Z0-9_]+)\}\}', {
            param($m)
            $name = $m.Groups['name'].Value
            if ($Values.ContainsKey($name)) { return [string]$Values[$name] }
            $missing.Add($name)
            return $m.Value
        })
    if ($missing.Count) { throw "Template values missing: $(($missing | Sort-Object -Unique) -join ', ')" }
    return $Text
}

function ConvertTo-XmlText {
    <# Escapes a value for use inside an XML attribute or element. #>
    param([string]$Value)
    return [System.Security.SecurityElement]::Escape($Value)
}

function Get-RelativePath {
    <# Path of $To relative to the directory $FromDir, with backslashes. #>
    param([string]$FromDir, [string]$To)
    $fromUri = New-Object System.Uri(([System.IO.Path]::GetFullPath($FromDir).TrimEnd('\') + '\'))
    $toUri = New-Object System.Uri([System.IO.Path]::GetFullPath($To))
    return [System.Uri]::UnescapeDataString($fromUri.MakeRelativeUri($toUri).ToString()).Replace('/', '\')
}

function Write-TextFile {
    <# UTF-8 without a BOM, CRLF line endings - what Visual Studio writes for these file types. #>
    param([string]$Path, [string]$Text)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $Text = [regex]::Replace($Text, '\r?\n', "`r`n")
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

function Read-SolutionText([string]$SolutionPath) {
    <# The file's text plus what is needed to write it back unchanged: BOM and line ending. #>
    $bytes = [System.IO.File]::ReadAllBytes($SolutionPath)
    $text = [System.IO.File]::ReadAllText($SolutionPath)
    $nl = "`n"
    if ($text.Contains("`r`n")) { $nl = "`r`n" }
    return [pscustomobject]@{
        Text   = $text
        NewLine = $nl
        HasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    }
}

function Add-SolutionProject {
    <#
      Adds a WiX project to a .sln or .slnx without making it part of any solution build, so "Build
      Solution" and CI's msbuild of the solution skip it:
        .sln   every solution configuration gets an ActiveCfg line (so Visual Studio knows which project
               configuration to show) and no Build.0 line.
        .slnx  <Build Project="false" /> and <Platform Project="x64" />, as Visual Studio writes them.
      DependsOn (absolute project paths already in the solution) orders a build of this project after
      them in Visual Studio: a ProjectDependencies section (.sln) or BuildDependency elements (.slnx).
      Keeps the file's own line endings and encoding (BOM included).
    #>
    param(
        [Parameter(Mandatory)] [string]$SolutionPath,
        [Parameter(Mandatory)] [string]$ProjectName,
        [Parameter(Mandatory)] [string]$ProjectRelativePath,
        [string[]]$DependsOn = @()
    )

    $solutionDir = Split-Path -Parent $SolutionPath
    $file = Read-SolutionText $SolutionPath
    $text = $file.Text
    $nl = $file.NewLine
    $existing = @(Get-SolutionProjects -SolutionPath $SolutionPath)
    $projectPath = [System.IO.Path]::GetFullPath((Join-Path $solutionDir $ProjectRelativePath))
    if ($existing | Where-Object { $_.Path -eq $projectPath }) { throw "$SolutionPath already contains $ProjectRelativePath." }

    $dependencies = @()
    foreach ($dep in $DependsOn) {
        $match = $existing | Where-Object { $_.Path -eq [System.IO.Path]::GetFullPath($dep) } | Select-Object -First 1
        if (-not $match) { throw "$dep is not in $SolutionPath." }
        $dependencies += $match
    }

    if (Test-SlnxPath $SolutionPath) {
        $indent = '  '
        $m = [regex]::Match($text, '(?m)^(?<i>[ \t]+)<(Project|Folder|Configurations)\b')
        if ($m.Success) { $indent = $m.Groups['i'].Value }
        $type = $script:WixProjectTypeGuid.Trim('{}').ToLowerInvariant()
        $entry = "$indent<Project Path=""$($ProjectRelativePath.Replace('\', '/'))"" Type=""$type"">" + $nl
        foreach ($dep in $dependencies) {
            $entry += "$indent$indent<BuildDependency Project=""$((Get-RelativePath $solutionDir $dep.Path).Replace('\', '/'))"" />" + $nl
        }
        $entry += "$indent$indent<Platform Project=""x64"" />" + $nl
        $entry += "$indent$indent<Build Project=""false"" />" + $nl
        $entry += "$indent</Project>" + $nl
        $end = [regex]::Match($text, '(?m)^[ \t]*</Solution>')
        if (-not $end.Success) { throw "$SolutionPath has no </Solution>; it does not look like a Visual Studio .slnx." }
        $text = $text.Insert($end.Index, $entry)
        [System.IO.File]::WriteAllText($SolutionPath, $text, (New-Object System.Text.UTF8Encoding($file.HasBom)))
        return
    }

    $ProjectGuid = '{' + [guid]::NewGuid().ToString().ToUpperInvariant() + '}'
    $entry = 'Project("' + $script:WixProjectTypeGuid + '") = "' + $ProjectName + '", "' + $ProjectRelativePath + '", "' + $ProjectGuid + '"' + $nl
    if ($dependencies.Count) {
        $entry += "`tProjectSection(ProjectDependencies) = postProject" + $nl
        foreach ($dep in $dependencies) { $entry += "`t`t$($dep.Guid) = $($dep.Guid)" + $nl }
        $entry += "`tEndProjectSection" + $nl
    }
    $entry += 'EndProject' + $nl

    $globalIndex = [regex]::Match($text, '(?m)^Global\s*$').Index
    if ($globalIndex -le 0) { throw "$SolutionPath has no Global section; it does not look like a Visual Studio .sln." }
    $text = $text.Insert($globalIndex, $entry)

    $configs = @()
    $section = [regex]::Match($text, '(?s)GlobalSection\(SolutionConfigurationPlatforms\)\s*=\s*preSolution(?<body>.*?)EndGlobalSection')
    if ($section.Success) {
        $configs = @([regex]::Matches($section.Groups['body'].Value, '(?m)^\s*(?<cfg>[^=\r\n]+?)\s*=') | ForEach-Object { $_.Groups['cfg'].Value.Trim() })
    }
    if (-not $configs.Count) { $configs = @('Debug|Any CPU', 'Release|Any CPU') }

    $lines = ''
    foreach ($cfg in $configs) {
        $configuration = ($cfg -split '\|')[0]
        $lines += "`t`t$ProjectGuid.$cfg.ActiveCfg = $configuration|x64" + $nl
    }

    $projectSection = [regex]::Match($text, '(?s)(?<head>GlobalSection\(ProjectConfigurationPlatforms\)\s*=\s*postSolution\r?\n)(?<body>.*?)(?<tail>\tEndGlobalSection)')
    if ($projectSection.Success) {
        $insertAt = $projectSection.Groups['tail'].Index
        $text = $text.Insert($insertAt, $lines)
    }
    else {
        $block = "`tGlobalSection(ProjectConfigurationPlatforms) = postSolution" + $nl + $lines + "`tEndGlobalSection" + $nl
        $endGlobal = [regex]::Match($text, '(?m)^EndGlobal\s*$').Index
        $text = $text.Insert($endGlobal, $block)
    }

    $encoding = New-Object System.Text.UTF8Encoding($file.HasBom)
    [System.IO.File]::WriteAllText($SolutionPath, $text, $encoding)
}

function Remove-SolutionProject {
    <#
      Takes a project out of a .sln or .slnx: its entry, its configuration lines, and every dependency
      other projects declare on it. Keeps the file's own line endings and encoding.
    #>
    param(
        [Parameter(Mandatory)] [string]$SolutionPath,
        [Parameter(Mandatory)] [string]$ProjectPath
    )

    $solutionDir = Split-Path -Parent $SolutionPath
    $file = Read-SolutionText $SolutionPath
    $text = $file.Text
    $ProjectPath = [System.IO.Path]::GetFullPath($ProjectPath)
    $project = Get-SolutionProjects -SolutionPath $SolutionPath | Where-Object { $_.Path -eq $ProjectPath } | Select-Object -First 1
    if (-not $project) { return }
    $rel = Get-RelativePath $solutionDir $ProjectPath

    if (Test-SlnxPath $SolutionPath) {
        $slash = [regex]::Escape($rel.Replace('\', '/'))
        $back = [regex]::Escape($rel)
        $path = "(?:$slash|$back)"
        # <Project Path="..."> ... </Project> or <Project Path="..." />, with its own line.
        $text = [regex]::Replace($text, "(?ms)^[ \t]*<Project\s+Path=""$path""[^>]*/>[ \t]*\r?\n", '')
        $text = [regex]::Replace($text, "(?ms)^[ \t]*<Project\s+Path=""$path""[^>]*>.*?</Project>[ \t]*\r?\n", '')
        $text = [regex]::Replace($text, "(?m)^[ \t]*<BuildDependency\s+Project=""$path""\s*/>[ \t]*\r?\n", '')
    }
    else {
        $guid = [regex]::Escape($project.Guid)
        $text = [regex]::Replace($text, "(?ms)^Project\(""[^""]+""\)\s*=\s*""[^""]*"",\s*""[^""]*"",\s*""$guid""\s*\r?\n.*?^EndProject[ \t]*\r?\n", '')
        $text = [regex]::Replace($text, "(?mi)^[ \t]*$guid\.[^\r\n]*\r?\n", '')
        $text = [regex]::Replace($text, "(?mi)^[ \t]*$guid\s*=\s*$guid[ \t]*\r?\n", '')
        # A dependency section left empty by that is dropped too.
        $text = [regex]::Replace($text, "(?m)^[ \t]*ProjectSection\(ProjectDependencies\)\s*=\s*postProject[ \t]*\r?\n[ \t]*EndProjectSection[ \t]*\r?\n", '')
    }
    [System.IO.File]::WriteAllText($SolutionPath, $text, (New-Object System.Text.UTF8Encoding($file.HasBom)))
}

function Get-SetupProjectInfo {
    <#
      What a WiX project already in the solution is, and whether this skill made it.
        Kind              Setup (one project building the .msi and the setup .exe, version 3+),
                          Package (.msi only) or Bundle (.exe only, an earlier generator's second project)
        Generated         the "Generated by custom-installer-wix" marker is in the .wixproj
        GeneratorVersion  <CustomInstallerWixVersion>; 1 for a generated project from before the stamp;
                          $null for a project this skill did not make (which -Refresh refuses to touch)
        Current           GeneratorVersion is this generator's
    #>
    param([Parameter(Mandatory)] [string]$ProjectPath)

    $text = ''
    if (Test-Path -LiteralPath $ProjectPath) { $text = [System.IO.File]::ReadAllText($ProjectPath) }
    $generated = $text.Contains('Generated by custom-installer-wix')
    $version = $null
    $m = [regex]::Match($text, '<CustomInstallerWixVersion>\s*(?<v>\d+)\s*</CustomInstallerWixVersion>')
    if ($m.Success) { $version = [int]$m.Groups['v'].Value }
    elseif ($generated) { $version = 1 }
    $kind = 'Package'
    if ($text -match '<OutputType>\s*Bundle\s*</OutputType>') { $kind = 'Bundle' }
    if ($text.Contains('CiwInner')) { $kind = 'Setup' }

    [pscustomobject]@{
        Path             = $ProjectPath
        Kind             = $kind
        Generated        = $generated
        GeneratorVersion = $version
        Current          = ($version -eq $script:GeneratorVersion)
    }
}

Export-ModuleMember -Function Get-SolutionProjects, Get-ProjectInfo, Expand-Template, ConvertTo-XmlText, Get-RelativePath, Write-TextFile, Add-SolutionProject, Remove-SolutionProject, Get-SetupProjectInfo -Variable WixProjectTypeGuid, GeneratorVersion, WixVersion
