import Cocoa
import GhosttyKit

// MARK: - terminal page (plain ssh surface)

/// A bare ghostty surface running `ssh <alias>` (EXEC io mode) — the
/// "no herdr" servers-menu choice. Full bleed, own scroll view, session
/// lives in the ssh child process for as long as this page exists.
final class TerminalPageController {
    let view = NSView(frame: .zero)
    let spec: SessionSpec

    private(set) var surfaceView: Ghostty.SurfaceView?
    private var scrollView: SurfaceScrollView?

    init(spec: SessionSpec) {
        self.spec = spec
        view.translatesAutoresizingMaskIntoConstraints = false
        view.wantsLayer = true

        guard case .ssh(let alias) = spec.target else { return }

        var config = Ghostty.SurfaceConfiguration()
        config.command = "ssh \(alias)"
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
        // The surface's child (ssh) exits with the surface; tearing the
        // view out of the window releases libghostty's resources.
        scrollView?.removeFromSuperview()
        surfaceView?.removeFromSuperview()
        surfaceView = nil
        scrollView = nil
    }
}
