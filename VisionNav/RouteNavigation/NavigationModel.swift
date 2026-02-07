//
//  NavigationModel.swift
//  VisionNav
//
//  Object detection with FOV box support

import Foundation
import Vision
import CoreML
import ARKit
import AVFoundation
import UIKit
import Combine

public struct NavigationDetection: Identifiable {
    public let id = UUID()
    public let label: String
    public let confidence: Float
    public let boundingBox: CGRect
    public let isObstacle: Bool
    public let distance: Float?
    
    public var confidencePercentage: Int { Int(confidence * 100) }
    
    static let obstacleClasses: Set<String> = [
        "person", "bicycle", "car", "motorcycle", "bus", "truck",
        "fire hydrant", "stop sign", "bench", "dog", "cat", "chair",
        "couch", "potted plant", "backpack", "suitcase", "bottle"
    ]
}

public struct NavigationAlert: Identifiable {
    public let id = UUID()
    public let message: String
    public let alertType: AlertType
    public let priority: Int
    
    public enum AlertType {
        case info, warning, danger, step
        
        public var color: UIColor {
            switch self {
            case .info: return .systemBlue
            case .warning: return .systemOrange
            case .danger: return .systemRed
            case .step: return .systemYellow
            }
        }
        
        public var icon: String {
            switch self {
            case .info: return "info.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .danger: return "exclamationmark.octagon.fill"
            case .step: return "stairs"
            }
        }
    }
}

class NavigationModel: NSObject, ObservableObject {
    
    @Published var detections: [NavigationDetection] = []
    @Published var detectionsInFOV: [NavigationDetection] = []
    @Published var detectionCount: Int = 0
    @Published var isModelLoaded: Bool = false
    @Published var modelName: String = "YOLO"
    @Published var currentAlert: NavigationAlert?
    @Published var speechEnabled: Bool = true
    @Published var nearestDistance: Float = 999
    
    private var visionModel: VNCoreMLModel?
    private let confidenceThreshold: Float = 0.4
    private let processingQueue = DispatchQueue(label: "detection", qos: .userInitiated)
    private var isProcessing: Bool = false
    private var lastAlertTime: Date = .distantPast
    private var lastStepAlertTime: Date = .distantPast
    
    private let speechSynthesizer = AVSpeechSynthesizer()
    private var currentDepthData: ARDepthData?
    private var currentFOVBox: CGRect = CGRect(x: 0.25, y: 0.2, width: 0.5, height: 0.6)
    
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
    
    private func loadModel() {
        processingQueue.async { [weak self] in
            let names = ["yolo11s", "yolov8s", "YOLOv3", "YOLOv3Tiny"]
            var url: URL?
            var name = "YOLO"
            
            for n in names {
                if let u = Bundle.main.url(forResource: n, withExtension: "mlmodelc") {
                    url = u; name = n; break
                }
                if let u = Bundle.main.url(forResource: n, withExtension: "mlpackage") {
                    url = u; name = n; break
                }
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
    
    private func handleResults(_ request: VNRequest) {
        var allResults: [NavigationDetection] = []
        var fovResults: [NavigationDetection] = []
        var minDist: Float = 999
        
        if let obs = request.results as? [VNRecognizedObjectObservation] {
            for o in obs.prefix(20) {
                guard let label = o.labels.first, label.confidence >= confidenceThreshold else { continue }
                let name = label.identifier.lowercased()
                let isObs = NavigationDetection.obstacleClasses.contains(name)
                let dist = getDepth(at: o.boundingBox)
                
                let detection = NavigationDetection(
                    label: label.identifier,
                    confidence: label.confidence,
                    boundingBox: o.boundingBox,
                    isObstacle: isObs,
                    distance: dist
                )
                
                allResults.append(detection)
                
                // Check if detection is within FOV box
                if isWithinFOV(o.boundingBox) {
                    fovResults.append(detection)
                    if let d = dist, d < minDist { minDist = d }
                }
            }
        }
        
        allResults.sort { ($0.distance ?? 999) < ($1.distance ?? 999) }
        fovResults.sort { ($0.distance ?? 999) < ($1.distance ?? 999) }
        
        checkAlert(fovResults)
        
        DispatchQueue.main.async {
            self.detections = allResults
            self.detectionsInFOV = fovResults
            self.detectionCount = allResults.count
            self.nearestDistance = minDist
            self.onDistanceUpdate?(minDist)
        }
    }
    
    private func isWithinFOV(_ box: CGRect) -> Bool {
        // Check if detection center is within FOV box
        let centerX = box.midX
        let centerY = box.midY
        
        return centerX >= currentFOVBox.minX &&
               centerX <= currentFOVBox.maxX &&
               centerY >= currentFOVBox.minY &&
               centerY <= currentFOVBox.maxY
    }
    
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
    
    private func checkAlert(_ detections: [NavigationDetection]) {
        let now = Date()
        guard now.timeIntervalSince(lastAlertTime) > 2.0 else { return }
        
        let obs = detections.filter { $0.isObstacle && $0.distance != nil }
        guard let nearest = obs.first, let dist = nearest.distance else { return }
        
        var alert: NavigationAlert?
        if dist < 1.0 {
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
