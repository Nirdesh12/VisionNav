//
//  NavigationCameraManager.swift
//  VisionNav
//
//  Resizable FOV box for depth detection with haptic feedback

import Foundation
import SwiftUI
import ARKit
import SceneKit
import UIKit
import Combine

public enum StepType: String {
    case none = ""
    case stepUp = "Steps going up ahead"
    case stepDown = "Steps going down ahead"
    case curb = "Curb ahead"
}

public enum ProximityLevel: Int {
    case none = 0
    case low = 1
    case medium = 2
    case high = 3
}

// MARK: - FOV Box Configuration
public struct FOVBoxConfig {
    var widthRatio: CGFloat = 0.5   // 0.2 to 0.8 of screen width
    var heightRatio: CGFloat = 0.6  // 0.2 to 0.8 of screen height
    var centerXOffset: CGFloat = 0  // -0.3 to 0.3
    var centerYOffset: CGFloat = 0  // -0.3 to 0.3
    
    var minWidth: CGFloat { 0.2 }
    var maxWidth: CGFloat { 0.8 }
    var minHeight: CGFloat { 0.2 }
    var maxHeight: CGFloat { 0.8 }
}

class NavigationCameraManager: NSObject, ObservableObject {
    
    // AR Session
    @Published var currentFrame: CVPixelBuffer?
    @Published var currentDepthData: ARDepthData?
    @Published var isSessionRunning: Bool = false
    @Published var hasLiDAR: Bool = false
    
    // Step Detection
    @Published var stepDetected: Bool = false
    @Published var stepType: StepType = .none
    @Published var stepDistance: Float = 0
    
    // Depth in FOV Box
    @Published var nearestObstacleDistance: Float = 999
    @Published var averageDepthInFOV: Float = 999
    @Published var currentProximity: ProximityLevel = .none
    
    // FOV Box (resizable)
    @Published var fovConfig: FOVBoxConfig = FOVBoxConfig()
    
    let arSession = ARSession()
    private var hapticTimer: Timer?
    private var depthHistory: [[Float]] = []
    
    override init() {
        super.init()
        hasLiDAR = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    }
    
    deinit { stopHaptics() }
    
    // MARK: - FOV Box Adjustment
    func adjustFOVWidth(delta: CGFloat) {
        let newWidth = fovConfig.widthRatio + delta
        fovConfig.widthRatio = min(max(newWidth, fovConfig.minWidth), fovConfig.maxWidth)
    }
    
    func adjustFOVHeight(delta: CGFloat) {
        let newHeight = fovConfig.heightRatio + delta
        fovConfig.heightRatio = min(max(newHeight, fovConfig.minHeight), fovConfig.maxHeight)
    }
    
    func resetFOVBox() {
        fovConfig = FOVBoxConfig()
    }
    
    // Get FOV box rect in normalized coordinates (0-1)
    var fovBoxNormalized: CGRect {
        let width = fovConfig.widthRatio
        let height = fovConfig.heightRatio
        let x = (1 - width) / 2 + fovConfig.centerXOffset
        let y = (1 - height) / 2 + fovConfig.centerYOffset
        return CGRect(x: max(0, x), y: max(0, y), width: min(width, 1-x), height: min(height, 1-y))
    }
    
    // MARK: - Haptics
    func updateHaptics(forDistance distance: Float) {
        let newProximity: ProximityLevel
        if distance < 1.0 { newProximity = .high }
        else if distance < 2.0 { newProximity = .medium }
        else if distance < 3.0 { newProximity = .low }
        else { newProximity = .none }
        
        if newProximity != currentProximity {
            currentProximity = newProximity
            nearestObstacleDistance = distance
            startHapticPattern(for: newProximity)
        }
    }
    
    private func startHapticPattern(for proximity: ProximityLevel) {
        hapticTimer?.invalidate()
        hapticTimer = nil
        guard proximity != .none else { return }
        
        let interval: TimeInterval
        switch proximity {
        case .high: interval = 0.12
        case .medium: interval = 0.35
        case .low: interval = 0.7
        case .none: return
        }
        
        hapticTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.triggerHaptic(for: proximity)
        }
        triggerHaptic(for: proximity)
    }
    
    private func triggerHaptic(for proximity: ProximityLevel) {
        let style: UIImpactFeedbackGenerator.FeedbackStyle
        switch proximity {
        case .high: style = .heavy
        case .medium: style = .medium
        case .low: style = .light
        case .none: return
        }
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }
    
    func stopHaptics() {
        hapticTimer?.invalidate()
        hapticTimer = nil
        currentProximity = .none
    }
    
    func triggerStepHaptic() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }
    
    // MARK: - AR Session
    func startSession() {
        let config = ARWorldTrackingConfiguration()
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            config.frameSemantics.insert(.smoothedSceneDepth)
        } else if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }
        config.planeDetection = [.horizontal]
        arSession.delegate = self
        arSession.run(config, options: [.resetTracking])
        DispatchQueue.main.async { self.isSessionRunning = true }
    }
    
    func stopSession() {
        arSession.pause()
        depthHistory.removeAll()
        stopHaptics()
        DispatchQueue.main.async {
            self.isSessionRunning = false
            self.currentFrame = nil
            self.currentDepthData = nil
            self.stepDetected = false
            self.stepType = .none
            self.nearestObstacleDistance = 999
            self.averageDepthInFOV = 999
        }
    }
    
    // MARK: - Depth Analysis within FOV Box
    private func analyzeDepthInFOVBox(_ depthData: ARDepthData) {
        let depthMap = depthData.depthMap
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
        guard let base = CVPixelBufferGetBaseAddress(depthMap) else { return }
        
        // Calculate FOV box bounds in depth map coordinates
        let fovBox = fovBoxNormalized
        let startX = Int(fovBox.minX * CGFloat(width))
        let endX = Int(fovBox.maxX * CGFloat(width))
        let startY = Int(fovBox.minY * CGFloat(height))
        let endY = Int(fovBox.maxY * CGFloat(height))
        
        var minDist: Float = 999
        var totalDepth: Float = 0
        var validCount: Float = 0
        
        // Sample within FOV box only
        let stepSize = 3
        for y in stride(from: startY, to: endY, by: stepSize) {
            for x in stride(from: startX, to: endX, by: stepSize) {
                guard x >= 0, x < width, y >= 0, y < height else { continue }
                let ptr = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: Float32.self)
                let depth = ptr[x]
                
                if depth.isFinite && depth > 0.1 && depth < 5.0 {
                    minDist = min(minDist, depth)
                    totalDepth += depth
                    validCount += 1
                }
            }
        }
        
        let avgDepth = validCount > 0 ? totalDepth / validCount : 999
        
        DispatchQueue.main.async {
            self.nearestObstacleDistance = minDist
            self.averageDepthInFOV = avgDepth
            self.updateHaptics(forDistance: minDist)
        }
        
        // Step detection in lower portion of FOV
        analyzeStepsInFOV(base: base, width: width, height: height, bytesPerRow: bytesPerRow, fovBox: fovBox)
    }
    
    private func analyzeStepsInFOV(base: UnsafeMutableRawPointer, width: Int, height: Int, bytesPerRow: Int, fovBox: CGRect) {
        // Sample 3 horizontal strips in lower portion of FOV box
        let strips: [CGFloat] = [0.85, 0.65, 0.45]
        var depths: [Float] = []
        
        let fovStartX = Int(fovBox.minX * CGFloat(width))
        let fovEndX = Int(fovBox.maxX * CGFloat(width))
        let fovCenterX = (fovStartX + fovEndX) / 2
        let sampleWidth = (fovEndX - fovStartX) / 2
        
        for stripRatio in strips {
            let y = Int(fovBox.minY * CGFloat(height) + fovBox.height * CGFloat(height) * stripRatio)
            guard y >= 0, y < height else {
                depths.append(0)
                continue
            }
            
            var sum: Float = 0
            var count: Float = 0
            let ptr = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: Float32.self)
            
            for x in stride(from: fovCenterX - sampleWidth/2, to: fovCenterX + sampleWidth/2, by: 2) {
                guard x >= 0, x < width else { continue }
                let d = ptr[x]
                if d.isFinite && d > 0.1 && d < 5.0 {
                    sum += d
                    count += 1
                }
            }
            depths.append(count > 0 ? sum / count : 0)
        }
        
        depthHistory.append(depths)
        if depthHistory.count > 5 { depthHistory.removeFirst() }
        guard depthHistory.count >= 3 else { return }
        
        var avg: [Float] = [0, 0, 0]
        for s in depthHistory {
            for (i, d) in s.enumerated() where i < 3 { avg[i] += d }
        }
        avg = avg.map { $0 / Float(depthHistory.count) }
        let change = avg[1] - avg[0]
        
        DispatchQueue.main.async {
            if abs(change) > 0.07 {
                self.stepDetected = true
                self.stepType = change > 0 ? .stepDown : .stepUp
                self.stepDistance = avg[0]
                self.triggerStepHaptic()
            } else if abs(change) > 0.04 {
                self.stepDetected = true
                self.stepType = .curb
                self.stepDistance = avg[0]
            } else {
                self.stepDetected = false
                self.stepType = .none
            }
        }
    }
}

// MARK: - ARSessionDelegate
extension NavigationCameraManager: ARSessionDelegate {
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let buffer = frame.capturedImage
        let depth = frame.smoothedSceneDepth ?? frame.sceneDepth
        
        if let d = depth {
            analyzeDepthInFOVBox(d)
        }
        
        DispatchQueue.main.async {
            self.currentFrame = buffer
            self.currentDepthData = depth
        }
    }
    
    func session(_ session: ARSession, didFailWithError error: Error) {
        DispatchQueue.main.async { self.isSessionRunning = false }
    }
}

// MARK: - Full Screen AR View
struct FullScreenARView: UIViewRepresentable {
    let session: ARSession
    
    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView()
        view.session = session
        view.automaticallyUpdatesLighting = true
        view.backgroundColor = .black
        view.contentMode = .scaleAspectFill
        return view
    }
    
    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}
