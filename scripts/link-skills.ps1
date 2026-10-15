# Creates the skill discovery links (.claude/.agents/.opencode -> skills/custom-installer-wix), so the skill
# can be used while working in this repo. Uses real symlinks when allowed (Developer Mode / admin);
# otherwise directory junctions, which work for local discovery but are not committed (they are added to
# .git/info/exclude).
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$name = "custom-installer-wix"
$target = Join-Path $root "skills\$name"
foreach ($dir in ".claude\skills", ".agents\skills", ".opencode\skills") {
    $parent = Join-Path $root $dir
    New-Item -ItemType Directory -Force $parent | Out-Null
    $link = Join-Path $parent $name
    if (Test-Path $link) { Write-Output "exists: $dir\$name"; continue }
    try {
        New-Item -ItemType SymbolicLink -Path $link -Target "..\..\skills\$name" | Out-Null
        Write-Output "symlink: $dir\$name"
    } catch {
        New-Item -ItemType Junction -Path $link -Target $target | Out-Null
        $exclude = Join-Path $root ".git\info\exclude"
        if (Test-Path (Split-Path $exclude)) { Add-Content $exclude ("/" + ($dir -replace '\', '/') + "/$name") }
        Write-Output "junction (not committed): $dir\$name"
    }
}
