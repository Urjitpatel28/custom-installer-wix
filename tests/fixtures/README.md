# Test fixtures

`v1-wpf-net8-peruser-bundle/` is a solution as the **first** generator left it (WiX 5.0.2, no
`CustomInstallerWixVersion` stamp, build logic inline in the `.wixproj`). It is frozen on purpose:
the Pester tests and `Invoke-EndToEnd.ps1` use it to prove that `New-WixSetup.ps1 -Refresh` migrates
such a project to the current templates without changing its UpgradeCodes, and that an installer
built from it upgrades in place to one built after the refresh.

Don't regenerate it. When the templates change again, add a new fixture next to it instead.
