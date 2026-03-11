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
        // Seg model custom classes
        "blind path", "stair", "stairs",
        "horizontal-directional-tactile", "vertical-directional-tactile", "warning-tactile",
        // Legacy/detection model names
        "tactile_paving", "crosswalk", "zebra_crossing", "tactile paving", "staircase", "steps"
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
    @Published var speechEnabled: Bool = true  // Voice feedback ON by default — critical for blind users
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
    private var lastAnnouncedDistanceBand: Int = 0  // 0=none, 1=3m, 2=2m, 3=1m, 4=stop
    private var consecutiveBandFrames: Int = 0       // frames in current band before announcing
    private let bandStabilityRequired: Int = 3       // require 3 frames before band change triggers speech

    // ── Global speech gate ──────────────────────────────────
    private var lastSpokeTime: Date = .distantPast
    private let globalSpeechGap: TimeInterval = 1.8  // minimum gap between non-emergency speech

    // ── Per-category cooldowns ──────────────────────────────
    private let emergencyCooldown: TimeInterval = 1.5
    private let dangerCooldown: TimeInterval = 2.5
    private let warningCooldown: TimeInterval = 4.0
    private let fovAlertCooldown: TimeInterval = 4.0
    private let pathClearCooldown: TimeInterval = 15.0
    private let stairCooldown: TimeInterval = 4.0
    private let dropOffCooldown: TimeInterval = 3.0
    private var lastEmergencyAlertTime: Date = .distantPast
    private var lastDropOffAlertTime: Date = .distantPast

    // Device pitch — used to suppress ground-plane false obstacle alerts
    var devicePitch: Float = 0  // radians, set from ARFrame.camera.eulerAngles.x

    // Zone distances — updated each frame from processFrame for directional alerts
    private var currentLeftZoneDist: Float = 999
    private var currentCenterZoneDist: Float = 999
    private var currentRightZoneDist: Float = 999
    private var currentObstacleDirection: String = "none"

    // Tactile temporal filtering
    private let tactileConfidenceThreshold: Float = 0.55
    private var consecutiveTactileFrames: Int = 0
    private let tactileFramesRequired: Int = 3
    private let minTactileBBoxArea: CGFloat = 0.005  // 0.5% of frame

    private let speechSynthesizer = AVSpeechSynthesizer()
    private var currentDepthData: ARDepthData?
    private var currentFOVBox: CGRect = CGRect(x: 0.25, y: 0.2, width: 0.5, height: 0.6)

    // Throttle segmentation mask rendering — no need to render every frame
    private var lastSegmentationRenderTime: Date = .distantPast
    private let segmentationRenderInterval: TimeInterval = 0.5

    // Stair counting & direction callbacks — set by the view to call NavigationCameraManager
    var stairCountProvider: ((CGRect, ARDepthData?) -> Int)?
    var stairDirectionProvider: ((CGRect, ARDepthData?) -> StairDirection)?
    var onDistanceUpdate: ((Float) -> Void)?

    // Model-specific class name mappings (discovered from model metadata)
    // The seg model (yolov26s-seg) was custom-trained with 6 navigation classes
    private let segModelClasses: [String] = [
        "blind path",                        // 0 — walkable path guidance
        "horizontal-directional-tactile",    // 1 — tactile paving (follow direction)
        "stair",                             // 2 — single stair / staircase
        "stairs",                            // 3 — stairs / staircase
        "vertical-directional-tactile",      // 4 — tactile paving (crossing indicator)
        "warning-tactile"                    // 5 — tactile warning (edge/stop)
    ]

    // Standard COCO 80 for the detection model (yolov26s)
    private let cocoClasses: [String] = [
        "person", "bicycle", "car", "motorcycle", "airplane", "bus", "train", "truck", "boat",
        "traffic light", "fire hydrant", "stop sign", "parking meter", "bench", "bird", "cat",
        "dog", "horse", "sheep", "cow", "elephant", "bear", "zebra", "giraffe", "backpack",
        "umbrella", "handbag", "tie", "suitcase", "frisbee", "skis", "snowboard", "sports ball",
        "kite", "baseball bat", "baseball glove", "skateboard", "surfboard", "tennis racket",
        "bottle", "wine glass", "cup", "fork", "knife", "spoon", "bowl", "banana", "apple",
        "sandwich", "orange", "broccoli", "carrot", "hot dog", "pizza", "donut", "cake",
        "chair", "couch", "potted plant", "bed", "dining table", "toilet", "tv", "laptop",
        "mouse", "remote", "keyboard", "cell phone", "microwave", "oven", "toaster", "sink",
        "refrigerator", "book", "clock", "vase", "scissors", "teddy bear", "hair drier", "toothbrush"
    ]

    /// Returns the correct class names based on which model is loaded
    private var activeClassNames: [String] {
        modelName.lowercased().contains("seg") ? segModelClasses : cocoClasses
    }

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
            autoreleasepool {
                do {
                    let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right, options: [:])
                    try handler.perform([request])
                } catch {}
            }
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
                    // Higher confidence threshold for tactile to reduce false positives
                    let bboxArea = obs.boundingBox.width * obs.boundingBox.height
                    if label.confidence >= tactileConfidenceThreshold && bboxArea >= minTactileBBoxArea {
                        foundTactilePaving = true
                        tactileBox = obs.boundingBox
                    }
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

                if name.contains("tactile") || name.contains("paving") || name.contains("blind path") {
                    // Higher confidence + min bbox for tactile (reduce false positives)
                    let bboxArea = detection.boundingBox.width * detection.boundingBox.height
                    if detection.confidence >= tactileConfidenceThreshold && bboxArea >= minTactileBBoxArea {
                        foundTactilePaving = true
                        tactileBox = detection.boundingBox
                    }
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

        // Analyze tactile paving position (with temporal filtering — require N consecutive frames)
        if foundTactilePaving, let box = tactileBox {
            consecutiveTactileFrames += 1
            if consecutiveTactileFrames >= tactileFramesRequired {
                analyzeTactilePavingPosition(box)
            }
        } else {
            consecutiveTactileFrames = 0  // reset on miss
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
            // Only update @Published when values changed (reduces SwiftUI redraws)
            if self.detectionCount != allResults.count {
                self.detections = allResults
                self.detectionsInFOV = fovResults
                self.detectionCount = allResults.count
            } else if !allResults.isEmpty {
                self.detections = allResults
                self.detectionsInFOV = fovResults
            }
            if abs(self.nearestDistance - minDist) > 0.05 {
                self.nearestDistance = minDist
                self.onDistanceUpdate?(minDist)
            }
        }
    }

    // MARK: - Parse Raw YOLO Tensor Output (stride-safe)
    /// Parses raw MLMultiArray output from YOLO mlProgram models (post-NMS format).
    /// Uses MLMultiArray strides for correct memory access regardless of layout.
    /// Detection tensor: [1, N, 6] or [1, N, 38] = [x1, y1, x2, y2, conf, class_id, ...mask_coeffs]
    /// Mask prototypes (seg model only): [1, 32, H, W]
    private func parseRawYOLODetections(from results: [VNObservation]) -> (detections: [NavigationDetection], maskPrototypes: MLMultiArray?, detectionTensor: MLMultiArray?) {
        var detectionArray: MLMultiArray?
        var maskPrototypes: MLMultiArray?

        for result in results {
            guard let featureObs = result as? VNCoreMLFeatureValueObservation,
                  let multiArray = featureObs.featureValue.multiArrayValue else { continue }

            let shape = multiArray.shape.map { $0.intValue }

            if shape.count == 3 && shape[1] <= 500 && shape[2] >= 6 {
                detectionArray = multiArray
            } else if shape.count == 4 && shape[1] == 32 && shape[2] > 50 {
                maskPrototypes = multiArray
            }
        }

        guard let detArray = detectionArray else { return ([], nil, nil) }

        let shape = detArray.shape.map { $0.intValue }
        let numDetections = shape[1]
        let fieldsPerDetection = shape[2]

        // CRITICAL: Use MLMultiArray strides for correct memory access
        // MLMultiArray may be column-major or have non-contiguous strides
        let strides = detArray.strides.map { $0.intValue }
        let stride1 = strides[1]  // stride between detections
        let stride2 = strides[2]  // stride between fields within a detection
        let pointer = detArray.dataPointer.bindMemory(to: Float32.self, capacity: detArray.count)

        var detections: [NavigationDetection] = []
        let inputSize: CGFloat = 640.0
        let names = activeClassNames

        for i in 0..<numDetections {
            let detOffset = i * stride1
            let x1 = CGFloat(pointer[detOffset + 0 * stride2])
            let y1 = CGFloat(pointer[detOffset + 1 * stride2])
            let x2 = CGFloat(pointer[detOffset + 2 * stride2])
            let y2 = CGFloat(pointer[detOffset + 3 * stride2])
            let confidence = pointer[detOffset + 4 * stride2]
            let classId = Int(round(pointer[detOffset + 5 * stride2]))

            // Skip low-confidence detections (includes zero-padded NMS slots)
            guard confidence >= confidenceThreshold else { continue }
            guard x2 > x1, y2 > y1 else { continue }
            guard classId >= 0 else { continue }

            // Convert from pixel coordinates (0-640, top-left origin) to
            // Vision normalized coordinates (0-1, bottom-left origin, y-up)
            let normX = x1 / inputSize
            let normY = 1.0 - (y2 / inputSize)
            let normW = (x2 - x1) / inputSize
            let normH = (y2 - y1) / inputSize

            let box = CGRect(x: normX, y: normY, width: normW, height: normH)

            // Map class ID to model-specific name
            let name: String
            if classId < names.count {
                name = names[classId]
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

    // MARK: - Render Instance Segmentation from Prototypes + Coefficients (stride-safe)
    /// Computes per-instance masks: mask_i = sigmoid(sum(coeff_k * prototype_k)), cropped to bbox
    private func renderInstanceSegmentation(detectionTensor: MLMultiArray, prototypes: MLMultiArray, inputSize: CGFloat) -> UIImage? {
        let detShape = detectionTensor.shape.map { $0.intValue }
        let protoShape = prototypes.shape.map { $0.intValue }

        guard detShape.count == 3, detShape[2] > 6 else { return nil }
        guard protoShape.count == 4, protoShape[1] == 32 else { return nil }

        let numDets = detShape[1]
        let fieldsPerDet = detShape[2]
        let numProtos = protoShape[1]
        let maskH = protoShape[2]
        let maskW = protoShape[3]

        guard maskW > 0, maskH > 0 else { return nil }

        // Use strides for correct memory access
        let detStrides = detectionTensor.strides.map { $0.intValue }
        let detS1 = detStrides[1]; let detS2 = detStrides[2]
        let protoStrides = prototypes.strides.map { $0.intValue }
        let protoS1 = protoStrides[1]; let protoS2 = protoStrides[2]; let protoS3 = protoStrides[3]

        let detPtr = detectionTensor.dataPointer.bindMemory(to: Float32.self, capacity: detectionTensor.count)
        let protoPtr = prototypes.dataPointer.bindMemory(to: Float32.self, capacity: prototypes.count)

        var pixels = [UInt8](repeating: 0, count: maskW * maskH * 4)

        for i in 0..<numDets {
            let detOff = i * detS1
            let conf = detPtr[detOff + 4 * detS2]
            guard conf >= confidenceThreshold else { continue }
            let classId = Int(round(detPtr[detOff + 5 * detS2]))

            // Bounding box in mask space
            let bx1 = max(0, Int(CGFloat(detPtr[detOff + 0 * detS2]) / inputSize * CGFloat(maskW)))
            let by1 = max(0, Int(CGFloat(detPtr[detOff + 1 * detS2]) / inputSize * CGFloat(maskH)))
            let bx2 = min(maskW, Int(CGFloat(detPtr[detOff + 2 * detS2]) / inputSize * CGFloat(maskW)))
            let by2 = min(maskH, Int(CGFloat(detPtr[detOff + 3 * detS2]) / inputSize * CGFloat(maskH)))

            guard bx2 > bx1, by2 > by1 else { continue }

            // Extract 32 mask coefficients using strides
            let coeffs = (0..<min(numProtos, fieldsPerDet - 6)).map { detPtr[detOff + (6 + $0) * detS2] }

            // Compute mask: sigmoid(sum(coeff_k * prototype_k[y][x]))
            for y in by1..<by2 {
                for x in bx1..<bx2 {
                    var sum: Float = 0
                    for k in 0..<coeffs.count {
                        let protoIdx = k * protoS1 + y * protoS2 + x * protoS3
                        guard protoIdx < prototypes.count else { continue }
                        sum += coeffs[k] * protoPtr[protoIdx]
                    }
                    let maskVal = 1.0 / (1.0 + exp(-sum))
                    if maskVal > 0.5 {
                        let pixIdx = (y * maskW + x) * 4
                        guard pixIdx + 3 < pixels.count else { continue }
                        colorForNavClass(classId, pixels: &pixels, at: pixIdx)
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

    /// Color for the seg model's 6 navigation classes (used in instance segmentation rendering)
    private func colorForNavClass(_ classId: Int, pixels: inout [UInt8], at offset: Int) {
        switch classId {
        case 0: // blind path — subtle green
            pixels[offset] = 0; pixels[offset + 1] = 200; pixels[offset + 2] = 100; pixels[offset + 3] = 60
        case 1: // horizontal-directional-tactile — bright yellow
            pixels[offset] = 255; pixels[offset + 1] = 230; pixels[offset + 2] = 0; pixels[offset + 3] = 120
        case 2, 3: // stair / stairs — orange
            pixels[offset] = 255; pixels[offset + 1] = 140; pixels[offset + 2] = 0; pixels[offset + 3] = 120
        case 4: // vertical-directional-tactile — yellow
            pixels[offset] = 255; pixels[offset + 1] = 210; pixels[offset + 2] = 0; pixels[offset + 3] = 120
        case 5: // warning-tactile — red/orange warning
            pixels[offset] = 255; pixels[offset + 1] = 80; pixels[offset + 2] = 0; pixels[offset + 3] = 140
        default: // COCO or unknown — light blue
            pixels[offset] = 100; pixels[offset + 1] = 180; pixels[offset + 2] = 255; pixels[offset + 3] = 50
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
        let shouldAlert = now.timeIntervalSince(lastTactileAlertTime) > 8.0

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
                if direction == .center {
                    self.speak("Follow the tactile paving ahead", priority: 2)
                } else {
                    self.speak(direction.rawValue, priority: 2)
                }
            }
        }
    }

    // MARK: - Stairs Analysis with LiDAR (YOLO-confirmed)
    /// Called when YOLO detects stairs. Uses LiDAR for step count, direction, and proximity alerts.
    private func analyzeStairsWithLiDAR(boundingBox: CGRect) {
        let count = stairCountProvider?(boundingBox, currentDepthData) ?? 0
        let direction = stairDirectionProvider?(boundingBox, currentDepthData) ?? .unknown
        let dist = getDepth(at: boundingBox)
        let now = Date()
        let shouldAlert = now.timeIntervalSince(lastStairAlertTime) > stairCooldown

        DispatchQueue.main.async {
            self.stairsDetected = true
            self.stairCount = count
            self.stairDirection = direction

            if shouldAlert {
                self.lastStairAlertTime = now
                var message: String

                // Build descriptive stair message
                let dirStr = direction != .unknown ? " \(direction.rawValue)" : ""

                if let d = dist {
                    if d < 0.5 {
                        // At the stairs
                        message = "Stairs at your feet\(dirStr). Hold the railing"
                    } else if d < 1.5 {
                        // Very close
                        if count > 0 {
                            message = "\(count) steps\(dirStr), \(String(format: "%.0f", d * 100)) centimeters ahead"
                        } else {
                            message = "Stairs\(dirStr) very close, watch your step"
                        }
                    } else {
                        // Approaching
                        if count > 0 {
                            message = "Stairs ahead, \(count) steps\(dirStr), \(String(format: "%.1f", d)) meters"
                        } else {
                            message = "Stairs\(dirStr) detected, \(String(format: "%.1f", d)) meters ahead"
                        }
                    }
                } else {
                    if count > 0 {
                        message = "\(count) steps\(dirStr) ahead"
                    } else {
                        message = "Stairs\(dirStr) detected ahead"
                    }
                }

                let priority = (dist ?? 999) < 1.0 ? 4 : 3
                let alert = NavigationAlert(message: message, alertType: .stairs, priority: priority)
                self.currentAlert = alert
                self.speak(message, priority: priority)
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

    // MARK: - Alert System (YOLO-labeled object alerts with directional guidance)
    /// Fires for YOLO-detected obstacles with specific label names and uses zone data
    /// to tell the user which direction to move (e.g., "person on your left, move right").
    private func checkAlert(_ detections: [NavigationDetection]) {
        let now = Date()
        guard now.timeIntervalSince(lastAlertTime) > 3.0 else { return }

        let obs = detections.filter { $0.isObstacle && $0.distance != nil }
        guard let nearest = obs.first, let dist = nearest.distance else { return }

        // Determine which side the obstacle is on from its bounding box center
        // Vision coordinate: 0=left edge, 1=right edge (midX)
        let objSide: String
        let midX = nearest.boundingBox.midX
        if midX < 0.35 {
            objSide = "left"
        } else if midX > 0.65 {
            objSide = "right"
        } else {
            objSide = "center"
        }

        // Suggest avoidance direction based on zone clearance
        let moveDir: String
        if objSide == "left" {
            moveDir = "move right"
        } else if objSide == "right" {
            moveDir = "move left"
        } else {
            // Center — pick the side with more space
            moveDir = currentLeftZoneDist > currentRightZoneDist ? "move left" : "move right"
        }

        var alert: NavigationAlert?
        if dist < 0.5 {
            alert = NavigationAlert(message: "\(nearest.label) very close! \(moveDir) now", alertType: .danger, priority: 4)
        } else if dist < 1.0 {
            let sideStr = objSide == "center" ? "ahead" : "on your \(objSide)"
            alert = NavigationAlert(message: "\(nearest.label) \(sideStr), \(moveDir)", alertType: .danger, priority: 3)
        } else if dist < 2.0 {
            let sideStr = objSide == "center" ? "ahead" : "on your \(objSide)"
            alert = NavigationAlert(message: "\(nearest.label) \(sideStr), \(String(format: "%.1f", dist)) meters", alertType: .warning, priority: 2)
        } else if dist < 3.0 {
            alert = NavigationAlert(message: "\(nearest.label) ahead", alertType: .info, priority: 1)
        }

        if let a = alert {
            lastAlertTime = now

            // Read feedback mode setting
            let feedbackMode = FeedbackMode(
                rawValue: UserDefaults.standard.string(forKey: "feedbackMode") ?? ""
            ) ?? .hapticWithCriticalVoice

            DispatchQueue.main.async {
                self.currentAlert = a

                // Voice gating: in haptic modes, only speak for critical/dangerous objects
                switch feedbackMode {
                case .voiceOnly:
                    self.speak(a.message, priority: a.priority)
                case .hapticOnly:
                    break  // Haptics handle all feedback
                case .hapticWithCriticalVoice:
                    // Only speak for priority >= 3 (close/dangerous labeled objects)
                    if a.priority >= 3 {
                        self.speak(a.message, priority: a.priority)
                    }
                }
            }
        }
    }

    // MARK: - FOV-Based Obstacle Avoidance with Progressive Distance Alerts
    /// Processes continuous LiDAR zone data for directional obstacle warnings, emergency STOP,
    /// progressive distance callouts, and "path clear" guidance.
    /// Voice is gated by FeedbackMode: in haptic modes, only critical/emergency alerts speak.
    func handleFOVObstacleAvoidance(
        obstacleInFOV: Bool,
        obstacleDirection: String,
        pathClear: Bool,
        nearestDistance: Float,
        leftZoneDistance: Float,
        centerZoneDistance: Float,
        rightZoneDistance: Float,
        routeBearing: Double?,
        userHeading: Double?,
        phonePointingAtGround: Bool = false
    ) {
        let now = Date()

        // Store zone distances for directional alerts in checkAlert
        currentLeftZoneDist = leftZoneDistance
        currentCenterZoneDist = centerZoneDistance
        currentRightZoneDist = rightZoneDistance
        currentObstacleDirection = obstacleDirection

        // Read feedback mode setting
        let feedbackMode = FeedbackMode(
            rawValue: UserDefaults.standard.string(forKey: "feedbackMode") ?? ""
        ) ?? .hapticWithCriticalVoice

        // Don't overlap with stair alerts
        if stairsDetected { return }

        // Suppress obstacle alerts when phone is pointing at the ground (~55°+ downward)
        // The ground surface reads as a close "obstacle" — filter it out.
        if phonePointingAtGround && nearestDistance > 0.3 { return }

        // === EMERGENCY STOP: < 0.3m ===
        if nearestDistance < 0.3 && nearestDistance > 0.05 {
            guard now.timeIntervalSince(lastEmergencyAlertTime) > emergencyCooldown else { return }
            lastEmergencyAlertTime = now
            lastAnnouncedDistanceBand = 4

            DispatchQueue.main.async {
                let alert = NavigationAlert(message: "Stop!", alertType: .danger, priority: 5)
                self.currentAlert = alert
                // Emergency STOP always speaks (except hapticOnly)
                if feedbackMode != .hapticOnly {
                    self.speak("Stop!", priority: 5)
                }
            }
            return
        }

        // === Progressive distance callouts with directional guidance ===
        if obstacleInFOV && nearestDistance < 3.0 {
            let suggestedDir = suggestAvoidanceDirection(
                obstacleDir: obstacleDirection,
                leftDist: leftZoneDistance,
                centerDist: centerZoneDistance,
                rightDist: rightZoneDistance,
                routeBearing: routeBearing,
                userHeading: userHeading
            )

            // Determine distance band for progressive callouts — ALWAYS include direction
            let currentBand: Int
            let message: String
            let priority: Int
            let cooldown: TimeInterval

            if nearestDistance < 0.5 {
                currentBand = 4
                message = "Very close! Move \(suggestedDir) now"
                priority = 4
                cooldown = dangerCooldown
            } else if nearestDistance < 1.0 {
                currentBand = 3
                message = "Obstacle close, move \(suggestedDir)"
                priority = 3
                cooldown = dangerCooldown
            } else if nearestDistance < 2.0 {
                currentBand = 2
                switch obstacleDirection {
                case "left": message = "Something on your left, move \(suggestedDir)"
                case "right": message = "Something on your right, move \(suggestedDir)"
                default: message = "Obstacle ahead, move \(suggestedDir)"
                }
                priority = 2
                cooldown = warningCooldown
            } else {
                currentBand = 1
                switch obstacleDirection {
                case "left": message = "Something approaching from your left"
                case "right": message = "Something approaching from your right"
                default: message = "Obstacle ahead, move \(suggestedDir)"
                }
                priority = 1
                cooldown = fovAlertCooldown
            }

            // Band stability: require multiple consecutive frames in same band before announcing
            if currentBand != lastAnnouncedDistanceBand {
                consecutiveBandFrames += 1
                if consecutiveBandFrames < bandStabilityRequired && currentBand < 3 {
                    return
                }
            }

            let bandChanged = currentBand > lastAnnouncedDistanceBand && consecutiveBandFrames >= bandStabilityRequired
            let cooldownExpired = now.timeIntervalSince(lastFOVObstacleAlertTime) > cooldown

            guard bandChanged || cooldownExpired else { return }

            lastFOVObstacleAlertTime = now
            lastFOVAlertMessage = message
            lastAnnouncedDistanceBand = currentBand
            consecutiveBandFrames = 0

            // Check if path is completely blocked (all zones < 1.5m)
            let allZonesBlocked = leftZoneDistance < 1.5 && centerZoneDistance < 1.5 && rightZoneDistance < 1.5

            DispatchQueue.main.async {
                let alertType: NavigationAlert.AlertType = nearestDistance < 1.0 ? .danger : .warning
                let alert = NavigationAlert(message: message, alertType: alertType, priority: priority)
                self.currentAlert = alert

                // Voice gating based on feedback mode
                switch feedbackMode {
                case .voiceOnly:
                    self.speak(message, priority: priority)
                case .hapticOnly:
                    break  // Directional haptics handle all feedback
                case .hapticWithCriticalVoice:
                    // Speak only for critical/emergency situations or blocked path
                    if priority >= 4 || allZonesBlocked {
                        let voiceMessage = allZonesBlocked && priority < 4
                            ? "Path blocked. Turn around or wait."
                            : message
                        self.speak(voiceMessage, priority: max(priority, 4))
                    }
                }
            }
        } else if pathClear && nearestDistance >= 3.0 {
            guard now.timeIntervalSince(lastPathClearTime) > pathClearCooldown else { return }
            guard now.timeIntervalSince(lastFOVObstacleAlertTime) > 5.0 else { return }

            lastPathClearTime = now
            lastFOVAlertMessage = ""
            lastAnnouncedDistanceBand = 0
            consecutiveBandFrames = 0

            // "Path clear" only speaks in voice modes
            if feedbackMode == .voiceOnly {
                DispatchQueue.main.async {
                    self.speak("Path clear", priority: 1)
                }
            }
        }
    }

    // MARK: - LiDAR Stair Detection Handler (YOLO-independent)
    /// Processes LiDAR-only stair detection as a safety fallback when YOLO misses stairs.
    func handleLiDARStairDetection(
        lidarDetected: Bool, lidarCount: Int,
        lidarDirection: StairDirection, lidarDistance: Float
    ) {
        // If YOLO already detected stairs, let YOLO handle it (has bounding box for better accuracy)
        if stairsDetected { return }

        let now = Date()
        guard lidarDetected else {
            // Only clear LiDAR stair state if YOLO also doesn't see stairs
            return
        }

        guard now.timeIntervalSince(lastStairAlertTime) > stairCooldown else { return }
        lastStairAlertTime = now

        let dirStr = lidarDirection != .unknown ? " \(lidarDirection.rawValue)" : ""
        var message: String
        if lidarDistance < 0.5 {
            message = "Stairs at your feet\(dirStr). Hold the railing"
        } else if lidarCount > 0 {
            message = "Stairs ahead, \(lidarCount) steps\(dirStr), \(String(format: "%.1f", lidarDistance)) meters"
        } else {
            message = "Stairs\(dirStr) detected, \(String(format: "%.1f", lidarDistance)) meters ahead"
        }

        let priority = lidarDistance < 1.0 ? 4 : 3
        DispatchQueue.main.async {
            self.stairsDetected = true
            self.stairCount = lidarCount
            self.stairDirection = lidarDirection
            let alert = NavigationAlert(message: message, alertType: .stairs, priority: priority)
            self.currentAlert = alert
            self.speak(message, priority: priority)
        }
    }

    // MARK: - Drop-off Detection Handler
    /// Processes LiDAR drop-off detection for curbs, step-downs, and platform edges.
    func handleDropOffDetection(detected: Bool, dropDepth: Float) {
        guard detected, dropDepth > 0.3 else { return }

        let now = Date()
        guard now.timeIntervalSince(lastDropOffAlertTime) > dropOffCooldown else { return }
        lastDropOffAlertTime = now

        let cm = Int(dropDepth * 100)
        let message = cm > 50 ? "Warning! Large drop ahead" : "Caution, step down ahead, \(cm) centimeters"
        let priority = cm > 50 ? 5 : 4

        DispatchQueue.main.async {
            let alert = NavigationAlert(message: message, alertType: .danger, priority: priority)
            self.currentAlert = alert
            self.speak(message, priority: priority)
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

    // MARK: - Speech (priority-aware, connected to Settings, clarity-optimized)
    /// Priority levels: 1=info, 2=warning, 3=danger, 4=critical, 5=emergency (STOP)
    /// Speech rate is intentionally slow for blind users who rely on hearing every word.
    func speak(_ text: String, priority: Int = 1) {
        guard speechEnabled else { return }

        // Ensure audio session is configured for playback — voice recognition
        // changes category to .record which silences the speech synthesizer
        ensurePlaybackAudioSession()

        let now = Date()

        // Priority 1-2: respect global speech gap to prevent low-priority chatter
        if priority <= 2 {
            guard now.timeIntervalSince(lastSpokeTime) > globalSpeechGap else { return }
            guard !speechSynthesizer.isSpeaking else { return }
        }

        // Priority 3: can interrupt at word boundary
        if priority == 3 {
            if speechSynthesizer.isSpeaking {
                speechSynthesizer.stopSpeaking(at: .word)
            }
        }

        // Priority 4-5: always interrupt immediately (safety-critical)
        if priority >= 4 && speechSynthesizer.isSpeaking {
            speechSynthesizer.stopSpeaking(at: .immediate)
        }

        lastSpokeTime = now

        // Read volume and speech rate from Settings (persisted in UserDefaults)
        let settingsVolume = Float(UserDefaults.standard.double(forKey: "voiceVolume"))
        let settingsRate = Float(UserDefaults.standard.double(forKey: "speechRate"))
        let volume = settingsVolume > 0.01 ? settingsVolume : 1.0

        // Map settings rate (0-1 slider) to AVSpeechUtterance rate
        // Range: 0.28 (very slow) to 0.48 (moderate) — optimized for accessibility
        // Default (no settings): 0.38 (clear and steady)
        let baseRate: Float = settingsRate > 0.01 ? (0.28 + settingsRate * 0.20) : 0.38

        // Add brief pauses (commas) for multi-clause sentences to aid comprehension
        let spokenText = addSpeechPauses(text)

        let u = AVSpeechUtterance(string: spokenText)
        u.rate = priority >= 4 ? min(baseRate + 0.06, 0.50) : baseRate
        u.volume = volume
        u.pitchMultiplier = priority >= 4 ? 1.15 : 1.0
        u.preUtteranceDelay = 0.05  // Tiny pause before speaking for clarity
        u.postUtteranceDelay = 0.1  // Brief pause after for natural rhythm
        speechSynthesizer.speak(u)
    }

    /// Insert natural pauses into speech text for better comprehension.
    /// Adds commas before directional instructions and between compound clauses.
    private func addSpeechPauses(_ text: String) -> String {
        var result = text
        // Add pause before "move" directives for emphasis
        result = result.replacingOccurrences(of: " move ", with: ", move ")
        // Add pause before distance callouts
        result = result.replacingOccurrences(of: " at ", with: ", at ")
        // Avoid double commas
        result = result.replacingOccurrences(of: ",, ", with: ", ")
        result = result.replacingOccurrences(of: ", , ", with: ", ")
        return result
    }

    /// Ensure audio session is in playback mode. Voice recognition sets it to .record
    /// which silences AVSpeechSynthesizer. This restores playback when needed.
    private func ensurePlaybackAudioSession() {
        let session = AVAudioSession.sharedInstance()
        if session.category != .playback {
            try? session.setCategory(.playback, mode: .voicePrompt, options: [.mixWithOthers, .duckOthers])
            try? session.setActive(true)
        }
    }

    func stopSpeaking() { speechSynthesizer.stopSpeaking(at: .immediate) }
    func startNavigation() { detections = []; detectionsInFOV = []; currentAlert = nil }
    func endNavigation() { detections = []; detectionsInFOV = []; currentAlert = nil; stopSpeaking() }
}
