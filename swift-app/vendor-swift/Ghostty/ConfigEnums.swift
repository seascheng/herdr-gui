import Foundation

extension Ghostty {
    /// Enum for the macos-window-buttons config option
    enum MacOSWindowButtons: String {
        case visible
        case hidden
    }

    /// Enum for the macos-titlebar-proxy-icon config option
    enum MacOSTitlebarProxyIcon: String {
        case visible
        case hidden
    }

    /// Enum for auto-update-channel config option
    enum AutoUpdateChannel: String {
        case tip
        case stable
    }
}

extension Ghostty.Notification {
    /// Used to pass a configuration along when creating a new tab/window/split.
    static let NewSurfaceConfigKey = "com.mitchellh.ghostty.newSurfaceConfig"

    /// Posted when a new split is requested. The sending object will be the surface that had focus. The
    /// userdata has one key "direction" with the direction to split to.
    static let ghosttyNewSplit = Notification.Name("com.mitchellh.ghostty.newSplit")

    /// Close the calling surface.
    static let ghosttyCloseSurface = Notification.Name("com.mitchellh.ghostty.closeSurface")

    /// Focus previous/next split. Has a SplitFocusDirection in the userinfo.
    static let ghosttyFocusSplit = Notification.Name("com.mitchellh.ghostty.focusSplit")
    static let SplitDirectionKey = ghosttyFocusSplit.rawValue

    /// Goto tab. Has tab index in the userinfo.
    static let ghosttyGotoTab = Notification.Name("com.mitchellh.ghostty.gotoTab")
    static let GotoTabKey = ghosttyGotoTab.rawValue

    /// New tab. Has base surface config requested in userinfo.
    static let ghosttyNewTab = Notification.Name("com.mitchellh.ghostty.newTab")

    /// New window. Has base surface config requested in userinfo.
    static let ghosttyNewWindow = Notification.Name("com.mitchellh.ghostty.newWindow")

    /// Present terminal. Bring the surface's window to focus without activating the app.
    static let ghosttyPresentTerminal = Notification.Name("com.mitchellh.ghostty.presentTerminal")

    /// Toggle fullscreen of current window
    static let ghosttyToggleFullscreen = Notification.Name("com.mitchellh.ghostty.toggleFullscreen")
    static let FullscreenModeKey = ghosttyToggleFullscreen.rawValue

    /// Notification sent to toggle split maximize/unmaximize.
    static let didToggleSplitZoom = Notification.Name("com.mitchellh.ghostty.didToggleSplitZoom")

    /// Notification
    static let didReceiveInitialWindowFrame = Notification.Name("com.mitchellh.ghostty.didReceiveInitialWindowFrame")
    static let FrameKey = "com.mitchellh.ghostty.frame"

    /// Notification to render the inspector for a surface
    static let inspectorNeedsDisplay = Notification.Name("com.mitchellh.ghostty.inspectorNeedsDisplay")

    /// Notification to show/hide the inspector
    static let didControlInspector = Notification.Name("com.mitchellh.ghostty.didControlInspector")

    static let confirmClipboard = Notification.Name("com.mitchellh.ghostty.confirmClipboard")
    static let ConfirmClipboardStrKey = confirmClipboard.rawValue + ".str"
    static let ConfirmClipboardStateKey = confirmClipboard.rawValue + ".state"
    static let ConfirmClipboardRequestKey = confirmClipboard.rawValue + ".request"

    /// Notification sent to the active split view to resize the split.
    static let didResizeSplit = Notification.Name("com.mitchellh.ghostty.didResizeSplit")
    static let ResizeSplitDirectionKey = didResizeSplit.rawValue + ".direction"
    static let ResizeSplitAmountKey = didResizeSplit.rawValue + ".amount"

    /// Notification sent to the split root to equalize split sizes
    static let didEqualizeSplits = Notification.Name("com.mitchellh.ghostty.didEqualizeSplits")

    /// Notification that renderer health changed
    static let didUpdateRendererHealth = Notification.Name("com.mitchellh.ghostty.didUpdateRendererHealth")

    /// Notifications related to key sequences
    static let didContinueKeySequence = Notification.Name("com.mitchellh.ghostty.didContinueKeySequence")
    static let didEndKeySequence = Notification.Name("com.mitchellh.ghostty.didEndKeySequence")
    static let KeySequenceKey = didContinueKeySequence.rawValue + ".key"

    /// Notifications related to key tables
    static let didChangeKeyTable = Notification.Name("com.mitchellh.ghostty.didChangeKeyTable")
    static let KeyTableKey = didChangeKeyTable.rawValue + ".action"
}

extension Notification.Name {
    /// Configuration change. If the object is nil then it is app-wide. Otherwise its surface-specific.
    static let ghosttyConfigDidChange = Notification.Name("com.mitchellh.ghostty.configDidChange")
    static let GhosttyConfigChangeKey = ghosttyConfigDidChange.rawValue

    /// Color change. Object is the surface changing.
    static let ghosttyColorDidChange = Notification.Name("com.mitchellh.ghostty.ghosttyColorDidChange")
    static let GhosttyColorChangeKey = ghosttyColorDidChange.rawValue

    /// Goto tab. Has tab index in the userinfo.
    static let ghosttyMoveTab = Notification.Name("com.mitchellh.ghostty.moveTab")
    static let GhosttyMoveTabKey = ghosttyMoveTab.rawValue

    /// Close tab
    static let ghosttyCloseTab = Notification.Name("com.mitchellh.ghostty.closeTab")

    /// Close other tabs
    static let ghosttyCloseOtherTabs = Notification.Name("com.mitchellh.ghostty.closeOtherTabs")

    /// Close tabs to the right of the focused tab
    static let ghosttyCloseTabsOnTheRight = Notification.Name("com.mitchellh.ghostty.closeTabsOnTheRight")

    /// Close window
    static let ghosttyCloseWindow = Notification.Name("com.mitchellh.ghostty.closeWindow")

    /// Resize the window to a default size.
    static let ghosttyResetWindowSize = Notification.Name("com.mitchellh.ghostty.resetWindowSize")

    /// Ring the bell
    static let ghosttyBellDidRing = Notification.Name("com.mitchellh.ghostty.ghosttyBellDidRing")

    /// Readonly mode changed
    static let ghosttyDidChangeReadonly = Notification.Name("com.mitchellh.ghostty.didChangeReadonly")
    static let ReadonlyKey = ghosttyDidChangeReadonly.rawValue + ".readonly"
    static let ghosttyCommandPaletteDidToggle = Notification.Name("com.mitchellh.ghostty.commandPaletteDidToggle")

    /// Toggle maximize of current window
    static let ghosttyMaximizeDidToggle = Notification.Name("com.mitchellh.ghostty.maximizeDidToggle")

    /// Notification sent when scrollbar updates
    static let ghosttyDidUpdateScrollbar = Notification.Name("com.mitchellh.ghostty.didUpdateScrollbar")
    static let ScrollbarKey = ghosttyDidUpdateScrollbar.rawValue + ".scrollbar"

    /// Focus the search field
    static let ghosttySearchFocus = Notification.Name("com.mitchellh.ghostty.searchFocus")
}

extension Ghostty {
    // The user notification category identifier
    static let userNotificationCategory = "com.mitchellh.ghostty.userNotification"

    // The user notification "Show" action
    static let userNotificationActionShow = "com.mitchellh.ghostty.userNotification.Show"
}

enum SplitFocusDirection: String {
    case previous, next, up, down, left, right, first, last
}

enum SplitResizeDirection: String {
    case up, down, left, right
}

import GhosttyKit

extension Ghostty {
    class AllocatedString {
        private let cString: ghostty_string_s

        init(_ c: ghostty_string_s) {
            self.cString = c
        }

        var string: String {
            guard let ptr = cString.ptr else { return "" }
            let data = Data(bytes: ptr, count: Int(cString.len))
            return String(data: data, encoding: .utf8) ?? ""
        }

        deinit {
            ghostty_string_free(cString)
        }
    }
}

extension SplitFocusDirection {
    func toNative() -> ghostty_action_goto_split_e {
        switch self {
        case .previous: return GHOSTTY_GOTO_SPLIT_PREVIOUS
        case .next: return GHOSTTY_GOTO_SPLIT_NEXT
        case .up: return GHOSTTY_GOTO_SPLIT_UP
        case .down: return GHOSTTY_GOTO_SPLIT_DOWN
        case .left: return GHOSTTY_GOTO_SPLIT_LEFT
        case .right: return GHOSTTY_GOTO_SPLIT_RIGHT
        case .first: return GHOSTTY_GOTO_SPLIT_PREVIOUS
        case .last: return GHOSTTY_GOTO_SPLIT_NEXT
        }
    }
}

extension SplitResizeDirection {
    func toNative() -> ghostty_action_resize_split_direction_e {
        switch self {
        case .up: return GHOSTTY_RESIZE_SPLIT_UP
        case .down: return GHOSTTY_RESIZE_SPLIT_DOWN
        case .left: return GHOSTTY_RESIZE_SPLIT_LEFT
        case .right: return GHOSTTY_RESIZE_SPLIT_RIGHT
        }
    }
}

import GhosttyKit

extension Ghostty {
    struct ClipboardContent {
        let mime: String
        let data: String

        static func from(content: ghostty_clipboard_content_s) -> ClipboardContent? {
            guard let mimePtr = content.mime,
                  let dataPtr = content.data else {
                return nil
            }

            return ClipboardContent(
                mime: String(cString: mimePtr),
                data: String(cString: dataPtr)
            )
        }
    }
}

import GhosttyKit

extension Ghostty {
    enum ClipboardRequest {
        /// A direct paste of clipboard contents
        case paste

        /// An application is attempting to read from the clipboard using OSC 52
        case osc_52_read

        /// An application is attempting to write to the clipboard using OSC 52
        case osc_52_write(OSPasteboard?)

        /// The text to show in the clipboard confirmation prompt for a given request type
        func text() -> String {
            switch self {
            case .paste:
                return """
                Pasting this text to the terminal may be dangerous as it looks like some commands may be executed.
                """
            case .osc_52_read:
                return """
                An application is attempting to read from the clipboard.
                The current clipboard contents are shown below.
                """
            case .osc_52_write:
                return """
                An application is attempting to write to the clipboard.
                The content to write is shown below.
                """
            }
        }

        static func from(request: ghostty_clipboard_request_e) -> ClipboardRequest? {
            switch request {
            case GHOSTTY_CLIPBOARD_REQUEST_PASTE:
                return .paste
            case GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ:
                return .osc_52_read
            case GHOSTTY_CLIPBOARD_REQUEST_OSC_52_WRITE:
                return .osc_52_write(nil)
            default:
                return nil
            }
        }
    }
}

import GhosttyKit

enum SetFloatWIndow {
    case on, off, toggle

    static func from(_ raw: ghostty_action_float_window_e) -> SetFloatWIndow? {
        switch raw {
        case GHOSTTY_FLOAT_WINDOW_ON: return .on
        case GHOSTTY_FLOAT_WINDOW_OFF: return .off
        case GHOSTTY_FLOAT_WINDOW_TOGGLE: return .toggle
        default: return nil
        }
    }
}

enum SetSecureInput {
    case on, off, toggle

    static func from(_ raw: ghostty_action_secure_input_e) -> SetSecureInput? {
        switch raw {
        case GHOSTTY_SECURE_INPUT_ON: return .on
        case GHOSTTY_SECURE_INPUT_OFF: return .off
        case GHOSTTY_SECURE_INPUT_TOGGLE: return .toggle
        default: return nil
        }
    }
}
