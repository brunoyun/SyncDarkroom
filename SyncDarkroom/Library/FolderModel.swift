import Foundation
import Observation

@MainActor
@Observable
final class FolderModel {
    let url: URL
    private(set) var items: [LibraryItem] = []
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    private(set) var errorMessage: String?

    @ObservationIgnored private var watcher: DirectoryWatcher?
    @ObservationIgnored private var reloadTask: Task<Void, Never>?

    init(url: URL) {
        self.url = url
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        let url = url
        do {
            let scanned = try await Task.detached(priority: .userInitiated) {
                try FolderScanner.scan(url)
            }.value
            if scanned != items { items = scanned }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        hasLoaded = true
    }

    /// Reloads when Synctrain (or anything else) adds, removes or renames files here.
    func startWatching() {
        guard watcher == nil else { return }
        watcher = DirectoryWatcher(url: url) { [weak self] in
            self?.scheduleReload()
        }
    }

    func stopWatching() {
        watcher?.cancel()
        watcher = nil
        reloadTask?.cancel()
    }

    func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task {
            // Syncthing writes temp files then renames them; wait for the burst to settle.
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            await load()
        }
    }
}

/// Watches a directory's entries with a kqueue vnode source.
final class DirectoryWatcher: @unchecked Sendable {
    private var source: DispatchSourceFileSystemObject?

    init?(url: URL, onChange: @escaping @MainActor () -> Void) {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete, .link],
            queue: .main
        )
        source.setEventHandler {
            MainActor.assumeIsolated { onChange() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    func cancel() {
        source?.cancel()
        source = nil
    }

    deinit {
        source?.cancel()
    }
}
