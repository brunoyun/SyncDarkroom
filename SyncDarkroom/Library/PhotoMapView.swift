import MapKit
import SwiftUI

/// Immich-style relative date ranges for the map.
enum MapDateRange: String, CaseIterable, Identifiable {
    case all, day, week, month, year, threeYears, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "All Time"
        case .day: "Past 24 Hours"
        case .week: "Past 7 Days"
        case .month: "Past 30 Days"
        case .year: "Past Year"
        case .threeYears: "Past 3 Years"
        case .custom: "Custom Range"
        }
    }
    var start: Date? {
        let now = Date()
        switch self {
        case .all, .custom: return nil
        case .day: return now.addingTimeInterval(-86_400)
        case .week: return now.addingTimeInterval(-7 * 86_400)
        case .month: return now.addingTimeInterval(-30 * 86_400)
        case .year: return Calendar.current.date(byAdding: .year, value: -1, to: now)
        case .threeYears: return Calendar.current.date(byAdding: .year, value: -3, to: now)
        }
    }
}

enum MapLook: String, CaseIterable, Identifiable {
    case standard, satellite, hybrid
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var style: MapStyle {
        switch self {
        case .standard: .standard(elevation: .flat, pointsOfInterest: .excludingAll)
        case .satellite: .imagery(elevation: .flat)
        case .hybrid: .hybrid(elevation: .flat, pointsOfInterest: .excludingAll)
        }
    }
}

/// World map of every geotagged photo under the root folder, modelled on Immich's map: a
/// density heatmap, photo groups that split as you zoom, date filters, and the photos in view.
struct PhotoMapView: View {
    @Environment(FolderStore.self) private var folderStore
    @State private var index = PhotoIndex.shared
    @State private var didFit = false
    /// Bumped to make the map frame `fitRect`.
    @State private var fitRequest = 0
    @State private var fitRect: MKMapRect?
    @State private var points: [MapPoint] = []
    @State private var clusters: [PhotoCluster] = []
    /// Visible map rectangle once the map stops (groups are recomputed then).
    @State private var settledRect: MKMapRect?
    @State private var mapSize: CGSize = .zero
    @State private var selected: PhotoCluster?
    @State private var showInView = false
    @State private var showSettings = false
    @AppStorage("mapShowsHeat") private var showsHeat = true
    @AppStorage("mapShowsGroups") private var showsGroups = true
    @AppStorage("mapIncludesCopies") private var includesCopies = false
    @AppStorage("mapDateRange") private var dateRange: MapDateRange = .all
    @AppStorage("mapCustomFrom") private var customFrom: Double = Date().addingTimeInterval(-365 * 86_400).timeIntervalSince1970
    @AppStorage("mapCustomTo") private var customTo: Double = Date().timeIntervalSince1970
    @AppStorage("mapLook") private var look: MapLook = .standard

    private var located: [IndexedPhoto] {
        let start: Date? = dateRange == .custom ? Date(timeIntervalSince1970: customFrom) : dateRange.start
        let end: Date? = dateRange == .custom ? Date(timeIntervalSince1970: customTo).addingTimeInterval(86_400) : nil
        return index.photos.filter { p in
            guard p.hasLocation, includesCopies || !p.isEditedCopy else { return false }
            if let start, p.date < start { return false }
            if let end, p.date >= end { return false }
            return true
        }
    }

    var body: some View {
        NavigationStack {
            PhotoMapKitView(points: points, clusters: showsGroups ? clusters : [], showsHeat: showsHeat, look: look,
                            root: folderStore.rootURL, fitRequest: fitRequest, fitRect: fitRect,
                            onSettle: { rect, size in
                                settledRect = rect
                                mapSize = size
                                regroup()
                            },
                            onSelect: { selected = $0 })
                .ignoresSafeArea(edges: .bottom)
            .overlay(alignment: .top) { status(points.count) }
            .overlay(alignment: .bottom) {
                if !points.isEmpty, let settledRect {
                    let inView = PhotoClustering.photos(points, in: settledRect)
                    Button {
                        showInView = true
                    } label: {
                        Label("\(inView.count) Photos in View", systemImage: "square.grid.2x2")
                            .font(.callout.weight(.semibold))
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .background(.regularMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(inView.isEmpty)
                    .padding(.bottom, 16)
                    .sheet(isPresented: $showInView) {
                        ClusterPhotosView(cluster: PhotoCluster(id: "view", coordinate: settledRect.origin.coordinate,
                                                                photos: inView, title: "Photos in View"))
                    }
                }
            }
            .overlay {
                if !index.isScanning && points.isEmpty {
                    ContentUnavailableView("No Photo Locations", systemImage: "map",
                                           description: Text(dateRange == .all
                                                             ? "None of the photos in this folder have GPS coordinates."
                                                             : "No photos with a location in \(dateRange.title.lowercased())."))
                }
            }
            .navigationTitle("Map")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Toggle(isOn: $showsHeat) { Label("Heat Map", systemImage: "flame") }
                    Toggle(isOn: $showsGroups) { Label("Photo Groups", systemImage: "square.stack") }
                    Button("Show All Photos", systemImage: "globe") { fitAll(points.map(\.photo)) }
                    Button("Map Settings", systemImage: "slider.horizontal.3") { showSettings = true }
                }
            }
            .toggleStyle(.button)
            .sheet(item: $selected) { cluster in
                ClusterPhotosView(cluster: cluster)
            }
            .sheet(isPresented: $showSettings) { settings }
        }
        .task {
            if let root = folderStore.rootURL { index.refreshIfNeeded(root: root) }
        }
        .onChange(of: index.isScanning) { rebuild(); fitOnce() }
        .onChange(of: index.lastUpdated) { rebuild() }
        .onChange(of: dateRange) { rebuild() }
        .onChange(of: customFrom) { rebuild() }
        .onChange(of: customTo) { rebuild() }
        .onChange(of: includesCopies) { rebuild() }
        .onAppear { rebuild(); fitOnce() }
    }

    private var settings: some View {
        NavigationStack {
            Form {
                Section("Date Taken") {
                    Picker("Show", selection: $dateRange) {
                        ForEach(MapDateRange.allCases) { Text($0.title).tag($0) }
                    }
                    if dateRange == .custom {
                        DatePicker("From", selection: Binding(get: { Date(timeIntervalSince1970: customFrom) },
                                                              set: { customFrom = $0.timeIntervalSince1970 }),
                                   displayedComponents: .date)
                        DatePicker("Until", selection: Binding(get: { Date(timeIntervalSince1970: customTo) },
                                                               set: { customTo = $0.timeIntervalSince1970 }),
                                   displayedComponents: .date)
                    }
                }
                Section("Map") {
                    Picker("Style", selection: $look) {
                        ForEach(MapLook.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Toggle("Heat Map", isOn: $showsHeat)
                    Toggle("Photo Groups", isOn: $showsGroups)
                    Toggle("Include Edited Copies", isOn: $includesCopies)
                }
            }
            .toggleStyle(.switch)
            .navigationTitle("Map Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { showSettings = false } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func status(_ count: Int) -> some View {
        HStack(spacing: 8) {
            if index.isScanning {
                ProgressView().controlSize(.small)
                Text("Reading locations… \(index.scanned) of \(index.toScan)")
            } else {
                Image(systemName: "mappin.and.ellipse")
                Text("\(count) photo\(count == 1 ? "" : "s") with a location")
                if dateRange != .all {
                    Text("· \(dateRange.title)").foregroundStyle(.secondary)
                }
            }
        }
        .font(.callout)
        .monospacedDigit()
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .padding(.top, 8)
    }

    private func rebuild() {
        points = MapPoint.make(located)
        regroup()
    }

    private func regroup() {
        clusters = settledRect.map { PhotoClustering.clusters(points, in: $0, viewSize: mapSize) } ?? []
    }

    private func fitOnce() {
        if !index.isScanning && !didFit && !points.isEmpty {
            didFit = true
            fitAll(points.map(\.photo))
        }
    }

    private func fitAll(_ photos: [IndexedPhoto]) {
        guard !photos.isEmpty else { return }
        let lats = photos.compactMap(\.latitude), lons = photos.compactMap(\.longitude)
        guard let minLat = lats.min(), let maxLat = lats.max(), let minLon = lons.min(), let maxLon = lons.max() else { return }
        let a = MKMapPoint(CLLocationCoordinate2D(latitude: maxLat, longitude: minLon))
        let b = MKMapPoint(CLLocationCoordinate2D(latitude: minLat, longitude: maxLon))
        let minSide = 2_000.0 * MKMapPointsPerMeterAtLatitude((minLat + maxLat) / 2)
        var rect = MKMapRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
        rect = rect.insetBy(dx: -max(0, minSide - rect.width) / 2, dy: -max(0, minSide - rect.height) / 2)
        fitRect = rect
        fitRequest += 1
    }
}

// MARK: - Points & clustering

/// A photo projected onto the flat (Web Mercator) map.
struct MapPoint {
    let photo: IndexedPhoto
    let point: MKMapPoint

    static func make(_ photos: [IndexedPhoto]) -> [MapPoint] {
        photos.compactMap { p in
            guard let lat = p.latitude, let lon = p.longitude else { return nil }
            return MapPoint(photo: p, point: MKMapPoint(CLLocationCoordinate2D(latitude: lat, longitude: lon)))
        }
    }
}

struct PhotoCluster: Identifiable {
    let id: String
    let coordinate: CLLocationCoordinate2D
    let photos: [IndexedPhoto]
    var title: String?
    /// Most recent photo, shown on the bubble.
    var cover: IndexedPhoto { photos.max { $0.date < $1.date } ?? photos[0] }
}

enum PhotoClustering {
    /// Screen distance (points) within which photos join a group: about a bubble's width.
    static let radius: CGFloat = 60

    /// Groups photos that are close on screen (like Immich/Supercluster). Each group is drawn
    /// at the photo nearest its centre, so it always sits where a photo was actually taken
    /// (an averaged position can fall in the sea between two coasts).
    static func clusters(_ points: [MapPoint], in rect: MKMapRect, viewSize: CGSize) -> [PhotoCluster] {
        guard viewSize.width > 0, rect.width > 0 else { return [] }
        let perPoint = rect.width / Double(viewSize.width)   // map units per screen point
        let cell = Double(radius) * perPoint
        let margin = rect.insetBy(dx: -rect.width * 0.5, dy: -rect.height * 0.5)
        let visible = points.filter { margin.contains($0.point) || rect.width >= MKMapSize.world.width * 0.9 }

        var grid: [Int64: [Int]] = [:]
        func key(_ x: Int, _ y: Int) -> Int64 { Int64(x) << 32 | Int64(UInt32(bitPattern: Int32(y))) }
        for (i, p) in visible.enumerated() {
            grid[key(Int(floor(p.point.x / cell)), Int(floor(p.point.y / cell))), default: []].append(i)
        }
        // Densest cells first, so big groups form around real hot spots.
        let seeds = grid.sorted { $0.value.count > $1.value.count }.flatMap(\.value)
        var used = [Bool](repeating: false, count: visible.count)
        var result: [PhotoCluster] = []
        for seed in seeds where !used[seed] {
            let s = visible[seed].point
            let cx = Int(floor(s.x / cell)), cy = Int(floor(s.y / cell))
            var members: [Int] = []
            for dx in -1...1 {
                for dy in -1...1 {
                    for j in grid[key(cx + dx, cy + dy)] ?? [] where !used[j] {
                        let q = visible[j].point
                        if hypot(q.x - s.x, q.y - s.y) <= cell {
                            used[j] = true
                            members.append(j)
                        }
                    }
                }
            }
            let mx = members.map { visible[$0].point.x }.reduce(0, +) / Double(members.count)
            let my = members.map { visible[$0].point.y }.reduce(0, +) / Double(members.count)
            let anchor = members.min { a, b in
                hypot(visible[a].point.x - mx, visible[a].point.y - my) < hypot(visible[b].point.x - mx, visible[b].point.y - my)
            } ?? seed
            let photos = members.map { visible[$0].photo }
            result.append(PhotoCluster(id: visible[anchor].photo.path, coordinate: visible[anchor].point.coordinate, photos: photos))
        }
        return result
    }

    static func photos(_ points: [MapPoint], in rect: MKMapRect) -> [IndexedPhoto] {
        points.filter { rect.contains($0.point) }.map(\.photo)
    }
}

// MARK: - Heatmap

/// Kernel-density heatmap drawn over the map, with Immich's colors (transparent → purple →
/// blue → green → yellow → orange), radius and intensity growing with zoom, 70 % opacity.
enum Heatmap {
    /// Map zoom level like web maps use (0 = whole world in 256 points), from points per map point.
    static func zoom(scale: Double) -> Double { log2(MKMapSize.world.width * scale / 256) }

    /// Immich: radius 4 → 8 → 16 px at zoom 0 → 4 → 9; intensity 0.5 → 2 at zoom 0 → 9.
    /// A little larger here, since an iPad map is much bigger than a web page's.
    static func radiusPoints(zoom z: Double) -> Double { 1.5 * (z <= 4 ? 4 + max(0, z) : min(16, 8 + (z - 4) * 8 / 5)) }
    static func intensity(zoom z: Double) -> Double { 0.5 + 1.5 * min(1, max(0, z / 9)) }

    /// Density image (w×h pixels) of the points over `rect`.
    static func render(points: [MKMapPoint], rect: MKMapRect, width w: Int, height h: Int,
                       radius r: Double, intensity: Double) -> CGImage? {
        guard w > 0, h > 0, rect.width > 0, !points.isEmpty else { return nil }
        let r = max(1.5, r)
        let sigma = r / 3
        let kr = Int(ceil(r))
        var kernel = [Float](repeating: 0, count: (2 * kr + 1) * (2 * kr + 1))
        for dy in -kr...kr {
            for dx in -kr...kr {
                let d2 = Double(dx * dx + dy * dy)
                kernel[(dy + kr) * (2 * kr + 1) + dx + kr] = d2 > r * r ? 0 : Float(exp(-d2 / (2 * sigma * sigma)) * 0.4 * intensity)
            }
        }

        var density = [Float](repeating: 0, count: w * h)
        let sx = Double(w) / rect.width, sy = Double(h) / rect.height
        for p in points {
            do {
                let x = (p.x - rect.minX) * sx
                let y = (p.y - rect.minY) * sy
                let ix = Int(x), iy = Int(y)
                guard ix >= -kr, ix < w + kr, iy >= -kr, iy < h + kr else { continue }
                for dy in -kr...kr {
                    let yy = iy + dy
                    guard yy >= 0, yy < h else { continue }
                    let row = yy * w
                    let krow = (dy + kr) * (2 * kr + 1) + kr
                    for dx in -kr...kr {
                        let xx = ix + dx
                        guard xx >= 0, xx < w else { continue }
                        density[row + xx] += kernel[krow + dx]
                    }
                }
            }
        }

        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) {
            let d = density[i]
            guard d > 0.01 else { continue }
            let c = color(min(1, d))
            // Premultiplied RGBA.
            pixels[i * 4] = UInt8(c.r * c.a * 255)
            pixels[i * 4 + 1] = UInt8(c.g * c.a * 255)
            pixels[i * 4 + 2] = UInt8(c.b * c.a * 255)
            pixels[i * 4 + 3] = UInt8(c.a * 255)
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Immich's ramp: density → color.
    private static let stops: [(Float, Float, Float, Float, Float)] = [
        (0.0, 103, 58, 183, 0), (0.3, 103, 58, 183, 1), (0.5, 33, 149, 243, 1),
        (0.7, 76, 175, 79, 1), (0.95, 255, 235, 59, 1), (1.0, 255, 86, 34, 1),
    ]

    static func color(_ d: Float) -> (r: Float, g: Float, b: Float, a: Float) {
        for i in 1..<stops.count where d <= stops[i].0 {
            let a = stops[i - 1], b = stops[i]
            let t = (d - a.0) / (b.0 - a.0)
            return ((a.1 + (b.1 - a.1) * t) / 255, (a.2 + (b.2 - a.2) * t) / 255,
                    (a.3 + (b.3 - a.3) * t) / 255, a.4 + (b.4 - a.4) * t)
        }
        return (1, 86 / 255, 34 / 255, 1)
    }
}

// MARK: - Views

struct ClusterBubble: View {
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

/// The photos of one map group (or all photos in view).
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
            .navigationTitle(cluster.title ?? "\(photos.count) Photo\(photos.count == 1 ? "" : "s")")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text(cluster.title ?? "\(photos.count) Photo\(photos.count == 1 ? "" : "s")").font(.headline)
                        if let first = photos.last?.date, let last = photos.first?.date {
                            Text("\(photos.count) · " + dateRange(first, last)).font(.caption).foregroundStyle(.secondary)
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

// MARK: - MapKit view

/// The map itself (UIKit MapKit, so the heatmap can be a real overlay drawn under the groups).
private struct PhotoMapKitView: UIViewRepresentable {
    let points: [MapPoint]
    let clusters: [PhotoCluster]
    let showsHeat: Bool
    let look: MapLook
    let root: URL?
    let fitRequest: Int
    let fitRect: MKMapRect?
    let onSettle: (MKMapRect, CGSize) -> Void
    let onSelect: (PhotoCluster) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.isRotateEnabled = false
        map.isPitchEnabled = false
        map.showsScale = true
        map.showsCompass = false
        map.register(ClusterAnnotationView.self, forAnnotationViewWithReuseIdentifier: ClusterAnnotationView.reuseID)
        // Start on a world view; the photos are framed once they're loaded.
        map.setRegion(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 30, longitude: 10),
                                         span: MKCoordinateSpan(latitudeDelta: 120, longitudeDelta: 180)), animated: false)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let c = context.coordinator
        c.parent = self

        if c.look != look {
            c.look = look
            switch look {
            case .standard:
                let config = MKStandardMapConfiguration(elevationStyle: .flat)
                config.pointOfInterestFilter = .excludingAll
                map.preferredConfiguration = config
            case .satellite: map.preferredConfiguration = MKImageryMapConfiguration(elevationStyle: .flat)
            case .hybrid:
                let config = MKHybridMapConfiguration(elevationStyle: .flat)
                config.pointOfInterestFilter = .excludingAll
                map.preferredConfiguration = config
            }
        }

        // Heat overlay: replaced when the photos or the toggle change.
        let heatKey = showsHeat ? points.count ^ (points.first?.photo.path.hashValue ?? 0) ^ (points.last?.photo.path.hashValue ?? 0) : -1
        if c.heatKey != heatKey {
            c.heatKey = heatKey
            map.removeOverlays(map.overlays)
            if showsHeat && !points.isEmpty { map.addOverlay(HeatOverlay(points: points.map(\.point)), level: .aboveLabels) }
        }

        // Groups: keep annotations whose group didn't change, to avoid flicker.
        let existing = map.annotations.compactMap { $0 as? ClusterAnnotation }
        let wanted = Dictionary(clusters.map { ($0.id + "|\($0.photos.count)", $0) }, uniquingKeysWith: { a, _ in a })
        let stale = existing.filter { wanted[$0.key] == nil }
        let present = Set(existing.map(\.key))
        map.removeAnnotations(stale)
        map.addAnnotations(wanted.filter { !present.contains($0.key) }.map { ClusterAnnotation(key: $0.key, cluster: $0.value) })
        for annotation in existing where wanted[annotation.key] != nil {
            annotation.cluster = wanted[annotation.key]!
        }
        c.root = root

        if c.fitRequest != fitRequest, let fitRect {
            c.fitRequest = fitRequest
            map.setVisibleMapRect(fitRect, edgePadding: UIEdgeInsets(top: 120, left: 60, bottom: 100, right: 60), animated: true)
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: PhotoMapKitView?
        var look: MapLook?
        var heatKey = Int.min
        var fitRequest = 0
        var root: URL?

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            let rect = mapView.visibleMapRect, size = mapView.bounds.size
            // Not during a SwiftUI update (setting the first region happens inside one).
            DispatchQueue.main.async { self.parent?.onSettle(rect, size) }
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let heat = overlay as? HeatOverlay else { return MKOverlayRenderer(overlay: overlay) }
            let renderer = HeatRenderer(overlay: heat)
            renderer.alpha = 0.7
            return renderer
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let annotation = annotation as? ClusterAnnotation else { return nil }
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: ClusterAnnotationView.reuseID, for: annotation)
            (view as? ClusterAnnotationView)?.show(annotation.cluster, root: root)
            return view
        }

        func mapView(_ mapView: MKMapView, didSelect annotation: MKAnnotation) {
            mapView.deselectAnnotation(annotation, animated: false)
            if let annotation = annotation as? ClusterAnnotation { parent?.onSelect(annotation.cluster) }
        }
    }
}

private final class ClusterAnnotation: NSObject, MKAnnotation {
    let key: String
    var cluster: PhotoCluster
    var coordinate: CLLocationCoordinate2D { cluster.coordinate }
    init(key: String, cluster: PhotoCluster) {
        self.key = key
        self.cluster = cluster
    }
}

private final class ClusterAnnotationView: MKAnnotationView {
    static let reuseID = "cluster"
    private var host: UIHostingController<ClusterBubble>?

    func show(_ cluster: PhotoCluster, root: URL?) {
        let bubble = ClusterBubble(cluster: cluster, root: root)
        if let host {
            host.rootView = bubble
        } else {
            let host = UIHostingController(rootView: bubble)
            host.view.backgroundColor = .clear
            host.view.frame = CGRect(x: 0, y: 0, width: 80, height: 80)
            addSubview(host.view)
            self.host = host
        }
        frame = CGRect(x: 0, y: 0, width: 80, height: 80)
        host?.view.frame = bounds
        canShowCallout = false
        displayPriority = .required
        collisionMode = .none
    }
}

/// All photo positions, drawn by `HeatRenderer` as a density map.
private final class HeatOverlay: NSObject, MKOverlay {
    let points: [MKMapPoint]
    let coordinate = CLLocationCoordinate2D(latitude: 0, longitude: 0)
    let boundingMapRect = MKMapRect.world

    init(points: [MKMapPoint]) {
        self.points = points.sorted { $0.x < $1.x }
    }

    /// Points within a map rectangle (binary search on x).
    func points(in rect: MKMapRect) -> [MKMapPoint] {
        var lo = 0, hi = points.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if points[mid].x < rect.minX { lo = mid + 1 } else { hi = mid }
        }
        var result: [MKMapPoint] = []
        var i = lo
        while i < points.count, points[i].x <= rect.maxX {
            if points[i].y >= rect.minY && points[i].y <= rect.maxY { result.append(points[i]) }
            i += 1
        }
        return result
    }
}

private final class HeatRenderer: MKOverlayRenderer {
    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard let heat = overlay as? HeatOverlay else { return }
        let z = Heatmap.zoom(scale: Double(zoomScale))
        let radiusPts = Heatmap.radiusPoints(zoom: z)
        let radiusMap = radiusPts / Double(zoomScale)
        let points = heat.points(in: mapRect.insetBy(dx: -radiusMap, dy: -radiusMap))
        guard !points.isEmpty else { return }
        // Half-point resolution is plenty for a soft glow.
        let res = 0.5
        let w = Int(ceil(mapRect.width * Double(zoomScale) * res))
        let h = Int(ceil(mapRect.height * Double(zoomScale) * res))
        guard let image = Heatmap.render(points: points, rect: mapRect, width: w, height: h,
                                         radius: radiusPts * res, intensity: Heatmap.intensity(zoom: z))
        else { return }
        UIGraphicsPushContext(context)
        UIImage(cgImage: image).draw(in: rect(for: mapRect))
        UIGraphicsPopContext()
    }
}
