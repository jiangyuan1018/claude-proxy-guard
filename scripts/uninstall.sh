#!/bin/bash
set -euo pipefail

for pair in \
    "io.github.jiangyuan1018.claude-proxy-guard:$HOME/Applications/Claude Proxy Guard.app" \
    "io.github.jiangyuan1018.claude-egress-guard:$HOME/Applications/Claude Egress Guard.app"; do
    task_label="${pair%%:*}"
    task_app="${pair#*:}"
    task_agent="$HOME/Library/LaunchAgents/$task_label.plist"
    if [[ -d "$task_app" ]]; then
        task_bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$task_app/Contents/Info.plist")"
        [[ "$task_bundle_id" == "$task_label" ]] || { echo "Refusing to remove an unrelated app: $task_app" >&2; exit 1; }
    fi
    /bin/launchctl bootout "gui/$(id -u)/$task_label" 2>/dev/null || true
    rm -f "$task_agent"
    rm -rf "$task_app"
done
printf 'Removed Claude Proxy Guard. Claude, Clash, and ~/.config/claude-proxy-guard were not modified.\n'
