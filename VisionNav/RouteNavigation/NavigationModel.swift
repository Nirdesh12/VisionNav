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
        case info, warning, danger, step, tactile, stairs

        public var color: UIColor {
            switch self {
            case .info: return .systemBlue
            case .warning: return .systemOrange
            case .danger: return .systemRed
            case .step: return .systemYellow
            case .tactile: return .systemYellow
            case .stairs: return .systemOrange
            }
        }

        public var icon: String {
            switch self {
            case .info: return "info.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .danger: return "exclamationmark.octagon.fill"
            case .step: return "stairs"
            case .tactile: return "road.lanes"
            case .stairs: return "stairs"
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

    private var visionModel: VNCoreMLModel?
    private let confidenceThreshold: Float = 0.4
    private let processingQueue = DispatchQueue(label: "detection", qos: .userInitiated)
    private var isProcessing: Bool = false
    private var lastAlertTime: Date = .distantPast
    private var lastStepAlertTime: Date = .distantPast
    private var lastTactileAlertTime: Date = .distantPast
    private var lastStairAlertTime: Date = .distantPast

    private let speechSynthesizer = AVSpeechSynthesizer()
    private var currentDepthData: ARDepthData?
    private var currentFOVBox: CGRect = CGRect(x: 0.25, y: 0.2, width: 0.5, height: 0.6)

    // Throttle segmentation mask rendering — no need to render every frame
    private var lastSegmentationRenderTime: Date = .distantPast
    private let segmentationRenderInterval: TimeInterval = 0.3  // Max ~3 mask renders per second

    // Stair counting callback — set by the view to call NavigationCameraManager
    var stairCountProvider: ((CGRect, ARDepthData?) -> Int)?
    var onDistanceUpdate: ((Float) -> Void)?

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
            let names = ["yolov26s-seg", "yolov26s", "yolo11s-seg", "yolo11s", "yolov8s-seg", "yolov8s", "YOLOv3", "YOLOv3Tiny"]
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
    func processFrame(pixelBuffer: CVPixelBuffer, depthData: ARDepthData?, stepInfo: (detected: Bool, type: StepType, distance: Float), fovBox: CGRect) {
        currentFOVBox = fovBox

        if stepInfo.detected && stepInfo.type != .none {
            handleStepAlert(type: stepInfo.type, distance: stepInfo.distance)
        }

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

        // Process recognized object observations (bounding boxes + optional masks)
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

                // Track tactile paving
                if name.contains("tactile") || name.contains("paving") {
                    foundTactilePaving = true
                    tactileBox = obs.boundingBox
                }

                // Track stairs
                if name.contains("stair") || name.contains("steps") {
                    foundStairs = true
                    stairsBBox = obs.boundingBox
                }

                // Check if detection is within FOV box
                if isWithinFOV(obs.boundingBox) {
                    fovResults.append(detection)
                    if let d = dist, d < minDist { minDist = d }
                }
            }
        }

        // Also handle raw feature observations for segmentation masks (throttled)
        let now = Date()
        if now.timeIntervalSince(lastSegmentationRenderTime) >= segmentationRenderInterval {
            for result in results {
                if let featureObs = result as? VNCoreMLFeatureValueObservation {
                    if let multiArray = featureObs.featureValue.multiArrayValue {
                        lastSegmentationRenderTime = now
                        let overlayImage = renderSegmentationMask(multiArray)
                        DispatchQueue.main.async {
                            self.segmentationOverlayImage = overlayImage
                        }
                        break  // Only render one mask per cycle
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

    // MARK: - Stairs Analysis with LiDAR
    private func analyzeStairsWithLiDAR(boundingBox: CGRect) {
        let count = stairCountProvider?(boundingBox, currentDepthData) ?? 0
        let dist = getDepth(at: boundingBox)
        let now = Date()
        let shouldAlert = now.timeIntervalSince(lastStairAlertTime) > 5.0

        DispatchQueue.main.async {
            self.stairsDetected = true
            self.stairCount = count

            if shouldAlert {
                self.lastStairAlertTime = now
                var message: String
                if count > 0 {
                    message = "Stairs ahead, approximately \(count) steps"
                } else {
                    message = "Stairs detected ahead"
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

    private func handleStepAlert(type: StepType, distance: Float) {
        let now = Date()
        guard now.timeIntervalSince(lastStepAlertTime) > 3.0 else { return }
        lastStepAlertTime = now

        let alert = NavigationAlert(message: type.rawValue, alertType: .step, priority: 2)
        DispatchQueue.main.async {
            self.currentAlert = alert
            if self.speechEnabled { self.speak(type.rawValue, priority: 2) }
        }
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
