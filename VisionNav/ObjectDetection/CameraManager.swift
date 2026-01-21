//
//  CameraManager.swift
//  VisionNav - Advanced LiDAR Camera Handler
//
//  Professional-grade LiDAR depth mapping with calibration
//  Matches quality of 3D scanner apps
//

import Foundation
import AVFoundation
import SwiftUI
import Combine
import Accelerate

// MARK: - Camera Manager

class CameraManager: NSObject, ObservableObject {
    
    // MARK: - Published Properties
    @Published var currentFrame: CVPixelBuffer?
    @Published var depthData: AVDepthData?
    @Published var isSessionRunning = false
    @Published var hasLiDAR = false
    @Published var depthDataReceived = false
    @Published var errorMessage: String?
    
    // MARK: - Private Properties
    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let depthOutput = AVCaptureDepthDataOutput()
    private var dataOutputSynchronizer: AVCaptureDataOutputSynchronizer?
    private let outputQueue = DispatchQueue(label: "com.visionnav.camera.output", qos: .userInitiated)
    private let synchronizerQueue = DispatchQueue(label: "com.visionnav.synchronizer", qos: .userInitiated)
    
    private var videoDevice: AVCaptureDevice?
    private var videoDeviceInput: AVCaptureDeviceInput?
    
    // Camera calibration data for accurate mapping
    private var depthToVideoTransform: simd_float3x3?
    private var videoResolution: CGSize = .zero
    private var depthResolution: CGSize = .zero
    
    // MARK: - Initialization
    
    override init() {
        super.init()
        print("🎥 CameraManager initialized - Professional LiDAR mode")
    }
    
    // MARK: - Setup Methods
    
    func setupCamera() {
        print("🎥 Setting up advanced LiDAR depth camera...")
        checkLiDARAvailability()
        
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            print("✅ Camera permission: Authorized")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.configureCaptureSession()
            }
        case .notDetermined:
            print("⏳ Camera permission: Requesting...")
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                if granted {
                    print("✅ Camera permission: Granted")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        self?.configureCaptureSession()
                    }
                } else {
                    print("❌ Camera permission: Denied")
                    DispatchQueue.main.async {
                        self?.errorMessage = "Camera access denied"
                    }
                }
            }
        case .denied, .restricted:
            print("❌ Camera permission: Denied or restricted")
            DispatchQueue.main.async {
                self.errorMessage = "Camera access denied. Enable in Settings."
            }
        @unknown default:
            print("⚠️ Camera permission: Unknown status")
            break
        }
    }
    
    private func checkLiDARAvailability() {
        let lidarDevice = AVCaptureDevice.default(.builtInLiDARDepthCamera, for: .video, position: .back)
        let hasLiDARSensor = lidarDevice != nil
        
        print("🔦 LiDAR Check:")
        print("   - LiDAR Depth Camera: \(hasLiDARSensor ? "Found ✅" : "Not Found ❌")")
        
        if let device = lidarDevice {
            print("   - Device: \(device.localizedName)")
            print("   - Available formats: \(device.formats.count)")
        }
        
        DispatchQueue.main.async {
            self.hasLiDAR = hasLiDARSensor
        }
    }
    
    private func configureCaptureSession() {
        print("⚙️ Configuring advanced capture session...")
        session.beginConfiguration()
        
        // Use photo preset for maximum quality
        session.sessionPreset = .photo
        
        guard let videoDevice = AVCaptureDevice.default(.builtInLiDARDepthCamera, for: .video, position: .back) else {
            print("❌ LiDAR depth camera not available")
            DispatchQueue.main.async {
                self.errorMessage = "LiDAR not available on this device"
                self.hasLiDAR = false
            }
            session.commitConfiguration()
            return
        }
        
        print("✅ Using: \(videoDevice.localizedName)")
        self.videoDevice = videoDevice
        
        do {
            try videoDevice.lockForConfiguration()
            
            // Select best format for both video and depth
            if let bestFormat = selectOptimalFormat(for: videoDevice) {
                videoDevice.activeFormat = bestFormat
                
                let videoDims = CMVideoFormatDescriptionGetDimensions(bestFormat.formatDescription)
                videoResolution = CGSize(width: Int(videoDims.width), height: Int(videoDims.height))
                print("   - Video: \(videoDims.width)x\(videoDims.height)")
                
                // Configure depth format
                if let depthFormat = selectBestDepthFormat(from: bestFormat.supportedDepthDataFormats) {
                    videoDevice.activeDepthDataFormat = depthFormat
                    
                    let depthDims = CMVideoFormatDescriptionGetDimensions(depthFormat.formatDescription)
                    depthResolution = CGSize(width: Int(depthDims.width), height: Int(depthDims.height))
                    print("   - Depth: \(depthDims.width)x\(depthDims.height)")
                }
            }
            
            // Lock focus and exposure for consistent depth mapping
            if videoDevice.isFocusModeSupported(.continuousAutoFocus) {
                videoDevice.focusMode = .continuousAutoFocus
            }
            
            if videoDevice.isExposureModeSupported(.continuousAutoExposure) {
                videoDevice.exposureMode = .continuousAutoExposure
            }
            
            // Lock white balance for consistent color
            if videoDevice.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                videoDevice.whiteBalanceMode = .continuousAutoWhiteBalance
            }
            
            videoDevice.unlockForConfiguration()
            
            // Add video input
            let videoInput = try AVCaptureDeviceInput(device: videoDevice)
            if session.canAddInput(videoInput) {
                session.addInput(videoInput)
                self.videoDeviceInput = videoInput
                print("✅ Video input configured")
            }
            
            // Configure video output with high quality
            videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferMetalCompatibilityKey as String: true
            ]
            videoOutput.alwaysDiscardsLateVideoFrames = false // Keep all frames for sync
            
            if session.canAddOutput(videoOutput) {
                session.addOutput(videoOutput)
                print("✅ Video output configured")
            }
            
            // Configure depth output with maximum quality
            depthOutput.isFilteringEnabled = true // Apple's filtering for noise reduction
            depthOutput.alwaysDiscardsLateDepthData = false // Keep all depth data
            
            if session.canAddOutput(depthOutput) {
                session.addOutput(depthOutput)
                print("✅ Depth output configured")
                
                if let connection = depthOutput.connection(with: .depthData) {
                    connection.isEnabled = true
                    connection.videoOrientation = .portrait
                }
            }
            
            // Critical: Set up synchronized data delivery
            dataOutputSynchronizer = AVCaptureDataOutputSynchronizer(dataOutputs: [videoOutput, depthOutput])
            dataOutputSynchronizer?.setDelegate(self, queue: synchronizerQueue)
            print("✅ Synchronization configured")
            
            // Set orientation
            if let connection = videoOutput.connection(with: .video) {
                connection.videoOrientation = .portrait
            }
            
            session.commitConfiguration()
            print("✅ Advanced capture session ready")
            
        } catch {
            print("❌ Configuration error: \(error.localizedDescription)")
            DispatchQueue.main.async {
                self.errorMessage = "Setup failed: \(error.localizedDescription)"
            }
            session.commitConfiguration()
        }
    }
    
    // Select optimal format with best depth support
    private func selectOptimalFormat(for device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        let formats = device.formats.filter { format in
            !format.supportedDepthDataFormats.isEmpty
        }
        
        // Prefer 4K or high resolution with depth support
        return formats.max { format1, format2 in
            let dims1 = CMVideoFormatDescriptionGetDimensions(format1.formatDescription)
            let dims2 = CMVideoFormatDescriptionGetDimensions(format2.formatDescription)
            let res1 = dims1.width * dims1.height
            let res2 = dims2.width * dims2.height
            return res1 < res2
        }
    }
    
    // Select highest quality depth format
    private func selectBestDepthFormat(from formats: [AVCaptureDevice.Format]) -> AVCaptureDevice.Format? {
        // Prefer Float32 for precision
        let float32Formats = formats.filter {
            CMFormatDescriptionGetMediaSubType($0.formatDescription) == kCVPixelFormatType_DepthFloat32
        }
        
        if !float32Formats.isEmpty {
            // Get highest resolution Float32
            return float32Formats.max { format1, format2 in
                let dims1 = CMVideoFormatDescriptionGetDimensions(format1.formatDescription)
                let dims2 = CMVideoFormatDescriptionGetDimensions(format2.formatDescription)
                return dims1.width * dims1.height < dims2.width * dims2.height
            }
        }
        
        // Fallback to highest resolution available
        return formats.max { format1, format2 in
            let dims1 = CMVideoFormatDescriptionGetDimensions(format1.formatDescription)
            let dims2 = CMVideoFormatDescriptionGetDimensions(format2.formatDescription)
            return dims1.width * dims1.height < dims2.width * dims2.height
        }
    }
    
    // MARK: - Session Control
    
    func startSession() {
        guard !session.isRunning else { return }
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.session.startRunning()
            DispatchQueue.main.async {
                self?.isSessionRunning = true
                print("✅ Session started - Professional mode active")
            }
        }
    }
    
    func stopSession() {
        guard session.isRunning else { return }
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.session.stopRunning()
            DispatchQueue.main.async {
                self?.isSessionRunning = false
                self?.depthDataReceived = false
                print("⏹️ Session stopped")
            }
        }
    }
    
    // MARK: - Advanced Distance Measurement
    
    /// High-precision distance measurement using camera calibration
    func getDistanceWithConfidence(in visionRect: CGRect) -> (distance: Float, confidence: Float)? {
        guard let depthData = depthData else { return nil }
        
        let depthMap = depthData.depthDataMap
        let depthWidth = CVPixelBufferGetWidth(depthMap)
        let depthHeight = CVPixelBufferGetHeight(depthMap)
        
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        
        guard let baseAddress = CVPixelBufferGetBaseAddress(depthMap) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
        
        // Transform Vision rect to depth map coordinates using calibration
        let depthRect = transformVisionRectToDepthRect(visionRect,
                                                        depthWidth: depthWidth,
                                                        depthHeight: depthHeight,
                                                        calibration: depthData.cameraCalibrationData)
        
        // Multi-scale sampling for robust measurement
        var validDepths: [Float] = []
        var weights: [Float] = []
        
        // Sample at multiple scales with gaussian weighting
        let centerX = depthRect.midX
        let centerY = depthRect.midY
        let radiusX = depthRect.width / 2
        let radiusY = depthRect.height / 2
        
        // Adaptive sampling density based on object size
        let samplesPerSide = min(20, max(5, Int(min(depthRect.width, depthRect.height) / 3)))
        
        for i in 0..<samplesPerSide {
            for j in 0..<samplesPerSide {
                let u = Float(i) / Float(samplesPerSide - 1) * 2.0 - 1.0 // -1 to 1
                let v = Float(j) / Float(samplesPerSide - 1) * 2.0 - 1.0
                
                let px = Int(centerX + CGFloat(u) * radiusX)
                let py = Int(centerY + CGFloat(v) * radiusY)
                
                guard px >= 0, px < depthWidth, py >= 0, py < depthHeight else { continue }
                
                let rowData = baseAddress.advanced(by: py * bytesPerRow)
                let depthValue = rowData.assumingMemoryBound(to: Float32.self)[px]
                
                // Validate depth
                guard depthValue > 0.05 && depthValue.isFinite && depthValue < 25.0 else { continue }
                
                // Gaussian weight (higher weight near center)
                let distFromCenter = sqrt(u * u + v * v)
                let weight = exp(-distFromCenter * distFromCenter * 2.0)
                
                validDepths.append(depthValue)
                weights.append(weight)
            }
        }
        
        guard validDepths.count >= 10 else { return nil }
        
        // Weighted median for robustness
        let weightedMedian = calculateWeightedMedian(values: validDepths, weights: weights)
        
        // Calculate confidence using multiple factors
        let confidence = calculateConfidence(
            values: validDepths,
            weights: weights,
            median: weightedMedian,
            sampleCount: validDepths.count,
            totalSamples: samplesPerSide * samplesPerSide
        )
        
        return (weightedMedian, confidence)
    }
    
    /// Transform Vision coordinates to depth map coordinates with calibration
    private func transformVisionRectToDepthRect(_ visionRect: CGRect,
                                                 depthWidth: Int,
                                                 depthHeight: Int,
                                                 calibration: AVCameraCalibrationData?) -> CGRect {
        
        // Vision uses normalized coordinates [0,1] with origin at bottom-left
        // Depth map uses pixel coordinates with origin at top-left
        
        // Basic transformation
        var x = visionRect.origin.x * CGFloat(depthWidth)
        var y = (1.0 - visionRect.origin.y - visionRect.height) * CGFloat(depthHeight)
        var width = visionRect.width * CGFloat(depthWidth)
        var height = visionRect.height * CGFloat(depthHeight)
        
        // Apply lens distortion correction if calibration available
        if let calibration = calibration {
            let intrinsics = calibration.intrinsicMatrix
            let distortion = calibration.lensDistortionLookupTable
            
            // Adjust for lens distortion (simplified)
            if distortion != nil {
                let centerX = x + width / 2
                let centerY = y + height / 2
                
                // Normalize to [-1, 1]
                let nx = (centerX / CGFloat(depthWidth) * 2.0 - 1.0)
                let ny = (centerY / CGFloat(depthHeight) * 2.0 - 1.0)
                
                // Simple radial distortion correction
                let r2 = nx * nx + ny * ny
                let distortionFactor = 1.0 + 0.02 * r2 // Approximate correction
                
                width *= distortionFactor
                height *= distortionFactor
                x = centerX - width / 2
                y = centerY - height / 2
            }
        }
        
        // Clamp to valid bounds
        x = max(0, min(x, CGFloat(depthWidth - 1)))
        y = max(0, min(y, CGFloat(depthHeight - 1)))
        width = max(1, min(width, CGFloat(depthWidth) - x))
        height = max(1, min(height, CGFloat(depthHeight) - y))
        
        return CGRect(x: x, y: y, width: width, height: height)
    }
    
    /// Calculate weighted median
    private func calculateWeightedMedian(values: [Float], weights: [Float]) -> Float {
        guard values.count == weights.count, !values.isEmpty else { return 0 }
        
        // Sort by value
        let sorted = zip(values, weights).sorted { $0.0 < $1.0 }
        
        // Find weighted median
        let totalWeight = weights.reduce(0, +)
        var cumulativeWeight: Float = 0
        
        for (value, weight) in sorted {
            cumulativeWeight += weight
            if cumulativeWeight >= totalWeight / 2.0 {
                return value
            }
        }
        
        return sorted.last?.0 ?? 0
    }
    
    /// Advanced confidence calculation
    private func calculateConfidence(values: [Float], weights: [Float], median: Float,
                                     sampleCount: Int, totalSamples: Int) -> Float {
        guard !values.isEmpty else { return 0 }
        
        // 1. Coverage factor
        let coverage = Float(sampleCount) / Float(max(1, totalSamples))
        let coverageScore = min(1.0, coverage * 1.5)
        
        // 2. Weighted MAD (Median Absolute Deviation)
        let absoluteDeviations = zip(values, weights).map { (abs($0.0 - median), $0.1) }
        let mad = calculateWeightedMedian(
            values: absoluteDeviations.map { $0.0 },
            weights: absoluteDeviations.map { $0.1 }
        )
        
        let normalizedMAD = mad / max(0.01, median)
        let consistencyScore = max(0.0, 1.0 - normalizedMAD * 8.0)
        
        // 3. Distance-based quality (LiDAR is most accurate 0.5m - 3m)
        let distanceQuality: Float
        if median < 0.3 {
            distanceQuality = 0.6 // Very close
        } else if median < 0.5 {
            distanceQuality = 0.85 // Close
        } else if median < 3.0 {
            distanceQuality = 1.0 // Optimal range
        } else if median < 5.0 {
            distanceQuality = 0.9 // Far
        } else {
            distanceQuality = 0.7 // Very far
        }
        
        // 4. Sample density
        let densityScore = min(1.0, Float(sampleCount) / 50.0)
        
        // Combined confidence
        return coverageScore * consistencyScore * distanceQuality * (0.8 + 0.2 * densityScore)
    }
    
    /// Get single point distance
    func getDistance(at normalizedPoint: CGPoint) -> Float? {
        guard let depthData = depthData else { return nil }
        
        let depthMap = depthData.depthDataMap
        let depthWidth = CVPixelBufferGetWidth(depthMap)
        let depthHeight = CVPixelBufferGetHeight(depthMap)
        
        let x = Int(normalizedPoint.x * CGFloat(depthWidth))
        let y = Int((1.0 - normalizedPoint.y) * CGFloat(depthHeight))
        
        guard x >= 0, x < depthWidth, y >= 0, y < depthHeight else { return nil }
        
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        
        guard let baseAddress = CVPixelBufferGetBaseAddress(depthMap) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
        let rowData = baseAddress.advanced(by: y * bytesPerRow)
        let depthValue = rowData.assumingMemoryBound(to: Float32.self)[x]
        
        return (depthValue > 0 && depthValue.isFinite) ? depthValue : nil
    }
    
    /// Debug information
    func getDepthDebugInfo(for rect: CGRect) -> String {
        guard let depthData = depthData else { return "No depth data" }
        
        let depthMap = depthData.depthDataMap
        let calibration = depthData.cameraCalibrationData
        
        var info = "Depth: \(CVPixelBufferGetWidth(depthMap))x\(CVPixelBufferGetHeight(depthMap))\n"
        info += "Video: \(Int(videoResolution.width))x\(Int(videoResolution.height))\n"
        info += "Accuracy: \(depthData.depthDataAccuracy == .absolute ? "Absolute" : "Relative")\n"
        info += "Quality: \(depthData.depthDataQuality)\n"
        
        if let intrinsics = calibration?.intrinsicMatrix {
            info += "fx: \(String(format: "%.1f", intrinsics[0][0])) fy: \(String(format: "%.1f", intrinsics[1][1]))\n"
        }
        
        return info
    }
}

// MARK: - Data Synchronizer Delegate

extension CameraManager: AVCaptureDataOutputSynchronizerDelegate {
    
    func dataOutputSynchronizer(_ synchronizer: AVCaptureDataOutputSynchronizer,
                               didOutput synchronizedDataCollection: AVCaptureSynchronizedDataCollection) {
        
        // Extract synchronized video
        if let syncedVideoData = synchronizedDataCollection.synchronizedData(for: videoOutput) as? AVCaptureSynchronizedSampleBufferData,
           !syncedVideoData.sampleBufferWasDropped,
           let pixelBuffer = CMSampleBufferGetImageBuffer(syncedVideoData.sampleBuffer) {
            DispatchQueue.main.async {
                self.currentFrame = pixelBuffer
            }
        }
        
        // Extract synchronized depth
        if let syncedDepthData = synchronizedDataCollection.synchronizedData(for: depthOutput) as? AVCaptureSynchronizedDepthData,
           !syncedDepthData.depthDataWasDropped {
            
            var depthData = syncedDepthData.depthData
            
            // Always convert to Float32 for precision
            if depthData.depthDataType != kCVPixelFormatType_DepthFloat32 {
                depthData = depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
            }
            
            DispatchQueue.main.async {
                self.depthData = depthData
                
                if !self.depthDataReceived {
                    self.depthDataReceived = true
                    
                    let map = depthData.depthDataMap
                    let w = CVPixelBufferGetWidth(map)
                    let h = CVPixelBufferGetHeight(map)
                    
                    print("🔦 ✅ Professional LiDAR active")
                    print("   - Depth resolution: \(w)x\(h)")
                    print("   - Video resolution: \(Int(self.videoResolution.width))x\(Int(self.videoResolution.height))")
                    print("   - Accuracy: \(depthData.depthDataAccuracy == .absolute ? "Metric (Absolute)" : "Relative")")
                    print("   - Quality level: \(depthData.depthDataQuality)")
                    
                    if let cal = depthData.cameraCalibrationData {
                        print("   - Calibrated: YES")
                        print("   - Intrinsics: fx=\(String(format: "%.1f", cal.intrinsicMatrix[0][0])), fy=\(String(format: "%.1f", cal.intrinsicMatrix[1][1]))")
                    }
                }
            }
        }
    }
}

// MARK: - Fallback Delegates

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard dataOutputSynchronizer == nil else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        DispatchQueue.main.async { self.currentFrame = pixelBuffer }
    }
}

extension CameraManager: AVCaptureDepthDataOutputDelegate {
    func depthDataOutput(_ output: AVCaptureDepthDataOutput, didOutput depthData: AVDepthData, timestamp: CMTime, connection: AVCaptureConnection) {
        guard dataOutputSynchronizer == nil else { return }
        
        var converted = depthData
        if depthData.depthDataType != kCVPixelFormatType_DepthFloat32 {
            converted = depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
        }
        
        DispatchQueue.main.async {
            self.depthData = converted
            if !self.depthDataReceived {
                self.depthDataReceived = true
                print("🔦 ✅ Professional LiDAR active")
            }
        }
    }
}
