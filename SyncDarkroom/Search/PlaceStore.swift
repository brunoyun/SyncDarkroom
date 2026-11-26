@preconcurrency import CoreLocation
import Foundation
import Observation

struct PlaceName: Codable, Hashable, Sendable {
    var city: String?
    var region: String?
    var country: String?

    /// "Lyon", or the region/country when there's no city.
    var title: String { city ?? region ?? country ?? "Unknown Place" }
    var subtitle: String? {
        let parts = [city == nil ? nil : region, country].compactMap { $0 }.filter { $0 != title }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
    var searchText: String { [city, region, country].compactMap { $0 }.joined(separator: " ") }
}

/// City/region/country names for photo locations, looked up once per ~5 km cell with Apple's
/// geocoder (rate-limited, so slowly, in the background) and remembered on this iPad.
@MainActor
@Observable
final class PlaceStore {
    static let shared = PlaceStore()

    private(set) var names: [String: PlaceName] = [:]
    private(set) var revision = 0
    private(set) var isResolving = false
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var failed: Set<String> = []

    init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let decoded = try? JSONDecoder().decode([String: PlaceName].self, from: data) {
            names = decoded
        }
    }

    static func cell(latitude: Double, longitude: Double) -> String {
        String(format: "%.2f,%.2f", (latitude * 20).rounded() / 20, (longitude * 20).rounded() / 20)
    }

    func place(for photo: IndexedPhoto) -> PlaceName? {
        guard photo.hasLocation, let lat = photo.latitude, let lon = photo.longitude else { return nil }
        return names[Self.cell(latitude: lat, longitude: lon)]
    }

    /// Looks up the names of cells not known yet (most photos first).
    func resolve(_ photos: [IndexedPhoto]) {
        guard task == nil else { return }
        var counts: [String: (Int, Double, Double)] = [:]
        for p in photos where p.hasLocation {
            guard let lat = p.latitude, let lon = p.longitude else { continue }
            let key = Self.cell(latitude: lat, longitude: lon)
            guard names[key] == nil, !failed.contains(key) else { continue }
            let c = counts[key]
            counts[key] = ((c?.0 ?? 0) + 1, lat, lon)
        }
        let todo = counts.sorted { $0.value.0 > $1.value.0 }.map { ($0.key, $0.value.1, $0.value.2) }
        guard !todo.isEmpty else { return }
        isResolving = true
        task = Task {
            let geocoder = CLGeocoder()
            for (key, lat, lon) in todo {
                if Task.isCancelled { break }
                do {
                    let placemarks = try await geocoder.reverseGeocodeLocation(CLLocation(latitude: lat, longitude: lon))
                    if let p = placemarks.first {
                        names[key] = PlaceName(city: p.locality ?? p.subAdministrativeArea,
                                               region: p.administrativeArea, country: p.country)
                    } else {
                        failed.insert(key)
                    }
                    revision += 1
                    if revision % 10 == 0 { save() }
                } catch {
                    let code = (error as? CLError)?.code
                    if code == .network { try? await Task.sleep(for: .seconds(30)) }
                    else if code == .geocodeFoundNoResult { failed.insert(key) }
                    else { try? await Task.sleep(for: .seconds(5)) }
                }
                // Apple allows about one request per second.
                try? await Task.sleep(for: .milliseconds(1300))
            }
            save()
            isResolving = false
            task = nil
        }
    }

    nonisolated private static var fileURL: URL { AppStorageFiles.url("places.json") }

    private func save() {
        let snapshot = names
        Task.detached(priority: .background) {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: Self.fileURL, options: .atomic)
        }
    }
}
