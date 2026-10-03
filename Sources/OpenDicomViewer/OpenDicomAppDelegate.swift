import AppKit

/// Finder can send several open events for one selection. Collect them before
/// replacing the current study, including events delivered during launch.
@MainActor
final class OpenEventBatcher {
    private var pendingURLs: [URL] = []
    private var pendingTask: Task<Void, Never>?
    private let open: ([URL]) -> Void

    init(open: @escaping ([URL]) -> Void) {
        self.open = open
    }

    func enqueue(_ urls: [URL]) {
        pendingURLs.append(contentsOf: urls.filter(\.isFileURL))
        guard !pendingURLs.isEmpty else { return }
        pendingTask?.cancel()
        pendingTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 100_000_000) }
            catch { return }
            self?.flush()
        }
    }

    func flush() {
        pendingTask?.cancel()
        pendingTask = nil
        var seen = Set<String>()
        let urls = pendingURLs.filter { seen.insert($0.standardizedFileURL.path).inserted }
        pendingURLs.removeAll()
        if !urls.isEmpty { open(urls) }
    }
}

@MainActor
final class OpenDicomAppDelegate: NSObject, NSApplicationDelegate {
    // A single model is available before both scene creation and launch-time
    // open events; SwiftUI observes the same instance for menu state updates.
    static let sharedModel = DICOMModel()
    let model = OpenDicomAppDelegate.sharedModel
    private lazy var openEvents = OpenEventBatcher { [weak self] urls in
        self?.model.load(urls: urls)
        self?.activateViewer()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        openEvents.enqueue(urls)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        activateViewer()
        return true
    }

    private func activateViewer() {
        if let window = NSApp.windows.first(where: { $0.canBecomeMain && !($0 is NSPanel) }) {
            window.deminiaturize(nil)
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}
