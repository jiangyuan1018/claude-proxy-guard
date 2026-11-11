#!/bin/bash
set -euo pipefail

task_label="io.github.jiangyuan1018.claude-egress-guard"
task_app="$HOME/Applications/Claude Egress Guard.app"
task_agent="$HOME/Library/LaunchAgents/$task_label.plist"
if [[ -d "$task_app" ]]; then
    task_bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$task_app/Contents/Info.plist")"
    [[ "$task_bundle_id" == "$task_label" ]] || { echo "Refusing to remove an unrelated app." >&2; exit 1; }
fi
/bin/launchctl bootout "gui/$(id -u)/$task_label" 2>/dev/null || true
rm -f "$task_agent"
rm -rf "$task_app"
printf 'Removed Claude Egress Guard. Claude and Clash configurations were not modified.\n'
