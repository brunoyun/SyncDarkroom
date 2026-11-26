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

                SearchView()
                    .tabItem { Label("Search", systemImage: "magnifyingglass") }
                    .tag("search")
            }
            .id(root)
            .background { BackgroundAnalysis(root: root) }
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

/// Keeps the search analysis going while the app is open: new photos are queued after each
/// library scan, and people are regrouped as faces come in.
private struct BackgroundAnalysis: View {
    let root: URL
    @State private var index = PhotoIndex.shared
    @State private var analysis = PhotoAnalysisStore.shared
    @State private var regroupScheduled = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Color.clear
            .task(id: root) {
                analysis.load(root: root)
                index.refreshIfNeeded(root: root)
            }
            .onChange(of: index.lastUpdated) {
                guard !index.isScanning else { return }
                analysis.indexLibrary(index.photos, root: root)
                PeopleStore.shared.update(index: index, analysis: analysis, root: root)
            }
            .onChange(of: analysis.revision) {
                guard !regroupScheduled else { return }
                regroupScheduled = true
                Task {
                    try? await Task.sleep(for: .seconds(4))
                    regroupScheduled = false
                    PeopleStore.shared.update(index: index, analysis: analysis, root: root)
                }
            }
            .onChange(of: scenePhase) {
                if scenePhase != .active { analysis.save() }
            }
    }
}
