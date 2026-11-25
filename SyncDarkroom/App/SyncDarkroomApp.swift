import SwiftUI

@main
struct SyncDarkroomApp: App {
    @State private var folderStore = FolderStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(folderStore)
        }
    }
}

struct RootView: View {
    @Environment(FolderStore.self) private var folderStore

    var body: some View {
        if let root = folderStore.rootURL {
            NavigationStack {
                LibraryView(folderURL: root, isRoot: true)
                    .navigationDestination(for: URL.self) { url in
                        LibraryView(folderURL: url)
                    }
            }
            .id(root)
        } else {
            WelcomeView()
        }
    }
}
