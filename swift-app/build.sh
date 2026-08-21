#!/bin/bash
# Build the native Herdr client against the vendored libghostty embedding API.

set -e
cd "$(dirname "$0")"

# Icon table is generated from Assets/AgentIcons/*.png (best-effort:
# falls back to the committed AgentIcons.swift when python3 is absent).
if command -v python3 >/dev/null 2>&1 && \
   ( [ ! -f Sources/AgentIcons.swift ] || \
     [ -n "$(find Assets/AgentIcons -name '*.png' -newer Sources/AgentIcons.swift -print -quit 2>/dev/null)" ] ); then
    python3 tools/gen_agent_icons.py
fi

MAPFILE=CGhostty/include/module.modulemap

VENDOR_SOURCES=(
    vendor-swift/Ghostty/GhosttyPackageMeta.swift
    vendor-swift/Ghostty/Ghostty.App.swift
    vendor-swift/Ghostty/Ghostty.Surface.swift
    vendor-swift/Ghostty/FullscreenMode+Extension.swift
    vendor-swift/Ghostty/Ghostty.Action.swift
    vendor-swift/Ghostty/Ghostty.Config.swift
    vendor-swift/Ghostty/Ghostty.ConfigTypes.swift
    vendor-swift/Ghostty/Ghostty.Event.swift
    vendor-swift/Ghostty/Ghostty.Command.swift
    vendor-swift/Ghostty/Ghostty.Inspector.swift

    vendor-swift/Ghostty/Ghostty.Shell.swift

    vendor-swift/Ghostty/Ghostty.Input.swift
    vendor-swift/Ghostty/Ghostty.Error.swift
    vendor-swift/Ghostty/GhosttyDelegate.swift
    vendor-swift/Ghostty/ConfigEnums.swift
    vendor-swift/Ghostty/NSEvent+Extension.swift
    vendor-swift/Ghostty/SurfaceViewDir/SurfaceView.swift
    vendor-swift/Ghostty/SurfaceViewDir/SurfaceProgressBar.swift

    vendor-swift/Ghostty/SurfaceViewDir/SurfaceView_AppKit.swift
    vendor-swift/Ghostty/SurfaceViewDir/SurfaceScrollView.swift
    vendor-swift/Helpers/CrossKit.swift
    vendor-swift/Helpers/Cursor.swift
    vendor-swift/Helpers/SecureInput.swift
    vendor-swift/Helpers/Fullscreen.swift
    vendor-swift/Helpers/KeyboardLayout.swift

    vendor-swift/Helpers/Weak.swift
    vendor-swift/Helpers/QuickTerminalPosition.swift
    vendor-swift/Helpers/QuickTerminalScreen.swift
    vendor-swift/Helpers/QuickTerminalSize.swift
    vendor-swift/Helpers/QuickTerminalSpaceBehavior.swift
    vendor-swift/Helpers/Extensions/Array+Extension.swift
    vendor-swift/Helpers/SecureInputOverlay.swift
    vendor-swift/Helpers/Extensions/EventModifiers+Extension.swift
    vendor-swift/Helpers/Extensions/NSAppearance+Extension.swift
    vendor-swift/Helpers/Extensions/UserDefaults+Extension.swift
    vendor-swift/Helpers/Extensions/NSMenuItem+Extension.swift
    vendor-swift/Helpers/Extensions/NSPasteboard+Extension.swift
    vendor-swift/Helpers/Extensions/NSScreen+Extension.swift
    vendor-swift/Helpers/Extensions/NSWorkspace+Extension.swift
    vendor-swift/Helpers/Extensions/ObjectIdentifier+Extension.swift
    vendor-swift/Helpers/Extensions/OSColor+Extension.swift
    vendor-swift/Helpers/Extensions/UUID+Extension.swift
)

SWIFT_SOURCES=("${VENDOR_SOURCES[@]}" Sources/*.swift)


swiftc \
    -parse-as-library -enable-bare-slash-regex -warnings-as-errors \
    -O -whole-module-optimization \
    "${SWIFT_SOURCES[@]}" \
    -Xcc -fmodule-map-file=$MAPFILE \
    -Xcc -ICGhostty/include \
    -L CGhostty/lib -lghostty \
    -Xlinker -rpath -Xlinker @executable_path/CGhostty/lib \
    -Xlinker -dead_strip \
    -framework AppKit \
    -framework Metal -framework MetalKit -framework CoreVideo \
    -framework QuartzCore -framework UserNotifications \
    -framework UniformTypeIdentifiers -framework ServiceManagement \
    -o herdr-mirror

echo "built: $(pwd)/herdr-mirror"
