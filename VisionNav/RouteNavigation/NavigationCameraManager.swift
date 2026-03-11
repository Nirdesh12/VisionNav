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

// MARK: - Spatial Map (2D Polar Occupancy Grid from ARKit Mesh Reconstruction)
/// Builds a persistent 2D occupancy grid around the user from ARMeshAnchor data,
/// similar to how a robotic vacuum maps a room. Tracks obstacle positions in angular
/// sectors at varying distances, surviving across frames even when obstacles leave the FOV.
class SpatialMap {
    /// Number of angular sectors (360° / sectorCount). 12 sectors = 30° each.
    let sectorCount: Int = 12
    /// Distance rings in meters from the user. Each ring is 1m wide.
    let maxDistance: Float = 5.0
    let ringWidth: Float = 0.5
    /// Grid: [sector][ring] = minimum obstacle distance within that cell.
    /// 999 = no obstacle detected. Lower = closer obstacle.
    private(set) var grid: [[Float]]
    /// Timestamp of last update per sector (for decay)
    private var sectorTimestamps: [TimeInterval]
    /// How quickly old data decays (seconds). After this, unrefreshed cells reset.
    let decayInterval: TimeInterval = 3.0

    var ringCount: Int { Int(maxDistance / ringWidth) }

    init() {
        let rings = Int(5.0 / 0.5)  // 10 rings
        grid = Array(repeating: Array(repeating: Float(999), count: rings), count: 12)
        sectorTimestamps = Array(repeating: 0, count: 12)
    }

    /// Clears the entire map.
    func reset() {
        let rings = ringCount
        grid = Array(repeating: Array(repeating: Float(999), count: rings), count: sectorCount)
        sectorTimestamps = Array(repeating: 0, count: sectorCount)
    }

    /// Updates the map from an ARMeshAnchor's geometry, projected relative to the user's current position.
    /// - Parameters:
    ///   - anchor: The mesh anchor containing 3D vertex data
    ///   - cameraTransform: The current camera (user) transform from ARFrame
    ///   - timestamp: Frame timestamp for decay tracking
    func updateFromMesh(_ anchor: ARMeshAnchor, cameraTransform: simd_float4x4, timestamp: TimeInterval) {
        let meshTransform = anchor.transform
        let geometry = anchor.geometry
        let vertexBuffer = geometry.vertices
        let vertexCount = vertexBuffer.count

        // User position in world coordinates
        let userPos = simd_float3(cameraTransform.columns.3.x,
                                   cameraTransform.columns.3.y,
                                   cameraTransform.columns.3.z)

        // User forward direction (negative Z in camera space, projected to XZ plane)
        let forward = simd_float3(-cameraTransform.columns.2.x,
                                    0,
                                    -cameraTransform.columns.2.z)
        let forwardNorm = simd_normalize(forward)
        // User's yaw angle (heading on XZ plane)
        let userYaw = atan2(forwardNorm.x, forwardNorm.z)

        // Sample vertices (stride for performance — every 4th vertex)
        let stride = max(1, vertexCount / 200)

        for i in Swift.stride(from: 0, to: vertexCount, by: stride) {
            // Read vertex position in mesh-local space
            let vertexPointer = vertexBuffer.buffer.contents()
                .advanced(by: vertexBuffer.offset + i * vertexBuffer.stride)
            let localPos = vertexPointer.assumingMemoryBound(to: SIMD3<Float>.self).pointee

            // Transform to world space
            let worldPos4 = meshTransform * simd_float4(localPos.x, localPos.y, localPos.z, 1.0)
            let worldPos = simd_float3(worldPos4.x, worldPos4.y, worldPos4.z)

            // Vector from user to vertex (on XZ ground plane)
            let dx = worldPos.x - userPos.x
            let dz = worldPos.z - userPos.z
            let dist = sqrt(dx * dx + dz * dz)

            // Filter: ignore vertices too far or too close, or significantly above/below user height
            let heightDiff = worldPos.y - userPos.y
            if dist > maxDistance || dist < 0.1 { continue }
            if heightDiff > 2.0 || heightDiff < -0.5 { continue }  // Only obstacles at walkable height

            // Angle from user to vertex relative to user's forward direction
            let vertexAngle = atan2(dx, dz)
            var relAngle = vertexAngle - userYaw
            // Normalize to [0, 2π)
            if relAngle < 0 { relAngle += 2 * .pi }
            if relAngle >= 2 * .pi { relAngle -= 2 * .pi }

            // Map to sector and ring
            let sector = Int(relAngle / (2 * .pi) * Float(sectorCount)) % sectorCount
            let ring = min(Int(dist / ringWidth), ringCount - 1)

            // Update grid with minimum distance
            grid[sector][ring] = min(grid[sector][ring], dist)
            sectorTimestamps[sector] = timestamp
        }
    }

    /// Decays old sectors that haven't been updated recently.
    func decayOldData(currentTimestamp: TimeInterval) {
        for sector in 0..<sectorCount {
            if currentTimestamp - sectorTimestamps[sector] > decayInterval {
                for ring in 0..<ringCount {
                    grid[sector][ring] = 999
                }
            }
        }
    }

    /// Returns the nearest obstacle distance in a given angular range (in sectors relative to forward).
    /// Sector 0 = directly ahead, sectorCount/4 = right 90°, etc.
    func nearestInSectors(_ sectorRange: Range<Int>) -> Float {
        var nearest: Float = 999
        for s in sectorRange {
            let sector = ((s % sectorCount) + sectorCount) % sectorCount
            for ring in 0..<ringCount {
                nearest = min(nearest, grid[sector][ring])
            }
        }
        return nearest
    }

    /// Returns the nearest obstacle in the front-left quadrant (sectors to the left of forward).
    var nearestFrontLeft: Float {
        // Sectors covering roughly -90° to 0° (left of forward)
        // With 12 sectors: sector 0 = ahead, sectors 9-11 = left side
        let quarterCount = sectorCount / 4
        return nearestInSectors((sectorCount - quarterCount)..<sectorCount)
    }

    /// Returns the nearest obstacle in the front-right quadrant.
    var nearestFrontRight: Float {
        // Sectors covering roughly 0° to +90° (right of forward)
        let quarterCount = sectorCount / 4
        return nearestInSectors(1..<(1 + quarterCount))
    }

    /// Returns the nearest obstacle directly ahead (narrow cone).
    var nearestAhead: Float {
        // Sector 0 = directly ahead, plus the two adjacent sectors
        let ahead = grid[0].min() ?? 999
        let slightLeft = grid[sectorCount - 1].min() ?? 999
        let slightRight = grid[1].min() ?? 999
        return min(ahead, min(slightLeft, slightRight))
    }

    /// Returns a summary of spatial awareness: which direction has the closest obstacle.
    var dominantObstacleDirection: HapticDirection {
        let left = nearestFrontLeft
        let right = nearestFrontRight
        let ahead = nearestAhead

        // No obstacle within range
        if ahead > maxDistance && left > maxDistance && right > maxDistance {
            return .none
        }

        // Ahead is closest
        if ahead <= left && ahead <= right && ahead < maxDistance {
            return .center
        }
        // Left is closest
        if left < right && left < maxDistance {
            return .left
        }
        // Right is closest
        if right < maxDistance {
            return .right
        }
        return .none
    }
}

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

// MARK: - Haptic Direction
/// Encodes obstacle direction for directional haptic feedback via sharpness differentiation.
public enum HapticDirection: String {
    case left = "left"
    case center = "center"
    case right = "right"
    case none = "none"

    /// CoreHaptics sharpness value: low = dull/soft ("left feel"), high = crisp/sharp ("right feel")
    var sharpnessValue: Float {
        switch self {
        case .left:   return 0.3   // Soft, rounded vibration
        case .center: return 0.5   // Neutral mid-range
        case .right:  return 0.8   // Sharp, crisp vibration
        case .none:   return 0.0
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

    // Obstacle spatial data (updated by LiDAR at 5Hz)
    @Published var obstacleInFOV: Bool = false
    @Published var obstacleDirection: String = "none"   // "left", "center", "right", "none"
    @Published var pathClear: Bool = true
    @Published var leftZoneDistance: Float = 999
    @Published var centerZoneDistance: Float = 999
    @Published var rightZoneDistance: Float = 999
    // 5-zone spatial awareness (finer granularity for directional haptics)
    @Published var farLeftZoneDistance: Float = 999
    @Published var farRightZoneDistance: Float = 999

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

    // Spatial map built from ARKit mesh reconstruction (like robotic vacuum mapping)
    let spatialMap = SpatialMap()
    private var lastSpatialMapUpdate: TimeInterval = 0
    private let spatialMapInterval: TimeInterval = 0.5  // Update map every 500ms
    private var lastCameraTransform: simd_float4x4 = matrix_identity_float4x4

    let arSession = ARSession()
    private var hapticTimer: Timer?

    // CoreHaptics engine
    private var hapticEngine: CHHapticEngine?
    private var continuousPlayer: CHHapticAdvancedPatternPlayer?
    private var engineRunning = false
    private var currentHapticDirection: HapticDirection = .none

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
        currentHapticDirection = .none
    }

    // MARK: - Directional Haptic Feedback (Sharpness Differentiation)

    /// Updates haptics with both distance-based intensity and direction-based sharpness.
    /// Left obstacles produce a soft/dull vibration; right obstacles produce a sharp/crisp vibration.
    func updateDirectionalHaptics(forDistance distance: Float, direction: HapticDirection) {
        let newProximity: ProximityLevel
        if distance < 0.5 { newProximity = .veryHigh }
        else if distance < 1.0 { newProximity = .high }
        else if distance < 2.0 { newProximity = .medium }
        else if distance < 3.0 { newProximity = .low }
        else if distance < 4.0 { newProximity = .veryLow }
        else { newProximity = .none }

        // Only update if proximity or direction changed
        guard newProximity != currentProximity || direction != currentHapticDirection else { return }

        currentProximity = newProximity
        currentHapticDirection = direction
        nearestObstacleDistance = distance

        playDirectionalHaptic(proximity: newProximity, direction: direction)
    }

    private func playDirectionalHaptic(proximity: ProximityLevel, direction: HapticDirection) {
        hapticTimer?.invalidate()
        hapticTimer = nil

        guard proximity != .none, direction != .none else {
            stopContinuousHaptic()
            return
        }

        if engineRunning, let engine = hapticEngine {
            playCoreDirectionalPattern(engine: engine, proximity: proximity, direction: direction)
        } else {
            // Fallback: legacy haptic (no direction encoding possible)
            startLegacyHapticPattern(for: proximity)
        }
    }

    /// Builds a CoreHaptics pattern where direction is encoded through sharpness:
    /// - Left obstacle: sharpness 0.3 (soft/dull feel)
    /// - Right obstacle: sharpness 0.8 (sharp/crisp feel)
    /// - Center obstacle: sharpness 0.5 (neutral) with tighter pulse interval
    private func playCoreDirectionalPattern(engine: CHHapticEngine, proximity: ProximityLevel, direction: HapticDirection) {
        stopContinuousHaptic()

        // At very high proximity (<0.5m), override to center/urgent feel
        let effectiveDirection = proximity == .veryHigh ? HapticDirection.center : direction

        let intensity = CHHapticEventParameter(
            parameterID: .hapticIntensity, value: proximity.hapticIntensity
        )
        let sharpness = CHHapticEventParameter(
            parameterID: .hapticSharpness, value: effectiveDirection.sharpnessValue
        )

        var events: [CHHapticEvent] = []
        var interval = proximity.hapticInterval
        // Center obstacles get a slightly tighter interval for urgency
        if effectiveDirection == .center {
            interval = max(0.04, interval * 0.8)
        }
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
            startLegacyHapticPattern(for: proximity)
        }
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

        // Enable mesh-based scene reconstruction for spatial mapping (LiDAR devices only)
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
        }

        arSession.delegate = self
        arSession.run(config, options: [.resetTracking])
        spatialMap.reset()
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
            self.farLeftZoneDistance = 999
            self.farRightZoneDistance = 999
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

    // MARK: - Five-Zone Depth Analysis with Spatial Awareness
    /// Divides the analysis area into 5 zones for fine-grained spatial awareness:
    /// farLeft / left / center / right / farRight
    /// The center zone matches the FOV box (human passage width).
    /// Left/right are inner halves of the margin; farLeft/farRight are outer halves.
    /// This enables directional haptic feedback based on obstacle position.
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

        // 5-zone boundaries: split each margin into inner and outer halves
        let leftMarginMid = (extStartX + centerStartX) / 2
        let rightMarginMid = (centerEndX + extEndX) / 2

        var minDistFarLeft: Float = 999, minDistLeft: Float = 999
        var minDistCenter: Float = 999
        var minDistRight: Float = 999, minDistFarRight: Float = 999
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

                    // Classify into 5 zones
                    if x < leftMarginMid {
                        minDistFarLeft = min(minDistFarLeft, depth)
                    } else if x < centerStartX {
                        minDistLeft = min(minDistLeft, depth)
                    } else if x < centerEndX {
                        minDistCenter = min(minDistCenter, depth)
                        overallMin = min(overallMin, depth)
                    } else if x < rightMarginMid {
                        minDistRight = min(minDistRight, depth)
                    } else {
                        minDistFarRight = min(minDistFarRight, depth)
                    }
                }
            }
        }

        // Combined left/right distances (backward-compatible with 3-zone consumers)
        let combinedLeft = min(minDistFarLeft, minDistLeft)
        let combinedRight = min(minDistRight, minDistFarRight)

        // Overall minimum considers center zone primarily,
        // but also triggers if side obstacles are very close
        let sideMin = min(combinedLeft, combinedRight)
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
        } else if combinedLeft < 2.0 && combinedLeft < combinedRight {
            direction = "left"
        } else if combinedRight < 2.0 && combinedRight < combinedLeft {
            direction = "right"
        } else if minDistCenter < warningThreshold {
            direction = "center"
        } else {
            direction = "none"
        }

        DispatchQueue.main.async {
            self.nearestObstacleDistance = overallMin
            self.averageDepthInFOV = avgDepth
            self.leftZoneDistance = combinedLeft
            self.centerZoneDistance = minDistCenter
            self.rightZoneDistance = combinedRight
            self.farLeftZoneDistance = minDistFarLeft
            self.farRightZoneDistance = minDistFarRight
            self.obstacleInFOV = hasObstacle
            self.obstacleDirection = direction
            self.pathClear = isPathClear
            self.updateHaptics(forDistance: overallMin)
        }
    }

    // MARK: - Stair Direction Detection (Depth Curve Analysis)
    /// Determines whether stairs go UP or DOWN by analyzing the SHAPE of the depth curve,
    /// not just comparing top-vs-bottom depth values.
    ///
    /// Key insight: LiDAR depth measures distance-from-camera, not elevation. For both up
    /// and down stairs, the far end is deeper. But the depth curve SHAPE differs:
    ///   - Stairs going UP (convex curve): depth increases slowly near (treads face camera),
    ///     then rapidly far (risers recede). farToMid > midToNear → positive curvature.
    ///   - Stairs going DOWN (concave curve): depth increases rapidly near (risers drop away),
    ///     then slowly far (treads are nearly perpendicular). midToNear > farToMid → negative curvature.
    ///
    /// Uses device pitch as tiebreaker when curvature is ambiguous.
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
        // In screen/image buffer: topY = far from user, bottomY = near to user
        let topY = Int((1.0 - boundingBox.maxY) * CGFloat(height))   // far end
        let bottomY = Int((1.0 - boundingBox.minY) * CGFloat(height)) // near end

        guard topY < bottomY, centerX >= 0, centerX < width else { return .unknown }

        let sampleWidth = max(1, Int(boundingBox.width * CGFloat(width) * 0.3))
        let xStart = max(0, centerX - sampleWidth / 2)
        let xEnd = min(width, centerX + sampleWidth / 2)

        // Sample 5 depth rows evenly: depthProfile[0] = far end, depthProfile[last] = near end
        let totalRows = bottomY - topY
        guard totalRows > 10 else { return .unknown }

        var depthProfile: [Float] = []
        let numSamples = 5
        for i in 0..<numSamples {
            let y = topY + (i * totalRows) / (numSamples - 1)
            guard y >= 0, y < height else { continue }

            var sum: Float = 0
            var count: Float = 0
            let ptr = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: Float32.self)
            for x in stride(from: xStart, to: xEnd, by: 2) {
                guard x >= 0, x < width else { continue }
                let d = ptr[x]
                if d.isFinite && d > 0.1 && d < 8.0 {
                    sum += d; count += 1
                }
            }
            if count > 0 {
                depthProfile.append(sum / count)
            }
        }

        guard depthProfile.count >= 3 else { return .unknown }

        // Analyze depth curve shape using curvature
        let farDepth = depthProfile[0]                           // far end (top of bbox)
        let midDepth = depthProfile[depthProfile.count / 2]      // middle
        let nearDepth = depthProfile[depthProfile.count - 1]     // near end (bottom of bbox)

        let farToMid = farDepth - midDepth
        let midToNear = midDepth - nearDepth
        let curvature = farToMid - midToNear

        // Convex (curvature > threshold) = UP, Concave (curvature < -threshold) = DOWN
        let curveThreshold: Float = 0.06
        if curvature > curveThreshold {
            return .up
        } else if curvature < -curveThreshold {
            return .down
        }

        // Tiebreaker: device pitch (from ARFrame.camera.eulerAngles.x)
        // Looking down (pitch < -0.4 rad ≈ 23° below horizontal) → more likely DOWN
        // Looking forward/up (pitch > -0.15 rad) → more likely UP
        if devicePitch < -0.4 {
            return .down
        } else if devicePitch > -0.15 {
            return .up
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

        // Determine direction using depth curve analysis (same logic as YOLO-confirmed path)
        var direction: StairDirection = .unknown
        if detected {
            let midX = (startX + endX) / 2
            guard midX >= 0, midX < width else {
                DispatchQueue.main.async {
                    self.lidarStairsDetected = detected
                    self.lidarStairCount = totalSteps
                    self.lidarStairDirection = direction
                    self.lidarStairDistance = nearestStairDepth
                }
                return
            }
            // Sample 3 depth points: top (far), mid, bottom (near)
            let midY = (startY + endY) / 2
            let topSampleY = max(0, min(startY, height - 1))
            let midSampleY = max(0, min(midY, height - 1))
            let botSampleY = max(0, min(endY - 1, height - 1))

            let topD = base.advanced(by: topSampleY * bytesPerRow).assumingMemoryBound(to: Float32.self)[midX]
            let midD = base.advanced(by: midSampleY * bytesPerRow).assumingMemoryBound(to: Float32.self)[midX]
            let botD = base.advanced(by: botSampleY * bytesPerRow).assumingMemoryBound(to: Float32.self)[midX]

            if topD.isFinite && midD.isFinite && botD.isFinite {
                // Curvature analysis: convex = UP, concave = DOWN
                let curvature = (topD - midD) - (midD - botD)
                if curvature > 0.06 { direction = .up }
                else if curvature < -0.06 { direction = .down }
                // Tiebreaker: device pitch
                else if devicePitch < -0.4 { direction = .down }
                else if devicePitch > -0.15 { direction = .up }
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

        // Store camera transform for spatial map processing
        lastCameraTransform = frame.camera.transform

        // Extract device pitch from camera transform (eulerAngles.x)
        // In ARKit portrait mode: ~0 = phone upright, large negative = pointing at ground
        let pitch = frame.camera.eulerAngles.x  // radians
        // Phone is "pointing at ground" when tilted more than ~55° downward from horizontal
        // In portrait mode with camera facing away, pitch < -0.95 rad ≈ phone looking at floor
        let pointingAtGround = pitch < -0.95  // ~55 degrees below horizontal

        let now = frame.timestamp

        // Throttle depth analysis on a background queue
        if let d = depth, !isAnalyzingDepth {
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

        // Decay old spatial map data periodically
        if now - lastSpatialMapUpdate >= spatialMapInterval {
            lastSpatialMapUpdate = now
            depthQueue.async { [weak self] in
                self?.spatialMap.decayOldData(currentTimestamp: now)
            }
        }

        DispatchQueue.main.async {
            self.currentFrame = buffer
            self.currentDepthData = depth
            self.devicePitch = pitch
            self.isPhonePointingAtGround = pointingAtGround
        }
    }

    // Process new mesh anchors from scene reconstruction
    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        processMeshAnchors(anchors)
    }

    // Process updated mesh anchors as the scene is refined
    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        processMeshAnchors(anchors)
    }

    private func processMeshAnchors(_ anchors: [ARAnchor]) {
        let cameraTransform = lastCameraTransform
        let timestamp = CACurrentMediaTime()

        depthQueue.async { [weak self] in
            guard let self = self else { return }
            for anchor in anchors {
                guard let meshAnchor = anchor as? ARMeshAnchor else { continue }
                self.spatialMap.updateFromMesh(meshAnchor, cameraTransform: cameraTransform, timestamp: timestamp)
            }
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
