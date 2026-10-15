# Samples

Each folder is one of the [examples](../examples/) after running the skill's generator on it. Open the `.sln`
in Visual Studio 2022 or 2026 (with HeatWave) to see the generated `<App>.Setup` project next to the app.

| Sample | App | Options |
|---|---|---|
| [wpf-net8-peruser](wpf-net8-peruser/) | WPF, .NET 8, with icon | per-user, license, website |
| [winforms-net48-permachine](winforms-net48-permachine/) | WinForms, .NET Framework 4.8 (legacy csproj), no icon | per-machine, license, no desktop shortcut by default |
| [winforms-net48-peruser-nolicense](winforms-net48-peruser-nolicense/) | same | per-user, placeholder license (`LICENSE`) |

What to look for (generator version 5):
- The WinForms samples' `Bundle.wxs` has the .NET Framework 4.8 check (`bal:Condition` on `NetFxRelease`).
  The WPF sample has none: it ships its own runtime.
- Every `.wixproj` has the signing switch, `SignCertificateThumbprint`, empty (signing off).
- `CustomInstallerWix.targets` is identical in all three. It's the build logic, including the signing
  targets.

They are generated, not hand-kept: [tests/Update-Samples.ps1](../tests/Update-Samples.ps1) rebuilds this
folder from `examples/` with these arguments:

```
New-WixSetup.ps1 -Solution InventoryApp.sln -Manufacturer "Contoso Ltd" -Scope perUser -License LICENSE.txt -Url https://contoso.example
New-WixSetup.ps1 -Solution ClinicDesk.sln -Manufacturer "Northwind Health" -License LICENSE.txt -NoDesktopShortcut
New-WixSetup.ps1 -Solution ClinicDesk.sln -Manufacturer "Northwind Health" -Scope perUser
```

The Pester suite regenerates them into a scratch folder and fails if this folder differs (GUIDs and images
aside). After changing a template or script, run `tests\Update-Samples.ps1` and commit the result.

## Installers

The built setup `.exe` files are not committed, because they would go stale with every template change.
CI builds the same scenarios in [tests/Invoke-EndToEnd.ps1](../tests/Invoke-EndToEnd.ps1) (generate, build,
install, upgrade v1 → v2, uninstall) and uploads the setups as the `installers` workflow artifact. To build
one locally:

```
msbuild wpf-net8-peruser\src\InventoryApp.Setup\InventoryApp.Setup.wixproj -restore -p:Configuration=Debug
```

The setup lands in `src\InventoryApp.Setup\bin\Debug\ContosoInventorySetup.exe`, the only file there.
