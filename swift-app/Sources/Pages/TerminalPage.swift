import Cocoa
import GhosttyKit

// MARK: - terminal page (plain shell surface)

/// A bare ghostty surface (EXEC io mode): `ssh <alias>` for the
/// "no herdr" servers-menu choice, or the user's local shell (nil
/// command → default login shell) for the menu's "Terminal" entry.
/// Full bleed, own scroll view; the child process lives as long as
/// this page exists.
final class TerminalPageController {
    let view = NSView(frame: .zero)
    let spec: SessionSpec

    private(set) var surfaceView: Ghostty.SurfaceView?
    private var scrollView: SurfaceScrollView?

    init(spec: SessionSpec) {
        self.spec = spec
        view.translatesAutoresizingMaskIntoConstraints = false
        view.wantsLayer = true

        var config = Ghostty.SurfaceConfiguration()
        if case .ssh(let alias) = spec.target {
            config.command = "ssh \(alias)"
        }
        config.context = GHOSTTY_SURFACE_CONTEXT_WINDOW
        let surface = Ghostty.SurfaceView(
            AppDelegate.ghosttyApp(), baseConfig: config)
        surfaceView = surface

        let scroll = SurfaceScrollView(
            contentSize: NSSize(width: 1000, height: 700),
            surfaceView: surface)
        scrollView = scroll
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    var keyView: NSView? { surfaceView }

    func focusTerminal() {
        if let keyView { keyView.window?.makeFirstResponder(keyView) }
    }

    func shutdown() {
        // The surface's child (ssh / shell) exits with the surface; tearing
        // the view out of the window releases libghostty's resources.
        scrollView?.removeFromSuperview()
        surfaceView?.removeFromSuperview()
        surfaceView = nil
        scrollView = nil
    }
}
