#!/bin/bash
# Build herdr-gui — the native macOS client for herdr servers.

set -e
cd "$(dirname "$0")"

# Icon table is generated from Assets/AgentIcons/*.png (best-effort:
# falls back to the committed Chrome/AgentIcons.swift when python3 is absent).
if command -v python3 >/dev/null 2>&1 && \
   ( [ ! -f Sources/Chrome/AgentIcons.swift ] || \
     [ -n "$(find Assets/AgentIcons -name '*.png' -newer Sources/Chrome/AgentIcons.swift -print -quit 2>/dev/null)" ] ); then
    python3 tools/gen_agent_icons.py
fi

# App icon + menu-bar template are generated from Assets/AppIcon/*.png.
if command -v python3 >/dev/null 2>&1 && \
   ( [ ! -f Sources/Chrome/AppIcon.swift ] || \
     [ -n "$(find Assets/AppIcon -name '*.png' -newer Sources/Chrome/AppIcon.swift -print -quit 2>/dev/null)" ] ); then
    python3 tools/gen_app_icon.py
fi

APP_SOURCES=($(find Sources -type f -name '*.swift' | sort))

swiftc \
    -parse-as-library -enable-bare-slash-regex -warnings-as-errors \
    -O -whole-module-optimization \
    "${APP_SOURCES[@]}" \
    -framework AppKit \
    -framework CoreText -framework QuartzCore -framework UserNotifications \
    -Xlinker -dead_strip \
    -o herdr-gui
echo "built: $(pwd)/herdr-gui"
