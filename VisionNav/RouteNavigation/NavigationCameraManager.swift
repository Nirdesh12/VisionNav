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

public enum StairDirection: String {
    case up = "going up"
    case down = "going down"
    case unknown = ""
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
    var widthRatio: CGFloat = 0.35  // Narrower: sized for human passage (~shoulder width)
    var heightRatio: CGFloat = 0.7  // Taller: captures full walking path
    var centerXOffset: CGFloat = 0  // -0.3 to 0.3
    var centerYOffset: CGFloat = 0  // -0.3 to 0.3
    var sideMarginRatio: CGFloat = 0.12 // Extra margin on each side for incoming obstacle alerts

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

    // Stair Counting via LiDAR
    @Published var stairStepCount: Int = 0

    // Depth in FOV Box
    @Published var nearestObstacleDistance: Float = 999
    @Published var averageDepthInFOV: Float = 999
    @Published var currentProximity: ProximityLevel = .none

    // FOV Box (resizable)
    @Published var fovConfig: FOVBoxConfig = FOVBoxConfig()

    // Obstacle spatial data (updated by LiDAR at 10Hz)
    @Published var obstacleInFOV: Bool = false
    @Published var obstacleDirection: String = "none"   // "left", "center", "right", "none"
    @Published var pathClear: Bool = true
    @Published var leftZoneDistance: Float = 999
    @Published var centerZoneDistance: Float = 999
    @Published var rightZoneDistance: Float = 999

    // LiDAR-only stair detection (independent of YOLO — safety fallback)
    @Published var lidarStairsDetected: Bool = false
    @Published var lidarStairCount: Int = 0
    @Published var lidarStairDirection: StairDirection = .unknown
    @Published var lidarStairDistance: Float = 999

    // LiDAR drop-off detection (curbs, step-downs, platform edges)
    @Published var dropOffDetected: Bool = false
    @Published var dropOffDepth: Float = 0

    // Device pitch angle (radians) — used to detect ground-facing orientation
    // 0 = horizontal, -π/2 = straight down at ground, π/2 = straight up
    @Published var devicePitch: Float = 0
    @Published var isPhonePointingAtGround: Bool = false  // true when pitch > ~60° downward

    private var lastLiDARStairTime: TimeInterval = 0
    private let lidarStairInterval: TimeInterval = 0.3  // Check stairs every 300ms

    let arSession = ARSession()
    private var hapticTimer: Timer?

    // CoreHaptics engine
    private var hapticEngine: CHHapticEngine?
    private var continuousPlayer: CHHapticAdvancedPatternPlayer?
    private var engineRunning = false

    // Frame throttling — skip frames to avoid overwhelming the main thread
    private let depthQueue = DispatchQueue(label: "depthAnalysis", qos: .userInitiated)
    private var lastDepthAnalysisTime: TimeInterval = 0
    private let depthAnalysisInterval: TimeInterval = 0.2  // Max 5 depth analyses per second (saves CPU)
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
        stopHaptics()
        DispatchQueue.main.async {
            self.isSessionRunning = false
            self.currentFrame = nil
            self.currentDepthData = nil
            self.stairStepCount = 0
            self.nearestObstacleDistance = 999
            self.averageDepthInFOV = 999
            self.obstacleInFOV = false
            self.obstacleDirection = "none"
            self.pathClear = true
            self.leftZoneDistance = 999
            self.centerZoneDistance = 999
            self.rightZoneDistance = 999
            self.lidarStairsDetected = false
            self.lidarStairCount = 0
            self.lidarStairDirection = .unknown
            self.lidarStairDistance = 999
            self.dropOffDetected = false
            self.dropOffDepth = 0
            self.devicePitch = 0
            self.isPhonePointingAtGround = false
        }
    }

    // MARK: - Three-Zone Depth Analysis with Side Margins
    /// Divides the analysis area into left-margin / center-passage / right-margin zones.
    /// The center zone matches the FOV box (human passage width).
    /// Left/right margin zones extend beyond the FOV box to detect incoming obstacles.
    private func analyzeDepthInFOVBox(_ depthData: ARDepthData) {
        let depthMap = depthData.depthMap
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
        guard let base = CVPixelBufferGetBaseAddress(depthMap) else { return }

        let fovBox = fovBoxNormalized
        let margin = fovConfig.sideMarginRatio

        // Center zone = FOV box (human passage area)
        let centerStartX = Int(fovBox.minX * CGFloat(width))
        let centerEndX = Int(fovBox.maxX * CGFloat(width))
        let startY = Int(fovBox.minY * CGFloat(height))
        let endY = Int(fovBox.maxY * CGFloat(height))

        // Extended bounds: left/right margins for incoming obstacle detection
        let extStartX = max(0, Int((fovBox.minX - margin) * CGFloat(width)))
        let extEndX = min(width, Int((fovBox.maxX + margin) * CGFloat(width)))

        var minDistLeft: Float = 999, minDistCenter: Float = 999, minDistRight: Float = 999
        var totalDepth: Float = 0, validCount: Float = 0
        var overallMin: Float = 999

        let stepSize = 3
        for y in stride(from: startY, to: endY, by: stepSize) {
            for x in stride(from: extStartX, to: extEndX, by: stepSize) {
                guard x >= 0, x < width, y >= 0, y < height else { continue }
                let ptr = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: Float32.self)
                let depth = ptr[x]

                if depth.isFinite && depth > 0.1 && depth < 6.0 {
                    totalDepth += depth
                    validCount += 1

                    // Classify: left margin / center passage / right margin
                    if x < centerStartX {
                        // Left margin zone — incoming obstacles from left
                        minDistLeft = min(minDistLeft, depth)
                    } else if x >= centerEndX {
                        // Right margin zone — incoming obstacles from right
                        minDistRight = min(minDistRight, depth)
                    } else {
                        // Center zone — direct path obstacles
                        minDistCenter = min(minDistCenter, depth)
                        overallMin = min(overallMin, depth)
                    }
                }
            }
        }

        // Overall minimum considers center (passage) zone primarily,
        // but also triggers if side obstacles are very close
        let sideMin = min(minDistLeft, minDistRight)
        if sideMin < 1.5 { overallMin = min(overallMin, sideMin) }

        let avgDepth = validCount > 0 ? totalDepth / validCount : 999

        // Determine obstacle state based on center passage zone
        let warningThreshold: Float = 3.0
        let hasObstacle = overallMin < warningThreshold || sideMin < 2.0
        let isPathClear = minDistCenter >= warningThreshold && sideMin >= 2.5

        // Determine primary obstacle direction
        let direction: String
        if minDistCenter < warningThreshold && minDistCenter <= sideMin {
            direction = "center"
        } else if minDistLeft < 2.0 && minDistLeft < minDistRight {
            direction = "left"
        } else if minDistRight < 2.0 && minDistRight < minDistLeft {
            direction = "right"
        } else if minDistCenter < warningThreshold {
            direction = "center"
        } else {
            direction = "none"
        }

        DispatchQueue.main.async {
            self.nearestObstacleDistance = overallMin
            self.averageDepthInFOV = avgDepth
            self.leftZoneDistance = minDistLeft
            self.centerZoneDistance = minDistCenter
            self.rightZoneDistance = minDistRight
            self.obstacleInFOV = hasObstacle
            self.obstacleDirection = direction
            self.pathClear = isPathClear
            self.updateHaptics(forDistance: overallMin)
        }
    }

    // MARK: - Stair Direction Detection (Phase 2)
    /// Determines whether stairs are going up or down by comparing depth in top vs bottom
    /// of the YOLO bounding box. Called only after YOLO confirms stairs.
    func determineStairDirection(boundingBox: CGRect, depthData: ARDepthData?) -> StairDirection {
        guard let depthData = depthData else { return .unknown }

        let depthMap = depthData.depthMap
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
        guard let base = CVPixelBufferGetBaseAddress(depthMap) else { return .unknown }

        let centerX = Int(boundingBox.midX * CGFloat(width))
        // Vision bounding box: origin bottom-left, y up
        let topY = Int((1.0 - boundingBox.maxY) * CGFloat(height))
        let bottomY = Int((1.0 - boundingBox.minY) * CGFloat(height))

        guard topY < bottomY, centerX >= 0, centerX < width else { return .unknown }

        let thirdHeight = (bottomY - topY) / 3
        var topSum: Float = 0, topCount: Float = 0
        var bottomSum: Float = 0, bottomCount: Float = 0

        let sampleWidth = max(1, Int(boundingBox.width * CGFloat(width) * 0.2))
        let xStart = max(0, centerX - sampleWidth / 2)
        let xEnd = min(width, centerX + sampleWidth / 2)

        for y in topY..<(topY + thirdHeight) {
            guard y >= 0, y < height else { continue }
            let ptr = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: Float32.self)
            for x in stride(from: xStart, to: xEnd, by: 2) {
                let d = ptr[x]
                if d.isFinite && d > 0.1 && d < 8.0 {
                    topSum += d; topCount += 1
                }
            }
        }

        for y in (bottomY - thirdHeight)..<bottomY {
            guard y >= 0, y < height else { continue }
            let ptr = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: Float32.self)
            for x in stride(from: xStart, to: xEnd, by: 2) {
                let d = ptr[x]
                if d.isFinite && d > 0.1 && d < 8.0 {
                    bottomSum += d; bottomCount += 1
                }
            }
        }

        guard topCount > 0, bottomCount > 0 else { return .unknown }

        let topAvg = topSum / topCount
        let bottomAvg = bottomSum / bottomCount

        // Top deeper = stairs going up (ascending away from user)
        // Bottom deeper = stairs going down (descending away from user)
        let depthDifference = topAvg - bottomAvg
        let threshold: Float = 0.15

        if depthDifference > threshold {
            return .up
        } else if depthDifference < -threshold {
            return .down
        }
        return .unknown
    }

    // MARK: - LiDAR-Only Stair Detection (YOLO-independent safety fallback)
    /// Detects stairs using LiDAR depth patterns in the bottom portion of FOV.
    /// Looks for regular depth step transitions across multiple vertical strips.
    /// This runs independently of YOLO as a critical safety backup.
    private func detectStairsFromLiDAR(_ depthData: ARDepthData) {
        let depthMap = depthData.depthMap
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
        guard let base = CVPixelBufferGetBaseAddress(depthMap) else { return }

        let fovBox = fovBoxNormalized

        // Focus on bottom 50% of FOV (where stairs would appear in camera)
        let startY = Int((fovBox.minY + fovBox.height * 0.5) * CGFloat(height))
        let endY = Int(fovBox.maxY * CGFloat(height))
        let startX = Int(fovBox.minX * CGFloat(width))
        let endX = Int(fovBox.maxX * CGFloat(width))

        guard endY > startY + 5, endX > startX + 5 else { return }

        let fovWidth = endX - startX
        let stripPositions = [startX + fovWidth / 5, startX + 2 * fovWidth / 5,
                              startX + fovWidth / 2, startX + 3 * fovWidth / 5,
                              startX + 4 * fovWidth / 5]

        var stripsWithStairs = 0
        var totalSteps = 0
        var nearestStairDepth: Float = 999

        for stripX in stripPositions {
            guard stripX >= 0, stripX < width else { continue }

            // Sample depth profile along this vertical strip
            var profile: [Float] = []
            let stepSize = max(1, (endY - startY) / 25)

            for y in stride(from: startY, to: endY, by: stepSize) {
                guard y >= 0, y < height else { continue }
                let ptr = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: Float32.self)
                let d = ptr[stripX]
                if d.isFinite && d > 0.1 && d < 5.0 {
                    profile.append(d)
                }
            }

            guard profile.count >= 4 else { continue }

            // Smooth with 3-point average
            var smoothed: [Float] = []
            for i in 0..<profile.count {
                let s = max(0, i - 1)
                let e = min(profile.count - 1, i + 1)
                smoothed.append(profile[s...e].reduce(0, +) / Float(e - s + 1))
            }

            // Count regular depth transitions (step = 12-25cm)
            var steps = 0
            var lastIdx = -2
            for i in 1..<smoothed.count {
                let change = abs(smoothed[i] - smoothed[i - 1])
                if change >= 0.10 && change <= 0.28 && (i - lastIdx) >= 2 {
                    steps += 1
                    lastIdx = i
                    nearestStairDepth = min(nearestStairDepth, smoothed[i])
                }
            }

            if steps >= 2 {
                stripsWithStairs += 1
                totalSteps = max(totalSteps, steps)
            }
        }

        // Confirm stairs if majority of strips detect step pattern
        let detected = stripsWithStairs >= 3

        // Determine direction from depth gradient
        var direction: StairDirection = .unknown
        if detected {
            let midX = (startX + endX) / 2
            let topY = startY
            let botY = endY - 1
            guard topY >= 0, topY < height, botY >= 0, botY < height, midX >= 0, midX < width else {
                direction = .unknown
                DispatchQueue.main.async {
                    self.lidarStairsDetected = detected
                    self.lidarStairCount = totalSteps
                    self.lidarStairDirection = direction
                    self.lidarStairDistance = nearestStairDepth
                }
                return
            }
            let topD = base.advanced(by: topY * bytesPerRow).assumingMemoryBound(to: Float32.self)[midX]
            let botD = base.advanced(by: botY * bytesPerRow).assumingMemoryBound(to: Float32.self)[midX]
            if topD.isFinite && botD.isFinite {
                let diff = topD - botD
                if diff > 0.15 { direction = .up }
                else if diff < -0.15 { direction = .down }
            }
        }

        DispatchQueue.main.async {
            self.lidarStairsDetected = detected
            self.lidarStairCount = totalSteps
            self.lidarStairDirection = direction
            self.lidarStairDistance = nearestStairDepth
        }
    }

    // MARK: - LiDAR Drop-off Detection (curbs, step-downs, platform edges)
    /// Detects sudden depth increases at the bottom of FOV indicating a drop-off.
    /// Critical safety feature for blind users to avoid falls.
    private func detectDropOff(_ depthData: ARDepthData) {
        let depthMap = depthData.depthMap
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
        guard let base = CVPixelBufferGetBaseAddress(depthMap) else { return }

        let fovBox = fovBoxNormalized

        // Compare depth at bottom 15% vs 30-45% of FOV
        let bottomY = Int(fovBox.maxY * CGFloat(height)) - 2
        let midY = Int((fovBox.minY + fovBox.height * 0.6) * CGFloat(height))
        let startX = Int(fovBox.minX * CGFloat(width))
        let endX = Int(fovBox.maxX * CGFloat(width))

        guard bottomY > midY, endX > startX else { return }

        var bottomSum: Float = 0, bottomCount: Float = 0
        var midSum: Float = 0, midCount: Float = 0
        let stepX = max(1, (endX - startX) / 10)

        for x in stride(from: startX, to: endX, by: stepX) {
            guard x >= 0, x < width else { continue }

            if bottomY >= 0, bottomY < height {
                let d = base.advanced(by: bottomY * bytesPerRow).assumingMemoryBound(to: Float32.self)[x]
                if d.isFinite && d > 0.1 && d < 8.0 { bottomSum += d; bottomCount += 1 }
            }
            if midY >= 0, midY < height {
                let d = base.advanced(by: midY * bytesPerRow).assumingMemoryBound(to: Float32.self)[x]
                if d.isFinite && d > 0.1 && d < 8.0 { midSum += d; midCount += 1 }
            }
        }

        guard bottomCount > 2, midCount > 2 else { return }

        let bottomAvg = bottomSum / bottomCount
        let midAvg = midSum / midCount

        // Drop-off: bottom depth is significantly deeper than mid (ground drops away)
        let depthDiff = bottomAvg - midAvg
        let detected = depthDiff > 0.35  // >35cm depth change = drop-off

        DispatchQueue.main.async {
            self.dropOffDetected = detected
            self.dropOffDepth = max(0, depthDiff)
        }
    }
}

// MARK: - ARSessionDelegate
extension NavigationCameraManager: ARSessionDelegate {
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let buffer = frame.capturedImage
        let depth = frame.smoothedSceneDepth ?? frame.sceneDepth

        // Extract device pitch from camera transform (eulerAngles.x)
        // In ARKit portrait mode: ~0 = phone upright, large negative = pointing at ground
        let pitch = frame.camera.eulerAngles.x  // radians
        // Phone is "pointing at ground" when tilted more than ~55° downward from horizontal
        // In portrait mode with camera facing away, pitch < -0.95 rad ≈ phone looking at floor
        let pointingAtGround = pitch < -0.95  // ~55 degrees below horizontal

        // Throttle depth analysis on a background queue
        if let d = depth, !isAnalyzingDepth {
            let now = frame.timestamp
            if now - lastDepthAnalysisTime >= depthAnalysisInterval {
                lastDepthAnalysisTime = now
                isAnalyzingDepth = true
                depthQueue.async { [weak self] in
                    guard let self = self else { return }
                    self.analyzeDepthInFOVBox(d)

                    // Run LiDAR stair + drop-off detection at lower frequency (every 300ms)
                    if now - self.lastLiDARStairTime >= self.lidarStairInterval {
                        self.lastLiDARStairTime = now
                        self.detectStairsFromLiDAR(d)
                        self.detectDropOff(d)
                    }

                    self.isAnalyzingDepth = false
                }
            }
        }

        DispatchQueue.main.async {
            self.currentFrame = buffer
            self.currentDepthData = depth
            self.devicePitch = pitch
            self.isPhonePointingAtGround = pointingAtGround
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
