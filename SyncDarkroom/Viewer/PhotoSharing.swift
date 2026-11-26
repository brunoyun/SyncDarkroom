import SwiftUI
import UIKit

/// Sends photos with the system share sheet (Mail, Messages, WhatsApp, Messenger, AirDrop…).
/// Files are first copied out of the synced folder, so share extensions can always read them.
enum PhotoSharing {
    private static var directory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Share", isDirectory: true)
    }

    nonisolated static func prepare(_ urls: [URL]) -> [URL] {
        let fm = FileManager.default
        try? fm.removeItem(at: directory)   // previous shares are done by now
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var used: Set<String> = []
        return urls.compactMap { url in
            var name = url.lastPathComponent
            var n = 2
            while used.contains(name.lowercased()) {
                name = url.deletingPathExtension().lastPathComponent + "-\(n)." + url.pathExtension
                n += 1
            }
            used.insert(name.lowercased())
            let target = folder.appendingPathComponent(name)
            let copied: Bool? = ImageLoading.coordinatedRead(url) { readURL in
                (try? fm.copyItem(at: readURL, to: target)) != nil
            }
            return copied == true ? target : nil
        }
    }

    @MainActor
    static func present(_ files: [URL], from sourceRect: CGRect) {
        guard !files.isEmpty,
              let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .flatMap(\.windows).first(where: \.isKeyWindow),
              var top = window.rootViewController else { return }
        while let presented = top.presentedViewController, !presented.isBeingDismissed { top = presented }
        let controller = UIActivityViewController(activityItems: files, applicationActivities: nil)
        if let popover = controller.popoverPresentationController {
            popover.sourceView = window
            // Toolbar buttons sometimes report no frame: anchor near the top trailing corner then.
            popover.sourceRect = sourceRect.isEmpty
                ? CGRect(x: window.bounds.maxX - 80, y: window.safeAreaInsets.top + 30, width: 1, height: 1)
                : sourceRect
        }
        top.present(controller, animated: true)
    }
}

/// A Share button that copies the photos and opens the share sheet next to itself.
struct ShareButton: View {
    let urls: [URL]
    var title = "Share"
    var iconOnly = false

    @State private var frame: CGRect = .zero
    @State private var preparing = false

    var body: some View {
        Button {
            share()
        } label: {
            if preparing {
                ProgressView()
            } else if iconOnly {
                Label(title, systemImage: "square.and.arrow.up").labelStyle(.iconOnly)
            } else {
                Label(title, systemImage: "square.and.arrow.up")
            }
        }
        .disabled(urls.isEmpty || preparing)
        .accessibilityLabel(urls.count > 1 ? "Share \(urls.count) photos" : "Share photo")
        .background {
            GeometryReader { geo in
                Color.clear
                    .onAppear { frame = geo.frame(in: .global) }
                    .onChange(of: geo.frame(in: .global)) { frame = geo.frame(in: .global) }
            }
        }
    }

    private func share() {
        preparing = true
        let urls = urls
        Task {
            let files = await Task.detached(priority: .userInitiated) { PhotoSharing.prepare(urls) }.value
            preparing = false
            PhotoSharing.present(files, from: frame)
        }
    }
}
