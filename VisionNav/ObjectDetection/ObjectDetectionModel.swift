//
//  ObjectDetectionModel.swift
//  VisionNav - Core ML Model Handler
//
//  YOLOv8m object detection with LiDAR distance integration
//

import Foundation
import CoreML
import Vision
import SwiftUI
import Combine

// MARK: - Detection Result Structure

struct DetectedObject: Identifiable, Equatable {
    let id = UUID()
    let label: String
    let confidence: Float
    let boundingBox: CGRect
    var distance: Float?
    var distanceConfidence: Float?
    let color: Color
    
    var confidencePercentage: Int {
        Int(confidence * 100)
    }
    
    var distanceString: String {
        guard let dist = distance else { return "N/A" }
        if dist < 1.0 {
            return String(format: "%.0f cm", dist * 100)
        } else {
            return String(format: "%.2f m", dist)
        }
    }
    
    var isDistanceReliable: Bool {
        guard let conf = distanceConfidence else { return false }
        return conf > 0.5
    }
    
    static func == (lhs: DetectedObject, rhs: DetectedObject) -> Bool {
        lhs.id == rhs.id
    }
    
    func withDistance(_ newDistance: Float?, confidence: Float? = nil) -> DetectedObject {
        DetectedObject(
            label: self.label,
            confidence: self.confidence,
            boundingBox: self.boundingBox,
            distance: newDistance,
            distanceConfidence: confidence,
            color: self.color
        )
    }
}

// MARK: - Object Detection Manager

class ObjectDetectionModel: ObservableObject {
    
    // MARK: - Published Properties
    @Published var detectedObjects: [DetectedObject] = []
    @Published var isModelLoaded = false
    @Published var errorMessage: String?
    @Published var inferenceTime: Double = 0.0
    @Published var fps: Double = 0.0
    
    // MARK: - Private Properties
    private var visionModel: VNCoreMLModel?
    private let confidenceThreshold: Float = 0.35
    private var lastFrameTime = Date()
    private var frameCount = 0
    
    private let classLabels = [
        "person", "bicycle", "car", "motorcycle", "airplane", "bus", "train", "truck", "boat",
        "traffic light", "fire hydrant", "stop sign", "parking meter", "bench", "bird", "cat",
        "dog", "horse", "sheep", "cow", "elephant", "bear", "zebra", "giraffe", "backpack",
        "umbrella", "handbag", "tie", "suitcase", "frisbee", "skis", "snowboard", "sports ball",
        "kite", "baseball bat", "baseball glove", "skateboard", "surfboard", "tennis racket",
        "bottle", "wine glass", "cup", "fork", "knife", "spoon", "bowl", "banana", "apple",
        "sandwich", "orange", "broccoli", "carrot", "hot dog", "pizza", "donut", "cake", "chair",
        "couch", "potted plant", "bed", "dining table", "toilet", "tv", "laptop", "mouse",
        "remote", "keyboard", "cell phone", "microwave", "oven", "toaster", "sink", "refrigerator",
        "book", "clock", "vase", "scissors", "teddy bear", "hair drier", "toothbrush"
    ]
    
    private let classColors: [Color] = [
        .red, .blue, .green, .orange, .purple,
        .pink, .teal, .indigo, .yellow, .brown,
        .cyan, .mint, .red, .blue, .green
    ]
    
    // MARK: - Initialization
    
    init() {
        print("🤖 ObjectDetectionModel initializing...")
        loadModel()
    }
    
    // MARK: - Model Loading
    
    private func loadModel() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            do {
                if let modelURL = Bundle.main.url(forResource: "yolov8m", withExtension: "mlmodelc") {
                    print("📦 Loading YOLOv8m (compiled): \(modelURL.lastPathComponent)")
                    let mlModel = try MLModel(contentsOf: modelURL)
                    let visionModel = try VNCoreMLModel(for: mlModel)
                    
                    DispatchQueue.main.async {
                        self.visionModel = visionModel
                        self.isModelLoaded = true
                        self.errorMessage = nil
                        print("✅ YOLOv8m loaded (compiled)")
                    }
                }
                else if let modelURL = Bundle.main.url(forResource: "yolov8m", withExtension: "mlmodel") {
                    print("📦 Loading YOLOv8m (uncompiled): \(modelURL.lastPathComponent)")
                    let mlModel = try MLModel(contentsOf: modelURL)
                    let visionModel = try VNCoreMLModel(for: mlModel)
                    
                    DispatchQueue.main.async {
                        self.visionModel = visionModel
                        self.isModelLoaded = true
                        self.errorMessage = nil
                        print("✅ YOLOv8m loaded (uncompiled)")
                        print("⚠️ Compiled models (.mlmodelc) perform better")
                    }
                } else {
                    throw NSError(
                        domain: "ObjectDetectionModel",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "YOLOv8m model not found. Add yolov8m.mlmodel or yolov8m.mlmodelc to project."]
                    )
                }
                
            } catch {
                DispatchQueue.main.async {
                    self.isModelLoaded = false
                    self.errorMessage = "Model load failed: \(error.localizedDescription)"
                    print("❌ Model error: \(error)")
                }
            }
        }
    }
    
    // MARK: - Object Detection
    
    func detectObjects(in pixelBuffer: CVPixelBuffer, completion: @escaping ([DetectedObject]) -> Void) {
        guard let model = visionModel else {
            DispatchQueue.main.async {
                self.errorMessage = "Model not loaded"
                completion([])
            }
            return
        }
        
        let startTime = Date()
        
        let request = VNCoreMLRequest(model: model) { [weak self] request, error in
            guard let self = self else { return }
            
            let inferenceTime = Date().timeIntervalSince(startTime) * 1000
            
            self.frameCount += 1
            let currentTime = Date()
            let timeDiff = currentTime.timeIntervalSince(self.lastFrameTime)
            
            if timeDiff >= 1.0 {
                let fps = Double(self.frameCount) / timeDiff
                DispatchQueue.main.async {
                    self.fps = fps
                }
                self.frameCount = 0
                self.lastFrameTime = currentTime
            }
            
            if let error = error {
                DispatchQueue.main.async {
                    self.errorMessage = "Detection error: \(error.localizedDescription)"
                    self.inferenceTime = inferenceTime
                    completion([])
                }
                return
            }
            
            guard let results = request.results as? [VNRecognizedObjectObservation] else {
                DispatchQueue.main.async {
                    self.inferenceTime = inferenceTime
                    completion([])
                }
                return
            }
            
            let objects = self.processDetections(results)
            
            DispatchQueue.main.async {
                self.inferenceTime = inferenceTime
                self.errorMessage = nil
                completion(objects)
            }
        }
        
        request.imageCropAndScaleOption = .scaleFill
        
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try handler.perform([request])
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = "Request failed: \(error.localizedDescription)"
                    completion([])
                }
            }
        }
    }
    
    // MARK: - Result Processing
    
    private func processDetections(_ observations: [VNRecognizedObjectObservation]) -> [DetectedObject] {
        var objects: [DetectedObject] = []
        
        for observation in observations {
            guard let topLabel = observation.labels.first,
                  topLabel.confidence >= confidenceThreshold else {
                continue
            }
            
            let label = topLabel.identifier
            let colorIndex = abs(label.hashValue) % classColors.count
            
            let object = DetectedObject(
                label: label,
                confidence: topLabel.confidence,
                boundingBox: observation.boundingBox,
                distance: nil,
                distanceConfidence: nil,
                color: classColors[colorIndex]
            )
            
            objects.append(object)
        }
        
        return objects.sorted { $0.confidence > $1.confidence }
    }
    
    // MARK: - LiDAR Integration
    
    func updateObjectsWithDistances(_ objectsWithDistances: [DetectedObject]) {
        DispatchQueue.main.async {
            self.detectedObjects = objectsWithDistances
        }
    }
    
    // MARK: - Statistics
    
    func getDetectionStats() -> (total: Int, withDistance: Int, withoutDistance: Int, reliable: Int) {
        let total = detectedObjects.count
        let withDistance = detectedObjects.filter { $0.distance != nil }.count
        let reliable = detectedObjects.filter { $0.isDistanceReliable }.count
        return (total, withDistance, total - withDistance, reliable)
    }
    
    func getDetectionSummary() -> String {
        let stats = getDetectionStats()
        
        if stats.total == 0 {
            return "No objects detected"
        }
        
        var summary = "\(stats.total) object\(stats.total == 1 ? "" : "s")"
        
        if stats.withDistance > 0 {
            summary += ", \(stats.withDistance) with distance"
            if stats.reliable < stats.withDistance {
                summary += " (\(stats.reliable) reliable)"
            }
        }
        
        return summary
    }
    
    // MARK: - Query Methods
    
    func getObjects(withLabel label: String) -> [DetectedObject] {
        detectedObjects.filter { $0.label == label }
    }
    
    func getClosestObject() -> DetectedObject? {
        detectedObjects
            .filter { $0.distance != nil }
            .min { ($0.distance ?? Float.infinity) < ($1.distance ?? Float.infinity) }
    }
    
    func getFarthestObject() -> DetectedObject? {
        detectedObjects
            .filter { $0.distance != nil }
            .max { ($0.distance ?? 0) < ($1.distance ?? 0) }
    }
    
    func getObjects(inRangeFrom minDistance: Float, to maxDistance: Float) -> [DetectedObject] {
        detectedObjects.filter { object in
            guard let distance = object.distance else { return false }
            return distance >= minDistance && distance <= maxDistance
        }
    }
    
    func getAverageDistance() -> Float? {
        let objectsWithDistance = detectedObjects.filter { $0.distance != nil }
        guard !objectsWithDistance.isEmpty else { return nil }
        
        let totalDistance = objectsWithDistance.reduce(0) { $0 + ($1.distance ?? 0) }
        return totalDistance / Float(objectsWithDistance.count)
    }
    
    func getReliableObjects() -> [DetectedObject] {
        detectedObjects.filter { $0.isDistanceReliable }
    }
}
