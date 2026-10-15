# Why the generated installer looks the way it does

Each choice below was settled by something that went wrong in a real installer. Read this before
"simplifying" a generated project.

## WiX 6.0.2, pinned

WiX v7 and later stop with `WIX7015` until the Open Source Maintenance Fee EULA
(https://wixtoolset.org/osmf/) has been accepted. Acceptance can be scripted, but it is a commitment for the
organisation that ships the installer (the OSMF asks commercial users to pay a maintenance fee), so it is
not something a generated build should do on their behalf. WiX 6 has no such step. The SDK
(`WixToolset.Sdk/6.0.2`) and every extension (`WixToolset.UI.wixext`,
`WixToolset.BootstrapperApplications.wixext`, `WixToolset.Util.wixext`) are pinned to 6.0.2. Extension
versions have to match the core version, or the build fails with WIX6101. The version lives in one place,
`$WixVersion` in `scripts/CustomInstallerWix.psm1`.

Projects from the first generator are on WiX 5.0.2. `New-WixSetup.ps1 -Refresh` moves them to 6.0.2 without
changing their identity; an installer built before the refresh upgrades in place to one built after it.

## Visual Studio 2022 and 2026

- **Building**: the `.wixproj` is a plain MSBuild SDK project. The MSBuild of Visual Studio 2022 (17.x),
  Visual Studio 2026 (18.x), their Build Tools and the .NET SDK all build it. The inline version task uses
  `RoslynCodeTaskFactory`, which every one of them ships.
- **Opening**: `.wixproj` is not a project type Visual Studio knows about on its own. Without the FireGiant
  **HeatWave** extension (the Community edition is free), the project shows as "(incompatible)", and
  Visual Studio may write an `UpgradeLog.htm` into the repo. FireGiant lists HeatWave for Visual Studio
  2022; check the Marketplace for a Visual Studio 2026 listing. Without it, build from the command line.
  "WiX SDK + MSBuild" is not an alternative to HeatWave: it is what the project already is. HeatWave only
  adds the Visual Studio project system (load, right-click Build, WiX IntelliSense).
- **Solutions**: `.sln` (the Visual Studio 2022 default) and `.slnx` (the Visual Studio 2026 default; Visual
  Studio 2022 opens it from 17.13) are both read and edited.

## One project, two WiX builds

A WiX project produces one output, and a setup .exe (a Burn bundle) can only embed an .msi that already
exists. So `<App>.Setup.wixproj` builds twice:
1. `BuildSetupMsi` (in `CustomInstallerWix.targets`) calls the same project with `CiwInner=true`. That build
   is `OutputType=Package`, compiles `Package.wxs`, builds the app and writes the .msi under `obj\msi\`.
2. The normal build is `OutputType=Bundle`, compiles `Bundle.wxs`, and embeds that .msi (`$(var.MsiPath)`).

Only step 2 writes to `bin\<Configuration>\`, and `SuppressPdbOutput` stops its `.wixpdb`, so the setup .exe
is the only file there. Earlier generators made a second project, `<App>.Setup.Bundle`, for step 2;
`-Refresh` merges it back (its UpgradeCode moves into `<App>.Setup\Bundle.wxs`).

WiX doesn't rebuild the .exe when only the embedded .msi changed, any more than it rebuilds the .msi for a
new version number. `bundle.stamp` (the .msi's path and time) is made a compile input for the same reason
as `payload.stamp` below.

The app is built in `AppConfiguration`, `Release` unless overridden, whatever configuration the setup is
built in. A setup built in Debug, as Visual Studio does by default, is still safe to hand out.

The bare .msi is not a deliverable. It is at `obj\msi\bin\<Configuration>\en-us\` after a build, and
`wix burn extract <Product>Setup.exe -o out` gets it out of a shipped .exe (as `a0`). `Setup.exe /layout`
does not: Burn only lays out packages that are outside the .exe.

## Not part of solution builds

A solution build (yours, or CI's `msbuild X.sln`) skips the Setup project, so:
- Day-to-day builds don't pay for a publish and an MSI link.
- A CI pipeline that only builds and tests doesn't start depending on the WiX SDK.

In a `.sln` they get `ActiveCfg` lines but no `Build.0` lines, and a `ProjectDependencies` entry. In a
`.slnx` they get `<Build Project="false" />`, `<Platform Project="x64" />` and a `<BuildDependency>`, which
is what Visual Studio writes itself. Either way, "Build" on the Setup project in Visual Studio builds the
app first.

## The build logic: `CustomInstallerWix.targets`

The `.wixproj` holds only settings (`AppProject`, `AppExeName`, `AppSelfContained`, ...). The steps (build
or publish the app, work out the version, guard it, stamp the payload) are in `CustomInstallerWix.targets`
next to it, the same file in every generated project. `-Refresh` replaces that file wholesale, so fixes
reach existing projects without touching anything the user edits.

## The payload

- **.NET 5+** (`net8.0-windows`, ...): `dotnet publish -r win-x64 --self-contained` into
  `obj\payload\<Config>\`, which is deleted before every publish so a file the app no longer ships is not
  harvested from an old one. Self-contained means the target PC needs no .NET runtime. The cost is about
  70 MB more in the MSI.
  The runtime is `win-x64`, or `win-x86` when the app's `PlatformTarget` (or `RuntimeIdentifier`) says x86:
  publishing an x86 app for `win-x64` fails with NETSDK1032. ARM64 apps are refused for now.
- **Several target frameworks** (`<TargetFrameworks>net48;net8.0-windows</TargetFrameworks>`): `dotnet publish`
  fails without `-f`, so the newest .NET 5+ one is packaged (the newest .NET Framework one if there's no
  .NET 5+ target) and written to `<AppTargetFramework>`. A single-target app gets no `AppTargetFramework`,
  so retargeting the app later needs no edit in the Setup project.
- **WinUI 3**: only an unpackaged app (`<WindowsPackageType>None</WindowsPackageType>`) can be installed by an
  .msi. A packaged one runs only from its .msix, and the generator refuses it. An unpackaged app is
  published with `-p:WindowsAppSDKSelfContained=true` (`<AppPublishArguments>`), so the Windows App SDK
  runtime ships in the install folder instead of being a prerequisite.
- **.NET Framework**: the app's normal build output (`bin\...`). The Framework is part of Windows, but not
  always the version the app targets (Windows 10 before 1903 has no 4.8, for example). So the setup .exe
  checks `HKLM\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full\Release` against the targeted version
  (4.5 and later) with a `bal:Condition`. A PC with an older Framework sees the failure page with a
  message saying what to install, before anything is changed. Uninstall and repair are never blocked
  (`WixBundleInstalled`). The bare .msi doesn't check.
- Files are harvested with `<Files Include="$(PayloadDir)**">`, so a new dependency never needs a `.wxs`
  edit. `*.pdb` files are excluded.
- WiX skips recompiling when no source file changed. A new version number or a new payload file doesn't
  change a source file, so the build writes `obj\...\payload.stamp` (the version plus the file list) and
  makes it a compile input. Without it, a version bump can ship the previous `.msi` unchanged.

## Version

In order: `-p:ProductVersion=x.y.z`, else the built app's **file version** (from `<Version>`/`<FileVersion>`,
or `[AssemblyFileVersion]` in a legacy project), else its `AssemblyVersion`. The file version comes first
because it is what teams bump per release; `AssemblyVersion` is often pinned on purpose so that binding
redirects keep working, and an installer that followed it would never upgrade. The numeric parts are read,
not the version string, which may carry a `+commit` suffix.

Windows Installer compares only **the first three parts**, so `1.2.3.4` → `1.2.3.5` installs side by side, or
is refused, instead of upgrading. Bump major, minor or build. The build:
- **fails** on a version Windows Installer can't hold (major or minor above 255, build above 65535), such
  as a date-style `2026.10.14`.
- **warns** on `1.0.0`, the .NET default when nobody set a version. It can be a real first release, so it
  doesn't fail.

## `REINSTALLMODE=amus`

The default mode (`omus`) overwrites a file only if the installed copy is older. If an assembly's version
went *down* (an `AssemblyVersion` reset, a dependency downgraded), the new file is dropped from the plan,
but the major upgrade still removes the old one, so the file ends up missing and the app can't start.
`amus` writes every file regardless. It is a `SetProperty` rather than a `Property` because a bootstrapper
passes `REINSTALLMODE` on the command line, which beats the Property table.

## Identity: what must never change

Windows decides that a new installer upgrades an installed product by its UpgradeCode, and the new version
then finds the user's choices by the registry key. So these are fixed once an installer has shipped, and
`-Refresh` refuses to change them:
- the UpgradeCodes (package and bundle)
- the product name: install folder and Add/Remove Programs name
- the manufacturer: part of the registry key
- the scope. A per-user and a per-machine package are separate installations to Windows. A per-machine
  "upgrade" of a per-user install leaves the old one in place, and both stay in Add/Remove Programs.

## UpgradeCode

Generated once, when the project is created. It is how Windows recognises version N+1 as an upgrade of N.
Change it, or generate a second Setup project, and new installers install next to the old ones. The bundle
has its own, different UpgradeCode. Sharing one with the MSI makes Burn treat its own package as a related
bundle.

## The user's choices, remembered

- Desktop and Start menu shortcuts follow `DESKTOPSHORTCUT` and `STARTMENUSHORTCUT` (1/0); the install
  folder is `INSTALLFOLDER`. The wizard's Options page sets them; the bundle passes them to the .msi.
- All three are written to `<HKLM|HKCU>\Software\<Manufacturer>\<Product>` (`DesktopShortcut`,
  `StartMenu`, `InstallFolder`) on every install, by a component that is always installed, because a "no"
  can't be recorded by a component that isn't installed. (`StartMenu`, not `StartMenuShortcut`: that name
  is already the Start menu shortcut component's own key path.) The MSI reads it back when nothing is passed, and the bundle reads it during detect.
  Without this, an unattended upgrade would put back a shortcut the user deleted, or remove one they asked
  for. Burn's `Persisted="yes"` doesn't help: it persists per bundle registration, and every version is a
  new registration.
- Shortcut components use an **HKCU** key path even in per-machine packages. Windows Installer validation
  (ICE38/ICE43/ICE57) rejects anything else for a component holding a non-advertised shortcut.

## The install folder

- First install: the Options page shows the default (`Program Files\<Product>` or
  `%LOCALAPPDATA%\Programs\<Product>`) in an editable box with Browse. `Setup.exe InstallFolder=...` sets
  it unattended.
- Upgrade: the bundle reads `InstallFolder` back, and finding the product's registry key at all sets
  `ProductInstalled`, which disables the box and Browse ("Installed here already"). Windows Installer
  doesn't reuse a custom folder on a major upgrade by itself; without this, v2 would go to the default
  folder and v1's files would move. Moving an installed app is an uninstall and a fresh install.
- The .msi reads `InstallFolder` back too (`INSTALLFOLDER_REMEMBERED`), so a bare-.msi upgrade keeps it.
- A per-user install runs without admin rights, so a folder like Program Files fails with "access
  denied". The Options page says so under the box; the wizard can't check the folder itself.

## Per-user or all users: fixed when generating

Choosing the scope in the wizard needs a "configurable-scope bundle", which only WiX 7 has (FireGiant:
"available in WiX v7 and later"). In WiX 6 a `perUserOrMachine` package inside a bundle is treated as
per-machine, so "just me" would still ask for admin rights. WiX 7 needs the OSMF EULA (see the top of this
file), so the scope is `-Scope` when generating. Moving to WiX 7 later would enable the stock
`WixStdBAScope` radio buttons.

## Per-user packages

They install to `%LOCALAPPDATA%\Programs\<Product>`. That is deliberately not `%LOCALAPPDATA%\<Product>`,
which is where apps keep data that must survive an uninstall. ICE38/ICE64/ICE91 are suppressed: they
demand an HKCU key path on every harvested file, which `<Files>` can't provide, and the package is correct
without it.

## The setup .exe (the bundle)

- Only an `.exe` can show the app's icon in Explorer. Every `.msi` gets msiexec's icon.
- `Theme` must name a stock theme even though `Assets\Theme.xml` replaces the layout, because the stock theme
  is what writes wixstdba's settings. `Theme="none"` builds, then exits at start-up ("manifest is missing
  wixstdba information"). With a license: `rtfLicense` (the license is shown inside the wizard). Without
  one: `hyperlinkLicense` with `LicenseUrl=""`, which is the stock "no license" setting.
- The stock theme already ships a `logo.png`, so ours goes through `LogoFile`. A second `Payload` named
  `logo.png` fails with WIX8002.
- Every image `Theme.xml` names must be a `Payload`. A missing one doesn't fail the build. The bootstrapper
  exits before drawing anything.
- Control names in `Theme.xml` (`InstallButton`, `EulaAcceptCheckbox`, `OverallCalculatedProgressbar`, ...)
  are how wixstdba finds its controls. Keep them.
- The panel is white because thmutil draws checkbox text near-black whatever the theme says. The brand
  colour is in the sidebar image (an accent gradient with the logo on a white card, on every page) and
  the button images. The accent comes from the logo and is darkened until white text on it is readable.
- Buttons are images, one 88×26 file per state. A sprite sheet fails to parse, and a button with fewer than
  three state images makes the theme fail to load.
- Install is gated by wixstdba's own `EulaAcceptCheckbox`: wixstdba disables `InstallButton` until it is
  ticked, which also blocks the keyboard. `HideWhenDisabled` makes thmutil hide the disabled button, and
  `InstallBlockedButton` (grey, inert) at the same place shows through. thmutil has no disabled-state
  image, and a disabled image button still looks clickable.
  - Declare `InstallBlockedButton` **after** `InstallButton`, and give it `HexStyle="4000000"`
    (`WS_CLIPSIBLINGS`). Win32 stacks sibling controls in creation order with the first one on top. Earlier
    generated themes declared it first: ticking the box enabled the real Install button underneath, but the
    grey one stayed on top and swallowed the click. Reordering alone fixes the clicks, but the grey button
    still paints over the blue one; `WS_CLIPSIBLINGS` keeps it from painting over a sibling above it.
    `-Refresh` rewrites `Assets\Theme.xml` with the fix.
  - Don't make the grey button react to a variable instead. wixstdba owns `EulaAcceptCheckbox` and never
    writes it to a variable, so a `VisibleCondition` on it never changes. Earlier versions did that, and
    the grey button never went away.
  - Don't wrap `InstallButton` in a `Panel` to hide it: thmutil's Panel is meant for billboards, and it
    broke page tracking (a refresh showed another page's controls).
- `InstallButton` must stay on the `Install` page. wixstdba tracks only its own pages (Install, Modify,
  Progress, ...): when the install starts it hides `Install` and shows `Progress`. An Install button on a
  custom page leaves that page drawn over the progress and success pages. The Options page is therefore
  reached with `ChangePageAction` and returns to `Install` (OK keeps the changes; Cancel restores them).
- Controls on a custom page aren't wixstdba's, so their `VisibleCondition` and `EnableCondition` work, and
  named checkboxes and edit boxes write their variables (checkboxes on click; edit boxes when the page is
  left).
- Negative X/Y place a control's right/bottom edge that far from the window's. Overlapping controls paint
  over each other: the version label is kept narrow so it doesn't hide the Options button.
- `License.rtf` is always there in a new project: the one word `LICENSE` until the developer replaces it.
  A refreshed project that shipped without a license stays without one (`hyperlinkLicense`).
- `MsiPackage Visible="no"`: only the bundle appears in Add/Remove Programs.
- `Version="!(bind.packageVersion.MainPackage)"`: the bundle always carries the MSI's version.

## Code signing

Generated, and off until a certificate is named:

```
msbuild <App>.Setup\<App>.Setup.wixproj -restore -p:Configuration=Release -p:SignCertificateThumbprint=<sha1>
```

A bundle has to be signed in three steps, and the WiX SDK's signing pipeline (`SignOutput=true`) runs
them. `CustomInstallerWix.targets` fills in the SDK's empty `SignMsi`, `SignBundleEngine` and `SignBundle`
targets:
1. The `.msi` is signed in the inner build, before the bundle embeds it.
2. The setup engine is detached from the `.exe` (`InscribeBundleEngine`) and signed. Burn checks the
   engine's own signature, so signing only the finished `.exe` isn't enough.
3. The engine is reattached and the `.exe` itself is signed last.

The command is `signtool sign /sha1 <thumbprint> /fd sha256 /tr <SignTimestampUrl> /td sha256`. signtool is
the newest one in the Windows 10/11 SDK (`SignToolPath` overrides it). The timestamp (DigiCert's public
server by default) keeps signatures valid after the certificate expires. For signers that aren't a
certificate in the store (Azure Trusted Signing, a hardware token, a signing service), set `SignCommand`
to the whole command. The file to sign is appended, in quotes. Pass these on the command line or from
CI secrets; don't commit them.
