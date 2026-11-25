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
    @SceneStorage("selectedTab") private var tab = "library"

    var body: some View {
        if let root = folderStore.rootURL {
            TabView(selection: $tab) {
                NavigationStack {
                    LibraryView(folderURL: root, isRoot: true)
                        .navigationDestination(for: URL.self) { url in
                            LibraryView(folderURL: url)
                        }
                }
                .tabItem { Label("Library", systemImage: "photo.on.rectangle") }
                .tag("library")

                PhotoMapView()
                    .tabItem { Label("Map", systemImage: "map") }
                    .tag("map")
            }
            .id(root)
            #if DEBUG
            .onAppear {
                if let t = UserDefaults.standard.string(forKey: "debugTab") { tab = t }
            }
            #endif
        } else {
            WelcomeView()
        }
    }
}
