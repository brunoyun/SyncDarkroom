import Charts
import SwiftUI

/// Statistics for a folder (optionally including its subfolders), from the shared photo index.
struct FolderStatsView: View {
    let folderURL: URL
    let title: String

    @Environment(FolderStore.self) private var folderStore
    @Environment(\.dismiss) private var dismiss
    @State private var index = PhotoIndex.shared
    @AppStorage("statsIncludeSubfolders") private var includeSubfolders = true

    private var root: URL? { folderStore.rootURL }

    private var relativeFolder: String {
        guard let root else { return "" }
        let rootPath = root.standardizedFileURL.path
        var path = folderURL.standardizedFileURL.path
        if path.hasPrefix(rootPath) { path = String(path.dropFirst(rootPath.count)) }
        return path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private var photos: [IndexedPhoto] {
        let folder = relativeFolder
        return index.photos.filter { photo in
            if includeSubfolders {
                folder.isEmpty || photo.path.hasPrefix(folder + "/")
            } else {
                photo.folder == folder
            }
        }
    }

    var body: some View {
        NavigationStack {
            let photos = photos
            Form {
                Section {
                    Toggle("Include Subfolders", isOn: $includeSubfolders)
                } footer: {
                    if index.isScanning {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Reading photo details… \(index.scanned) of \(index.toScan)")
                        }
                    }
                }
                if photos.isEmpty && !index.isScanning {
                    ContentUnavailableView("No Photos", systemImage: "photo.on.rectangle.angled")
                } else {
                    overview(photos)
                    types(photos)
                    years(photos)
                    cameras(photos)
                    largest(photos)
                }
            }
            .navigationTitle("\(title) Statistics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .task { if let root { index.refreshIfNeeded(root: root) } }
    }

    // MARK: Sections

    private func overview(_ photos: [IndexedPhoto]) -> some View {
        let total = photos.reduce(Int64(0)) { $0 + $1.size }
        let copies = photos.filter(\.isEditedCopy)
        let originals = photos.count - copies.count
        let folders = Set(photos.map(\.folder)).count
        let dates = photos.map(\.date).filter { $0 > .distantPast }
        let located = photos.filter(\.hasLocation).count
        let megapixels = photos.compactMap { $0.pixelCount > 0 ? Double($0.pixelCount) / 1e6 : nil }
        return Section("Overview") {
            stat("Photos", "\(photos.count)", icon: "photo.on.rectangle")
            stat("Total Size", total.formatted(.byteCount(style: .file)), icon: "internaldrive")
            stat("Average Size", photos.isEmpty ? "–" : (total / Int64(photos.count)).formatted(.byteCount(style: .file)),
                 icon: "chart.bar")
            stat("Originals", "\(originals)", icon: "camera")
            stat("Edited Copies", "\(copies.count)", icon: "slider.horizontal.3")
            stat("Originals with Edits", "\(photos.filter(\.hasEdits).count)", icon: "wand.and.stars")
            if includeSubfolders { stat("Folders", "\(folders)", icon: "folder") }
            stat("With Location", "\(located) (\(percent(located, photos.count)))", icon: "location")
            if let first = dates.min(), let last = dates.max() {
                stat("Date Range", "\(first.formatted(date: .abbreviated, time: .omitted)) – \(last.formatted(date: .abbreviated, time: .omitted))",
                     icon: "calendar")
            }
            if !megapixels.isEmpty {
                stat("Average Resolution", String(format: "%.1f MP", megapixels.reduce(0, +) / Double(megapixels.count)),
                     icon: "aspectratio")
            }
        }
    }

    private func types(_ photos: [IndexedPhoto]) -> some View {
        let groups = Dictionary(grouping: photos) { $0.type?.label ?? "Other" }
            .map { (type: $0.key, count: $0.value.count, size: $0.value.reduce(Int64(0)) { $0 + $1.size }) }
            .sorted { $0.size > $1.size }
        return Section("By Type") {
            Chart(groups, id: \.type) { group in
                BarMark(x: .value("Size", Double(group.size) / 1e6), y: .value("Type", group.type))
                    .foregroundStyle(by: .value("Type", group.type))
                    .annotation(position: .trailing) {
                        Text("\(group.count) · \(group.size.formatted(.byteCount(style: .file)))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
            }
            .chartLegend(.hidden)
            .chartXAxisLabel("MB")
            .frame(height: CGFloat(max(1, groups.count)) * 36 + 30)
        }
    }

    private func years(_ photos: [IndexedPhoto]) -> some View {
        let calendar = Calendar.current
        let byYear = Dictionary(grouping: photos.filter { $0.date > .distantPast }) { calendar.component(.year, from: $0.date) }
            .map { (year: $0.key, count: $0.value.count) }
            .sorted { $0.year < $1.year }
        return Section("Photos per Year") {
            if byYear.isEmpty {
                Text("No dates found").foregroundStyle(.secondary)
            } else {
                Chart(byYear, id: \.year) { item in
                    BarMark(x: .value("Year", String(item.year)), y: .value("Photos", item.count))
                        .foregroundStyle(Color.accentColor)
                        .annotation(position: .top) { Text("\(item.count)").font(.caption2).foregroundStyle(.secondary) }
                }
                .frame(height: 180)
            }
        }
    }

    @ViewBuilder
    private func cameras(_ photos: [IndexedPhoto]) -> some View {
        let cameras = top(photos.compactMap(\.camera))
        let lenses = top(photos.compactMap(\.lens))
        if !cameras.isEmpty {
            Section("Cameras") {
                ForEach(cameras, id: \.name) { stat($0.name, "\($0.count)", icon: "camera.aperture") }
            }
        }
        if !lenses.isEmpty {
            Section("Lenses") {
                ForEach(lenses, id: \.name) { stat($0.name, "\($0.count)", icon: "circle.circle") }
            }
        }
    }

    private func largest(_ photos: [IndexedPhoto]) -> some View {
        Section("Largest Files") {
            ForEach(photos.sorted { $0.size > $1.size }.prefix(5)) { photo in
                stat(photo.name, photo.size.formatted(.byteCount(style: .file)), icon: "doc")
            }
        }
    }

    // MARK: Helpers

    private func top(_ values: [String], limit: Int = 6) -> [(name: String, count: Int)] {
        Dictionary(grouping: values, by: { $0 }).map { ($0.key, $0.value.count) }
            .sorted { $0.1 > $1.1 }.prefix(limit).map { (name: $0.0, count: $0.1) }
    }

    private func percent(_ part: Int, _ whole: Int) -> String {
        whole == 0 ? "0%" : "\(Int((Double(part) / Double(whole) * 100).rounded()))%"
    }

    private func stat(_ label: String, _ value: String, icon: String) -> some View {
        LabeledContent {
            Text(value).monospacedDigit()
        } label: {
            Label(label, systemImage: icon)
        }
    }
}
