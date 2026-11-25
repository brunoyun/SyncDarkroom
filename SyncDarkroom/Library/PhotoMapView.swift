import MapKit
import SwiftUI

/// World map of every geotagged photo under the root folder: groups that split as you zoom,
/// plus a heat map of where many photos were taken.
struct PhotoMapView: View {
    @Environment(FolderStore.self) private var folderStore
    @State private var index = PhotoIndex.shared
    // Not .automatic: that re-fits the camera whenever the groups change, which changes the
    // region, which changes the groups again (an endless loop).
    @State private var position: MapCameraPosition = .region(
        MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 25, longitude: 10),
                           span: MKCoordinateSpan(latitudeDelta: 140, longitudeDelta: 300)))
    @State private var didFit = false
    @State private var region: MKCoordinateRegion?
    @State private var selected: PhotoCluster?
    @AppStorage("mapShowsHeat") private var showsHeat = true
    @AppStorage("mapShowsGroups") private var showsGroups = true
    @AppStorage("mapIncludesCopies") private var includesCopies = false

    private var located: [IndexedPhoto] {
        index.photos.filter { $0.hasLocation && (includesCopies || !$0.isEditedCopy) }
    }

    var body: some View {
        NavigationStack {
            let located = located
            let clusters = region.map { PhotoClustering.clusters(located, in: $0) } ?? []
            let heat = region.map { PhotoClustering.heat(located, in: $0) } ?? []
            Map(position: $position) {
                if showsHeat {
                    ForEach(heat) { cell in
                        MapCircle(center: cell.center, radius: cell.radius)
                            .foregroundStyle(cell.color)
                    }
                }
                if showsGroups {
                    ForEach(clusters) { cluster in
                        Annotation("", coordinate: cluster.center, anchor: .center) {
                            ClusterBubble(cluster: cluster, root: folderStore.rootURL)
                                .onTapGesture { selected = cluster }
                        }
                    }
                }
            }
            .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
            .mapControls {
                MapPitchToggle()
                MapCompass()
                MapScaleView()
            }
            .onMapCameraChange(frequency: .onEnd) { context in region = context.region }
            .overlay(alignment: .top) { status(located.count) }
            .overlay {
                if !index.isScanning && located.isEmpty {
                    ContentUnavailableView("No Photo Locations", systemImage: "map",
                                           description: Text("None of the photos in this folder have GPS coordinates."))
                }
            }
            .navigationTitle("Map")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Toggle(isOn: $showsHeat) { Label("Heat Map", systemImage: "flame") }
                    Toggle(isOn: $showsGroups) { Label("Photo Groups", systemImage: "square.stack") }
                    Menu {
                        Toggle("Include Edited Copies", isOn: $includesCopies)
                        Button("Show All Photos", systemImage: "globe") { fitAll(located) }
                    } label: {
                        Label("Options", systemImage: "ellipsis.circle")
                    }
                }
            }
            .toggleStyle(.button)
            .sheet(item: $selected) { cluster in
                ClusterPhotosView(cluster: cluster)
            }
        }
        .task {
            if let root = folderStore.rootURL { index.refreshIfNeeded(root: root) }
        }
        .onChange(of: index.isScanning) {
            // Frame all photos once, after the first scan.
            if !index.isScanning && !didFit && !located.isEmpty {
                didFit = true
                fitAll(located)
            }
        }
        .onAppear {
            if !index.isScanning && !didFit && !located.isEmpty {
                didFit = true
                fitAll(located)
            }
        }
    }

    private func status(_ count: Int) -> some View {
        HStack(spacing: 8) {
            if index.isScanning {
                ProgressView().controlSize(.small)
                Text("Reading locations… \(index.scanned) of \(index.toScan)")
            } else {
                Image(systemName: "mappin.and.ellipse")
                Text("\(count) photo\(count == 1 ? "" : "s") with a location")
            }
        }
        .font(.callout)
        .monospacedDigit()
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .padding(.top, 8)
    }

    private func fitAll(_ photos: [IndexedPhoto]) {
        guard !photos.isEmpty else { return }
        let lats = photos.compactMap(\.latitude), lons = photos.compactMap(\.longitude)
        guard let minLat = lats.min(), let maxLat = lats.max(), let minLon = lons.min(), let maxLon = lons.max() else { return }
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2)
        let span = MKCoordinateSpan(latitudeDelta: min(170, max(0.05, (maxLat - minLat) * 1.4)),
                                    longitudeDelta: min(360, max(0.05, (maxLon - minLon) * 1.4)))
        withAnimation { position = .region(MKCoordinateRegion(center: center, span: span)) }
    }
}

// MARK: - Clustering

struct PhotoCluster: Identifiable {
    let id: String
    let center: CLLocationCoordinate2D
    let photos: [IndexedPhoto]
    /// Most recent photo, shown on the bubble.
    var cover: IndexedPhoto { photos.max { $0.date < $1.date } ?? photos[0] }
}

struct HeatCell: Identifiable {
    let id: String
    let center: CLLocationCoordinate2D
    let radius: CLLocationDistance
    let color: Color
}

enum PhotoClustering {
    /// Grid sized to the visible region (≈ 7 columns), so zooming in splits groups.
    static func clusters(_ photos: [IndexedPhoto], in region: MKCoordinateRegion) -> [PhotoCluster] {
        let cellLon = max(1e-5, region.span.longitudeDelta / 7)
        let cellLat = max(1e-5, region.span.latitudeDelta / 8)
        return grid(photos, in: region, cellLat: cellLat, cellLon: cellLon).map { key, members in
            let lat = members.compactMap(\.latitude).reduce(0, +) / Double(members.count)
            let lon = members.compactMap(\.longitude).reduce(0, +) / Double(members.count)
            return PhotoCluster(id: key, center: CLLocationCoordinate2D(latitude: lat, longitude: lon), photos: members)
        }
    }

    /// Finer grid, colored yellow → red by photo count.
    static func heat(_ photos: [IndexedPhoto], in region: MKCoordinateRegion) -> [HeatCell] {
        let cellLon = max(1e-5, region.span.longitudeDelta / 36)
        let cellLat = max(1e-5, region.span.latitudeDelta / 36)
        let cells = grid(photos, in: region, cellLat: cellLat, cellLon: cellLon)
            .sorted { $0.value.count > $1.value.count }
            .prefix(700)
        let maxCount = Double(cells.first?.value.count ?? 1)
        // Radius ≈ 1.3 cells so neighbouring circles blend into a continuous glow.
        let radius = cellLat * 111_000 * 1.3
        return cells.map { key, members in
            let lat = members.compactMap(\.latitude).reduce(0, +) / Double(members.count)
            let lon = members.compactMap(\.longitude).reduce(0, +) / Double(members.count)
            let t = log(1 + Double(members.count)) / log(1 + maxCount)
            let color = Color(hue: 0.16 * (1 - t), saturation: 0.95, brightness: 1).opacity(0.18 + 0.42 * t)
            return HeatCell(id: key, center: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                            radius: radius * (0.7 + 0.5 * t), color: color)
        }
    }

    private static func grid(_ photos: [IndexedPhoto], in region: MKCoordinateRegion,
                             cellLat: Double, cellLon: Double) -> [String: [IndexedPhoto]] {
        // Include a margin around the visible area so groups don't pop at the edges.
        let minLat = region.center.latitude - region.span.latitudeDelta
        let maxLat = region.center.latitude + region.span.latitudeDelta
        let minLon = region.center.longitude - region.span.longitudeDelta
        let maxLon = region.center.longitude + region.span.longitudeDelta
        let wholeWorld = region.span.longitudeDelta >= 180
        var cells: [String: [IndexedPhoto]] = [:]
        for photo in photos {
            guard let lat = photo.latitude, let lon = photo.longitude else { continue }
            guard lat >= minLat, lat <= maxLat, wholeWorld || (lon >= minLon && lon <= maxLon) else { continue }
            let key = "\(Int(floor(lat / cellLat))):\(Int(floor(lon / cellLon)))"
            cells[key, default: []].append(photo)
        }
        return cells
    }
}

// MARK: - Views

private struct ClusterBubble: View {
    let cluster: PhotoCluster
    let root: URL?

    var body: some View {
        let size: CGFloat = cluster.photos.count > 99 ? 64 : 56
        ZStack(alignment: .topTrailing) {
            Group {
                if let root {
                    ThumbnailCell(item: cluster.cover.libraryItem(root: root), pixelSize: 160)
                } else {
                    Color.gray
                }
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white, lineWidth: 3))
            .shadow(color: .black.opacity(0.35), radius: 4, y: 2)

            if cluster.photos.count > 1 {
                Text("\(cluster.photos.count)")
                    .font(.caption.bold())
                    .monospacedDigit()
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.accentColor, in: Capsule())
                    .foregroundStyle(.white)
                    .offset(x: 8, y: -8)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement()
        .accessibilityLabel("\(cluster.photos.count) photos")
        .accessibilityAddTraits(.isButton)
    }
}

/// The photos of one map group.
private struct ClusterPhotosView: View {
    let cluster: PhotoCluster
    @Environment(FolderStore.self) private var folderStore
    @Environment(\.dismiss) private var dismiss
    @State private var viewer: ViewerContext?

    var body: some View {
        NavigationStack {
            let photos = cluster.photos.sorted { $0.date > $1.date }
            ScrollView {
                if let root = folderStore.rootURL {
                    let items = photos.map { $0.libraryItem(root: root) }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 4)], spacing: 4) {
                        ForEach(items) { item in
                            Button {
                                viewer = ViewerContext(items: items, startURL: item.url)
                            } label: {
                                ThumbnailCell(item: item, pixelSize: 320)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("\(photos.count) Photo\(photos.count == 1 ? "" : "s")")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text("\(photos.count) Photo\(photos.count == 1 ? "" : "s")").font(.headline)
                        if let first = photos.last?.date, let last = photos.first?.date {
                            Text(dateRange(first, last)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .fullScreenCover(item: $viewer) { PhotoViewer(context: $0) }
    }

    private func dateRange(_ a: Date, _ b: Date) -> String {
        let f = a.formatted(date: .abbreviated, time: .omitted), l = b.formatted(date: .abbreviated, time: .omitted)
        return f == l ? f : "\(f) – \(l)"
    }
}
