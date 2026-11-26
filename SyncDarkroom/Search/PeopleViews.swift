import CoreImage
import ImageIO
import SwiftUI

func photoCount(_ n: Int) -> String { n == 1 ? "1 photo" : "\(n) photos" }

// MARK: - Face thumbnails

/// Square crops of faces, cut from a downsampled copy of the photo.
final class FaceImageLoader: @unchecked Sendable {
    static let shared = FaceImageLoader()
    private let cache = NSCache<NSString, UIImage>()
    private let context = CIContext(options: [.cacheIntermediates: false])

    func image(for face: FaceRef, root: URL) async -> UIImage? {
        let key = face.id as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let url = root.appendingPathComponent(face.path)
        let box = face.box, roll = face.roll, context = context
        let image = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            // Big enough that the face itself is at least ~160 px.
            let side = Int(min(2048, max(400, 200 / max(0.05, max(box.width, box.height)))))
            guard let full = ImageLoading.coordinatedRead(url, { readURL -> CGImage? in
                guard let source = CGImageSourceCreateWithURL(readURL as CFURL, nil) else { return nil }
                return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: side,
                ] as CFDictionary)
            }) else { return nil }
            let w = CGFloat(full.width), h = CGFloat(full.height)
            let extent = max(box.width * w, box.height * h) * 1.6
            // Core Image has a bottom-left origin; turn the face upright around its centre.
            let center = CGPoint(x: box.midX * w, y: (1 - box.midY) * h)
            let out = min(400, extent)
            let transform = CGAffineTransform(translationX: -center.x, y: -center.y)
                .concatenating(CGAffineTransform(rotationAngle: -roll))
                .concatenating(CGAffineTransform(scaleX: out / extent, y: out / extent))
                .concatenating(CGAffineTransform(translationX: out / 2, y: out / 2))
            let output = CIImage(cgImage: full).clampedToExtent().transformed(by: transform)
            guard let crop = context.createCGImage(output, from: CGRect(x: 0, y: 0, width: out, height: out))
            else { return nil }
            return UIImage(cgImage: crop)
        }.value
        if let image { cache.setObject(image, forKey: key) }
        return image
    }
}

struct FaceAvatar: View {
    let face: FaceRef?
    var size: CGFloat = 96

    @Environment(FolderStore.self) private var folderStore
    @State private var image: UIImage?

    var body: some View {
        Circle()
            .fill(Color.secondary.opacity(0.15))
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "person.fill").font(.system(size: size * 0.4)).foregroundStyle(.secondary)
                }
            }
            .clipShape(Circle())
            .frame(width: size, height: size)
            .task(id: face?.id) {
                guard let face, let root = folderStore.rootURL else { image = nil; return }
                image = await FaceImageLoader.shared.image(for: face, root: root)
            }
    }
}

// MARK: - People

/// All people found in the folder: tap to open, select to merge or hide.
struct PeopleView: View {
    @State private var store = PeopleStore.shared
    @State private var selecting = false
    @State private var selection: Set<UUID> = []
    @State private var showHidden = false
    @AppStorage("peopleShowSingles") private var showSingles = false
    @State private var confirmMerge = false
    @State private var showStrictness = false

    var body: some View {
        let people = store.sortedPeople(includeHidden: showHidden, minimumFaces: showSingles ? 1 : 2)
        ScrollView {
            if people.isEmpty {
                ContentUnavailableView("No People Yet", systemImage: "person.2",
                                       description: Text("Faces appear here as photos are analyzed."))
                    .padding(.top, 60)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 16)], spacing: 20) {
                ForEach(people) { person in
                    if selecting {
                        Button {
                            if selection.contains(person.id) { selection.remove(person.id) } else { selection.insert(person.id) }
                        } label: {
                            PersonCell(person: person, selected: selection.contains(person.id))
                        }
                        .buttonStyle(.plain)
                    } else {
                        NavigationLink(value: SearchRoute.person(person.id)) {
                            PersonCell(person: person, selected: false)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding()
        }
        .navigationTitle("People")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if selecting {
                    Button("Merge \(selection.count)", systemImage: "arrow.triangle.merge") { confirmMerge = true }
                        .disabled(selection.count < 2)
                    Button(showHidden ? "Show" : "Hide", systemImage: "eye.slash") {
                        for id in selection { store.setHidden(id, !showHidden) }
                        selection.removeAll()
                    }
                    .disabled(selection.isEmpty)
                    Button("Done") { selecting = false; selection.removeAll() }
                } else {
                    Button("Select") { selecting = true }
                    Menu {
                        Toggle("Show Hidden People", isOn: $showHidden)
                        Toggle("Show People in One Photo", isOn: $showSingles)
                        Button("Grouping Strictness…", systemImage: "slider.horizontal.3") { showStrictness = true }
                    } label: {
                        Label("Options", systemImage: "ellipsis.circle")
                    }
                }
            }
        }
        .confirmationDialog("Merge \(selection.count) People?", isPresented: $confirmMerge, titleVisibility: .visible) {
            Button("Merge") {
                let chosen = people.filter { selection.contains($0.id) }
                // Keep a named person (or the one with most photos) as the target.
                if let target = chosen.first(where: { !$0.name.isEmpty }) ?? chosen.max(by: { store.faceCount($0.id) < store.faceCount($1.id) }) {
                    store.merge(chosen.map(\.id), into: target.id)
                }
                selection.removeAll()
                selecting = false
            }
        } message: {
            Text("Their photos become one person. The name of the first named person is kept.")
        }
        .sheet(isPresented: $showStrictness) { StrictnessSheet() }
    }
}

private struct PersonCell: View {
    let person: Person
    let selected: Bool
    @State private var store = PeopleStore.shared

    var body: some View {
        VStack(spacing: 6) {
            FaceAvatar(face: store.coverFace(of: person), size: 110)
                .overlay(alignment: .bottomTrailing) {
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.accentColor)
                    }
                }
                .opacity(person.isHidden ? 0.4 : 1)
            Text(person.name.isEmpty ? "Add a Name" : person.name)
                .font(.callout.weight(person.name.isEmpty ? .regular : .semibold))
                .foregroundStyle(person.name.isEmpty ? .secondary : .primary)
                .lineLimit(1)
            Text(photoCount(store.photoPaths(of: person.id).count)).font(.caption).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }
}

private struct StrictnessSheet: View {
    @State private var store = PeopleStore.shared
    @State private var value: Double = 0.5
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text("Looser")
                        Slider(value: $value, in: 0.35...0.7)
                        Text("Stricter")
                    }
                } footer: {
                    Text("Looser grouping puts more faces together, but may mix up similar-looking people. Stricter grouping splits one person into several, which you can merge. Faces you named, merged or moved stay where they are.")
                }
            }
            .navigationTitle("Grouping Strictness")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Regroup") {
                        store.regroup(strictness: Float(value))
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
        .onAppear { value = Double(store.saved.strictness) }
    }
}

// MARK: - One person

struct PersonDetailView: View {
    let personID: UUID

    @Environment(FolderStore.self) private var folderStore
    @State private var store = PeopleStore.shared
    @State private var index = PhotoIndex.shared
    @State private var tab = 0
    @State private var renaming = false
    @State private var newName = ""
    @State private var mergeCandidate: Person?
    @State private var pickingMerge = false
    @State private var movingFace: FaceRef?
    @State private var viewer: ViewerContext?

    var body: some View {
        if let person = store.person(personID) {
            content(person)
        } else {
            ContentUnavailableView("Person Merged or Removed", systemImage: "person.crop.circle.badge.questionmark")
        }
    }

    private func content(_ person: Person) -> some View {
        let paths = store.photoPaths(of: personID)
        let photos = index.photos.filter { paths.contains($0.path) }.sorted { $0.date > $1.date }
        return ScrollView {
            VStack(spacing: 10) {
                FaceAvatar(face: store.coverFace(of: person), size: 120)
                Button {
                    newName = person.name
                    renaming = true
                } label: {
                    Label(person.name.isEmpty ? "Add a Name" : person.name, systemImage: "pencil")
                        .font(.title2.weight(.semibold))
                }
                Text(photoCount(photos.count)).foregroundStyle(.secondary)
                Picker("Show", selection: $tab) {
                    Text("Photos").tag(0)
                    Text("Faces").tag(1)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 320)
                .padding(.top, 6)
            }
            .padding(.top)

            if tab == 0 {
                photoGrid(photos)
            } else {
                faceGrid(person)
            }
        }
        .navigationTitle(person.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Menu {
                Button("Rename", systemImage: "pencil") { newName = person.name; renaming = true }
                Button("Merge With…", systemImage: "arrow.triangle.merge") { pickingMerge = true }
                Button(person.isHidden ? "Show Person" : "Hide Person", systemImage: person.isHidden ? "eye" : "eye.slash") {
                    store.setHidden(personID, !person.isHidden)
                }
            } label: {
                Label("Options", systemImage: "ellipsis.circle")
            }
        }
        .alert("Name", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                if let other = store.existingPerson(named: newName, except: personID) {
                    mergeCandidate = other
                } else {
                    store.rename(personID, to: newName)
                }
            }
        }
        .confirmationDialog("“\(mergeCandidate?.name ?? "")” Already Exists",
                            isPresented: Binding(get: { mergeCandidate != nil }, set: { if !$0 { mergeCandidate = nil } }),
                            titleVisibility: .visible) {
            Button("Merge Into “\(mergeCandidate?.name ?? "")”") {
                if let other = mergeCandidate { store.merge([personID], into: other.id) }
            }
            Button("Keep as a Different Person") { store.rename(personID, to: newName) }
        } message: {
            Text("Is this the same person? Merging moves these photos to them.")
        }
        .sheet(isPresented: $pickingMerge) {
            PersonPicker(title: "Merge With", excluding: personID, allowsNew: false) { target in
                if let target { store.merge([personID], into: target) }
            }
        }
        .sheet(item: $movingFace) { face in
            PersonPicker(title: "Who Is This?", excluding: personID, allowsNew: true) { target in
                store.move(face.id, to: target)
            }
        }
        .fullScreenCover(item: $viewer) { PhotoViewer(context: $0) }
    }

    private func photoGrid(_ photos: [IndexedPhoto]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 4)], spacing: 4) {
            if let root = folderStore.rootURL {
                let items = photos.map { $0.libraryItem(root: root) }
                ForEach(items) { item in
                    Button { viewer = ViewerContext(items: items, startURL: item.url) } label: {
                        ThumbnailCell(item: item, pixelSize: 320)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding()
    }

    private func faceGrid(_ person: Person) -> some View {
        VStack(alignment: .leading) {
            Text("Touch and hold a face to correct it.").font(.callout).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 12)], spacing: 12) {
                ForEach(store.facesByPerson[personID] ?? []) { face in
                    FaceAvatar(face: face, size: 90)
                        .contextMenu {
                            Button("Not \(person.name.isEmpty ? "This Person" : person.name)…", systemImage: "person.crop.circle.badge.xmark") {
                                movingFace = face
                            }
                            Button("Use as Cover", systemImage: "person.crop.square") { store.setCover(face.id, for: personID) }
                            if let root = folderStore.rootURL {
                                Button("View Photo", systemImage: "photo") {
                                    let item = LibraryItem(url: root.appendingPathComponent(face.path),
                                                           name: (face.path as NSString).lastPathComponent, isFolder: false,
                                                           type: ImageType(fileExtension: (face.path as NSString).pathExtension),
                                                           modified: face.date, fileSize: 0, hasEdits: false)
                                    viewer = ViewerContext(items: [item], startURL: item.url)
                                }
                            }
                        }
                }
            }
        }
        .padding()
    }
}

/// Chooses a person (or a new one) for merging or correcting a face.
struct PersonPicker: View {
    let title: String
    let excluding: UUID
    let allowsNew: Bool
    let onPick: (UUID?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var store = PeopleStore.shared
    @State private var filter = ""

    var body: some View {
        NavigationStack {
            List {
                if allowsNew {
                    Button {
                        onPick(nil)
                        dismiss()
                    } label: {
                        Label("A New Person", systemImage: "person.badge.plus")
                    }
                }
                let people = store.sortedPeople(includeHidden: true).filter {
                    $0.id != excluding && (filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter))
                }
                ForEach(people) { person in
                    Button {
                        onPick(person.id)
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            FaceAvatar(face: store.coverFace(of: person), size: 44)
                            VStack(alignment: .leading) {
                                Text(person.displayName).foregroundStyle(person.name.isEmpty ? .secondary : .primary)
                                Text(photoCount(store.photoPaths(of: person.id).count)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .searchable(text: $filter, prompt: "Name")
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}
