# Examples

Plain apps with **no installer**, used by the tests and CI to exercise the generator:

| Example | What it covers |
|---|---|
| [wpf-net8](wpf-net8/) | SDK-style WPF on .NET 8 with an `<ApplicationIcon>`, a class library and an xUnit project (which must not be offered as the app). Packaged as a self-contained publish. |
| [winforms-net48](winforms-net48/) | Legacy (non-SDK) WinForms project on .NET Framework 4.8, AnyCPU only, with **no icon**, and metadata in `Properties\AssemblyInfo.cs`. Packaged from its build output. |

Keep them installer-free. [../samples/](../samples/) has the same apps after the generator ran.
