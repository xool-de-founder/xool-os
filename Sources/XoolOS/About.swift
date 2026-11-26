import AppKit
import SwiftUI

// Search › About Search: the icon, the name and the version, as the
// standard panel shows them, with a What's New button under the version
// line that brings back this version's card (idea 968). A window of our
// own, because the standard panel takes no button.

@MainActor
enum AboutWindow {
    private static var window: NSWindow?

    /// Shown, or brought forward if it is already up. Never in a test run:
    /// a probe stays off every screen (the view is drawn by the bench).
    static func show() {
        guard !Store.testing else { return }
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let host = NSHostingView(rootView: AboutView())
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    static func close() {
        window?.close()
        window = nil
    }
}

/// What the About window holds. Its own view, so the bench can draw it.
struct AboutView: View {

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
                .padding(.bottom, 10)
            Text(verbatim: "Xool OS")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Palette.ink)
            Text(verbatim: AboutView.versionLine)
                .font(.system(size: 11))
                .foregroundStyle(Palette.muted)
                .textSelection(.enabled)
                .padding(.top, 3)
            Text(verbatim: AboutView.copyright)
                .font(.system(size: 10.5))
                .foregroundStyle(Palette.faint)
                .padding(.top, 16)
        }
        .padding(.top, 34)
        .padding(.bottom, 20)
        .padding(.horizontal, 28)
        .frame(width: 320)
        .background(Palette.ground)
    }

    /// As the standard panel writes it: "Version 1.0.18 (202611221830)".
    static var versionLine: String {
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty ? "Version \(AppInfo.version)" : "Version \(AppInfo.version) (\(build))"
    }

    static var copyright: String {
        Bundle.main.infoDictionary?["NSHumanReadableCopyright"] as? String ?? "Xool OS · based on Search (MIT)"
    }
}
