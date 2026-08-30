import CoreML
import Vision

final class ObjectDetector {
    enum DetectorError: LocalizedError {
        case modelNotFound

        var errorDescription: String? {
            switch self {
            case .modelNotFound:
                "The bundled YOLO model could not be loaded. Clean and rebuild the project."
            }
        }
    }

    private let model: VNCoreMLModel

    init() throws {
        guard let url = Bundle.main.url(forResource: "YOLOv3TinyFP16", withExtension: "mlmodelc") else {
            throw DetectorError.modelNotFound
        }
        model = try VNCoreMLModel(for: MLModel(contentsOf: url))
    }

    func detect(in pixelBuffer: CVPixelBuffer, minimumConfidence: Float) throws -> [DetectedObject] {
        var result: [DetectedObject] = []
        let request = VNCoreMLRequest(model: model) { request, _ in
            let observations = request.results as? [VNRecognizedObjectObservation] ?? []
            result = observations.compactMap { observation in
                guard let topLabel = observation.labels.first,
                      topLabel.confidence >= minimumConfidence else { return nil }
                return DetectedObject(
                    label: topLabel.identifier.replacingOccurrences(of: "_", with: " "),
                    confidence: topLabel.confidence,
                    boundingBox: observation.boundingBox
                )
            }
        }
        request.imageCropAndScaleOption = .scaleFill
        try VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up).perform([request])
        return result.sorted { $0.confidence > $1.confidence }
    }
}
