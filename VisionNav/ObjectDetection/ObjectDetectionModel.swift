//
//  ObjectDetectionModel.swift
//  VisionNav - Object Detection with ARKit Depth
//
//  Uses ARKit's smoothedSceneDepth + confidenceMap for accurate depth
//

import Foundation
import CoreML
import Vision
import SwiftUI
import Combine
import AVFoundation
import ARKit
import CoreHaptics

// MARK: - Detection Result

struct DetectedObject: Identifiable {
    let id = UUID()
    let label: String
    let confidence: Float
    let boundingBox: CGRect
    let timestamp: Date
    
    var confidencePercentage: Int { Int(confidence * 100) }
}

// MARK: - Depth Result

struct DepthResult {
    let distance: Float
    let isLiDAR: Bool
    let timestamp: Date
    
    var distanceString: String {
        if distance < 1.0 {
            return String(format: "%.0f cm", distance * 100)
        } else {
            return String(format: "%.2f m", distance)
        }
    }
}

// MARK: - ARKit Depth Processor

class ARKitDepthProcessor {
    
    // Smoothing buffer
    private var depthHistory: [Float] = []
    private let historySize = 5
    
    /// Extract accurate depth from ARKit's depth data with confidence filtering
    func processDepth(_ depthData: ARDepthData, focusBox: CGRect) -> Float? {
        
        let depthMap = depthData.depthMap
        
        // Lock buffer
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
        
        guard let baseAddress = CVPixelBufferGetBaseAddress(depthMap) else {
            return nil
        }
        
        // Get confidence map if available
        var confidenceBase: UnsafeMutableRawPointer?
        var confidenceBytesPerRow = 0
        
        if let confidenceMap = depthData.confidenceMap {
            CVPixelBufferLockBaseAddress(confidenceMap, .readOnly)
            confidenceBase = CVPixelBufferGetBaseAddress(confidenceMap)
            confidenceBytesPerRow = CVPixelBufferGetBytesPerRow(confidenceMap)
        }
        
        defer {
            if let confidenceMap = depthData.confidenceMap {
                CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly)
            }
        }
        
        // Convert focus box to depth map coordinates
        let minX = max(0, Int(focusBox.minX * CGFloat(width)))
        let maxX = min(width - 1, Int(focusBox.maxX * CGFloat(width)))
        let minY = max(0, Int(focusBox.minY * CGFloat(height)))
        let maxY = min(height - 1, Int(focusBox.maxY * CGFloat(height)))
        
        // Collect high-confidence depth values
        var validDepths: [Float] = []
        validDepths.reserveCapacity(300)
        
        let floatsPerRow = bytesPerRow / MemoryLayout<Float32>.size
        
        // Sample every 2nd pixel
        for y in stride(from: minY, through: maxY, by: 2) {
            for x in stride(from: minX, through: maxX, by: 2) {
                
                // Check confidence if available
                if let confBase = confidenceBase {
                    let confPtr = confBase.advanced(by: y * confidenceBytesPerRow).assumingMemoryBound(to: UInt8.self)
                    let confValue = Int(confPtr[x])
                    
                    // ARConfidenceLevel: 0=low, 1=medium, 2=high
                    // Only use medium or high confidence
                    if confValue < 1 {
                        continue
                    }
                }
                
                // Get depth value (Float32, in meters)
                let depthPtr = baseAddress.advanced(by: y * bytesPerRow).assumingMemoryBound(to: Float32.self)
                let depth = depthPtr[x]
                
                // Valid depth: finite, positive, within range
                if depth.isFinite && depth > 0.05 && depth < 5.0 {
                    validDepths.append(depth)
                }
            }
        }
        
        // Need enough valid samples
        guard validDepths.count >= 5 else {
            // Return last known value
            return depthHistory.last
        }
        
        // Sort and get median
        validDepths.sort()
        let median = validDepths[validDepths.count / 2]
        
        // Add to history for extra smoothing
        depthHistory.append(median)
        if depthHistory.count > historySize {
            depthHistory.removeFirst()
        }
        
        // Return median of history
        let sortedHistory = depthHistory.sorted()
        return sortedHistory[sortedHistory.count / 2]
    }
    
    func reset() {
        depthHistory.removeAll()
    }
}

// MARK: - Haptic Feedback Manager

class HapticFeedbackManager {
    private var engine: CHHapticEngine?
    private var lastTime: Date = .distantPast
    
    init() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        engine = try? CHHapticEngine()
        try? engine?.start()
        engine?.resetHandler = { [weak self] in try? self?.engine?.start() }
    }
    
    func trigger(distance: Float) {
        guard let engine = engine else { return }
        
        let interval: TimeInterval
        let intensity: Float
        
        switch distance {
        case ..<0.3:
            interval = 0.08; intensity = 1.0
        case 0.3..<0.5:
            interval = 0.12; intensity = 0.9
        case 0.5..<0.8:
            interval = 0.18; intensity = 0.75
        case 0.8..<1.2:
            interval = 0.28; intensity = 0.6
        case 1.2..<1.8:
            interval = 0.4; intensity = 0.45
        case 1.8..<2.5:
            interval = 0.55; intensity = 0.3
        default:
            interval = 0.75; intensity = 0.2
        }
        
        let now = Date()
        guard now.timeIntervalSince(lastTime) >= interval else { return }
        lastTime = now
        
        let event = CHHapticEvent(
            eventType: .hapticTransient,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: intensity)
            ],
            relativeTime: 0
        )
        
        if let pattern = try? CHHapticPattern(events: [event], parameters: []),
           let player = try? engine.makePlayer(with: pattern) {
            try? player.start(atTime: CHHapticTimeImmediate)
        }
    }
}

// MARK: - Speech Manager

class SpeechManager {
    private let synthesizer = AVSpeechSynthesizer()
    private var lastLabel = ""
    private var lastTime: Date = .distantPast
    
    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers, .duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
    }
    
    func speak(_ label: String, distance: Float?) {
        let now = Date()
        guard label != lastLabel || now.timeIntervalSince(lastTime) > 2.5 else { return }
        
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        
        var text = label
        if let d = distance {
            text += d < 1 ? ", \(Int(d * 100)) centimeters" : ", \(String(format: "%.1f", d)) meters"
        }
        
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = 0.52
        utterance.volume = 0.8
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        synthesizer.speak(utterance)
        
        lastLabel = label
        lastTime = now
    }
    
    func stop() {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
    }
}

// MARK: - Object Detection Model

class ObjectDetectionModel: ObservableObject {
    
    // MARK: - Published Properties
    @Published var detectedObject: DetectedObject?
    @Published var currentDepth: DepthResult?
    @Published var isModelLoaded = false
    @Published var errorMessage: String?
    @Published var inferenceTime: Double = 0
    @Published var fps: Double = 0
    @Published var speechEnabled = true
    @Published var hapticsEnabled = true
    
    // MARK: - Private Properties
    private var visionModel: VNCoreMLModel?
    private let confidenceThreshold: Float = 0.25
    
    private let depthProcessor = ARKitDepthProcessor()
    private let hapticManager = HapticFeedbackManager()
    private let speechManager = SpeechManager()
    
    private var frameCount = 0
    private var lastFPSTime = Date()
    
    private let processingQueue = DispatchQueue(label: "com.visionnav.detection", qos: .userInitiated)
    private var isProcessing = false
    
    // MARK: - Initialization
    
    init() {
        loadModel()
    }
    
    deinit {
        speechManager.stop()
    }
    
    // MARK: - Model Loading
    
    private func loadModel() {
        processingQueue.async { [weak self] in
            guard let self else { return }
            
            let url = Bundle.main.url(forResource: "yolov26s", withExtension: "mlmodelc")
                ?? Bundle.main.url(forResource: "yolov26s", withExtension: "mlpackage")
                ?? Bundle.main.url(forResource: "yolov26s", withExtension: "mlmodel")
            
            guard let url else {
                DispatchQueue.main.async { self.errorMessage = "Model not found" }
                return
            }
            
            do {
                let config = MLModelConfiguration()
                config.computeUnits = .all
                let model = try VNCoreMLModel(for: MLModel(contentsOf: url, configuration: config))
                DispatchQueue.main.async {
                    self.visionModel = model
                    self.isModelLoaded = true
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }
    
    // MARK: - Main Detection Function (Updated for ARKit)
    
    func detectInFocusBox(
        in pixelBuffer: CVPixelBuffer?,
        depthData: ARDepthData?,
        focusBox: CGRect,
        completion: @escaping (DetectedObject?, DepthResult?) -> Void
    ) {
        guard !isProcessing else {
            completion(nil, nil)
            return
        }
        isProcessing = true
        
        // Process depth using ARKit's confidence-filtered approach
        var depthResult: DepthResult?
        if let depth = depthData {
            if let distance = depthProcessor.processDepth(depth, focusBox: focusBox) {
                depthResult = DepthResult(distance: distance, isLiDAR: true, timestamp: Date())
                
                // Trigger haptic feedback
                if hapticsEnabled {
                    hapticManager.trigger(distance: distance)
                }
            }
        }
        
        // If no pixel buffer or model, just return depth
        guard let pixelBuffer = pixelBuffer, let model = visionModel else {
            isProcessing = false
            DispatchQueue.main.async { completion(nil, depthResult) }
            return
        }
        
        let startTime = Date()
        
        let request = VNCoreMLRequest(model: model) { [weak self] request, error in
            guard let self else { return }
            
            // Update FPS
            self.frameCount += 1
            let elapsed = Date().timeIntervalSince(self.lastFPSTime)
            if elapsed >= 1.0 {
                DispatchQueue.main.async {
                    self.fps = Double(self.frameCount) / elapsed
                    self.inferenceTime = Date().timeIntervalSince(startTime) * 1000
                }
                self.frameCount = 0
                self.lastFPSTime = Date()
            }
            
            // Process results
            var detectedObject: DetectedObject?
            
            if let observations = request.results as? [VNRecognizedObjectObservation] {
                detectedObject = self.findBestObject(in: observations, focusBox: focusBox)
            } else if let features = request.results as? [VNCoreMLFeatureValueObservation] {
                detectedObject = self.parseYOLOOutput(features, focusBox: focusBox)
            }
            
            // Speak detected object
            if let obj = detectedObject, self.speechEnabled {
                self.speechManager.speak(obj.label, distance: depthResult?.distance)
            }
            
            self.isProcessing = false
            DispatchQueue.main.async { completion(detectedObject, depthResult) }
        }
        
        request.imageCropAndScaleOption = .scaleFill
        
        processingQueue.async {
            do {
                // ARKit camera image is in landscape orientation
                // We need to specify the correct orientation for Vision
                let handler = VNImageRequestHandler(
                    cvPixelBuffer: pixelBuffer,
                    orientation: .right,  // ARKit camera is rotated 90° clockwise
                    options: [:]
                )
                try handler.perform([request])
            } catch {
                self.isProcessing = false
                DispatchQueue.main.async { completion(nil, depthResult) }
            }
        }
    }
    
    // MARK: - Object Detection
    
    private func findBestObject(
        in observations: [VNRecognizedObjectObservation],
        focusBox: CGRect
    ) -> DetectedObject? {
        
        let center = CGPoint(x: focusBox.midX, y: focusBox.midY)
        var best: (VNRecognizedObjectObservation, Float)?
        
        for obs in observations {
            guard let label = obs.labels.first, label.confidence >= confidenceThreshold else { continue }
            
            let inter = obs.boundingBox.intersection(focusBox)
            guard !inter.isNull else { continue }
            
            let overlap = Float((inter.width * inter.height) / (obs.boundingBox.width * obs.boundingBox.height))
            guard overlap > 0.15 else { continue }
            
            let dist = hypot(Float(obs.boundingBox.midX - center.x), Float(obs.boundingBox.midY - center.y))
            let score = overlap - dist * 0.5
            
            if best == nil || score > best!.1 {
                best = (obs, score)
            }
        }
        
        guard let (winner, _) = best, let label = winner.labels.first else { return nil }
        
        return DetectedObject(
            label: label.identifier,
            confidence: label.confidence,
            boundingBox: winner.boundingBox,
            timestamp: Date()
        )
    }
    
    private func parseYOLOOutput(
        _ features: [VNCoreMLFeatureValueObservation],
        focusBox: CGRect
    ) -> DetectedObject? {
        
        guard let arr = features.first?.featureValue.multiArrayValue else { return nil }
        let shape = arr.shape.map { $0.intValue }
        guard shape.count == 3, shape[0] == 1, shape[2] == 6 else { return nil }
        
        let center = CGPoint(x: focusBox.midX, y: focusBox.midY)
        var best: (CGRect, String, Float, Float)?
        
        for i in 0..<shape[1] {
            let x1 = arr[[0, i, 0] as [NSNumber]].floatValue / 640
            let y1 = arr[[0, i, 1] as [NSNumber]].floatValue / 640
            let x2 = arr[[0, i, 2] as [NSNumber]].floatValue / 640
            let y2 = arr[[0, i, 3] as [NSNumber]].floatValue / 640
            let conf = arr[[0, i, 4] as [NSNumber]].floatValue
            let cls = Int(arr[[0, i, 5] as [NSNumber]].floatValue)
            
            guard conf >= confidenceThreshold else { continue }
            
            let box = CGRect(
                x: CGFloat(min(x1, x2)),
                y: CGFloat(1 - max(y1, y2)),
                width: CGFloat(abs(x2 - x1)),
                height: CGFloat(abs(y2 - y1))
            )
            
            let inter = box.intersection(focusBox)
            guard !inter.isNull else { continue }
            
            let overlap = Float((inter.width * inter.height) / (box.width * box.height))
            guard overlap > 0.15 else { continue }
            
            let dist = hypot(Float(box.midX - center.x), Float(box.midY - center.y))
            let score = overlap - dist * 0.5
            let name = cocoClassNames[cls] ?? "object"
            
            if best == nil || score > best!.3 {
                best = (box, name, conf, score)
            }
        }
        
        guard let (box, name, conf, _) = best else { return nil }
        
        return DetectedObject(
            label: name,
            confidence: conf,
            boundingBox: box,
            timestamp: Date()
        )
    }
    
    // MARK: - Public Controls
    
    func toggleSpeech() {
        speechEnabled.toggle()
        if !speechEnabled { speechManager.stop() }
    }
    
    func toggleHaptics() {
        hapticsEnabled.toggle()
    }
    
    func resetDepth() {
        depthProcessor.reset()
    }
    
    // MARK: - COCO Classes
    
    private let cocoClassNames: [Int: String] = [
        0: "person", 1: "bicycle", 2: "car", 3: "motorcycle", 4: "airplane",
        5: "bus", 6: "train", 7: "truck", 8: "boat", 9: "traffic light",
        10: "fire hydrant", 11: "stop sign", 12: "parking meter", 13: "bench",
        14: "bird", 15: "cat", 16: "dog", 17: "horse", 18: "sheep", 19: "cow",
        20: "elephant", 21: "bear", 22: "zebra", 23: "giraffe", 24: "backpack",
        25: "umbrella", 26: "handbag", 27: "tie", 28: "suitcase", 29: "frisbee",
        30: "skis", 31: "snowboard", 32: "sports ball", 33: "kite",
        34: "baseball bat", 35: "baseball glove", 36: "skateboard", 37: "surfboard",
        38: "tennis racket", 39: "bottle", 40: "wine glass", 41: "cup",
        42: "fork", 43: "knife", 44: "spoon", 45: "bowl", 46: "banana",
        47: "apple", 48: "sandwich", 49: "orange", 50: "broccoli", 51: "carrot",
        52: "hot dog", 53: "pizza", 54: "donut", 55: "cake", 56: "chair",
        57: "couch", 58: "potted plant", 59: "bed", 60: "dining table",
        61: "toilet", 62: "tv", 63: "laptop", 64: "mouse", 65: "remote",
        66: "keyboard", 67: "cell phone", 68: "microwave", 69: "oven",
        70: "toaster", 71: "sink", 72: "refrigerator", 73: "book", 74: "clock",
        75: "vase", 76: "scissors", 77: "teddy bear", 78: "hair drier",
        79: "toothbrush"
    ]
}
