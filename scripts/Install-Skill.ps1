<#
.SYNOPSIS
    Copies the skill into your personal Claude Code skills folder (~/.claude/skills/custom-installer-wix),
    so /custom-installer-wix works in every repo. Re-run it after pulling changes.

    The plugin install (/plugin marketplace add Urjitpatel28/custom-installer-wix) does the same job and
    updates itself; use this when you work from a clone instead.
#>
[CmdletBinding()]
param(
    # Another agent's skills folder, e.g. "$HOME\.agents\skills".
    [string]$SkillsRoot = (Join-Path $HOME ".claude\skills")
)
$ErrorActionPreference = "Stop"
$source = Join-Path (Split-Path -Parent $PSScriptRoot) "skills\custom-installer-wix"
$dest = Join-Path $SkillsRoot "custom-installer-wix"
New-Item -ItemType Directory -Force $dest | Out-Null
# /MIR removes files the skill no longer has. robocopy exit codes below 8 are success.
robocopy $source $dest /MIR /NJH /NJS /NFL /NDL | Out-Null
if ($LASTEXITCODE -ge 8) { throw "robocopy failed with exit code $LASTEXITCODE." }
Write-Output "Installed to $dest"
