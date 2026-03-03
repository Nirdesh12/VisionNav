//
//  NavigationModel.swift
//  VisionNav
//
//  Segmentation-based object detection with FOV box support,
//  tactile paving guidance, and LiDAR stair counting

import Foundation
import Vision
import CoreML
import ARKit
import AVFoundation
import UIKit
import Combine
import CoreImage

// MARK: - Detection Result
public struct NavigationDetection: Identifiable {
    public let id = UUID()
    public let label: String
    public let confidence: Float
    public let boundingBox: CGRect
    public let isObstacle: Bool
    public let isGuidance: Bool      // tactile_paving, crosswalk, stairs
    public let distance: Float?
    public let segmentationMask: UIImage?  // Per-object segmentation mask

    public var confidencePercentage: Int { Int(confidence * 100) }

    static let obstacleClasses: Set<String> = [
        "person", "bicycle", "car", "motorcycle", "bus", "truck",
        "fire hydrant", "stop sign", "bench", "dog", "cat", "chair",
        "couch", "potted plant", "backpack", "suitcase", "bottle"
    ]

    static let guidanceClasses: Set<String> = [
        "tactile_paving", "stairs", "crosswalk", "zebra_crossing",
        "tactile paving", "staircase", "steps"
    ]
}

// MARK: - Alert
public struct NavigationAlert: Identifiable {
    public let id = UUID()
    public let message: String
    public let alertType: AlertType
    public let priority: Int

    public enum AlertType {
        case info, warning, danger, tactile, stairs, pathClear

        public var color: UIColor {
            switch self {
            case .info: return .systemBlue
            case .warning: return .systemOrange
            case .danger: return .systemRed
            case .tactile: return .systemYellow
            case .stairs: return .systemOrange
            case .pathClear: return .systemGreen
            }
        }

        public var icon: String {
            switch self {
            case .info: return "info.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .danger: return "exclamationmark.octagon.fill"
            case .tactile: return "road.lanes"
            case .stairs: return "stairs"
            case .pathClear: return "checkmark.shield.fill"
            }
        }
    }
}

// MARK: - Tactile Paving Direction
public enum TactilePavingDirection: String {
    case left = "Tactile paving on your left"
    case center = "Tactile paving ahead"
    case right = "Tactile paving on your right"
    case none = ""
}

// MARK: - Navigation Model
class NavigationModel: NSObject, ObservableObject {

    // Detections
    @Published var detections: [NavigationDetection] = []
    @Published var detectionsInFOV: [NavigationDetection] = []
    @Published var detectionCount: Int = 0
    @Published var isModelLoaded: Bool = false
    @Published var modelName: String = "YOLO"
    @Published var currentAlert: NavigationAlert?
    @Published var speechEnabled: Bool = true
    @Published var nearestDistance: Float = 999

    // Segmentation
    @Published var segmentationOverlayImage: UIImage?

    // Tactile Paving
    @Published var tactilePavingDetected: Bool = false
    @Published var tactilePavingDirection: TactilePavingDirection = .none

    // Stairs
    @Published var stairsDetected: Bool = false
    @Published var stairCount: Int = 0
    @Published var stairDirection: StairDirection = .unknown

    private var visionModel: VNCoreMLModel?
    private let confidenceThreshold: Float = 0.4
    private let processingQueue = DispatchQueue(label: "detection", qos: .userInitiated)
    private var isProcessing: Bool = false
    private var lastAlertTime: Date = .distantPast
    private var lastTactileAlertTime: Date = .distantPast
    private var lastStairAlertTime: Date = .distantPast

    // FOV-based obstacle avoidance state
    private var lastFOVObstacleAlertTime: Date = .distantPast
    private var lastPathClearTime: Date = .distantPast
    private var lastFOVAlertMessage: String = ""
    private let fovAlertCooldown: TimeInterval = 4.0
    private let pathClearCooldown: TimeInterval = 6.0

    private let speechSynthesizer = AVSpeechSynthesizer()
    private var currentDepthData: ARDepthData?
    private var currentFOVBox: CGRect = CGRect(x: 0.25, y: 0.2, width: 0.5, height: 0.6)

    // Throttle segmentation mask rendering — no need to render every frame
    private var lastSegmentationRenderTime: Date = .distantPast
    private let segmentationRenderInterval: TimeInterval = 0.3  // Max ~3 mask renders per second

    // Stair counting & direction callbacks — set by the view to call NavigationCameraManager
    var stairCountProvider: ((CGRect, ARDepthData?) -> Int)?
    var stairDirectionProvider: ((CGRect, ARDepthData?) -> StairDirection)?
    var onDistanceUpdate: ((Float) -> Void)?

    // COCO 80 class names + extended custom classes for navigation assistance
    // Indices 0-79 = standard COCO, 80+ = custom-trained classes (adjust to match your model)
    private let classNames: [String] = [
        "person", "bicycle", "car", "motorcycle", "airplane", "bus", "train", "truck", "boat",
        "traffic light", "fire hydrant", "stop sign", "parking meter", "bench", "bird", "cat",
        "dog", "horse", "sheep", "cow", "elephant", "bear", "zebra", "giraffe", "backpack",
        "umbrella", "handbag", "tie", "suitcase", "frisbee", "skis", "snowboard", "sports ball",
        "kite", "baseball bat", "baseball glove", "skateboard", "surfboard", "tennis racket",
        "bottle", "wine glass", "cup", "fork", "knife", "spoon", "bowl", "banana", "apple",
        "sandwich", "orange", "broccoli", "carrot", "hot dog", "pizza", "donut", "cake",
        "chair", "couch", "potted plant", "bed", "dining table", "toilet", "tv", "laptop",
        "mouse", "remote", "keyboard", "cell phone", "microwave", "oven", "toaster", "sink",
        "refrigerator", "book", "clock", "vase", "scissors", "teddy bear", "hair drier", "toothbrush",
        // Extended custom classes (indices 80+) — adjust order to match your custom-trained model
        "tactile_paving", "stairs", "crosswalk", "zebra_crossing", "staircase", "steps"
    ]

    override init() {
        super.init()
        setupSpeech()
        loadModel()
    }

    private func setupSpeech() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .voicePrompt, options: [.mixWithOthers, .duckOthers])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {}
    }

    // MARK: - Model Loading (segmentation model preferred, detection-only as fallback)
    private func loadModel() {
        processingQueue.async { [weak self] in
            // Prefer segmentation model, fall back to detection-only
            // NOTE: Add your custom trained seg model as "yolov26s-seg.mlpackage" to the Models/ folder
            let names = ["yolov26s-seg", "yolo26s-seg", "yolov26s", "yolo26s", "yolo11s-seg", "yolo11s", "yolov8s-seg", "yolov8s", "YOLOv3", "YOLOv3Tiny"]
            var url: URL?
            var name = "YOLO"

            for n in names {
                for ext in ["mlmodelc", "mlpackage", "mlmodel"] {
                    if let u = Bundle.main.url(forResource: n, withExtension: ext) {
                        url = u; name = n; break
                    }
                }
                if url != nil { break }
            }

            guard let modelURL = url else {
                DispatchQueue.main.async { self?.modelName = "No Model" }
                return
            }

            do {
                let config = MLModelConfiguration()
                config.computeUnits = .all
                let ml = try MLModel(contentsOf: modelURL, configuration: config)
                let vm = try VNCoreMLModel(for: ml)
                DispatchQueue.main.async {
                    self?.visionModel = vm
                    self?.isModelLoaded = true
                    self?.modelName = name.uppercased()
                }
            } catch {
                print("Model error: \(error)")
            }
        }
    }

    func updateFOVBox(_ box: CGRect) {
        currentFOVBox = box
    }

    // MARK: - Process Frame
    func processFrame(pixelBuffer: CVPixelBuffer, depthData: ARDepthData?, fovBox: CGRect) {
        currentFOVBox = fovBox

        guard !isProcessing, let model = visionModel else { return }
        isProcessing = true
        currentDepthData = depthData

        let request = VNCoreMLRequest(model: model) { [weak self] req, _ in
            self?.handleResults(req)
        }
        request.imageCropAndScaleOption = .scaleFill

        processingQueue.async { [weak self] in
            do {
                let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right, options: [:])
                try handler.perform([request])
            } catch {}
            self?.isProcessing = false
        }
    }

    // MARK: - Handle Detection + Segmentation Results
    private func handleResults(_ request: VNRequest) {
        var allResults: [NavigationDetection] = []
        var fovResults: [NavigationDetection] = []
        var minDist: Float = 999
        var foundTactilePaving = false
        var tactileBox: CGRect?
        var foundStairs = false
        var stairsBBox: CGRect?

        guard let results = request.results else {
            finishProcessing(allResults: [], fovResults: [], minDist: 999)
            return
        }

        // Try standard VNRecognizedObjectObservation first (for object detector pipeline models)
        for result in results.prefix(25) {
            if let obs = result as? VNRecognizedObjectObservation {
                guard let label = obs.labels.first, label.confidence >= confidenceThreshold else { continue }
                let name = label.identifier.lowercased()
                let isObstacle = NavigationDetection.obstacleClasses.contains(name)
                let isGuidance = NavigationDetection.guidanceClasses.contains(name)
                let dist = getDepth(at: obs.boundingBox)

                let detection = NavigationDetection(
                    label: label.identifier,
                    confidence: label.confidence,
                    boundingBox: obs.boundingBox,
                    isObstacle: isObstacle,
                    isGuidance: isGuidance,
                    distance: dist,
                    segmentationMask: nil
                )

                allResults.append(detection)

                if name.contains("tactile") || name.contains("paving") {
                    foundTactilePaving = true
                    tactileBox = obs.boundingBox
                }
                if name.contains("stair") || name.contains("steps") {
                    foundStairs = true
                    stairsBBox = obs.boundingBox
                }
                if isWithinFOV(obs.boundingBox) {
                    fovResults.append(detection)
                    if let d = dist, d < minDist { minDist = d }
                }
            }
        }

        // If no VNRecognizedObjectObservation found, parse raw YOLO tensor output
        // (mlProgram models output raw MLMultiArray tensors, not recognized objects)
        if allResults.isEmpty {
            let parsed = parseRawYOLODetections(from: results)
            for detection in parsed.detections {
                let name = detection.label.lowercased()
                allResults.append(detection)

                if name.contains("tactile") || name.contains("paving") {
                    foundTactilePaving = true
                    tactileBox = detection.boundingBox
                }
                if name.contains("stair") || name.contains("steps") {
                    foundStairs = true
                    stairsBBox = detection.boundingBox
                }
                if isWithinFOV(detection.boundingBox) {
                    fovResults.append(detection)
                    if let d = detection.distance, d < minDist { minDist = d }
                }
            }

            // Render segmentation overlay from mask prototypes (seg model only, throttled)
            if let prototypes = parsed.maskPrototypes, let detTensor = parsed.detectionTensor {
                let now = Date()
                if now.timeIntervalSince(lastSegmentationRenderTime) >= segmentationRenderInterval {
                    lastSegmentationRenderTime = now
                    let overlayImage = renderInstanceSegmentation(
                        detectionTensor: detTensor,
                        prototypes: prototypes,
                        inputSize: 640.0
                    )
                    DispatchQueue.main.async {
                        self.segmentationOverlayImage = overlayImage
                    }
                }
            }
        } else {
            // Standard path: handle segmentation masks from VNCoreMLFeatureValueObservation (throttled)
            let now = Date()
            if now.timeIntervalSince(lastSegmentationRenderTime) >= segmentationRenderInterval {
                for result in results {
                    if let featureObs = result as? VNCoreMLFeatureValueObservation,
                       let multiArray = featureObs.featureValue.multiArrayValue {
                        let shape = multiArray.shape.map { $0.intValue }
                        // Only render spatial masks (height/width > 50), skip detection tensors
                        guard shape.count >= 2 else { continue }
                        let h = shape.count >= 3 ? shape[shape.count - 2] : shape[0]
                        let w = shape[shape.count - 1]
                        guard h > 50 && w > 50 else { continue }

                        lastSegmentationRenderTime = now
                        let overlayImage = renderSegmentationMask(multiArray)
                        DispatchQueue.main.async {
                            self.segmentationOverlayImage = overlayImage
                        }
                        break
                    }
                }
            }
        }

        // Analyze tactile paving position
        if foundTactilePaving, let box = tactileBox {
            analyzeTactilePavingPosition(box)
        } else {
            DispatchQueue.main.async {
                self.tactilePavingDetected = false
                self.tactilePavingDirection = .none
            }
        }

        // Analyze stairs with LiDAR
        if foundStairs, let box = stairsBBox {
            analyzeStairsWithLiDAR(boundingBox: box)
        } else {
            DispatchQueue.main.async {
                self.stairsDetected = false
                self.stairCount = 0
                self.stairDirection = .unknown
            }
        }

        allResults.sort { ($0.distance ?? 999) < ($1.distance ?? 999) }
        fovResults.sort { ($0.distance ?? 999) < ($1.distance ?? 999) }

        checkAlert(fovResults)

        finishProcessing(allResults: allResults, fovResults: fovResults, minDist: minDist)
    }

    private func finishProcessing(allResults: [NavigationDetection], fovResults: [NavigationDetection], minDist: Float) {
        DispatchQueue.main.async {
            self.detections = allResults
            self.detectionsInFOV = fovResults
            self.detectionCount = allResults.count
            self.nearestDistance = minDist
            self.onDistanceUpdate?(minDist)
        }
    }

    // MARK: - Parse Raw YOLO Tensor Output
    /// Parses raw MLMultiArray output from YOLO mlProgram models (post-NMS format).
    /// Detection tensor: [1, N, 6] or [1, N, 38] where each detection = [x1, y1, x2, y2, conf, class_id, ...mask_coeffs]
    /// Mask prototypes (seg model only): [1, 32, H, W]
    private func parseRawYOLODetections(from results: [VNObservation]) -> (detections: [NavigationDetection], maskPrototypes: MLMultiArray?, detectionTensor: MLMultiArray?) {
        var detectionArray: MLMultiArray?
        var maskPrototypes: MLMultiArray?

        for result in results {
            guard let featureObs = result as? VNCoreMLFeatureValueObservation,
                  let multiArray = featureObs.featureValue.multiArrayValue else { continue }

            let shape = multiArray.shape.map { $0.intValue }

            if shape.count == 3 && shape[1] <= 500 && shape[2] >= 6 {
                // Detection tensor: [1, N, 6+] — post-NMS detections
                detectionArray = multiArray
            } else if shape.count == 4 && shape[1] == 32 && shape[2] > 50 {
                // Segmentation mask prototypes: [1, 32, H, W]
                maskPrototypes = multiArray
            }
        }

        guard let detArray = detectionArray else { return ([], nil, nil) }

        let shape = detArray.shape.map { $0.intValue }
        let numDetections = shape[1]
        let fieldsPerDetection = shape[2]

        let pointer = detArray.dataPointer.bindMemory(to: Float32.self, capacity: detArray.count)

        var detections: [NavigationDetection] = []
        let inputSize: CGFloat = 640.0

        for i in 0..<numDetections {
            let base = i * fieldsPerDetection
            let x1 = CGFloat(pointer[base + 0])
            let y1 = CGFloat(pointer[base + 1])
            let x2 = CGFloat(pointer[base + 2])
            let y2 = CGFloat(pointer[base + 3])
            let confidence = pointer[base + 4]
            let classId = Int(pointer[base + 5])

            // Skip low-confidence detections (includes zero-padded NMS slots)
            guard confidence >= confidenceThreshold else { continue }
            guard x2 > x1, y2 > y1 else { continue }  // Valid box
            guard classId >= 0 else { continue }

            // Convert from pixel coordinates (0-640, top-left origin) to
            // Vision normalized coordinates (0-1, bottom-left origin, y-up)
            let normX = x1 / inputSize
            let normY = 1.0 - (y2 / inputSize)  // Flip y: YOLO y2 (bottom) → Vision origin
            let normW = (x2 - x1) / inputSize
            let normH = (y2 - y1) / inputSize

            let box = CGRect(x: normX, y: normY, width: normW, height: normH)

            // Map class ID to name
            let name: String
            if classId < classNames.count {
                name = classNames[classId]
            } else {
                name = "object_\(classId)"
            }

            let isObstacle = NavigationDetection.obstacleClasses.contains(name)
            let isGuidance = NavigationDetection.guidanceClasses.contains(name)
            let dist = getDepth(at: box)

            let detection = NavigationDetection(
                label: name,
                confidence: confidence,
                boundingBox: box,
                isObstacle: isObstacle,
                isGuidance: isGuidance,
                distance: dist,
                segmentationMask: nil
            )

            detections.append(detection)
        }

        return (detections, maskPrototypes, detectionArray)
    }

    // MARK: - Render Instance Segmentation from Prototypes + Coefficients
    /// Computes per-instance masks: mask_i = sigmoid(sum(coeff_k * prototype_k)), cropped to bbox
    private func renderInstanceSegmentation(detectionTensor: MLMultiArray, prototypes: MLMultiArray, inputSize: CGFloat) -> UIImage? {
        let detShape = detectionTensor.shape.map { $0.intValue }
        let protoShape = prototypes.shape.map { $0.intValue }

        guard detShape.count == 3, detShape[2] > 6 else { return nil } // Need mask coefficients
        guard protoShape.count == 4, protoShape[1] == 32 else { return nil }

        let numDets = detShape[1]
        let fieldsPerDet = detShape[2]
        let numProtos = protoShape[1]
        let maskH = protoShape[2]
        let maskW = protoShape[3]

        guard maskW > 0, maskH > 0 else { return nil }

        let detPtr = detectionTensor.dataPointer.bindMemory(to: Float32.self, capacity: detectionTensor.count)
        let protoPtr = prototypes.dataPointer.bindMemory(to: Float32.self, capacity: prototypes.count)

        var pixels = [UInt8](repeating: 0, count: maskW * maskH * 4)

        for i in 0..<numDets {
            let base = i * fieldsPerDet
            let conf = detPtr[base + 4]
            guard conf >= confidenceThreshold else { continue }
            let classId = Int(detPtr[base + 5])

            // Bounding box in mask space
            let bx1 = max(0, Int(CGFloat(detPtr[base + 0]) / inputSize * CGFloat(maskW)))
            let by1 = max(0, Int(CGFloat(detPtr[base + 1]) / inputSize * CGFloat(maskH)))
            let bx2 = min(maskW, Int(CGFloat(detPtr[base + 2]) / inputSize * CGFloat(maskW)))
            let by2 = min(maskH, Int(CGFloat(detPtr[base + 3]) / inputSize * CGFloat(maskH)))

            guard bx2 > bx1, by2 > by1 else { continue }

            // Extract 32 mask coefficients
            let coeffs = (0..<min(numProtos, fieldsPerDet - 6)).map { detPtr[base + 6 + $0] }

            // Compute mask within bounding box: sigmoid(sum(coeff_k * prototype_k[y][x]))
            for y in by1..<by2 {
                for x in bx1..<bx2 {
                    var sum: Float = 0
                    for k in 0..<coeffs.count {
                        let protoIdx = k * maskH * maskW + y * maskW + x
                        guard protoIdx < prototypes.count else { continue }
                        sum += coeffs[k] * protoPtr[protoIdx]
                    }
                    let maskVal = 1.0 / (1.0 + exp(-sum))
                    if maskVal > 0.5 {
                        let pixIdx = (y * maskW + x) * 4
                        guard pixIdx + 3 < pixels.count else { continue }
                        colorForSegmentationClass(classId < 80 ? (classId % 20) + 1 : classId - 76, pixels: &pixels, at: pixIdx)
                    }
                }
            }
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixels,
            width: maskW,
            height: maskH,
            bitsPerComponent: 8,
            bytesPerRow: maskW * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        guard let cgImage = context.makeImage() else { return nil }
        return UIImage(cgImage: cgImage)
    }

    // MARK: - Render Segmentation Mask from MLMultiArray
    private func renderSegmentationMask(_ multiArray: MLMultiArray) -> UIImage? {
        // Segmentation masks are typically [1, numClasses, H, W] or [H, W]
        let shape = multiArray.shape.map { $0.intValue }
        guard shape.count >= 2 else { return nil }
        // Safety: skip rendering if the array is too small (likely not a segmentation mask)
        guard multiArray.count > 100 else { return nil }

        let height: Int
        let width: Int
        let numClasses: Int

        if shape.count == 4 {
            // [batch, classes, H, W]
            numClasses = shape[1]
            height = shape[2]
            width = shape[3]
        } else if shape.count == 3 {
            // [classes, H, W]
            numClasses = shape[0]
            height = shape[1]
            width = shape[2]
        } else {
            // [H, W] — single class mask
            height = shape[0]
            width = shape[1]
            numClasses = 1
        }

        guard width > 0, height > 0 else { return nil }

        // Create RGBA pixel buffer
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let pointer = multiArray.dataPointer.bindMemory(to: Float32.self, capacity: multiArray.count)

        for y in 0..<height {
            for x in 0..<width {
                let pixelIndex = (y * width + x) * 4

                if numClasses == 1 {
                    // Single channel — treat as binary mask
                    let value = pointer[y * width + x]
                    if value > 0.5 {
                        pixels[pixelIndex] = 255     // R — yellow for tactile paving
                        pixels[pixelIndex + 1] = 220 // G
                        pixels[pixelIndex + 2] = 0   // B
                        pixels[pixelIndex + 3] = 120  // A
                    }
                } else {
                    // Multi-class: find argmax class for this pixel
                    var maxClass = 0
                    var maxValue: Float = -Float.infinity
                    for c in 0..<numClasses {
                        let offset: Int
                        if shape.count == 4 {
                            offset = c * height * width + y * width + x
                        } else {
                            offset = c * height * width + y * width + x
                        }
                        guard offset < multiArray.count else { continue }
                        let val = pointer[offset]
                        if val > maxValue {
                            maxValue = val
                            maxClass = c
                        }
                    }

                    // Color by class — customize based on your model's class mapping
                    // Class 0 is typically background
                    if maxClass > 0 && maxValue > 0.3 {
                        colorForSegmentationClass(maxClass, pixels: &pixels, at: pixelIndex)
                    }
                }
            }
        }

        // Create UIImage from pixel data
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        guard let cgImage = context.makeImage() else { return nil }
        return UIImage(cgImage: cgImage)
    }

    /// Map segmentation class index to RGBA color.
    /// Adjust class indices to match your yolo26s-seg model's output classes.
    private func colorForSegmentationClass(_ classIndex: Int, pixels: inout [UInt8], at offset: Int) {
        // Default coloring — customize these based on actual model class mapping
        // Tactile paving classes → bright yellow
        // Stairs classes → orange
        // Road/sidewalk → subtle blue
        // Person/obstacles → red tint

        switch classIndex {
        case 1...3:
            // Typical: road, sidewalk, building — subtle or transparent
            break
        case 4, 5:
            // Could be tactile_paving or similar — bright yellow highlight
            pixels[offset] = 255
            pixels[offset + 1] = 230
            pixels[offset + 2] = 0
            pixels[offset + 3] = 100
        case 6, 7:
            // Stairs/steps — orange highlight
            pixels[offset] = 255
            pixels[offset + 1] = 140
            pixels[offset + 2] = 0
            pixels[offset + 3] = 100
        default:
            // Other detectable classes — light overlay
            pixels[offset] = 100
            pixels[offset + 1] = 180
            pixels[offset + 2] = 255
            pixels[offset + 3] = 50
        }
    }

    // MARK: - Tactile Paving Position Analysis
    private func analyzeTactilePavingPosition(_ box: CGRect) {
        // Vision bounding box: origin bottom-left, x right, y up, normalized 0-1
        let centerX = box.midX

        let direction: TactilePavingDirection
        if centerX < 0.35 {
            direction = .left
        } else if centerX > 0.65 {
            direction = .right
        } else {
            direction = .center
        }

        let now = Date()
        let shouldAlert = now.timeIntervalSince(lastTactileAlertTime) > 4.0

        DispatchQueue.main.async {
            self.tactilePavingDetected = true
            self.tactilePavingDirection = direction

            if shouldAlert {
                self.lastTactileAlertTime = now
                let alert = NavigationAlert(
                    message: direction.rawValue,
                    alertType: .tactile,
                    priority: 2
                )
                self.currentAlert = alert
                if self.speechEnabled {
                    if direction == .center {
                        self.speak("Follow the tactile paving ahead", priority: 2)
                    } else {
                        self.speak(direction.rawValue, priority: 2)
                    }
                }
            }
        }
    }

    // MARK: - Stairs Analysis with LiDAR (YOLO-confirmed only)
    /// Called only when YOLO detects stairs. Uses LiDAR for step count and up/down direction.
    private func analyzeStairsWithLiDAR(boundingBox: CGRect) {
        let count = stairCountProvider?(boundingBox, currentDepthData) ?? 0
        let direction = stairDirectionProvider?(boundingBox, currentDepthData) ?? .unknown
        let dist = getDepth(at: boundingBox)
        let now = Date()
        let shouldAlert = now.timeIntervalSince(lastStairAlertTime) > 5.0

        DispatchQueue.main.async {
            self.stairsDetected = true
            self.stairCount = count
            self.stairDirection = direction

            if shouldAlert {
                self.lastStairAlertTime = now
                var message: String
                if count > 0 {
                    let dirStr = direction != .unknown ? " \(direction.rawValue)" : ""
                    message = "\(count) steps\(dirStr) ahead"
                } else {
                    let dirStr = direction != .unknown ? " \(direction.rawValue)" : ""
                    message = "Stairs\(dirStr) detected ahead"
                }
                if let d = dist {
                    message += String(format: " at %.1f meters", d)
                }

                let alert = NavigationAlert(message: message, alertType: .stairs, priority: 3)
                self.currentAlert = alert
                if self.speechEnabled {
                    self.speak(message, priority: 3)
                }
            }
        }
    }

    // MARK: - FOV Check
    private func isWithinFOV(_ box: CGRect) -> Bool {
        let centerX = box.midX
        let centerY = box.midY
        return centerX >= currentFOVBox.minX &&
               centerX <= currentFOVBox.maxX &&
               centerY >= currentFOVBox.minY &&
               centerY <= currentFOVBox.maxY
    }

    // MARK: - Depth Extraction
    private func getDepth(at box: CGRect) -> Float? {
        guard let depth = currentDepthData else { return nil }
        let map = depth.depthMap
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }

        let w = CVPixelBufferGetWidth(map)
        let h = CVPixelBufferGetHeight(map)
        let bpr = CVPixelBufferGetBytesPerRow(map)
        guard let base = CVPixelBufferGetBaseAddress(map) else { return nil }

        let x = Int(box.midX * CGFloat(w))
        let y = Int((1 - box.midY) * CGFloat(h))
        guard x >= 0, x < w, y >= 0, y < h else { return nil }

        let d = base.advanced(by: y * bpr).assumingMemoryBound(to: Float32.self)[x]
        return d.isFinite && d > 0.1 && d < 5.0 ? d : nil
    }

    // MARK: - Alert System
    private func checkAlert(_ detections: [NavigationDetection]) {
        let now = Date()
        guard now.timeIntervalSince(lastAlertTime) > 2.0 else { return }

        let obs = detections.filter { $0.isObstacle && $0.distance != nil }
        guard let nearest = obs.first, let dist = nearest.distance else { return }

        var alert: NavigationAlert?
        if dist < 0.5 {
            alert = NavigationAlert(message: "\(nearest.label) extremely close!", alertType: .danger, priority: 4)
        } else if dist < 1.0 {
            alert = NavigationAlert(message: "\(nearest.label) very close!", alertType: .danger, priority: 3)
        } else if dist < 2.0 {
            alert = NavigationAlert(message: "\(nearest.label) \(String(format: "%.1f", dist))m", alertType: .warning, priority: 2)
        } else if dist < 3.0 {
            alert = NavigationAlert(message: "\(nearest.label) nearby", alertType: .info, priority: 1)
        }

        if let a = alert {
            lastAlertTime = now
            DispatchQueue.main.async {
                self.currentAlert = a
                if self.speechEnabled { self.speak(a.message, priority: a.priority) }
            }
        }
    }

    // MARK: - FOV-Based Obstacle Avoidance (LiDAR Priority)
    /// Processes continuous LiDAR zone data for directional obstacle warnings and "path clear" guidance.
    /// Runs independently of YOLO — ensures LiDAR always triggers obstacle warnings.
    func handleFOVObstacleAvoidance(
        obstacleInFOV: Bool,
        obstacleDirection: String,
        pathClear: Bool,
        nearestDistance: Float,
        leftZoneDistance: Float,
        centerZoneDistance: Float,
        rightZoneDistance: Float,
        routeBearing: Double?,
        userHeading: Double?
    ) {
        let now = Date()

        // Don't overlap with stair alerts
        if stairsDetected { return }

        if obstacleInFOV && nearestDistance < 3.0 {
            guard now.timeIntervalSince(lastFOVObstacleAlertTime) > fovAlertCooldown else { return }

            let suggestedDir = suggestAvoidanceDirection(
                obstacleDir: obstacleDirection,
                leftDist: leftZoneDistance,
                centerDist: centerZoneDistance,
                rightDist: rightZoneDistance,
                routeBearing: routeBearing,
                userHeading: userHeading
            )

            let message: String
            if nearestDistance < 2.0 {
                message = "Obstacle very close, move \(suggestedDir)"
            } else {
                message = "Obstacle ahead, move \(suggestedDir)"
            }

            guard message != lastFOVAlertMessage || now.timeIntervalSince(lastFOVObstacleAlertTime) > fovAlertCooldown else { return }

            lastFOVObstacleAlertTime = now
            lastFOVAlertMessage = message

            DispatchQueue.main.async {
                let alert = NavigationAlert(message: message, alertType: .warning, priority: 3)
                self.currentAlert = alert
                if self.speechEnabled {
                    self.speak(message, priority: 3)
                }
            }
        } else if pathClear && nearestDistance >= 3.0 {
            guard now.timeIntervalSince(lastPathClearTime) > pathClearCooldown else { return }
            guard now.timeIntervalSince(lastFOVObstacleAlertTime) > 2.0 else { return }

            lastPathClearTime = now
            lastFOVAlertMessage = ""

            DispatchQueue.main.async {
                if self.speechEnabled {
                    self.speak("Path clear, move forward", priority: 1)
                }
            }
        }
    }

    /// Determines which direction the user should move to avoid an obstacle,
    /// considering both zone clearance and route bearing for smart alignment.
    private func suggestAvoidanceDirection(
        obstacleDir: String,
        leftDist: Float,
        centerDist: Float,
        rightDist: Float,
        routeBearing: Double?,
        userHeading: Double?
    ) -> String {
        let moveDirection: String

        switch obstacleDir {
        case "left":
            moveDirection = "right"
        case "right":
            moveDirection = "left"
        case "center":
            // Obstacle dead center — suggest the side with more space
            if leftDist > rightDist {
                moveDirection = "left"
            } else {
                moveDirection = "right"
            }
        default:
            moveDirection = "forward"
        }

        // Smart navigation alignment: prefer the direction that keeps user on route
        if let routeB = routeBearing, let userH = userHeading, obstacleDir == "center" {
            let routeRelative = normalizeAngle(routeB - userH)
            let leftViable = leftDist > 2.0
            let rightViable = rightDist > 2.0

            if routeRelative < -10 && leftViable {
                return "left"
            } else if routeRelative > 10 && rightViable {
                return "right"
            }
        }

        return moveDirection
    }

    private func normalizeAngle(_ angle: Double) -> Double {
        var n = angle
        while n > 180 { n -= 360 }
        while n < -180 { n += 360 }
        return n
    }

    // MARK: - Speech
    func speak(_ text: String, priority: Int = 1) {
        guard speechEnabled else { return }
        if priority >= 2 && speechSynthesizer.isSpeaking {
            speechSynthesizer.stopSpeaking(at: .immediate)
        }
        guard !speechSynthesizer.isSpeaking else { return }
        let u = AVSpeechUtterance(string: text)
        u.rate = 0.5
        u.volume = 1.0
        speechSynthesizer.speak(u)
    }

    func stopSpeaking() { speechSynthesizer.stopSpeaking(at: .immediate) }
    func startNavigation() { detections = []; detectionsInFOV = []; currentAlert = nil }
    func endNavigation() { detections = []; detectionsInFOV = []; currentAlert = nil; stopSpeaking() }
}
