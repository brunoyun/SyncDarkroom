import SwiftUI

struct WelcomeView: View {
    @Environment(FolderStore.self) private var folderStore
    @State private var showPicker = false

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "camera.aperture")
                .font(.system(size: 72, weight: .light))
                .foregroundStyle(.tint)
            Text("SyncDarkroom")
                .font(.largeTitle.bold())
            Text("Choose the folder Synctrain keeps in sync. In the picker, tap **Browse**, open **Synctrain** (or wherever the folder lives), select your photo folder and tap **Open**.\n\nOriginals are never modified — edits are saved as copies next to them.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 520)
            Button {
                showPicker = true
            } label: {
                Label("Choose Folder", systemImage: "folder.badge.plus")
                    .font(.headline)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)

            if let error = folderStore.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .frame(maxWidth: 520)
            }
        }
        .padding(40)
        .folderPicker(isPresented: $showPicker)
    }
}

extension View {
    /// Presents the system folder picker and stores the chosen folder.
    func folderPicker(isPresented: Binding<Bool>) -> some View {
        modifier(FolderPickerModifier(isPresented: isPresented))
    }
}

private struct FolderPickerModifier: ViewModifier {
    @Environment(FolderStore.self) private var folderStore
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        content.fileImporter(isPresented: $isPresented, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url):
                folderStore.choose(url)
            case .failure(let error):
                folderStore.lastError = error.localizedDescription
            }
        }
    }
}
