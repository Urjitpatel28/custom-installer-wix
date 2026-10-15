# Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Visual Studio shows `<App>.Setup (incompatible)` and writes `UpgradeLog.htm` | The HeatWave extension isn't installed | Extensions → Manage Extensions → install **HeatWave** (FireGiant), restart VS, then Reload Project. Delete the `UpgradeLog*.htm` files. |
| `MSB4236: The SDK 'WixToolset.Sdk/6.0.2' specified could not be found` | nuget.org unreachable on the first build | Build once with network access; the SDK is cached in `%USERPROFILE%\.nuget\packages` afterwards. |
| `NU1301 ... Microsoft.NETCore.App.Runtime.win-x64` | Self-contained publish needs runtime packs from nuget.org | Same as above. Then `-p:SkipAppBuild=true` packages whatever is already in `obj\payload\<Config>`. |
| `WIX6101` (extension built against a newer WiX) | An extension version doesn't match the SDK | Keep every `WixToolset.*` reference at `6.0.2`. |
| `WIX7015: You must accept the Open Source Maintenance Fee (OSMF) EULA` | Someone bumped the SDK to v7 | Pin back to `6.0.2`, or accept the OSMF deliberately (see wix-notes.md). |
| An older generated project still says `WixToolset.Sdk/5.0.2` | Generated before WiX 6 | Commit, then `New-WixSetup.ps1 -Solution X.sln -Refresh`. It keeps the UpgradeCodes. |
| Bundle build: `wixnative.exe failed ... The system cannot find the path specified` / `failed to add file` | The repo path is long and Burn's intermediate paths pass 260 characters | Build from a shorter path (e.g. `C:\src\App`), or turn on Windows long paths (`LongPathsEnabled`). |
| `ICE38` / `ICE43` / `ICE57` on a shortcut component | A shortcut component's key path isn't HKCU | Keep `Root="HKCU"` on the shortcut components' `RegistryValue`, even for per-machine installs. |
| `ICE38` / `ICE64` / `ICE91` in a per-user package | Harvested files in the user profile | These are suppressed in the generated per-user `.wixproj` (`SuppressIces`). Keep that line. |
| `<Exe> is not in <dir>. The app build did not produce it.` | The app's `AssemblyName` changed, or the build output went elsewhere | Fix `<AppExeName>`/`<AppAssemblyName>` in the `.wixproj` and the shortcut targets in `Package.wxs` (`Target="[INSTALLFOLDER]...`). |
| Legacy app: `The OutputPath property is not set for project` | The app has no PropertyGroup for the platform the Setup project passes | Set `<AppPlatform>` in the `.wixproj` to one the app declares (`AnyCPU`, `x64`). |
| `Version '2026.10.14' cannot be an installer version` | The app's version is date-style, or above 255.255.65535 | Give the app a `<Version>` within range, or pass `-p:ProductVersion=x.y.z`. |
| Warning `Packaging version 1.0.0, the .NET default` | The app project sets no `<Version>` | Fine for a first release. After that, set `<Version>` or nothing will upgrade. |
| A new version installs next to the old one, or "a newer version is already installed" | Only the 4th version part changed, the UpgradeCode changed, or the scope changed between per-user and per-machine | Bump major/minor/build of `<Version>` (the file version, not `AssemblyVersion`). Never change `UpgradeCode` or scope. |
| A rebuilt setup still has the old version | The `payload.stamp` or `bundle.stamp` block was removed from `CustomInstallerWix.targets` | `-Refresh` puts them back; WiX doesn't treat a version change, or a new embedded .msi, as a reason to recompile. |
| `bin\<Configuration>\` has more than the setup .exe | `SuppressPdbOutput` or the inner build's `OutputPath` (`obj\msi\...`) was changed in the `.wixproj` | `-Refresh` restores them. The .msi belongs in `obj\msi\`, embedded in the .exe. |
| Need the bare `.msi` (Intune, Group Policy) | The project ships only the setup .exe | Take it from `<App>.Setup\obj\msi\bin\<Configuration>\en-us\`, or `wix burn extract <Product>Setup.exe -o out` (the file is `a0`; rename it to `.msi`). `Setup.exe /layout` does not extract an embedded .msi. |
| Per-user setup fails with "access denied" / error 1925 / 5 | The user chose a folder they can't write to (e.g. under Program Files) on the Options page | Per-user installs run without admin rights: pick a folder under the user profile. For all-users installs, generate with `-Scope perMachine`. |
| The license page says just `LICENSE` | The placeholder in `<App>.Setup\License.rtf` was never replaced | Put the agreement in `License.rtf` (WordPad or Word), or regenerate with `-License <file>`, and rebuild. |
| Install stays grey | "I agree to the license terms" isn't ticked | Tick it. wixstdba keeps Install disabled (and the grey stand-in visible) until then. |
| Install stays grey even with the license box ticked | `Assets\Theme.xml` from an earlier generator declares `InstallBlockedButton` before `InstallButton`, so the grey button sits on top of the enabled one | Commit, then `New-WixSetup.ps1 -Solution X.sln -Refresh`, or move `InstallBlockedButton` below `InstallButton` by hand. |
| Install folder box and Browse are disabled | The product is already installed | By design: upgrades go to the installed folder. Uninstall first to install somewhere else. |
| The solution still has an `<App>.Setup.Bundle` project | Generated by an earlier version of the skill | Commit, then `New-WixSetup.ps1 -Solution X.sln -Refresh`. It merges it into `<App>.Setup` and keeps the UpgradeCodes. |
| `-Refresh`: "Uncommitted changes in files the refresh rewrites" / "not in a git repository" | The refresh overwrites generated files in place (and, when it merges an `<App>.Setup.Bundle` project, the solution file) | Commit or stash first, then review the diff. `-Force` skips the check. |
| `-Refresh`: "refusing to change it to ..." | `-ProductName`, `-Manufacturer` or `-Scope` differs from the shipped product | Leave them out. Changing them would break upgrades of installed copies. |
| Bundle `.exe` exits at once with nothing on screen | A theme image is missing from the `Payload` list, a control name was changed, or a button lost one of its three state images | Check the log in `%TEMP%\<Product>_*.log`. Every `ImageFile` in `Theme.xml` must have a matching `Payload Name=`. |
| `error WIX0010 ... exactly one of the LicenseFile or LicenseUrl` | The bundle's license was removed by hand | Without a license use `Theme="hyperlinkLicense" LicenseUrl=""`, and remove the license controls from `Theme.xml`. |
| `WIX8002` on `logo.png` | A `Payload` named `logo.png` was added | Use `LogoFile=` on `WixStandardBootstrapperApplication` instead. |
| Generator: "is packaged as MSIX" | A WinUI 3 app without `<WindowsPackageType>None</WindowsPackageType>` | A packaged app runs only from its .msix, so ship that. Or make the app unpackaged (the developer's call: it loses package identity) and run the generator again. |
| Generator: "is built for win-arm64" | The app's `PlatformTarget`/`RuntimeIdentifier` is ARM64 | Not supported yet. x64 apps run on ARM64 Windows 11 under emulation. |
| `NETSDK1032` (RuntimeIdentifier and PlatformTarget must be compatible) | The app's platform changed after generating (e.g. to x86) | Commit, then `New-WixSetup.ps1 -Solution X.sln -Refresh`. It re-reads the platform. Or set `<AppRuntimeIdentifier>` in the `.wixproj` by hand. |
| `NETSDK1129` / "must specify a framework" on publish | The app became multi-targeted after generating | `-Refresh` writes `<AppTargetFramework>`, or add it to the `.wixproj` by hand. |
| Setup stops with "needs .NET Framework 4.x or later" | The PC's .NET Framework is older than the app's target | Install the Framework (or the Windows update that includes it), then run setup again. To ship to such PCs, retarget the app. |
| "Signing is on ... but signtool.exe was not found" | `SignCertificateThumbprint` is set and no Windows SDK is installed | Install the Windows SDK (Visual Studio Installer → Individual components), set `SignToolPath`, or use `SignCommand`. |
| signtool: "No certificates were found that met all the given criteria" | The thumbprint isn't in the current user's (or the machine's) certificate store, or the certificate has no private key | Check with `Get-ChildItem Cert:\CurrentUser\My`. Build as the user who has the certificate. |
| Testing setup from Git Bash: `/passive` is ignored and the wizard opens | Git Bash rewrites `/passive` into a path | Use `MSYS_NO_PATHCONV=1 ./Setup.exe /passive`, or run from cmd/PowerShell. |

Visual Studio 2022 or 2026 shows `(incompatible)` even with HeatWave: check that the installed HeatWave supports that Visual Studio version (Extensions → Manage Extensions). Command-line builds are unaffected.

Burn logs: `%TEMP%\<Product>_<timestamp>.log`. MSI log: `msiexec /i X.msi /l*v install.log`.
