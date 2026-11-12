#!/bin/bash
set -euo pipefail

task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_build="$task_root/.build"
task_app="$task_build/Claude Proxy Guard.app"
task_arch="$(/usr/bin/uname -m)"

case "$task_arch" in arm64|x86_64) ;; *) echo "Unsupported architecture: $task_arch" >&2; exit 1 ;; esac
for task_tool in /usr/bin/ruby /usr/bin/curl /usr/bin/xcrun /usr/bin/iconutil /usr/bin/codesign; do
    [[ -x "$task_tool" ]] || { echo "Missing required tool: $task_tool" >&2; exit 1; }
done
/usr/bin/xcrun --find swiftc >/dev/null

mkdir -p "$task_app/Contents/MacOS" "$task_app/Contents/Resources" "$task_build/module-cache"
/usr/bin/xcrun swiftc -O -target "$task_arch-apple-macosx13.0" \
    -module-cache-path "$task_build/module-cache" \
    "$task_root/Sources/ClaudeProxyGuard.swift" -o "$task_app/Contents/MacOS/ClaudeProxyGuard"
/usr/bin/xcrun swiftc -O -target "$task_arch-apple-macosx13.0" \
    -module-cache-path "$task_build/module-cache" \
    "$task_root/tools/RenderIcons.swift" -o "$task_build/RenderIcons"
"$task_build/RenderIcons" "$task_app/Contents/Resources" "$task_build/AppIcon.iconset" "$task_root/assets/Mascot.png"
/usr/bin/iconutil -c icns "$task_build/AppIcon.iconset" -o "$task_app/Contents/Resources/AppIcon.icns"
cp "$task_root/Resources/Info.plist" "$task_app/Contents/Info.plist"
cp "$task_root/Resources/proxy_check.rb" "$task_app/Contents/Resources/proxy_check.rb"
/usr/bin/plutil -lint "$task_app/Contents/Info.plist"
/usr/bin/ruby -c "$task_app/Contents/Resources/proxy_check.rb"
/usr/bin/ruby "$task_root/tests/probe_order.rb"
/usr/bin/codesign --force --sign - --timestamp=none "$task_app"
/usr/bin/codesign --verify --deep --strict "$task_app"
"$task_app/Contents/MacOS/ClaudeProxyGuard" --self-test
printf 'Built: %s\n' "$task_app"
