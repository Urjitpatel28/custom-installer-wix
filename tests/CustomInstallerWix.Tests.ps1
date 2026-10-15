# Pester 5. Run from the repo root:  Invoke-Pester tests
# Fast tests only: nothing here builds an installer (Invoke-EndToEnd.ps1 does that against the examples).

BeforeAll {
    # GitHub Actions runs PowerShell steps with 'Stop', under which Windows PowerShell 5.1 throws on the
    # first stderr line a redirected native command writes (the generator's refusals, git's warnings).
    $ErrorActionPreference = 'Continue'
    $repo = Split-Path -Parent $PSScriptRoot
    $scripts = Join-Path $repo 'skills\custom-installer-wix\scripts'
    Import-Module (Join-Path $scripts 'CustomInstallerWix.psm1') -Force

    function Copy-Example([string]$Name, [string]$From = 'examples') {
        $dest = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        Copy-Item -Recurse (Join-Path $repo "$From\$Name") $dest
        return $dest
    }

    function Invoke-Generator([string]$Solution, [string[]]$Arguments) {
        $output = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scripts 'New-WixSetup.ps1') -Solution $Solution @Arguments 2>&1
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($output | Out-String) }
    }

    function Get-Json([string]$Output) {
        # The generator prints its JSON last; anything before it is progress noise.
        return ($Output.Substring($Output.IndexOf('{'))) | ConvertFrom-Json
    }

    function New-TestProject([string]$Properties, [string]$Items = '') {
        <# A throwaway SDK-style project file with the given PropertyGroup content, for Get-ProjectInfo. #>
        $path = Join-Path $TestDrive "$([guid]::NewGuid().ToString('N')).csproj"
        Set-Content -LiteralPath $path -Value "<Project Sdk=""Microsoft.NET.Sdk""><PropertyGroup><OutputType>WinExe</OutputType>$Properties</PropertyGroup>$Items</Project>"
        return $path
    }

    function Edit-ExampleProject([string]$Dir, [string]$Find, [string]$Replace) {
        <# Changes the copied wpf-net8 example's app project, as a developer's own project would differ. #>
        $proj = Join-Path $Dir 'src\InventoryApp\InventoryApp.csproj'
        $text = [System.IO.File]::ReadAllText($proj)
        if (-not $text.Contains($Find)) { throw "InventoryApp.csproj has no '$Find'." }
        [System.IO.File]::WriteAllText($proj, $text.Replace($Find, $Replace))
    }

    function ConvertTo-Slnx([string]$Sln) {
        <# A .slnx of the same projects, without depending on `dotnet sln migrate`. #>
        $dir = Split-Path -Parent $Sln
        $lines = foreach ($p in Get-SolutionProjects -SolutionPath $Sln) {
            "  <Project Path=""$((Get-RelativePath $dir $p.Path).Replace('\', '/'))"" />"
        }
        $slnx = [System.IO.Path]::ChangeExtension($Sln, '.slnx')
        Set-Content -LiteralPath $slnx -Value (@('<Solution>', '  <Configurations>', '    <Platform Name="Any CPU" />', '  </Configurations>') + $lines + '</Solution>')
        Remove-Item -LiteralPath $Sln
        return $slnx
    }
}

Describe 'Expand-Template' {
    It 'replaces values' {
        Expand-Template -Text 'a {{X}} b' -Values @{ X = '1' } | Should -Be 'a 1 b'
    }
    It 'keeps or drops sections' {
        Expand-Template -Text '{{#ON}}yes{{/ON}}{{#OFF}}no{{/OFF}}{{^OFF}}!{{/OFF}}' -Values @{ ON = $true; OFF = $false } | Should -Be 'yes!'
    }
    It 'removes standalone section lines' {
        $text = "a`n{{#ON}}`nb`n{{/ON}}`nc`n"
        Expand-Template -Text $text -Values @{ ON = $true } | Should -Be "a`nb`nc`n"
    }
    It 'handles nested sections' {
        Expand-Template -Text '{{#A}}[{{#B}}b{{/B}}]{{/A}}' -Values @{ A = $true; B = $false } | Should -Be '[]'
    }
    It 'refuses an unknown value' {
        { Expand-Template -Text '{{NOPE}}' -Values @{} } | Should -Throw '*NOPE*'
    }
}

Describe 'Get-ProjectInfo' {
    It 'reads a modern WPF app' {
        $info = Get-ProjectInfo (Join-Path $repo 'examples\wpf-net8\src\InventoryApp\InventoryApp.csproj')
        $info.IsSdkStyle | Should -BeTrue
        $info.IsModernDotNet | Should -BeTrue
        $info.Kind | Should -Be 'wpf'
        $info.OutputType | Should -Be 'WinExe'
        $info.IconExists | Should -BeTrue
        $info.Product | Should -Be 'Contoso Inventory'
        $info.Company | Should -Be 'Contoso Ltd'
    }
    It 'reads a legacy WinForms app' {
        $info = Get-ProjectInfo (Join-Path $repo 'examples\winforms-net48\ClinicDesk\ClinicDesk.csproj')
        $info.IsSdkStyle | Should -BeFalse
        $info.IsModernDotNet | Should -BeFalse
        $info.Kind | Should -Be 'winforms'
        $info.Platform | Should -Be 'AnyCPU'
        $info.IconExists | Should -BeFalse
        $info.Company | Should -Be 'Northwind Health'
        $info.Version | Should -Be '2.0.1.0'
        $info.NetFxVersion | Should -Be ([version]'4.8')
        $info.RuntimeIdentifier | Should -BeNullOrEmpty
    }
    It 'flags test projects' {
        (Get-ProjectInfo (Join-Path $repo 'examples\wpf-net8\tests\InventoryApp.Tests\InventoryApp.Tests.csproj')).IsTest | Should -BeTrue
    }
    It 'leaves a single-target app without a package framework, published for win-x64' {
        $info = Get-ProjectInfo (Join-Path $repo 'examples\wpf-net8\src\InventoryApp\InventoryApp.csproj')
        $info.PackageTargetFramework | Should -BeNullOrEmpty
        $info.RuntimeIdentifier | Should -Be 'win-x64'
        $info.IsMsixPackaged | Should -BeFalse
    }
    It 'packages the newest .NET 5+ framework of a multi-targeted app' {
        $info = Get-ProjectInfo (New-TestProject '<TargetFrameworks>net48;net8.0-windows;net6.0-windows</TargetFrameworks><UseWPF>true</UseWPF>')
        $info.IsModernDotNet | Should -BeTrue
        $info.PackageTargetFramework | Should -Be 'net8.0-windows'
        $info.NetFxVersion | Should -BeNullOrEmpty
    }
    It 'packages the newest .NET Framework of a Framework-only multi-targeted app' {
        $info = Get-ProjectInfo (New-TestProject '<TargetFrameworks>net472;net48;net462</TargetFrameworks><UseWindowsForms>true</UseWindowsForms>')
        $info.IsModernDotNet | Should -BeFalse
        $info.PackageTargetFramework | Should -Be 'net48'
        $info.NetFxVersion | Should -Be ([version]'4.8')
    }
    It 'publishes an x86 app for win-x86' {
        (Get-ProjectInfo (New-TestProject '<TargetFramework>net8.0-windows</TargetFramework><PlatformTarget>x86</PlatformTarget>')).RuntimeIdentifier | Should -Be 'win-x86'
        (Get-ProjectInfo (New-TestProject '<TargetFramework>net8.0-windows</TargetFramework><RuntimeIdentifier>win-x86</RuntimeIdentifier>')).RuntimeIdentifier | Should -Be 'win-x86'
        (Get-ProjectInfo (New-TestProject '<TargetFramework>net8.0-windows</TargetFramework><PlatformTarget>ARM64</PlatformTarget>')).RuntimeIdentifier | Should -Be 'win-arm64'
    }
    It 'ignores per-configuration platform targets that disagree' {
        $proj = New-TestProject '<TargetFramework>net8.0-windows</TargetFramework>' `
            '<PropertyGroup Condition="''$(Platform)''==''x86''"><PlatformTarget>x86</PlatformTarget></PropertyGroup><PropertyGroup Condition="''$(Platform)''==''x64''"><PlatformTarget>x64</PlatformTarget></PropertyGroup>'
        (Get-ProjectInfo $proj).RuntimeIdentifier | Should -Be 'win-x64'
    }
    It 'tells a packaged WinUI app from an unpackaged one' {
        $page = '<ItemGroup><Page Update="MainWindow.xaml" /></ItemGroup>'
        $packaged = Get-ProjectInfo (New-TestProject '<TargetFramework>net8.0-windows10.0.19041.0</TargetFramework><UseWinUI>true</UseWinUI><EnableMsixTooling>true</EnableMsixTooling>' $page)
        $packaged.Kind | Should -Be 'winui'     # not wpf, despite the <Page> item
        $packaged.IsMsixPackaged | Should -BeTrue
        $unpackaged = Get-ProjectInfo (New-TestProject '<TargetFramework>net8.0-windows10.0.19041.0</TargetFramework><UseWinUI>true</UseWinUI><WindowsPackageType>None</WindowsPackageType>' $page)
        $unpackaged.IsMsixPackaged | Should -BeFalse
        $unpackaged.IsModernDotNet | Should -BeTrue
    }
}

Describe 'Find-StartupProject' {
    It 'offers only the app, not the library or the tests' {
        $json = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scripts 'Find-StartupProject.ps1') -Solution (Join-Path $repo 'examples\wpf-net8\InventoryApp.sln') | Out-String | ConvertFrom-Json
        @($json.Candidates).Count | Should -Be 1
        $json.Candidates[0].Name | Should -Be 'InventoryApp'
        @($json.ExistingSetup).Count | Should -Be 0
    }
    It 'reports a first-generation Setup project as generated but not current' {
        $json = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scripts 'Find-StartupProject.ps1') -Solution (Join-Path $repo 'tests\fixtures\v1-wpf-net8-peruser-bundle\InventoryApp.sln') | Out-String | ConvertFrom-Json
        @($json.ExistingSetup).Count | Should -Be 2
        foreach ($e in $json.ExistingSetup) {
            $e.Generated | Should -BeTrue
            $e.GeneratorVersion | Should -Be 1
            $e.Current | Should -BeFalse
        }
        @($json.ExistingSetup | Where-Object Kind -eq 'Bundle').Count | Should -Be 1
    }
    It 'reads a .slnx' {
        $dir = Copy-Example 'wpf-net8'
        $slnx = ConvertTo-Slnx (Join-Path $dir 'InventoryApp.sln')
        $json = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scripts 'Find-StartupProject.ps1') -Solution $slnx | Out-String | ConvertFrom-Json
        @($json.Candidates).Count | Should -Be 1
        $json.Candidates[0].Name | Should -Be 'InventoryApp'
    }
}

Describe 'New-WixSetup' {
    It 'generates one Setup project for a per-machine legacy app without an icon' {
        $dir = Copy-Example 'winforms-net48'
        $sln = Join-Path $dir 'ClinicDesk.sln'
        $r = Invoke-Generator $sln @('-Manufacturer', 'Northwind Health')
        $r.ExitCode | Should -Be 0 -Because $r.Output

        $setup = Join-Path $dir 'ClinicDesk.Setup'
        $wxs = Get-Content -Raw (Join-Path $setup 'Package.wxs')
        { [xml]$wxs } | Should -Not -Throw
        $wxs | Should -Not -Match '\{\{'
        $wxs | Should -Match 'Scope="perMachine"'
        $wxs | Should -Match 'ProgramFiles64Folder'
        $wxs | Should -Not -Match 'ARPPRODUCTICON'
        $wxs | Should -Match 'WixUILicenseRtf'                              # a new project always has a licence
        $wxs | Should -Match 'Value="amus"'

        $proj = Get-Content -Raw (Join-Path $setup 'ClinicDesk.Setup.wixproj')
        { [xml]$proj } | Should -Not -Throw
        $proj | Should -Match '<AppPlatform>AnyCPU</AppPlatform>'
        $proj | Should -Match '<AppSelfContained>false</AppSelfContained>'
        $proj | Should -Match '<Import Project="CustomInstallerWix.targets" />'
        Test-Path (Join-Path $setup 'CustomInstallerWix.targets') | Should -BeTrue
        Test-Path (Join-Path $setup 'Assets\Dialog.bmp') | Should -BeFalse     # no icon: WiX's own dialog images
        Test-Path (Join-Path $setup 'Assets\LogoSide.png') | Should -BeTrue    # the wizard draws a lettered tile
        Test-Path (Join-Path $dir 'ClinicDesk.Setup.Bundle') | Should -BeFalse
        # Without -License the licence is a placeholder for the developer to replace.
        (Get-Content -Raw (Join-Path $setup 'License.rtf')) | Should -Match '^\{\\rtf1.* LICENSE\}$'
    }

    It 'lets the end user choose the folder and the shortcuts, and remembers them' {
        $dir = Copy-Example 'winforms-net48'
        $r = Invoke-Generator (Join-Path $dir 'ClinicDesk.sln') @('-Manufacturer', 'Northwind Health')
        $r.ExitCode | Should -Be 0 -Because $r.Output
        $setup = Join-Path $dir 'ClinicDesk.Setup'

        $wxs = Get-Content -Raw (Join-Path $setup 'Package.wxs')
        foreach ($name in 'InstallFolder', 'StartMenu', 'DesktopShortcut') {
            $wxs | Should -Match "RegistryValue [^>]*Name=`"$name`""                    # recorded ...
            $wxs | Should -Match "RegistrySearch [^>]*Name=`"$name`""                   # ... and read back on upgrade
        }
        $wxs | Should -Match 'Component Id="StartMenuShortcut" Condition=''STARTMENUSHORTCUT = "1"'''
        $wxs | Should -Match 'SetProperty Id="INSTALLFOLDER"[^>]*Condition="INSTALLFOLDER_REMEMBERED AND NOT INSTALLFOLDER"'

        $bundle = Get-Content -Raw (Join-Path $setup 'Bundle.wxs')
        $bundle | Should -Match 'Variable Name="InstallFolder" Type="formatted" Value="\[ProgramFiles64Folder\]Clinic Desk"'
        $bundle | Should -Match 'MsiProperty Name="INSTALLFOLDER" Value="\[InstallFolder\]"'
        $bundle | Should -Match 'MsiProperty Name="STARTMENUSHORTCUT" Value="\[StartMenuShortcut\]"'
        $bundle | Should -Match 'Variable Name="LaunchTarget" Type="formatted" Value="\[InstallFolder\]\\ClinicDesk\.exe"'
        $bundle | Should -Match 'Result="exists" Variable="ProductInstalled"'

        [xml]$theme = Get-Content -Raw (Join-Path $setup 'Assets\Theme.xml')
        $install = $theme.Theme.Window.Page | Where-Object Name -eq 'Install'
        $options = $theme.Theme.Window.Page | Where-Object Name -eq 'InstallOptions'
        # The location is chosen only on the options page, which Options... opens.
        $install.OuterXml | Should -Not -Match 'InstallFolder'
        ($install.Button | Where-Object Name -eq 'InstallOptionsButton').ChangePageAction.Page | Should -Be 'InstallOptions'
        # wixstdba keeps InstallButton disabled, and so hidden, until its own accept checkbox is ticked.
        ($install.Button | Where-Object Name -eq 'InstallButton').HideWhenDisabled | Should -Be 'yes'
        @($install.Checkbox | Where-Object Name -eq 'EulaAcceptCheckbox').Count | Should -Be 1
        # The grey stand-in must come after InstallButton: the first-declared sibling is drawn on top.
        $buttons = @($install.Button | ForEach-Object Name)
        [array]::IndexOf($buttons, 'InstallBlockedButton') | Should -BeGreaterThan ([array]::IndexOf($buttons, 'InstallButton'))
        # ...and must clip itself against it (WS_CLIPSIBLINGS), or it still paints over the enabled button.
        ($install.Button | Where-Object Name -eq 'InstallBlockedButton').HexStyle | Should -Be '4000000'
        ($options.Editbox | Where-Object Name -eq 'InstallFolder').EnableCondition | Should -Be 'NOT ProductInstalled'
        ($options.Button | Where-Object Name -eq 'InstallFolderBrowseButton').BrowseDirectoryAction.VariableName | Should -Be 'InstallFolder'
        @($options.Checkbox | ForEach-Object Name) | Should -Be @('DesktopShortcut', 'StartMenuShortcut')
        # Install itself never moves off wixstdba's Install page (see Theme.xml).
        $options.OuterXml | Should -Not -Match 'Name="InstallButton"'
    }

    It 'builds only the setup .exe into bin\<Configuration>, packaging the app''s Release build' {
        $dir = Copy-Example 'wpf-net8'
        $r = Invoke-Generator (Join-Path $dir 'InventoryApp.sln') @('-Manufacturer', 'Contoso Ltd')
        $r.ExitCode | Should -Be 0 -Because $r.Output
        [xml]$proj = Get-Content -Raw (Join-Path $dir 'src\InventoryApp.Setup\InventoryApp.Setup.wixproj')
        $outer = $proj.Project.PropertyGroup | Where-Object { -not $_.Condition } | Select-Object -First 1
        $outer.OutputType | Should -Be 'Bundle'
        $outer.OutputPath | Should -Be 'bin\$(Configuration)\'
        $outer.SuppressPdbOutput | Should -Be 'true'
        $outer.AppConfiguration.'#text' | Should -Be 'Release'
        $inner = $proj.Project.PropertyGroup | Where-Object { $_.Condition -eq "'`$(CiwInner)' == 'true'" }
        $inner.OutputType | Should -Be 'Package'
        $inner.OutputPath | Should -Match '^obj\\'
        (Get-Content -Raw (Join-Path $dir 'src\InventoryApp.Setup\Bundle.wxs')) | Should -Match 'SourceFile="\$\(var\.MsiPath\)"'
        (Get-Json $r.Output).Output | Should -Match 'bin\\<Configuration>\\ContosoInventorySetup\.exe$'
    }

    It 'pins every WiX package to one version and stamps the generator version' {
        $dir = Copy-Example 'wpf-net8'
        $r = Invoke-Generator (Join-Path $dir 'InventoryApp.sln') @('-Manufacturer', 'Contoso Ltd')
        $r.ExitCode | Should -Be 0 -Because $r.Output
        $text = Get-Content -Raw (Join-Path $dir 'src\InventoryApp.Setup\InventoryApp.Setup.wixproj')
        $versions = @([regex]::Matches($text, '(?:WixToolset\.Sdk/|Version=")(\d+\.\d+\.\d+)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        $versions | Should -Be @($WixVersion)
        $text | Should -Match "<CustomInstallerWixVersion>$GeneratorVersion</CustomInstallerWixVersion>"
    }

    It 'generates a per-user setup for a modern app with icon and licence' {
        $dir = Copy-Example 'wpf-net8'
        $sln = Join-Path $dir 'InventoryApp.sln'
        $r = Invoke-Generator $sln @('-Manufacturer', 'Contoso Ltd', '-Scope', 'perUser', '-License', (Join-Path $repo 'LICENSE'), '-NoDesktopShortcut')
        $r.ExitCode | Should -Be 0 -Because $r.Output

        $setup = Join-Path $dir 'src\InventoryApp.Setup'
        $wxs = Get-Content -Raw (Join-Path $setup 'Package.wxs')
        $wxs | Should -Match 'Scope="perUser"'
        $wxs | Should -Match 'LocalAppDataFolder'
        $wxs | Should -Match 'ARPPRODUCTICON'
        $wxs | Should -Match 'WixUILicenseRtf'
        $wxs | Should -Match 'Value="0"\s+After="SetDESKTOPSHORTCUT"'
        (Get-Content -Raw (Join-Path $setup 'InventoryApp.Setup.wixproj')) | Should -Match '<AppSelfContained>true</AppSelfContained>'
        $rtf = Get-Content -Raw (Join-Path $setup 'License.rtf')
        $rtf | Should -Match '^\{\\rtf1'
        $rtf | Should -Not -Match 'person\\par'   # hard-wrapped lines are joined into paragraphs
        Test-Path (Join-Path $setup 'Assets\Banner.bmp') | Should -BeTrue

        foreach ($f in 'Bundle.wxs', 'Assets\Theme.xml', 'Assets\Theme.wxl', 'InventoryApp.Setup.wixproj') {
            $text = Get-Content -Raw (Join-Path $setup $f)
            { [xml]$text } | Should -Not -Throw
            $text | Should -Not -Match '\{\{'
        }
        $bundle = Get-Content -Raw (Join-Path $setup 'Bundle.wxs')
        $bundle | Should -Match 'Theme="rtfLicense"'
        $bundle | Should -Match 'LicenseFile="\$\(sys\.SOURCEFILEDIR\)License\.rtf"'
        (Get-Content -Raw (Join-Path $setup 'Assets\Theme.xml')) | Should -Match 'EulaRichedit'
        foreach ($png in 'Logo.png', 'LogoSide.png', 'ButtonPrimary.png', 'ButtonDisabled.png') {
            Test-Path (Join-Path $setup "Assets\$png") | Should -BeTrue
        }
    }

    It 'keeps bulleted licence lines as their own paragraphs' {
        $dir = Copy-Example 'winforms-net48'
        $eula = Join-Path $dir 'EULA.txt'
        [System.IO.File]::WriteAllText($eula, "Terms:`n$([char]0x2022) First point`n$([char]0x2022) Second point`n", (New-Object System.Text.UTF8Encoding($false)))
        $r = Invoke-Generator (Join-Path $dir 'ClinicDesk.sln') @('-Manufacturer', 'Northwind Health', '-License', $eula)
        $r.ExitCode | Should -Be 0 -Because $r.Output
        $rtf = Get-Content -Raw (Join-Path $dir 'ClinicDesk.Setup\License.rtf')
        $rtf | Should -Match 'Terms:\\par\s+\\u8226\? First point\\par\s+\\u8226\? Second point'
    }

    It 'keeps a refreshed project that shipped without a licence licence-free' {
        $dir = Copy-Example 'winforms-net48'
        $sln = Join-Path $dir 'ClinicDesk.sln'
        $r = Invoke-Generator $sln @('-Manufacturer', 'Northwind Health', '-Bundle')   # -Bundle: still accepted
        $r.ExitCode | Should -Be 0 -Because $r.Output
        # As an earlier generator left a project without -License: no License.rtf, no licence page.
        Remove-Item (Join-Path $dir 'ClinicDesk.Setup\License.rtf')
        $r = Invoke-Generator $sln @('-Refresh', '-Force')
        $r.ExitCode | Should -Be 0 -Because $r.Output
        Test-Path (Join-Path $dir 'ClinicDesk.Setup\License.rtf') | Should -BeFalse
        $bundle = Get-Content -Raw (Join-Path $dir 'ClinicDesk.Setup\Bundle.wxs')
        $bundle | Should -Match 'Theme="hyperlinkLicense"'
        $bundle | Should -Not -Match 'LicenseFile'
        (Get-Content -Raw (Join-Path $dir 'ClinicDesk.Setup\Assets\Theme.xml')) | Should -Not -Match 'EulaRichedit'
    }

    It 'adds one project to a .sln without any Build.0 line' {
        $dir = Copy-Example 'wpf-net8'
        $sln = Join-Path $dir 'InventoryApp.sln'
        $r = Invoke-Generator $sln @('-Manufacturer', 'Contoso Ltd')
        $r.ExitCode | Should -Be 0 -Because $r.Output

        $text = Get-Content -Raw $sln
        $guids = @([regex]::Matches($text, 'Project\("\{B7DD6F7E-DEF8-4E67-B5B7-07EF123DB6F0\}"\) = "([^"]+)", "[^"]+", "(\{[^}]+\})"'))
        $guids.Count | Should -Be 1
        $guids[0].Groups[1].Value | Should -Be 'InventoryApp.Setup'
        $g = $guids[0].Groups[2].Value
        $text | Should -Match ([regex]::Escape("$g.Release|Any CPU.ActiveCfg = Release|x64"))
        $text | Should -Not -Match ([regex]::Escape("$g.") + '[^\r\n]*Build\.0')
        $text | Should -Match 'ProjectSection\(ProjectDependencies\)'
        $text | Should -Match "`r`n"   # line endings kept
    }

    It 'adds one project to a .slnx without building it' {
        $dir = Copy-Example 'wpf-net8'
        $slnx = ConvertTo-Slnx (Join-Path $dir 'InventoryApp.sln')
        $r = Invoke-Generator $slnx @('-Manufacturer', 'Contoso Ltd')
        $r.ExitCode | Should -Be 0 -Because $r.Output

        [xml]$xml = Get-Content -Raw $slnx
        @($xml.SelectNodes("//Project[contains(@Path, '.wixproj')]")).Count | Should -Be 1
        $setup = $xml.SelectSingleNode("//Project[@Path='src/InventoryApp.Setup/InventoryApp.Setup.wixproj']")
        $setup | Should -Not -BeNullOrEmpty
        $setup.GetAttribute('Type') | Should -Be 'b7dd6f7e-def8-4e67-b5b7-07ef123db6f0'
        $setup.SelectSingleNode('Build').GetAttribute('Project') | Should -Be 'false'
        $setup.SelectSingleNode('Platform').GetAttribute('Project') | Should -Be 'x64'
        $setup.SelectSingleNode('BuildDependency').GetAttribute('Project') | Should -Be 'src/InventoryApp/InventoryApp.csproj'
    }

    It 'removes a project and the dependencies on it from a .slnx' {
        $slnx = Join-Path $TestDrive 'remove.slnx'
        Set-Content -LiteralPath $slnx -Value @(
            '<Solution>'
            '  <Project Path="App/App.csproj" />'
            '  <Project Path="App.Setup/App.Setup.wixproj" Type="b7dd6f7e-def8-4e67-b5b7-07ef123db6f0">'
            '    <BuildDependency Project="App/App.csproj" />'
            '    <Build Project="false" />'
            '  </Project>'
            '  <Project Path="App.Setup.Bundle/App.Setup.Bundle.wixproj" Type="b7dd6f7e-def8-4e67-b5b7-07ef123db6f0">'
            '    <BuildDependency Project="App.Setup/App.Setup.wixproj" />'
            '    <Build Project="false" />'
            '  </Project>'
            '  <Project Path="Other/Other.csproj">'
            '    <BuildDependency Project="App.Setup.Bundle/App.Setup.Bundle.wixproj" />'
            '  </Project>'
            '</Solution>')
        Remove-SolutionProject -SolutionPath $slnx -ProjectPath (Join-Path $TestDrive 'App.Setup.Bundle\App.Setup.Bundle.wixproj')
        [xml]$xml = Get-Content -Raw $slnx
        @($xml.SelectNodes('//Project')).Count | Should -Be 3
        (Get-Content -Raw $slnx) | Should -Not -Match 'Bundle'
        $xml.SelectSingleNode("//Project[@Path='App.Setup/App.Setup.wixproj']/BuildDependency").GetAttribute('Project') | Should -Be 'App/App.csproj'
    }
    It 'refuses to generate a second Setup project and points at -Refresh' {
        $dir = Copy-Example 'winforms-net48'
        $sln = Join-Path $dir 'ClinicDesk.sln'
        (Invoke-Generator $sln @('-Manufacturer', 'Northwind Health')).ExitCode | Should -Be 0
        $second = Invoke-Generator $sln @('-Manufacturer', 'Northwind Health')
        $second.ExitCode | Should -Not -Be 0
        $second.Output | Should -Match 'already has a WiX project'
        $second.Output | Should -Match '-Refresh'
    }

    It 'makes setup check the .NET Framework version a Framework app targets' {
        $dir = Copy-Example 'winforms-net48'
        $r = Invoke-Generator (Join-Path $dir 'ClinicDesk.sln') @('-Manufacturer', 'Northwind Health')
        $r.ExitCode | Should -Be 0 -Because $r.Output
        (Get-Json $r.Output).NetFxRequired | Should -Be '4.8'
        $bundle = Get-Content -Raw (Join-Path $dir 'ClinicDesk.Setup\Bundle.wxs')
        { [xml]$bundle } | Should -Not -Throw
        $bundle | Should -Match 'Key="SOFTWARE\\Microsoft\\NET Framework Setup\\NDP\\v4\\Full"'
        # 528040 is .NET Framework 4.8; an installed bundle can always be uninstalled or repaired.
        $bundle | Should -Match 'bal:Condition Condition="WixBundleInstalled OR NetFxRelease &gt;= 528040"'
        $bundle | Should -Match 'needs \.NET Framework 4\.8 or later'
    }

    It 'leaves the .NET Framework check out of a self-contained app' {
        $dir = Copy-Example 'wpf-net8'
        $r = Invoke-Generator (Join-Path $dir 'InventoryApp.sln') @('-Manufacturer', 'Contoso Ltd')
        $r.ExitCode | Should -Be 0 -Because $r.Output
        (Get-Content -Raw (Join-Path $dir 'src\InventoryApp.Setup\Bundle.wxs')) | Should -Not -Match 'NetFxRelease'
        $proj = Get-Content -Raw (Join-Path $dir 'src\InventoryApp.Setup\InventoryApp.Setup.wixproj')
        $proj | Should -Match '<AppRuntimeIdentifier>win-x64</AppRuntimeIdentifier>'
        $proj | Should -Not -Match 'AppTargetFramework'           # single target: follows the app
        $proj | Should -Not -Match 'AppPublishArguments'
    }

    It 'packages the newest framework of a multi-targeted app' {
        $dir = Copy-Example 'wpf-net8'
        Edit-ExampleProject $dir '<TargetFramework>net8.0-windows</TargetFramework>' '<TargetFrameworks>net6.0-windows;net8.0-windows</TargetFrameworks>'
        $r = Invoke-Generator (Join-Path $dir 'InventoryApp.sln') @('-Manufacturer', 'Contoso Ltd')
        $r.ExitCode | Should -Be 0 -Because $r.Output
        (Get-Content -Raw (Join-Path $dir 'src\InventoryApp.Setup\InventoryApp.Setup.wixproj')) | Should -Match '<AppTargetFramework>net8.0-windows</AppTargetFramework>'
        (Get-Json $r.Output).Payload | Should -Match 'net8\.0-windows$'
    }

    It 'publishes an x86 app for win-x86' {
        $dir = Copy-Example 'wpf-net8'
        Edit-ExampleProject $dir '<UseWPF>true</UseWPF>' '<UseWPF>true</UseWPF><PlatformTarget>x86</PlatformTarget>'
        $r = Invoke-Generator (Join-Path $dir 'InventoryApp.sln') @('-Manufacturer', 'Contoso Ltd')
        $r.ExitCode | Should -Be 0 -Because $r.Output
        (Get-Content -Raw (Join-Path $dir 'src\InventoryApp.Setup\InventoryApp.Setup.wixproj')) | Should -Match '<AppRuntimeIdentifier>win-x86</AppRuntimeIdentifier>'
    }

    It 'refuses an ARM64 app' {
        $dir = Copy-Example 'wpf-net8'
        Edit-ExampleProject $dir '<UseWPF>true</UseWPF>' '<UseWPF>true</UseWPF><PlatformTarget>ARM64</PlatformTarget>'
        $r = Invoke-Generator (Join-Path $dir 'InventoryApp.sln') @('-Manufacturer', 'Contoso Ltd')
        $r.ExitCode | Should -Not -Be 0
        $r.Output | Should -Match 'built for win-arm64'
        Test-Path (Join-Path $dir 'src\InventoryApp.Setup') | Should -BeFalse
    }

    It 'refuses an MSIX-packaged WinUI app' {
        $dir = Copy-Example 'wpf-net8'
        Edit-ExampleProject $dir '<UseWPF>true</UseWPF>' '<UseWinUI>true</UseWinUI><EnableMsixTooling>true</EnableMsixTooling>'
        $r = Invoke-Generator (Join-Path $dir 'InventoryApp.sln') @('-Manufacturer', 'Contoso Ltd')
        $r.ExitCode | Should -Not -Be 0
        $r.Output | Should -Match 'packaged as MSIX'
        Test-Path (Join-Path $dir 'src\InventoryApp.Setup') | Should -BeFalse
    }

    It 'publishes an unpackaged WinUI app with the Windows App SDK runtime inside' {
        $dir = Copy-Example 'wpf-net8'
        Edit-ExampleProject $dir '<UseWPF>true</UseWPF>' '<UseWinUI>true</UseWinUI><WindowsPackageType>None</WindowsPackageType>'
        $r = Invoke-Generator (Join-Path $dir 'InventoryApp.sln') @('-Manufacturer', 'Contoso Ltd')
        $r.ExitCode | Should -Be 0 -Because $r.Output
        (Get-Content -Raw (Join-Path $dir 'src\InventoryApp.Setup\InventoryApp.Setup.wixproj')) |
            Should -Match '<AppPublishArguments>-p:Platform=x64 -p:WindowsAppSDKSelfContained=true</AppPublishArguments>'
    }

    It 'generates code signing, off until a certificate is named' {
        $dir = Copy-Example 'winforms-net48'
        $r = Invoke-Generator (Join-Path $dir 'ClinicDesk.sln') @('-Manufacturer', 'Northwind Health')
        $r.ExitCode | Should -Be 0 -Because $r.Output
        [xml]$targets = Get-Content -Raw (Join-Path $dir 'ClinicDesk.Setup\CustomInstallerWix.targets')
        # The WiX SDK declares these empty; ours fill them in. All three are needed for a bundle.
        foreach ($t in 'SignMsi', 'SignBundleEngine', 'SignBundle') {
            @($targets.Project.Target | Where-Object Name -eq $t).Count | Should -Be 1
        }
        $sign = $targets.Project.PropertyGroup | Where-Object { $_.SignOutput }
        $sign.Condition | Should -Match 'SignCertificateThumbprint'
        (Get-Content -Raw (Join-Path $dir 'ClinicDesk.Setup\ClinicDesk.Setup.wixproj')) | Should -Match '<SignCertificateThumbprint Condition='
    }

    It 'converts a PNG logo into the installer icon' {
        $dir = Copy-Example 'winforms-net48'
        $png = Join-Path $dir 'logo.png'
        Add-Type -AssemblyName System.Drawing
        $b = New-Object System.Drawing.Bitmap(128, 128)
        $g = [System.Drawing.Graphics]::FromImage($b); $g.Clear([System.Drawing.Color]::FromArgb(255, 200, 40, 40)); $g.Dispose()
        $b.Save($png, [System.Drawing.Imaging.ImageFormat]::Png); $b.Dispose()

        $r = Invoke-Generator (Join-Path $dir 'ClinicDesk.sln') @('-Manufacturer', 'Northwind Health', '-Icon', $png)
        $r.ExitCode | Should -Be 0 -Because $r.Output
        $ico = Join-Path $dir 'ClinicDesk.Setup\AppIcon.ico'
        $bytes = [System.IO.File]::ReadAllBytes($ico)
        [BitConverter]::ToUInt16($bytes, 4) | Should -Be 7     # 16..256 px frames
        (Get-Content -Raw (Join-Path $dir 'ClinicDesk.Setup\Package.wxs')) | Should -Match 'SOURCEFILEDIR\)AppIcon\.ico'
    }
}

Describe 'New-WixSetup -Refresh' {
    BeforeAll {
        function Get-UpgradeCode([string]$File, [string]$Element) {
            [xml]$x = Get-Content -Raw $File
            return $x.SelectSingleNode("//*[local-name()='$Element']").GetAttribute('UpgradeCode')
        }
    }

    It 'migrates a first-generation two-project setup into one project and keeps its identity' {
        $dir = Copy-Example 'v1-wpf-net8-peruser-bundle' 'tests\fixtures'
        $setup = Join-Path $dir 'src\InventoryApp.Setup'
        $bundle = Join-Path $dir 'src\InventoryApp.Setup.Bundle'
        $package1 = Get-Content -Raw (Join-Path $setup 'Package.wxs')
        $msiCode = Get-UpgradeCode (Join-Path $setup 'Package.wxs') 'Package'
        $bundleCode = Get-UpgradeCode (Join-Path $bundle 'Bundle.wxs') 'Bundle'

        $r = Invoke-Generator (Join-Path $dir 'InventoryApp.sln') @('-Refresh', '-Force')
        $r.ExitCode | Should -Be 0 -Because $r.Output
        $json = Get-Json $r.Output
        $json.PreviousGeneratorVersion | Should -Be 1
        $json.UpgradeCode | Should -Be $msiCode
        $json.BundleUpgradeCode | Should -Be $bundleCode
        $json.MergedBundleProject | Should -Be $bundle

        Get-UpgradeCode (Join-Path $setup 'Package.wxs') 'Package' | Should -Be $msiCode
        Get-UpgradeCode (Join-Path $setup 'Bundle.wxs') 'Bundle' | Should -Be $bundleCode
        Test-Path $bundle | Should -BeFalse
        # The identity the first generation put in Package.wxs is recovered unchanged; only the template
        # around it is new.
        $identity = {
            param([string]$Text)
            [xml]$x = $Text
            $pkg = $x.SelectSingleNode("//*[local-name()='Package']")
            @($pkg.Name, $pkg.Manufacturer, $pkg.UpgradeCode, $pkg.Scope,
              $x.SelectSingleNode("//*[local-name()='Directory'][@Id='INSTALLFOLDER']").Name,
              $x.SelectSingleNode("//*[local-name()='RegistryValue'][@Name='DesktopShortcut']").Key) -join '|'
        }
        & $identity (Get-Content -Raw (Join-Path $setup 'Package.wxs')) | Should -Be (& $identity $package1)
        $proj = Get-Content -Raw (Join-Path $setup 'InventoryApp.Setup.wixproj')
        $proj | Should -Match "WixToolset.Sdk/$([regex]::Escape($WixVersion))"
        $proj | Should -Match "<CustomInstallerWixVersion>$GeneratorVersion</CustomInstallerWixVersion>"
        Test-Path (Join-Path $setup 'CustomInstallerWix.targets') | Should -BeTrue
        # One WiX project left in the solution: the Setup project, with its dependency on the app.
        $sln = Get-Content -Raw (Join-Path $dir 'InventoryApp.sln')
        $sln | Should -Not -Match 'Setup\.Bundle'
        @([regex]::Matches($sln, '\.wixproj"')).Count | Should -Be 1
        $sln | Should -Match 'ProjectSection\(ProjectDependencies\)'
        @(Get-SolutionProjects (Join-Path $dir 'InventoryApp.sln') | Where-Object { $_.Path -like '*.wixproj' } |
            ForEach-Object { (Get-SetupProjectInfo $_.Path).Kind }) | Should -Be @('Setup')
    }

    It 'refuses to change the install scope' {
        $dir = Copy-Example 'v1-wpf-net8-peruser-bundle' 'tests\fixtures'
        $r = Invoke-Generator (Join-Path $dir 'InventoryApp.sln') @('-Refresh', '-Force', '-Scope', 'perMachine')
        $r.ExitCode | Should -Not -Be 0
        $r.Output | Should -Match "refusing to change it to 'perMachine'"
    }

    It 'refuses outside git without -Force' {
        $dir = Copy-Example 'v1-wpf-net8-peruser-bundle' 'tests\fixtures'
        $r = Invoke-Generator (Join-Path $dir 'InventoryApp.sln') @('-Refresh')
        $r.ExitCode | Should -Not -Be 0
        $r.Output | Should -Match 'not in a git repository'
    }

    It 'refuses uncommitted changes in the Setup projects' -Skip:(-not (Get-Command git -ErrorAction SilentlyContinue)) {
        $dir = Copy-Example 'v1-wpf-net8-peruser-bundle' 'tests\fixtures'
        & git -C $dir init -q
        & git -C $dir -c core.autocrlf=false add -A 2>$null
        & git -C $dir -c user.name=test -c user.email=test@example.com -c core.autocrlf=false commit -qm v1
        Add-Content (Join-Path $dir 'src\InventoryApp.Setup\Package.wxs') '<!-- hand edit -->'
        $r = Invoke-Generator (Join-Path $dir 'InventoryApp.sln') @('-Refresh')
        $r.ExitCode | Should -Not -Be 0
        $r.Output | Should -Match 'Uncommitted changes'
    }

    It 'refuses uncommitted changes in the solution a merge would edit' -Skip:(-not (Get-Command git -ErrorAction SilentlyContinue)) {
        $dir = Copy-Example 'v1-wpf-net8-peruser-bundle' 'tests\fixtures'
        & git -C $dir init -q
        & git -C $dir -c core.autocrlf=false add -A 2>$null
        & git -C $dir -c user.name=test -c user.email=test@example.com -c core.autocrlf=false commit -qm v1
        Add-Content (Join-Path $dir 'InventoryApp.sln') '# hand edit'
        $r = Invoke-Generator (Join-Path $dir 'InventoryApp.sln') @('-Refresh')
        $r.ExitCode | Should -Not -Be 0
        $r.Output | Should -Match 'Uncommitted changes'
        $r.Output | Should -Match 'InventoryApp\.sln'
    }

    It 'refuses a WiX project it did not generate' {
        $dir = Copy-Example 'winforms-net48'
        $sln = Join-Path $dir 'ClinicDesk.sln'
        (Invoke-Generator $sln @('-Manufacturer', 'Northwind Health')).ExitCode | Should -Be 0
        $proj = Join-Path $dir 'ClinicDesk.Setup\ClinicDesk.Setup.wixproj'
        (Get-Content -Raw $proj).Replace('Generated by custom-installer-wix', 'Hand-made') | Set-Content -NoNewline $proj
        $r = Invoke-Generator $sln @('-Refresh', '-Force')
        $r.ExitCode | Should -Not -Be 0
        $r.Output | Should -Match 'was not generated by custom-installer-wix'
    }
}

Describe 'samples' {
    It 'are what the current generator produces (run tests\Update-Samples.ps1 if not)' {
        $fresh = Join-Path $TestDrive 'samples'
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'tests\Update-Samples.ps1') -OutDir $fresh | Out-Null
        $LASTEXITCODE | Should -Be 0

        # Text files only: images are drawn with System.Drawing, whose anti-aliasing can differ between
        # machines. GUIDs are new on every generation.
        $textExt = '.wxs', '.wixproj', '.targets', '.xml', '.wxl', '.rtf', '.sln', '.slnx'
        $mask = { param($s) [regex]::Replace($s, '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}', 'GUID') }
        $committed = Join-Path $repo 'samples'
        $buildOutput = '\\(bin|obj|\.vs)\\'   # git-ignored; there after opening a sample in Visual Studio
        foreach ($name in Get-ChildItem -LiteralPath $fresh -Directory | ForEach-Object Name) {
            $want = @(Get-ChildItem -LiteralPath (Join-Path $fresh $name) -Recurse -File | Where-Object { $_.FullName -notmatch $buildOutput } | ForEach-Object { $_.FullName.Substring($fresh.Length) } | Sort-Object)
            $have = @(Get-ChildItem -LiteralPath (Join-Path $committed $name) -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notmatch $buildOutput } | ForEach-Object { $_.FullName.Substring($committed.Length) } | Sort-Object)
            ($have -join "`n") | Should -Be ($want -join "`n") -Because "samples\$name should list the same files"
            foreach ($rel in $want | Where-Object { [System.IO.Path]::GetExtension($_) -in $textExt }) {
                $a = & $mask ([System.IO.File]::ReadAllText((Join-Path $committed $rel)).Replace("`r`n", "`n"))
                $b = & $mask ([System.IO.File]::ReadAllText((Join-Path $fresh $rel)).Replace("`r`n", "`n"))
                $a | Should -Be $b -Because "samples$rel should match the generator"
            }
        }
    }
}
