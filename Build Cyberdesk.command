#!/bin/zsh
set -euo pipefail
cd -- "${0:A:h}"
app="$HOME/Library/Caches/Cyberdesk/Build/Cyberdesk.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
xcrun swiftc Source/main.swift Source/Configuration.swift Source/DesktopFiles.swift Source/Wallpaper.swift -o "$app/Contents/MacOS/Cyberdesk" -framework Cocoa -framework WebKit -framework IOKit -framework AVFoundation -framework QuartzCore
cp -X Info.plist "$app/Contents/Info.plist"
cp -X Source/desktop.html Source/config.example.json Source/city.png "$app/Contents/Resources/"
xattr -dr com.apple.FinderInfo "$app" 2>/dev/null || true
xattr -dr com.apple.ResourceFork "$app" 2>/dev/null || true
codesign --force --sign - "$app"
print "Built: $app"
print 'Open the app when ready. Sign-in startup is optional in its menu.'
