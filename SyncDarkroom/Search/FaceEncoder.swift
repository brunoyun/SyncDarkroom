import CoreGraphics
import CoreML
import Foundation

/// OpenCV's SFace face-recognition model (Apache-2.0), converted to Core ML and bundled.
/// Takes a 112×112 face aligned to the ArcFace template; returns a unit-length 128-value
/// embedding. Two faces belong to the same person when their cosine similarity is ≥ ~0.36.
final class FaceEncoder: @unchecked Sendable {
    static let shared: FaceEncoder? = FaceEncoder(directory: Bundle.main.resourceURL)
    /// Cosine similarity above which two faces are taken to be the same person (SFace's published threshold).
    static let samePersonSimilarity: Float = 0.363

    private let model: MLModel
    private let constraint: MLImageConstraint
    private let inputName: String
    private let lock = NSLock()

    init?(directory: URL?) {
        guard let directory,
              let model = try? MLModel(contentsOf: directory.appendingPathComponent("sface.mlmodelc")),
              let (name, input) = model.modelDescription.inputDescriptionsByName.first,
              let constraint = input.imageConstraint
        else { return nil }
        self.model = model
        self.constraint = constraint
        inputName = name
    }

    func embed(_ face: CGImage) -> [Float]? {
        guard let value = try? MLFeatureValue(cgImage: face, constraint: constraint, options: nil),
              let input = try? MLDictionaryFeatureProvider(dictionary: [inputName: value])
        else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard let output = try? model.prediction(from: input),
              let name = output.featureNames.first,
              let array = output.featureValue(for: name)?.multiArrayValue else { return nil }
        var v = (0..<array.count).map { array[$0].floatValue }
        let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
        guard norm > 0 else { return nil }
        for i in v.indices { v[i] /= norm }
        return v
    }
}
