import CoreGraphics
import CoreML
import Foundation
import Vision

/// MobileCLIP-S0 image and text encoders (bundled with the app). Both return unit-length
/// 512-value embeddings, so the dot product of an image and a text embedding is their similarity.
final class CLIPEncoder: @unchecked Sendable {
    static let shared: CLIPEncoder? = CLIPEncoder(directory: Bundle.main.resourceURL)

    private let imageModel: MLModel
    private let textModel: MLModel
    private let tokenizer: CLIPTokenizer
    private let imageConstraint: MLImageConstraint
    private let lock = NSLock()

    init?(directory: URL?) {
        guard let directory,
              let tokenizer = CLIPTokenizer(mergesURL: directory.appendingPathComponent("clip-merges.txt"))
        else { return nil }
        let config = MLModelConfiguration()
        config.computeUnits = .all
        guard let image = try? MLModel(contentsOf: directory.appendingPathComponent("mobileclip_s0_image.mlmodelc"),
                                       configuration: config),
              let text = try? MLModel(contentsOf: directory.appendingPathComponent("mobileclip_s0_text.mlmodelc"),
                                      configuration: config),
              let constraint = image.modelDescription.inputDescriptionsByName["image"]?.imageConstraint
        else { return nil }
        imageModel = image
        textModel = text
        self.tokenizer = tokenizer
        imageConstraint = constraint
    }

    func embed(image: CGImage) -> [Float]? {
        let options: [MLFeatureValue.ImageOption: Any] = [.cropAndScale: VNImageCropAndScaleOption.centerCrop.rawValue]
        guard let value = try? MLFeatureValue(cgImage: image, constraint: imageConstraint, options: options),
              let input = try? MLDictionaryFeatureProvider(dictionary: ["image": value])
        else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard let output = try? imageModel.prediction(from: input) else { return nil }
        return Self.normalizedOutput(output)
    }

    func embed(text: String) -> [Float]? {
        let tokens = tokenizer.encode(text)
        guard let array = try? MLMultiArray(shape: [1, NSNumber(value: CLIPTokenizer.contextLength)], dataType: .int32)
        else { return nil }
        for (i, t) in tokens.enumerated() { array[i] = NSNumber(value: t) }
        guard let input = try? MLDictionaryFeatureProvider(dictionary: ["text": MLFeatureValue(multiArray: array)])
        else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard let output = try? textModel.prediction(from: input) else { return nil }
        return Self.normalizedOutput(output)
    }

    private static func normalizedOutput(_ output: MLFeatureProvider) -> [Float]? {
        guard let name = output.featureNames.first,
              let array = output.featureValue(for: name)?.multiArrayValue else { return nil }
        var v = (0..<array.count).map { array[$0].floatValue }
        let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
        guard norm > 0 else { return nil }
        for i in v.indices { v[i] /= norm }
        return v
    }
}
