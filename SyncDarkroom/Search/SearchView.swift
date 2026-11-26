import SwiftUI

enum SearchRoute: Hashable {
    case people
    case person(UUID)
    case bucket(kind: String, id: String)
}

/// Search tab: smart (CLIP), metadata and object search with people/place/camera/date filters,
/// and an Explore page (people, places, things, cameras) like Immich's.
struct SearchView: View {
    @Environment(FolderStore.self) private var folderStore
    @State private var index = PhotoIndex.shared
    @State private var analysis = PhotoAnalysisStore.shared
    @State private var people = PeopleStore.shared
    @State private var places = PlaceStore.shared

    @State private var text = ""
    @AppStorage("searchMode") private var mode: SearchMode = .smart
    @State private var filters = SearchFilters()
    @State private var similarTo: IndexedPhoto?
    @State private var results: [SearchResult] = []
    @State private var searching = false
    @State private var showFilters = false
    @State private var viewer: ViewerContext?
    @State private var path = NavigationPath()
    @State private var searchTask: Task<Void, Never>?
    /// Smart results above this index are less relevant and hidden until asked for.
    @State private var relevantCount: Int?
    @State private var showAllResults = false

    private var isSearching: Bool {
        !text.trimmingCharacters(in: .whitespaces).isEmpty || filters.activeCount > 0 || similarTo != nil
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    if isSearching {
                        resultsGrid
                    } else {
                        ExploreView()
                    }
                }
                .padding(.vertical)
            }
            .navigationTitle("Search")
            .searchable(text: $text, placement: .navigationBarDrawer(displayMode: .always), prompt: mode.prompt)
            .onSubmit(of: .search) { runSearch(debounce: false) }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showFilters = true
                    } label: {
                        Label(filters.activeCount > 0 ? "Filters (\(filters.activeCount))" : "Filters",
                              systemImage: filters.activeCount > 0 ? "line.3.horizontal.decrease.circle.fill"
                                  : "line.3.horizontal.decrease.circle")
                    }
                }
            }
            .navigationDestination(for: SearchRoute.self) { route in
                switch route {
                case .people: PeopleView()
                case .person(let id): PersonDetailView(personID: id)
                case .bucket(let kind, let id): BucketView(kind: kind, id: id)
                }
            }
            .sheet(isPresented: $showFilters) { SearchFilterSheet(filters: $filters) }
            .fullScreenCover(item: $viewer) { PhotoViewer(context: $0) }
        }
        .onChange(of: text) { runSearch(debounce: true) }
        .onChange(of: mode) { runSearch(debounce: false) }
        .onChange(of: filters) { runSearch(debounce: false) }
        .onChange(of: similarTo) { runSearch(debounce: false) }
        .task(id: folderStore.rootURL) {
            guard let root = folderStore.rootURL else { return }
            index.refreshIfNeeded(root: root)
            PeopleStore.shared.update(index: index, analysis: analysis, root: root)
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Search Mode", selection: $mode) {
                ForEach(SearchMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 420)

            if let similarTo {
                chip("Similar to \(similarTo.name)", systemImage: "sparkles") { self.similarTo = nil }
            }
            if filters.activeCount > 0 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack { activeFilterChips }
                }
            }
            AnalysisStatus()
        }
        .padding(.horizontal)
    }

    @ViewBuilder
    private var activeFilterChips: some View {
        ForEach(Array(filters.people), id: \.self) { id in
            chip(people.person(id)?.displayName ?? "Person", systemImage: "person") { filters.people.remove(id) }
        }
        if let place = filters.place { chip(place, systemImage: "mappin") { filters.place = nil } }
        if let camera = filters.camera { chip(camera, systemImage: "camera") { filters.camera = nil } }
        if let lens = filters.lens { chip(lens, systemImage: "camera.aperture") { filters.lens = nil } }
        if filters.from != nil || filters.to != nil {
            chip(dateRangeText, systemImage: "calendar") { filters.from = nil; filters.to = nil }
        }
        if filters.media != .all { chip(filters.media.title, systemImage: "photo") { filters.media = .all } }
        if filters.includeEditedCopies { chip("With Edited Copies", systemImage: "slider.horizontal.3") { filters.includeEditedCopies = false } }
    }

    private var dateRangeText: String {
        let f = filters.from?.formatted(date: .abbreviated, time: .omitted)
        let t = filters.to?.formatted(date: .abbreviated, time: .omitted)
        switch (f, t) {
        case let (f?, t?): return "\(f) – \(t)"
        case let (f?, nil): return "From \(f)"
        case let (nil, t?): return "Until \(t)"
        default: return ""
        }
    }

    private func chip(_ title: String, systemImage: String, remove: @escaping () -> Void) -> some View {
        Button(action: remove) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                Text(title).lineLimit(1)
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .font(.callout)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.accentColor.opacity(0.15), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Remove \(title)")
    }

    // MARK: Results

    @ViewBuilder
    private var resultsGrid: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if searching {
                    ProgressView().controlSize(.small)
                }
                Text(resultsSummary).font(.callout).foregroundStyle(.secondary)
            }
            .padding(.horizontal)
            if !searching && results.isEmpty {
                ContentUnavailableView.search(text: text)
            }
            if let root = folderStore.rootURL {
                let shown = showAllResults ? results : Array(results.prefix(relevantCount ?? results.count))
                let items = shown.map { $0.photo.libraryItem(root: root) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 4)], spacing: 4) {
                    ForEach(Array(zip(shown, items)), id: \.0.id) { result, item in
                        Button { viewer = ViewerContext(items: items, startURL: item.url) } label: {
                            ThumbnailCell(item: item, pixelSize: 320)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            if SearchEngine.clipEmbedding(of: result.photo) != nil {
                                Button("Find Similar Photos", systemImage: "sparkles") {
                                    mode = .smart
                                    text = ""
                                    similarTo = result.photo
                                }
                            }
                            let inPhoto = people.people(inPhoto: result.photo.path)
                            ForEach(inPhoto) { person in
                                Button(person.displayName, systemImage: "person.crop.circle") {
                                    path.append(SearchRoute.person(person.id))
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 4)
                if let relevantCount, relevantCount < results.count {
                    Button(showAllResults ? "Show Only the Best Matches"
                           : "Show \(results.count - relevantCount) Less Relevant Photos") {
                        showAllResults.toggle()
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                }
            }
        }
    }

    private var resultsSummary: String {
        let n = showAllResults ? results.count : (relevantCount ?? results.count)
        let base = n == 1 ? "1 photo" : "\(n) photos"
        if mode == .smart && (similarTo != nil || !text.isEmpty) && n > 0 { return base + ", most relevant first" }
        return base
    }

    // MARK: Running searches

    private func runSearch(debounce: Bool) {
        searchTask?.cancel()
        guard isSearching else {
            results = []
            searching = false
            return
        }
        let query = text.trimmingCharacters(in: .whitespaces)
        let mode = mode
        let filters = filters
        let similar = similarTo
        searching = true
        searchTask = Task {
            if debounce { try? await Task.sleep(for: .milliseconds(mode == .smart ? 450 : 200)) }
            guard !Task.isCancelled else { return }
            let candidates = SearchEngine.filtered(filters)
            var found: [SearchResult]
            if let similar, let embedding = SearchEngine.clipEmbedding(of: similar) {
                found = SearchEngine.rank(by: embedding, in: candidates.filter { $0.path != similar.path })
                if !query.isEmpty {
                    let keep = Set(SearchEngine.metadataSearch(query, in: candidates).map(\.id))
                    found = found.filter { keep.contains($0.id) }
                }
            } else if query.isEmpty {
                found = candidates.sorted { $0.date > $1.date }.map { SearchResult(photo: $0, score: 0) }
            } else {
                switch mode {
                case .smart:
                    let embedding = await Task.detached(priority: .userInitiated) {
                        CLIPEncoder.shared?.embed(text: query)
                    }.value
                    if let embedding {
                        found = SearchEngine.rank(by: embedding, in: candidates)
                    } else {
                        found = SearchEngine.metadataSearch(query, in: candidates)
                    }
                case .metadata:
                    found = SearchEngine.metadataSearch(query, in: candidates)
                case .objects:
                    found = SearchEngine.objectSearch(query, in: candidates)
                }
            }
            guard !Task.isCancelled else { return }
            // CLIP ranks every photo; keep the clear matches (similarity close to the best one).
            var cutoff: Int?
            if let top = found.first?.score, mode == .smart || similar != nil, top != 0 {
                let floor = similar != nil ? max(0.55, top - 0.2) : max(0.15, top - 0.08)
                cutoff = max(1, found.prefix { $0.score >= floor }.count)
            }
            results = found
            relevantCount = cutoff
            showAllResults = false
            searching = false
        }
    }
}

// MARK: - Analysis status

/// "Analyzing photos for search… 120 of 4,812" with pause/resume.
struct AnalysisStatus: View {
    @State private var analysis = PhotoAnalysisStore.shared
    @State private var people = PeopleStore.shared

    var body: some View {
        if analysis.pendingCount > 0 {
            HStack(spacing: 10) {
                if analysis.isWorking {
                    ProgressView().controlSize(.small)
                    Text("Analyzing photos for search… \(analysis.finishedCount) of \(analysis.finishedCount + analysis.pendingCount)")
                } else {
                    Image(systemName: "pause.circle")
                    Text("Analysis paused, \(analysis.pendingCount) photos left")
                }
                Spacer()
                Button(analysis.isPaused ? "Resume" : "Pause") { analysis.isPaused.toggle() }
            }
            .font(.callout)
            .monospacedDigit()
            .padding(10)
            .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        } else if CLIPEncoder.shared == nil {
            Label("Smart search isn't available in this build (the CLIP model is missing). Metadata and object search still work.",
                  systemImage: "exclamationmark.triangle")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Explore

private struct ExploreView: View {
    @Environment(FolderStore.self) private var folderStore
    @State private var people = PeopleStore.shared
    @State private var places = PlaceStore.shared
    @State private var analysis = PhotoAnalysisStore.shared
    @State private var index = PhotoIndex.shared

    var body: some View {
        let _ = (places.revision, analysis.revision, index.photos.count)
        let persons = people.sortedPeople(minimumFaces: 2)
        let placeBuckets = SearchEngine.placeBuckets()
        let things = SearchEngine.thingBuckets()
        let cameras = SearchEngine.cameraBuckets()

        VStack(alignment: .leading, spacing: 24) {
            section("People", see: persons.isEmpty ? nil : .people) {
                if persons.isEmpty {
                    placeholder("Faces appear here as photos are analyzed. Name people to search for them.")
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 16) {
                            ForEach(persons.prefix(20)) { person in
                                NavigationLink(value: SearchRoute.person(person.id)) {
                                    VStack {
                                        FaceAvatar(face: people.coverFace(of: person), size: 92)
                                        Text(person.name.isEmpty ? " " : person.name).font(.callout).lineLimit(1)
                                    }
                                    .frame(width: 100)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal)
                    }
                }
            }
            bucketRow("Places", kind: "place", buckets: placeBuckets,
                      empty: places.isResolving ? "Looking up place names…" : "Photos with a location appear here.")
            bucketRow("Things", kind: "thing", buckets: things, empty: "Objects and scenes appear here as photos are analyzed.")
            bucketRow("Cameras", kind: "camera", buckets: cameras, empty: "No camera information.")
        }
        .task(id: index.photos.count) { places.resolve(index.photos) }
    }

    private func section<Content: View>(_ title: String, see route: SearchRoute? = nil,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.title2.bold())
                Spacer()
                if let route { NavigationLink("See All", value: route) }
            }
            .padding(.horizontal)
            content()
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary).padding(.horizontal)
    }

    private func bucketRow(_ title: String, kind: String, buckets: [SearchEngine.Bucket], empty: String) -> some View {
        section(title) {
            if buckets.isEmpty {
                placeholder(empty)
            } else if let root = folderStore.rootURL {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 12) {
                        ForEach(buckets) { bucket in
                            NavigationLink(value: SearchRoute.bucket(kind: kind, id: bucket.id)) {
                                ThumbnailCell(item: bucket.cover.libraryItem(root: root), pixelSize: 320)
                                    .frame(width: 150, height: 150)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                    .overlay(alignment: .bottomLeading) {
                                        VStack(alignment: .leading, spacing: 0) {
                                            Text(bucket.title).font(.callout.bold()).lineLimit(1)
                                            Text("\(bucket.photos.count)").font(.caption)
                                        }
                                        .foregroundStyle(.white)
                                        .shadow(color: .black.opacity(0.8), radius: 3)
                                        .padding(8)
                                    }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                }
                .frame(height: 150)
            }
        }
    }
}

/// Photos of one place, thing or camera.
private struct BucketView: View {
    let kind: String
    let id: String
    @Environment(FolderStore.self) private var folderStore
    @State private var viewer: ViewerContext?

    var body: some View {
        let buckets: [SearchEngine.Bucket] = switch kind {
        case "place": SearchEngine.placeBuckets()
        case "thing": SearchEngine.thingBuckets(limit: 500)
        default: SearchEngine.cameraBuckets()
        }
        let photos = (buckets.first { $0.id == id }?.photos ?? []).sorted { $0.date > $1.date }
        ScrollView {
            if let root = folderStore.rootURL {
                let items = photos.map { $0.libraryItem(root: root) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 4)], spacing: 4) {
                    ForEach(items) { item in
                        Button { viewer = ViewerContext(items: items, startURL: item.url) } label: {
                            ThumbnailCell(item: item, pixelSize: 320)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(4)
            }
        }
        .navigationTitle(buckets.first { $0.id == id }?.title ?? id)
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $viewer) { PhotoViewer(context: $0) }
    }
}

// MARK: - Filters

private struct SearchFilterSheet: View {
    @Binding var filters: SearchFilters
    @Environment(\.dismiss) private var dismiss
    @State private var people = PeopleStore.shared
    @State private var draft = SearchFilters()

    var body: some View {
        NavigationStack {
            Form {
                Section("People") {
                    let persons = people.sortedPeople(minimumFaces: 2)
                    if persons.isEmpty {
                        Text("No people found yet.").foregroundStyle(.secondary)
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 14) {
                                ForEach(persons) { person in
                                    let on = draft.people.contains(person.id)
                                    Button {
                                        if on { draft.people.remove(person.id) } else { draft.people.insert(person.id) }
                                    } label: {
                                        VStack {
                                            FaceAvatar(face: people.coverFace(of: person), size: 64)
                                                .overlay(Circle().stroke(on ? Color.accentColor : .clear, lineWidth: 3))
                                            Text(person.name.isEmpty ? " " : person.name).font(.caption).lineLimit(1)
                                        }
                                        .frame(width: 72)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                Section("Place & Camera") {
                    Picker("Place", selection: $draft.place) {
                        Text("Any").tag(String?.none)
                        ForEach(SearchEngine.placeBuckets().map(\.title).sorted(), id: \.self) { Text($0).tag(String?.some($0)) }
                    }
                    Picker("Camera", selection: $draft.camera) {
                        Text("Any").tag(String?.none)
                        ForEach(SearchEngine.cameraBuckets().map(\.title).sorted(), id: \.self) { Text($0).tag(String?.some($0)) }
                    }
                    Picker("Lens", selection: $draft.lens) {
                        Text("Any").tag(String?.none)
                        ForEach(SearchEngine.lensNames(), id: \.self) { Text($0).tag(String?.some($0)) }
                    }
                }
                Section("Date Taken") {
                    Toggle("From", isOn: Binding(get: { draft.from != nil },
                                                 set: { draft.from = $0 ? (draft.from ?? Date().addingTimeInterval(-365 * 86_400)) : nil }))
                    if let from = draft.from {
                        DatePicker("From", selection: Binding(get: { from }, set: { draft.from = $0 }), displayedComponents: .date)
                    }
                    Toggle("Until", isOn: Binding(get: { draft.to != nil }, set: { draft.to = $0 ? (draft.to ?? Date()) : nil }))
                    if let to = draft.to {
                        DatePicker("Until", selection: Binding(get: { to }, set: { draft.to = $0 }), displayedComponents: .date)
                    }
                }
                Section("Type") {
                    Picker("Media", selection: $draft.media) {
                        ForEach(MediaKind.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("Include Edited Copies", isOn: $draft.includeEditedCopies)
                        .disabled(draft.media == .edited || draft.media == .raw)
                }
            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Reset") { draft = SearchFilters() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        filters = draft
                        dismiss()
                    }
                }
            }
        }
        .onAppear { draft = filters }
    }
}
