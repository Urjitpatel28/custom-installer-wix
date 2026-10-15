#!/usr/bin/env sh
# Creates the skill discovery links (.claude/.agents/.opencode -> skills/custom-installer-wix) so the skill
# can be used while working in this repo. The skill itself only runs on Windows.
set -e
root="$(cd "$(dirname "$0")/.." && pwd)"
name="custom-installer-wix"
for dir in .claude/skills .agents/skills .opencode/skills; do
  mkdir -p "$root/$dir"
  if [ -e "$root/$dir/$name" ]; then echo "exists: $dir/$name"; continue; fi
  ln -s "../../skills/$name" "$root/$dir/$name"
  echo "symlink: $dir/$name"
done
