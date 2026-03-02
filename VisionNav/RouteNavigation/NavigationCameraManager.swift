//
//  NavigationCameraManager.swift
//  VisionNav
//
//  Resizable FOV box with LiDAR depth analysis, stair counting, and haptic feedback

import Foundation
import SwiftUI
import ARKit
import SceneKit
import UIKit
import Combine
import CoreHaptics

public enum StepType: String {
    case none = ""
    case stepUp = "Steps going up ahead"
    case stepDown = "Steps going down ahead"
    case curb = "Curb ahead"
}

public enum ProximityLevel: Int, Comparable {
    case none = 0
    case veryLow = 1
    case low = 2
    case medium = 3
    case high = 4
    case veryHigh = 5

    public static func < (lhs: ProximityLevel, rhs: ProximityLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var hapticInterval: TimeInterval {
        switch self {
        case .veryHigh: return 0.06
        case .high: return 0.12
        case .medium: return 0.25
        case .low: return 0.5
        case .veryLow: return 0.8
        case .none: return 0
        }
    }

    var hapticIntensity: Float {
        switch self {
        case .veryHigh: return 1.0
        case .high: return 0.85
        case .medium: return 0.65
        case .low: return 0.45
        case .veryLow: return 0.3
        case .none: return 0
        }
    }
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

    // Stair Counting via LiDAR
    @Published var stairStepCount: Int = 0

    // Depth in FOV Box
    @Published var nearestObstacleDistance: Float = 999
    @Published var averageDepthInFOV: Float = 999
    @Published var currentProximity: ProximityLevel = .none

    // FOV Box (resizable)
    @Published var fovConfig: FOVBoxConfig = FOVBoxConfig()

    let arSession = ARSession()
    private var hapticTimer: Timer?
    private var depthHistory: [[Float]] = []

    // CoreHaptics engine
    private var hapticEngine: CHHapticEngine?
    private var continuousPlayer: CHHapticAdvancedPatternPlayer?
    private var engineRunning = false

    // Frame throttling — skip frames to avoid overwhelming the main thread
    private let depthQueue = DispatchQueue(label: "depthAnalysis", qos: .userInitiated)
    private var lastDepthAnalysisTime: TimeInterval = 0
    private let depthAnalysisInterval: TimeInterval = 0.1  // Max 10 depth analyses per second
    private var isAnalyzingDepth = false

    override init() {
        super.init()
        hasLiDAR = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
        setupHapticEngine()
    }

    deinit { stopHaptics() }

    // MARK: - CoreHaptics Engine Setup
    private func setupHapticEngine() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }

        do {
            hapticEngine = try CHHapticEngine()
            hapticEngine?.stoppedHandler = { [weak self] reason in
                self?.engineRunning = false
            }
            hapticEngine?.resetHandler = { [weak self] in
                do {
                    try self?.hapticEngine?.start()
                    self?.engineRunning = true
                } catch {}
            }
            try hapticEngine?.start()
            engineRunning = true
        } catch {
            print("Haptic engine error: \(error)")
        }
    }

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

    // MARK: - 5-Level Proximity Haptics
    func updateHaptics(forDistance distance: Float) {
        let newProximity: ProximityLevel
        if distance < 0.5 { newProximity = .veryHigh }
        else if distance < 1.0 { newProximity = .high }
        else if distance < 2.0 { newProximity = .medium }
        else if distance < 3.0 { newProximity = .low }
        else if distance < 4.0 { newProximity = .veryLow }
        else { newProximity = .none }

        if newProximity != currentProximity {
            currentProximity = newProximity
            nearestObstacleDistance = distance
            playProximityHaptic(for: newProximity, distance: distance)
        }
    }

    private func playProximityHaptic(for proximity: ProximityLevel, distance: Float) {
        hapticTimer?.invalidate()
        hapticTimer = nil
        guard proximity != .none else {
            stopContinuousHaptic()
            return
        }

        // Try CoreHaptics first for richer patterns
        if engineRunning, let engine = hapticEngine {
            playCoreHapticPattern(engine: engine, proximity: proximity, distance: distance)
        } else {
            // Fallback to UIImpactFeedbackGenerator
            startLegacyHapticPattern(for: proximity)
        }
    }

    private func playCoreHapticPattern(engine: CHHapticEngine, proximity: ProximityLevel, distance: Float) {
        stopContinuousHaptic()

        let intensity = CHHapticEventParameter(parameterID: .hapticIntensity, value: proximity.hapticIntensity)
        let sharpness = CHHapticEventParameter(parameterID: .hapticSharpness, value: proximity >= .high ? 0.8 : 0.4)

        // Create repeating transient events
        var events: [CHHapticEvent] = []
        let interval = proximity.hapticInterval
        let patternDuration: TimeInterval = 2.0
        var time: TimeInterval = 0

        while time < patternDuration {
            let event = CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [intensity, sharpness],
                relativeTime: time
            )
            events.append(event)
            time += interval
        }

        do {
            let pattern = try CHHapticPattern(events: events, parameters: [])
            let player = try engine.makeAdvancedPlayer(with: pattern)
            player.loopEnabled = true
            try player.start(atTime: CHHapticTimeImmediate)
            continuousPlayer = player
        } catch {
            // Fallback
            startLegacyHapticPattern(for: proximity)
        }
    }

    private func stopContinuousHaptic() {
        try? continuousPlayer?.stop(atTime: CHHapticTimeImmediate)
        continuousPlayer = nil
    }

    private func startLegacyHapticPattern(for proximity: ProximityLevel) {
        hapticTimer?.invalidate()
        let interval = proximity.hapticInterval

        hapticTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.triggerLegacyHaptic(for: proximity)
        }
        triggerLegacyHaptic(for: proximity)
    }

    private func triggerLegacyHaptic(for proximity: ProximityLevel) {
        let style: UIImpactFeedbackGenerator.FeedbackStyle
        switch proximity {
        case .veryHigh, .high: style = .heavy
        case .medium: style = .medium
        case .low, .veryLow: style = .light
        case .none: return
        }
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }

    func stopHaptics() {
        hapticTimer?.invalidate()
        hapticTimer = nil
        stopContinuousHaptic()
        currentProximity = .none
    }

    func triggerStepHaptic() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    // MARK: - LiDAR Stair Step Counting
    /// Count individual stair steps within a bounding box region using LiDAR depth data.
    /// Analyzes vertical depth profile for regular depth transitions (~15-20cm per step).
    func countStairsInRegion(boundingBox: CGRect, depthData: ARDepthData?) -> Int {
        guard let depthData = depthData else { return 0 }

        let depthMap = depthData.depthMap
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
        guard let base = CVPixelBufferGetBaseAddress(depthMap) else { return 0 }

        // Map bounding box to depth map coordinates
        // Vision bounding box: origin bottom-left, y up
        let startX = Int(boundingBox.midX * CGFloat(width)) // Sample vertical strip at center
        let sampleWidth = max(1, Int(boundingBox.width * CGFloat(width) * 0.3))
        let startY = Int((1.0 - boundingBox.maxY) * CGFloat(height))
        let endY = Int((1.0 - boundingBox.minY) * CGFloat(height))

        guard startY < endY, startX >= 0, startX < width else { return 0 }

        // Sample depth along a vertical strip through the stairs
        var depthProfile: [Float] = []
        let stepSize = max(1, (endY - startY) / 30) // ~30 samples

        for y in stride(from: startY, to: endY, by: stepSize) {
            guard y >= 0, y < height else { continue }

            var sum: Float = 0
            var count: Float = 0
            let xStart = max(0, startX - sampleWidth / 2)
            let xEnd = min(width, startX + sampleWidth / 2)

            for x in stride(from: xStart, to: xEnd, by: 2) {
                let ptr = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: Float32.self)
                let d = ptr[x]
                if d.isFinite && d > 0.1 && d < 5.0 {
                    sum += d
                    count += 1
                }
            }

            if count > 0 {
                depthProfile.append(sum / count)
            }
        }

        guard depthProfile.count >= 4 else { return 0 }

        // Smooth the profile
        var smoothed: [Float] = []
        for i in 0..<depthProfile.count {
            let start = max(0, i - 1)
            let end = min(depthProfile.count - 1, i + 1)
            let avg = depthProfile[start...end].reduce(0, +) / Float(end - start + 1)
            smoothed.append(avg)
        }

        // Count depth transitions (step = ~0.12-0.25m depth change)
        let minStepDepth: Float = 0.10  // 10cm min for a step
        let maxStepDepth: Float = 0.30  // 30cm max for a step
        var stepCount = 0
        var lastTransitionIndex = -3

        for i in 1..<smoothed.count {
            let change = abs(smoothed[i] - smoothed[i - 1])
            if change >= minStepDepth && change <= maxStepDepth && (i - lastTransitionIndex) >= 2 {
                stepCount += 1
                lastTransitionIndex = i
            }
        }

        return stepCount
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

        // Restart haptic engine if needed
        if !engineRunning {
            try? hapticEngine?.start()
            engineRunning = true
        }
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
            self.stairStepCount = 0
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

        // Step detection in lower portion of FOV (6 strips for better resolution)
        analyzeStepsInFOV(base: base, width: width, height: height, bytesPerRow: bytesPerRow, fovBox: fovBox)
    }

    private func analyzeStepsInFOV(base: UnsafeMutableRawPointer, width: Int, height: Int, bytesPerRow: Int, fovBox: CGRect) {
        // Sample 6 horizontal strips in FOV box for better step detection resolution
        let strips: [CGFloat] = [0.90, 0.78, 0.66, 0.54, 0.42, 0.30]
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

        // Average across history for stability
        var avg = [Float](repeating: 0, count: strips.count)
        for s in depthHistory {
            for (i, d) in s.enumerated() where i < strips.count { avg[i] += d }
        }
        avg = avg.map { $0 / Float(depthHistory.count) }

        // Check consecutive strip pairs for step transitions
        var maxChange: Float = 0
        var changeDirection: Float = 0
        for i in 0..<(avg.count - 1) {
            let change = avg[i + 1] - avg[i]
            if abs(change) > abs(maxChange) {
                maxChange = change
                changeDirection = change
            }
        }

        DispatchQueue.main.async {
            if abs(maxChange) > 0.07 {
                self.stepDetected = true
                self.stepType = changeDirection > 0 ? .stepDown : .stepUp
                self.stepDistance = avg[0]
                self.triggerStepHaptic()
            } else if abs(maxChange) > 0.04 {
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

        // Throttle depth analysis — run at most every 100ms on a background queue
        if let d = depth, !isAnalyzingDepth {
            let now = frame.timestamp
            if now - lastDepthAnalysisTime >= depthAnalysisInterval {
                lastDepthAnalysisTime = now
                isAnalyzingDepth = true
                depthQueue.async { [weak self] in
                    self?.analyzeDepthInFOVBox(d)
                    self?.isAnalyzingDepth = false
                }
            }
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
