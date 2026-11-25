import Foundation
import Observation
import UIKit

enum BatchEdit {
    /// What to render for `item` with a new look. Originals start fresh; an edited copy is
    /// redone from its original keeping everything (crop, RAW settings, masks, heals, markup)
    /// except the look. Never overwrites anything: the result is always saved as a new copy.
    static func plan(for item: LibraryItem, look: Look) -> (source: URL, recipe: EditRecipe) {
        if let sidecar = SidecarStore.load(forCopy: item.url) {
            let original = item.url.deletingLastPathComponent().appendingPathComponent(sidecar.source)
            if FileManager.default.fileExists(atPath: original.path) {
                var recipe = sidecar.recipe
                recipe.look = look
                return (original, recipe)
            }
        }
        var recipe = EditRecipe()
        recipe.look = look
        return (item.url, recipe)
    }
}

/// Runs one look over many photos, one at a time (full-resolution renders are memory-heavy).
@MainActor
@Observable
final class BatchRunner {
    struct Failure: Identifiable {
        let id = UUID()
        let name: String
        let message: String
    }

    let items: [LibraryItem]
    private(set) var completed = 0
    private(set) var current: String?
    private(set) var failures: [Failure] = []
    private(set) var isRunning = false
    private(set) var isFinished = false
    private(set) var wasCancelled = false
    @ObservationIgnored private var cancelRequested = false

    init(items: [LibraryItem]) {
        self.items = items
    }

    var succeeded: Int { completed - failures.count }

    func cancel() {
        cancelRequested = true
    }

    func run(look: Look, format: ExportFormat, quality: Double) async {
        guard !isRunning else { return }
        isRunning = true
        UIApplication.shared.isIdleTimerDisabled = true
        // If the user switches apps, ask for time to finish the photo in progress.
        var backgroundTask = UIBackgroundTaskIdentifier.invalid
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Batch edit") {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
        defer {
            UIApplication.shared.isIdleTimerDisabled = false
            if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask) }
            isRunning = false
            isFinished = true
        }

        for item in items {
            if cancelRequested {
                wasCancelled = true
                break
            }
            current = item.name
            do {
                try await Task.detached(priority: .userInitiated) {
                    let plan = BatchEdit.plan(for: item, look: look)
                    _ = try ExportJob(source: plan.source, recipe: plan.recipe, format: format,
                                      quality: quality, updating: nil).run()
                }.value
            } catch {
                failures.append(Failure(name: item.name, message: error.localizedDescription))
            }
            completed += 1
        }
        current = nil
    }
}
