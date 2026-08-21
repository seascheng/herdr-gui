import Cocoa

extension NSScreen {
    /// The unique CoreGraphics display ID for this screen.
    var displayID: UInt32? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32
    }

    /// The stable UUID for this display, suitable for tracking across
    /// reconnects and NSScreen garbage collection.
    var displayUUID: UUID? {
        guard let displayID = displayID else { return nil }
        guard let cfuuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else { return nil }
        return UUID(cfuuid)
    }
}
