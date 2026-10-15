# Changelog

The major version is the generator version, `<CustomInstallerWixVersion>` in every generated `.wixproj`.
After upgrading the skill, run `New-WixSetup.ps1 -Solution X.sln -Refresh` to bring a generated Setup
project up to the new generator version. It keeps the UpgradeCodes.

## 5.0.0

- **Multi-targeted apps** (`<TargetFrameworks>net48;net8.0-windows</TargetFrameworks>`) are packaged. The
  newest .NET 5+ framework is published (`<AppTargetFramework>`). Before this, `dotnet publish` failed with
  NETSDK1129.
- **x86 apps** (`PlatformTarget` or `RuntimeIdentifier`) are published for `win-x86`. Before this, they failed
  with NETSDK1032. ARM64 apps are refused with a clear message.
- **WinUI 3**: an unpackaged app is published with the Windows App SDK runtime inside
  (`WindowsAppSDKSelfContained`). An MSIX-packaged app is refused, because an .msi can't install it. WinUI
  projects are no longer mistaken for WPF.
- **.NET Framework check**: for a .NET Framework app, the setup .exe stops with a readable message when the PC
  has an older Framework than the app targets, instead of installing an app that can't start.
- **Code signing**: generated, off by default. `-p:SignCertificateThumbprint=<sha1>` signs the .msi, the setup
  engine and the setup .exe with signtool. `SignCommand` supports any other signer.
- A plain-text licence with `•` bullet lines keeps each bullet as its own paragraph. Windows PowerShell
  misread the bullet in the script, which has no BOM.
- `-Refresh` also refuses when a merge would overwrite uncommitted changes to the solution file.
- The `.wixproj` comment no longer says `Setup.exe /layout` extracts the .msi. It doesn't; use
  `wix burn extract`.
- Repo: a Claude Code plugin marketplace manifest (`.claude-plugin/`), a PSScriptAnalyzer CI job,
  end-to-end scenarios for a `.slnx` solution and a per-machine upgrade, and this release workflow.

## 4

- The wizard's Options page: install folder (locked on upgrades) and a Start menu checkbox, both
  remembered. A new project always has a licence page (placeholder `LICENSE` until replaced).

## 3

- One `<App>.Setup` project builds both the .msi and the setup .exe. `-Refresh` merges the earlier
  `<App>.Setup.Bundle` project into it.

## 2

- The generator version is stamped into projects. A separate `<App>.Setup.Bundle` project builds the setup
  .exe.

## 1

- Projects from before the stamp, on WiX 5.0.2.
