---
name: custom-installer-wix
description: Add a WiX v6 installer to a .NET solution (.sln or .slnx) in Visual Studio 2022 or 2026. It finds the startup (WinExe/Exe) project, packages it (.NET Framework build output, or a self-contained publish for .NET 5+), uses the app's own icon as the installer logo, and adds one <App>.Setup project that builds a branded, modern setup .exe (the .msi is built and embedded inside it) that upgrades earlier versions in place. Also brings Setup projects it generated earlier up to date (-Refresh). Use when the user types /custom-installer-wix, or asks to "create an installer", "add a WiX setup project", "make an MSI", "package this app for install", "add a setup.exe", or "update/upgrade the installer project" for a WPF, WinForms, WinUI or console .NET app.
argument-hint: "[--per-user] [--project <name>] [--license <file>] [--refresh]"
---

# custom-installer-wix

You add an installer to the .NET solution in the current repo. **You** make the judgement calls: which app,
what to call it, and what to ask the developer. The bundled **scripts** do the mechanics: reading projects,
filling templates, drawing images and editing the `.sln`/`.slnx`. Don't hand-write the WiX files. Run the
scripts, then explain what they produced.

Scripts live in `scripts/` under this skill's base directory. Run them with Windows PowerShell:

```
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill dir>\scripts\<Script>.ps1" ...
```

## What gets generated

One project, `<App>.Setup\` (next to the app's project folder):
- `<App>.Setup.wixproj`: WiX 6 SDK project. Building it puts **only `<Product>Setup.exe`** in
  `bin\<Configuration>\` (`bin\Debug\` in Visual Studio's default configuration). It always packages the
  app's **Release** build, whatever the setup's configuration (`-p:AppConfiguration=Debug` to override).
  The build logic is in `CustomInstallerWix.targets` beside it.
- `Package.wxs`: the .msi, which the project builds first (an inner build into `obj\msi\`) and embeds in
  the .exe. Per-machine (Program Files) or per-user (`%LOCALAPPDATA%\Programs`), with:
  - the app icon in Add/Remove Programs
  - Start menu and desktop shortcuts, each the end user's choice; the choices and the install folder are
    remembered, so an upgrade keeps them
  - `MajorUpgrade`, so a new version replaces the old one in place
  - `REINSTALLMODE=amus`
- `Bundle.wxs` and `Assets\`: the setup .exe, with the app's icon on the file and a branded wizard (an
  accent sidebar drawn from the icon):
  - **Install page**: the license with "I agree" (Install stays greyed out until it is ticked),
    **Options...**, Install, Cancel.
  - **Options page**: the install location (box + Browse; locked to the installed folder on upgrades) and
    the Desktop and Start menu checkboxes; OK / Cancel go back.
  - Launch at the end; repair, uninstall and upgrade pages in the same style.
- `License.rtf`: always present. Without `-License` it holds the one-word placeholder `LICENSE`, which the
  developer replaces with their agreement (edit it in WordPad or Word) before building a release.
- The project is added to the `.sln` or `.slnx` so that **no solution build** ("Build Solution", CI's
  `msbuild X.sln`) builds it. It is built on its own (right-click > Build).
- The `.wixproj` carries `<CustomInstallerWixVersion>`, which `-Refresh` uses.
- For a .NET Framework app, the setup .exe checks that the PC has the Framework version the app targets
  (4.5 or later) and stops with a readable message if not, instead of installing an app that can't start.
- Code signing is generated but off. It turns on when `SignCertificateThumbprint` (or `SignCommand`) is
  set, and then signs the .msi, the setup engine and the setup .exe.

## Workflow

### 1. Find the app

Find the solution, `.sln` or `.slnx` (ask if there are several). Run:

```
Find-StartupProject.ps1 -Solution <path.sln|path.slnx>
```

The output is JSON with `ExistingSetup`, `Candidates` (best first) and `Skipped`.

- If `ExistingSetup` is not empty, **don't generate a new project**. Another one would mint a new
  UpgradeCode, and its installers would install side by side with the ones already shipped instead of
  upgrading them. Look at the entries:
  - `Generated` and not `Current` (an older generator, e.g. WiX 5, or two projects `<App>.Setup` +
    `<App>.Setup.Bundle`): offer **`-Refresh`** (step 3b), which brings it up to date, merges it into one
    project and keeps its identity.
  - `Generated` and `Current`: it is up to date. Help edit it directly.
  - Not `Generated`: someone else's WiX project. Help edit it by hand; the scripts won't touch it.
- No candidates: tell the user that no WinExe/Exe project was found, and stop.
- One candidate: use it.
- Several: ask which one to package. A solution file doesn't record Visual Studio's startup project. List
  the candidates with their `Kind`, and put the first one (WinExe before Exe) first as the suggestion.
- A candidate with `IsMsixPackaged` true (a WinUI 3 app without `<WindowsPackageType>None</WindowsPackageType>`)
  can't be packaged: it runs only from its .msix. Say so. Don't edit the app's project to change that; it's
  the developer's decision, because an unpackaged app loses package identity.
- A modern app whose `RuntimeIdentifier` isn't `win-x64` or `win-x86` (ARM64) can't be packaged yet.
- `PackageTargetFramework` is set when the app targets several frameworks: that one is packaged. Mention it.

### 2. Ask once, in one message

Use what the JSON already tells you (`Product`, `Company`, `Description`, `ApplicationIcon`) as defaults, and
ask only for what's missing or worth confirming. Skip anything the user's arguments already answered.

| Option | Default | Script parameter |
|---|---|---|
| Product name | `Product`, else `Title`, else assembly name | `-ProductName` |
| Manufacturer | `Company`. **Required**: ask if empty | `-Manufacturer` |
| Install for | all users (Program Files, needs admin) | `-Scope perMachine` / `perUser` |
| Desktop shortcut ticked by default | yes | `-NoDesktopShortcut` |
| License text | the placeholder `LICENSE` (look for `LICENSE`, `LICENSE.txt`, `EULA.rtf` in the repo and offer it) | `-License <file>` (.rtf, or plain text that gets converted) |
| Website (Add/Remove Programs link) | none | `-Url` |

The end user picks the install folder and the shortcuts in the wizard. **"Install for" is fixed here, not
in the wizard**: an install-time choice between per-user and all users needs WiX 7 ("configurable-scope
bundles") and its OSMF licence. If the user asks for it, explain that, and don't work around it.

Say plainly that **the product name, manufacturer and scope are permanent** once installers ship: changing
any of them later stops new versions from upgrading installed ones.

**Icon.** If `IconExists` is true, use the project's `ApplicationIcon` and say so. Otherwise ask for a
logo file (.ico, or .png, which gets converted to a multi-size .ico). If the user has none, continue with
`-NoIcon`. Never invent a logo.

### 3a. Generate

```
New-WixSetup.ps1 -Solution <sln|slnx> -Project <name> -Manufacturer "<...>" [-ProductName "<...>"] [-Scope perUser]
                 [-Icon <file> | -NoIcon] [-License <file>] [-NoDesktopShortcut] [-Url <url>]
```

It prints JSON with the created files, the UpgradeCodes and the build commands. If it throws, report the
message. Its refusals (existing WiX project, folder already there) are deliberate, so don't work around
them.

### 3b. Refresh an existing generated project

```
New-WixSetup.ps1 -Solution <sln|slnx> -Refresh [-License <file>] [-Icon <file>] [-Url <url>] [-NoDesktopShortcut]
```

It rewrites the generated files from the current templates (WiX version, build logic, wizard theme) and
keeps both UpgradeCodes, product name, manufacturer, scope, install folder and registry key. A setup with a
separate `<App>.Setup.Bundle` project is merged: that project is removed from the solution and its folder
deleted (its UpgradeCode moves into `<App>.Setup\Bundle.wxs`). A setup that was .msi-only gets the setup
.exe. It refuses when:
- the Setup folders (or, for a merge, the solution file) have uncommitted changes, or aren't in git. The refresh overwrites hand edits, so the
  result must show up as its own diff. Ask the user to commit first. Use `-Force` only if they say so.
- `-ProductName`, `-Manufacturer` or `-Scope` would change. Explain why (step 2) instead of forcing it.

Afterwards, show the user the diff (the `Review` command in the JSON) and point out any of their own edits
that were overwritten, so they can re-apply them.

### 4. Build it once

Build the Setup project with **MSBuild**, not `dotnet build`. Legacy .NET Framework projects and WiX's VS
integration both expect MSBuild. Visual Studio 2022 or 2026 (or their Build Tools) both work. Find MSBuild
with:
`"%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe" -latest -products * -requires Microsoft.Component.MSBuild -find MSBuild\**\Bin\MSBuild.exe`.

```
MSBuild.exe <App>.Setup\<App>.Setup.wixproj -restore -p:Configuration=Debug
```

Check that `<App>.Setup\bin\Debug\` holds only `<Product>Setup.exe`.

The first build downloads `WixToolset.Sdk` 6.0.2 and its extensions from nuget.org. For .NET 5+ apps it also
downloads the runtime packs for the self-contained publish. If the build fails, read
[references/troubleshooting.md](references/troubleshooting.md) before changing anything.

### 5. Report

Tell the user:
- What was packaged, and how (build output, or self-contained publish), plus the scope.
- If no `-License` was given: **replace the `LICENSE` placeholder in `<App>.Setup\License.rtf`** with the
  real agreement before shipping. Nothing checks it.
- Where the `.exe` is: `<App>.Setup\bin\Debug\` or `bin\Release\`, the only file there. It packages the
  app's Release build either way.
- It installs silently with `<Product>Setup.exe /quiet`. If an IT department wants the bare `.msi`, it is
  at `<App>.Setup\obj\msi\bin\<Configuration>\en-us\` after a build, or `wix burn extract <Product>Setup.exe -o out`
  extracts it from a shipped .exe (the file is named `a0`; rename it to `.msi`).
- **To open the Setup project in Visual Studio, install the FireGiant HeatWave extension** (free
  Community edition). Without it they show as "incompatible". Building from the command line needs
  nothing extra.
- **To release a new version, bump `<Version>` in the app's project** (or `AssemblyFileVersion` in a
  legacy project). The installer's version is the app's file version. Windows Installer compares only the
  first three parts, so `1.2.0.5` → `1.2.0.6` is **not** an upgrade. `-p:ProductVersion=x.y.z` overrides
  it. Running the new setup over the old one upgrades in place, in the folder the user chose, keeping
  their shortcut choices.
- Never change the `UpgradeCode`s in `Package.wxs` / `Bundle.wxs`.
- The Setup project is not built by "Build Solution". Right-click and choose Build, or use the command
  above in CI.

## Rules

- Pin WiX to **6.0.2** (SDK and extensions). WiX v7+ requires accepting the Open Source Maintenance Fee
  EULA, which is a commitment for the user's organisation, not something to do in their build. Don't
  "upgrade" it.
- Don't put the Setup project into solution builds (no `Build.0` lines in a `.sln`; `<Build Project="false" />`
  in a `.slnx`).
- Don't edit the app's own project to make packaging work. The Setup project adapts to the app.
- Don't remove `REINSTALLMODE=amus`. Without it, a file whose version went down is deleted on upgrade and
  not replaced.
- Never switch an existing product between per-user and per-machine. The two never upgrade each other.
- Don't edit `CustomInstallerWix.targets` in a generated project; `-Refresh` replaces it. Put changes in
  the `.wixproj`.
- Don't add a second WiX project for the bundle. One `<App>.Setup` project builds both the .msi and the
  setup .exe.
- Keep InstallButton on the wizard's `Install` page. wixstdba hides only its own pages when the install
  starts, so an Install button on a custom page leaves that page drawn over the progress page.
- Code signing is built in but off. If the user asks, tell them to pass `-p:SignCertificateThumbprint=<thumbprint>`
  (or set `SignCommand` for a cloud or hardware-token signer). Don't put a certificate or password in the
  repo. Details: [references/wix-notes.md](references/wix-notes.md).

More background on each design choice: [references/wix-notes.md](references/wix-notes.md).
