import Foundation
import ImageIO
import SwiftUI

struct PhotoMetadata: Sendable {
    var pixelWidth: Int?
    var pixelHeight: Int?
    var make: String?
    var model: String?
    var lens: String?
    var fNumber: Double?
    var exposureTime: Double?
    var iso: Int?
    var focalLength: Double?
    var focalLength35mm: Int?
    var exposureBias: Double?
    var flashFired: Bool?
    var dateTaken: Date?
    var colorProfile: String?
    var latitude: Double?
    var longitude: Double?

    static func read(from url: URL) -> PhotoMetadata {
        ImageLoading.coordinatedRead(url) { readURL -> PhotoMetadata? in
            guard let source = CGImageSourceCreateWithURL(readURL as CFURL, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            else { return nil }
            return PhotoMetadata(properties: props)
        } ?? PhotoMetadata()
    }

    init() {}

    init(properties props: [CFString: Any]) {
        pixelWidth = props[kCGImagePropertyPixelWidth] as? Int
        pixelHeight = props[kCGImagePropertyPixelHeight] as? Int
        if let orientation = props[kCGImagePropertyOrientation] as? Int, (5...8).contains(orientation) {
            swap(&pixelWidth, &pixelHeight)
        }
        colorProfile = props[kCGImagePropertyProfileName] as? String

        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        make = (tiff?[kCGImagePropertyTIFFMake] as? String)?.trimmingCharacters(in: .whitespaces)
        model = (tiff?[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespaces)

        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let exifAux = props[kCGImagePropertyExifAuxDictionary] as? [CFString: Any]
        lens = (exif?[kCGImagePropertyExifLensModel] as? String) ?? (exifAux?[kCGImagePropertyExifAuxLensModel] as? String)
        fNumber = exif?[kCGImagePropertyExifFNumber] as? Double
        exposureTime = exif?[kCGImagePropertyExifExposureTime] as? Double
        iso = (exif?[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first
        focalLength = exif?[kCGImagePropertyExifFocalLength] as? Double
        focalLength35mm = exif?[kCGImagePropertyExifFocalLenIn35mmFilm] as? Int
        exposureBias = exif?[kCGImagePropertyExifExposureBiasValue] as? Double
        if let flash = exif?[kCGImagePropertyExifFlash] as? Int { flashFired = flash & 1 == 1 }
        if let raw = (exif?[kCGImagePropertyExifDateTimeOriginal] as? String)
            ?? (tiff?[kCGImagePropertyTIFFDateTime] as? String) {
            dateTaken = Self.exifDateFormatter.date(from: raw)
        }

        if let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any],
           let lat = gps[kCGImagePropertyGPSLatitude] as? Double,
           let lon = gps[kCGImagePropertyGPSLongitude] as? Double {
            latitude = (gps[kCGImagePropertyGPSLatitudeRef] as? String) == "S" ? -lat : lat
            longitude = (gps[kCGImagePropertyGPSLongitudeRef] as? String) == "W" ? -lon : lon
        }
    }

    private static let exifDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter
    }()

    var cameraName: String? {
        guard let model else { return make }
        if let make, !model.lowercased().hasPrefix(make.lowercased().split(separator: " ").first.map(String.init) ?? "") {
            return "\(make) \(model)"
        }
        return model
    }

    var shutterText: String? {
        guard let t = exposureTime, t > 0 else { return nil }
        if t >= 1 { return t.formatted(.number.precision(.fractionLength(0...1))) + " s" }
        return "1/\(Int((1 / t).rounded())) s"
    }

    var apertureText: String? {
        fNumber.map { "ƒ/" + $0.formatted(.number.precision(.fractionLength(0...1))) }
    }

    var focalText: String? {
        guard let focalLength else { return nil }
        var text = focalLength.formatted(.number.precision(.fractionLength(0...1))) + " mm"
        if let focalLength35mm, Int(focalLength.rounded()) != focalLength35mm {
            text += " (\(focalLength35mm) mm eq.)"
        }
        return text
    }

    var biasText: String? {
        guard let exposureBias else { return nil }
        let sign = exposureBias > 0 ? "+" : ""
        return sign + exposureBias.formatted(.number.precision(.fractionLength(0...2))) + " EV"
    }
}

struct MetadataPanel: View {
    let item: LibraryItem
    @State private var metadata: PhotoMetadata?

    var body: some View {
        Form {
            Section("File") {
                row("Name", item.name)
                row("Type", item.type?.label)
                row("Size", item.fileSize.formatted(.byteCount(style: .file)))
                row("Modified", item.modified.formatted(date: .abbreviated, time: .shortened))
                if let w = metadata?.pixelWidth, let h = metadata?.pixelHeight {
                    row("Dimensions", "\(w) × \(h)  (\(String(format: "%.1f", Double(w * h) / 1_000_000)) MP)")
                }
                row("Color Profile", metadata?.colorProfile)
            }
            if let m = metadata {
                Section("Camera") {
                    row("Camera", m.cameraName)
                    row("Lens", m.lens)
                    row("Taken", m.dateTaken?.formatted(date: .abbreviated, time: .standard))
                }
                Section("Exposure") {
                    row("Aperture", m.apertureText)
                    row("Shutter", m.shutterText)
                    row("ISO", m.iso.map(String.init))
                    row("Focal Length", m.focalText)
                    row("Exposure Comp.", m.biasText)
                    row("Flash", m.flashFired.map { $0 ? "Fired" : "Off" })
                }
                if let lat = m.latitude, let lon = m.longitude {
                    Section("Location") {
                        row("Coordinates", String(format: "%.5f, %.5f", lat, lon))
                        if let url = URL(string: "maps://?ll=\(lat),\(lon)&q=Photo") {
                            Link("Open in Maps", destination: url)
                        }
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .task(id: item) {
            metadata = nil
            let url = item.url
            metadata = await Task.detached(priority: .utility) { PhotoMetadata.read(from: url) }.value
        }
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            LabeledContent(label) {
                Text(value).textSelection(.enabled).multilineTextAlignment(.trailing)
            }
        }
    }
}
