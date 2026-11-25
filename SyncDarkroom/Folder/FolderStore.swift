import Foundation
import Observation

/// Remembers the user-chosen root folder (e.g. a Synctrain folder) across launches
/// using a security-scoped bookmark, and keeps access to it open while the app runs.
@MainActor
@Observable
final class FolderStore {
    private(set) var rootURL: URL?
    var lastError: String?

    @ObservationIgnored private var accessedURL: URL?
    private static let bookmarkKey = "rootFolderBookmark"

    init() {
        #if DEBUG
        // For simulator testing: launch with `-debugRootPath /path/to/folder`.
        if let path = UserDefaults.standard.string(forKey: "debugRootPath") {
            activate(URL(fileURLWithPath: path, isDirectory: true))
            return
        }
        #endif
        restore()
    }

    var displayName: String {
        rootURL?.lastPathComponent ?? "SyncDarkroom"
    }

    /// Called with the URL returned by the system folder picker.
    func choose(_ url: URL) {
        let didStart = url.startAccessingSecurityScopedResource()
        do {
            let data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(data, forKey: Self.bookmarkKey)
            lastError = nil
            activate(url)
        } catch {
            if didStart { url.stopAccessingSecurityScopedResource() }
            lastError = "Couldn't remember this folder: \(error.localizedDescription)"
        }
    }

    func forget() {
        UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
        accessedURL?.stopAccessingSecurityScopedResource()
        accessedURL = nil
        rootURL = nil
    }

    private func restore() {
        guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return }
        do {
            var isStale = false
            let url = try URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale)
            _ = url.startAccessingSecurityScopedResource()
            if isStale, let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                UserDefaults.standard.set(fresh, forKey: Self.bookmarkKey)
            }
            guard FileManager.default.fileExists(atPath: url.path) else {
                url.stopAccessingSecurityScopedResource()
                lastError = "The folder \"\(url.lastPathComponent)\" is no longer available. Choose it again."
                return
            }
            activate(url)
        } catch {
            lastError = "Couldn't reopen your folder. Choose it again."
        }
    }

    private func activate(_ url: URL) {
        if let old = accessedURL, old != url {
            old.stopAccessingSecurityScopedResource()
        }
        accessedURL = url
        rootURL = url
    }
}
