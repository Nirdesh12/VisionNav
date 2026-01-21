//
//  ObjectDetectionView.swift
//  VisionNav - Main Object Detection Interface
//
//  Real-time object detection with LiDAR distance
//  Using Apple's coordinate system properly
//

import SwiftUI
import AVFoundation
import Vision
import Combine

// MARK: - Main View

struct ObjectDetectionView: View {
    
    @StateObject private var cameraManager = CameraManager()
    @StateObject private var detectionModel = ObjectDetectionModel()
    @Environment(\.dismiss) var dismiss
    
    @State private var isProcessing = false
    @State private var selectedObject: DetectedObject?
    @State private var lastProcessTime = Date()
    @State private var showDebugInfo = false
    
    private let processingInterval: TimeInterval = 0.1
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            if cameraManager.isSessionRunning {
                CameraPreviewView(cameraManager: cameraManager)
                    .ignoresSafeArea()
                
                GeometryReader { geometry in
                    DetectionOverlayView(
                        detectedObjects: detectionModel.detectedObjects,
                        selectedObject: $selectedObject,
                        viewSize: geometry.size,
                        showDebugInfo: showDebugInfo
                    )
                }
                .ignoresSafeArea()
            } else {
                LoadingView(hasLiDAR: cameraManager.hasLiDAR)
            }
            
            VStack {
                TopControlsView(
                    isModelLoaded: detectionModel.isModelLoaded,
                    hasLiDAR: cameraManager.hasLiDAR,
                    depthDataReceived: cameraManager.depthDataReceived,
                    fps: detectionModel.fps,
                    inferenceTime: detectionModel.inferenceTime,
                    showDebugInfo: $showDebugInfo,
                    dismiss: dismiss
                )
                
                Spacer()
                
                BottomInfoPanel(
                    detectedObjects: detectionModel.detectedObjects,
                    selectedObject: selectedObject,
                    cameraManager: cameraManager
                )
            }
            
            if let error = detectionModel.errorMessage ?? cameraManager.errorMessage {
                VStack {
                    Spacer()
                    ErrorBanner(message: error)
                        .padding()
                }
            }
        }
        .navigationBarHidden(true)
        .onAppear {
            setupObjectDetection()
        }
        .onDisappear {
            cameraManager.stopSession()
        }
        .onChange(of: cameraManager.currentFrame) { oldValue, newFrame in
            processFrameWithThrottling(newFrame)
        }
    }
    
    // MARK: - Setup
    
    private func setupObjectDetection() {
        print("🚀 Starting object detection with LiDAR depth camera")
        cameraManager.setupCamera()
        cameraManager.startSession()
    }
    
    // MARK: - Frame Processing
    
    private func processFrameWithThrottling(_ pixelBuffer: CVPixelBuffer?) {
        let now = Date()
        guard now.timeIntervalSince(lastProcessTime) >= processingInterval else {
            return
        }
        lastProcessTime = now
        processFrame(pixelBuffer)
    }
    
    private func processFrame(_ pixelBuffer: CVPixelBuffer?) {
        guard let pixelBuffer = pixelBuffer,
              detectionModel.isModelLoaded,
              !isProcessing else { return }
        
        isProcessing = true
        
        detectionModel.detectObjects(in: pixelBuffer) { detectedObjects in
            
            if self.cameraManager.hasLiDAR && self.cameraManager.depthDataReceived {
                
                var objectsWithDistances: [DetectedObject] = []
                
                for object in detectedObjects {
                    // Use advanced calibrated distance measurement
                    if let result = self.cameraManager.getDistanceWithConfidence(in: object.boundingBox) {
                        let objectWithDistance = object.withDistance(result.distance, confidence: result.confidence)
                        objectsWithDistances.append(objectWithDistance)
                        
                        if self.showDebugInfo {
                            let bbox = object.boundingBox
                            print("📏 \(object.label): \(String(format: "%.3fm", result.distance)) (conf: \(String(format: "%.0f%%", result.confidence * 100)))")
                            print("   BBox: [\(String(format: "%.3f", bbox.origin.x)), \(String(format: "%.3f", bbox.origin.y)), \(String(format: "%.3f", bbox.width))x\(String(format: "%.3f", bbox.height))]")
                        }
                    } else {
                        objectsWithDistances.append(object)
                        if self.showDebugInfo {
                            print("⚠️ \(object.label): Insufficient depth samples")
                        }
                    }
                }
                
                self.detectionModel.updateObjectsWithDistances(objectsWithDistances)
                
            } else {
                self.detectionModel.updateObjectsWithDistances(detectedObjects)
            }
            
            self.isProcessing = false
        }
    }
}

// MARK: - Camera Preview

struct CameraPreviewView: View {
    @ObservedObject var cameraManager: CameraManager
    
    var body: some View {
        GeometryReader { geometry in
            if let pixelBuffer = cameraManager.currentFrame {
                CameraPreviewRepresentable(pixelBuffer: pixelBuffer)
                    .frame(width: geometry.size.width, height: geometry.size.height)
            } else {
                Color.black
                    .overlay(
                        Text("Initializing camera...")
                            .foregroundColor(.white)
                    )
            }
        }
    }
}

struct CameraPreviewRepresentable: UIViewRepresentable {
    let pixelBuffer: CVPixelBuffer
    
    func makeUIView(context: Context) -> CameraPreviewUIView {
        CameraPreviewUIView()
    }
    
    func updateUIView(_ uiView: CameraPreviewUIView, context: Context) {
        uiView.display(pixelBuffer: pixelBuffer)
    }
}

class CameraPreviewUIView: UIView {
    private let imageView = UIImageView()
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupImageView()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupImageView()
    }
    
    private func setupImageView() {
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        addSubview(imageView)
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        imageView.frame = bounds
    }
    
    func display(pixelBuffer: CVPixelBuffer) {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        
        if let cgImage = context.createCGImage(ciImage, from: ciImage.extent) {
            DispatchQueue.main.async {
                self.imageView.image = UIImage(cgImage: cgImage)
            }
        }
    }
}

// MARK: - Detection Overlay

struct DetectionOverlayView: View {
    let detectedObjects: [DetectedObject]
    @Binding var selectedObject: DetectedObject?
    let viewSize: CGSize
    let showDebugInfo: Bool
    
    var body: some View {
        ZStack {
            ForEach(detectedObjects) { object in
                BoundingBoxView(
                    object: object,
                    isSelected: selectedObject?.id == object.id,
                    viewSize: viewSize,
                    showDebugInfo: showDebugInfo
                )
                .onTapGesture {
                    withAnimation(.spring(response: 0.3)) {
                        selectedObject = selectedObject?.id == object.id ? nil : object
                    }
                }
            }
        }
    }
}

struct BoundingBoxView: View {
    let object: DetectedObject
    let isSelected: Bool
    let viewSize: CGSize
    let showDebugInfo: Bool
    
    // Convert Vision's normalized coordinates (origin: bottom-left) to SwiftUI (origin: top-left)
    private var displayRect: CGRect {
        let visionRect = object.boundingBox
        
        // Vision coordinate system: origin at bottom-left, y increases upward
        // SwiftUI coordinate system: origin at top-left, y increases downward
        let x = visionRect.origin.x * viewSize.width
        let y = (1 - visionRect.origin.y - visionRect.height) * viewSize.height
        let width = visionRect.width * viewSize.width
        let height = visionRect.height * viewSize.height
        
        return CGRect(x: x, y: y, width: width, height: height)
    }
    
    var body: some View {
        ZStack {
            // Bounding box rectangle
            Rectangle()
                .stroke(
                    object.isDistanceReliable ? object.color : object.color.opacity(0.6),
                    lineWidth: isSelected ? 3.5 : 2.5
                )
                .frame(width: displayRect.width, height: displayRect.height)
                .position(x: displayRect.midX, y: displayRect.midY)
            
            // Label overlay
            VStack(alignment: .leading, spacing: 3) {
                Text(object.label.capitalized)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
                
                HStack(spacing: 6) {
                    // Detection confidence
                    HStack(spacing: 2) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 9))
                        Text("\(object.confidencePercentage)%")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundColor(.white.opacity(0.95))
                    
                    if let distance = object.distance {
                        Text("•")
                            .font(.system(size: 8))
                            .foregroundColor(.white.opacity(0.5))
                        
                        // Distance with LiDAR icon
                        HStack(spacing: 3) {
                            Image(systemName: object.isDistanceReliable ? "light.beacon.max.fill" : "light.beacon.max")
                                .font(.system(size: 9))
                            Text(object.distanceString)
                                .font(.system(size: 11, weight: .bold))
                        }
                        .foregroundColor(object.isDistanceReliable ? Color.green : Color.yellow)
                        
                        if showDebugInfo, let conf = object.distanceConfidence {
                            Text("(\(Int(conf * 100))%)")
                                .font(.system(size: 8))
                                .foregroundColor(.white.opacity(0.7))
                        }
                    } else {
                        Text("•")
                            .font(.system(size: 8))
                            .foregroundColor(.white.opacity(0.5))
                        
                        Text("No LiDAR")
                            .font(.system(size: 9))
                            .foregroundColor(.red.opacity(0.9))
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(object.color.opacity(0.92))
                    .shadow(color: .black.opacity(0.3), radius: 3, y: 2)
            )
            .position(
                x: displayRect.minX + displayRect.width / 2,
                y: max(25, displayRect.minY - 18)
            )
            
            // Debug crosshair at bounding box center
            if showDebugInfo {
                ZStack {
                    Circle()
                        .fill(Color.cyan)
                        .frame(width: 10, height: 10)
                    
                    Circle()
                        .stroke(Color.white, lineWidth: 2)
                        .frame(width: 10, height: 10)
                    
                    Rectangle()
                        .fill(Color.cyan)
                        .frame(width: 25, height: 2)
                    
                    Rectangle()
                        .fill(Color.cyan)
                        .frame(width: 2, height: 25)
                }
                .position(x: displayRect.midX, y: displayRect.midY)
            }
        }
    }
}

// MARK: - Top Controls

struct TopControlsView: View {
    let isModelLoaded: Bool
    let hasLiDAR: Bool
    let depthDataReceived: Bool
    let fps: Double
    let inferenceTime: Double
    @Binding var showDebugInfo: Bool
    let dismiss: DismissAction
    
    var body: some View {
        HStack(alignment: .top) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "arrow.backward")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(14)
                    .background(
                        Circle()
                            .fill(Color.black.opacity(0.65))
                            .shadow(color: .black.opacity(0.3), radius: 5)
                    )
            }
            
            Spacer()
            
            VStack(alignment: .trailing, spacing: 5) {
                // Camera Type
                HStack(spacing: 5) {
                    Image(systemName: "camera.metering.matrix")
                        .font(.system(size: 11))
                    Text("LiDAR Depth Camera")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundColor(.cyan)
                
                // Model Status
                HStack(spacing: 6) {
                    Circle()
                        .fill(isModelLoaded ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                    Text(isModelLoaded ? "YOLOv8 Active" : "Loading Model...")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(.white)
                
                // LiDAR Status
                HStack(spacing: 6) {
                    Circle()
                        .fill(depthDataReceived ? Color.green : (hasLiDAR ? Color.orange : Color.red))
                        .frame(width: 8, height: 8)
                    
                    Image(systemName: depthDataReceived ? "light.beacon.max.fill" : "light.beacon.max")
                        .font(.system(size: 10))
                    
                    Text(depthDataReceived ? "LiDAR Active" : (hasLiDAR ? "LiDAR Starting..." : "No LiDAR"))
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(depthDataReceived ? .green : (hasLiDAR ? .orange : .red))
                
                // Performance Stats
                HStack(spacing: 8) {
                    Text(String(format: "%.0f FPS", fps))
                        .font(.system(size: 10, weight: .medium))
                    Text("•")
                        .font(.system(size: 8))
                    Text(String(format: "%.0fms", inferenceTime))
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundColor(.white.opacity(0.85))
                
                Divider()
                    .frame(height: 1)
                    .background(Color.white.opacity(0.3))
                    .padding(.vertical, 2)
                
                // Debug Toggle
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showDebugInfo.toggle()
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: showDebugInfo ? "info.circle.fill" : "info.circle")
                            .font(.system(size: 11))
                        Text("Debug Mode")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(showDebugInfo ? .yellow : .white.opacity(0.7))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.black.opacity(0.65))
                    .shadow(color: .black.opacity(0.3), radius: 5)
            )
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }
}

// MARK: - Bottom Info Panel

struct BottomInfoPanel: View {
    let detectedObjects: [DetectedObject]
    let selectedObject: DetectedObject?
    let cameraManager: CameraManager
    
    var body: some View {
        VStack(spacing: 12) {
            if let selected = selectedObject {
                SelectedObjectCard(object: selected, cameraManager: cameraManager)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if !detectedObjects.isEmpty {
                DetectionSummaryCard(detectedObjects: detectedObjects)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 20)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: selectedObject?.id)
    }
}

struct SelectedObjectCard: View {
    let object: DetectedObject
    let cameraManager: CameraManager
    
    var body: some View {
        HStack(spacing: 16) {
            // Icon
            ZStack {
                Circle()
                    .fill(object.color)
                    .frame(width: 56, height: 56)
                
                Image(systemName: "cube.box.fill")
                    .font(.system(size: 24))
                    .foregroundColor(.white)
            }
            
            VStack(alignment: .leading, spacing: 6) {
                Text(object.label.capitalized)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.white)
                
                HStack(spacing: 14) {
                    // Detection confidence
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 11))
                        Text("\(object.confidencePercentage)%")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundColor(.green)
                    
                    if let distance = object.distance {
                        HStack(spacing: 4) {
                            Image(systemName: object.isDistanceReliable ? "ruler.fill" : "ruler")
                                .font(.system(size: 11))
                            Text(object.distanceString)
                                .font(.system(size: 14, weight: .bold))
                            
                            if !object.isDistanceReliable {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 9))
                                    .foregroundColor(.yellow)
                            }
                        }
                        .foregroundColor(object.isDistanceReliable ? .cyan : .yellow)
                    } else {
                        HStack(spacing: 4) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                            Text("No depth data")
                                .font(.system(size: 12))
                        }
                        .foregroundColor(.red)
                    }
                }
            }
            
            Spacer()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Color.black.opacity(0.75))
                .shadow(color: object.color.opacity(0.4), radius: 8)
        )
    }
}

struct DetectionSummaryCard: View {
    let detectedObjects: [DetectedObject]
    
    private var stats: (total: Int, withDistance: Int, reliable: Int) {
        let total = detectedObjects.count
        let withDistance = detectedObjects.filter { $0.distance != nil }.count
        let reliable = detectedObjects.filter { $0.isDistanceReliable }.count
        return (total, withDistance, reliable)
    }
    
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "viewfinder.circle.fill")
                .font(.system(size: 32))
                .foregroundColor(.blue)
            
            VStack(alignment: .leading, spacing: 4) {
                Text("\(stats.total) Object\(stats.total == 1 ? "" : "s") Detected")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white)
                
                if stats.withDistance > 0 {
                    HStack(spacing: 6) {
                        Image(systemName: "light.beacon.max.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.green)
                        
                        if stats.reliable == stats.withDistance {
                            Text("\(stats.reliable) with accurate LiDAR distance")
                                .font(.system(size: 11))
                                .foregroundColor(.green)
                        } else {
                            Text("\(stats.reliable) accurate • \(stats.withDistance - stats.reliable) uncertain")
                                .font(.system(size: 11))
                                .foregroundColor(.yellow)
                        }
                    }
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                        Text("No LiDAR depth data available")
                            .font(.system(size: 11))
                    }
                    .foregroundColor(.orange)
                }
            }
            
            Spacer()
            
            Image(systemName: "hand.tap.fill")
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.5))
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.black.opacity(0.75))
                .shadow(color: .black.opacity(0.4), radius: 6)
        )
    }
}

// MARK: - Loading View

struct LoadingView: View {
    let hasLiDAR: Bool
    
    var body: some View {
        VStack(spacing: 24) {
            ProgressView()
                .scaleEffect(1.8)
                .tint(.white)
            
            VStack(spacing: 10) {
                Text("Initializing LiDAR Camera")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white)
                
                if !hasLiDAR {
                    VStack(spacing: 6) {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 13))
                            Text("LiDAR sensor not detected")
                                .font(.system(size: 13, weight: .medium))
                        }
                        .foregroundColor(.orange)
                        
                        Text("Requires iPhone 12 Pro or newer Pro models")
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.7))
                    }
                    .padding(.top, 8)
                } else {
                    Text("LiDAR depth camera detected")
                        .font(.system(size: 13))
                        .foregroundColor(.green)
                }
            }
        }
        .padding(32)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color.black.opacity(0.7))
                .shadow(radius: 10)
        )
    }
}

// MARK: - Error Banner

struct ErrorBanner: View {
    let message: String
    
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 16))
                .foregroundColor(.yellow)
            
            Text(message)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.red.opacity(0.85))
                .shadow(color: .black.opacity(0.3), radius: 5)
        )
    }
}
