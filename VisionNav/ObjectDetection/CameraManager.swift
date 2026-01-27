//
//  CameraManager.swift
//  VisionNav - ARKit-based Camera and Depth Manager
//
//  Uses ARKit instead of AVFoundation for accurate depth like White Cane app:
//  - smoothedSceneDepth: Temporally smoothed by Apple's algorithms
//  - confidenceMap: Filter low-confidence readings
//  - Float32 depth values in meters
//

import Foundation
import ARKit
import SwiftUI
import Combine

class CameraManager: NSObject, ObservableObject {
    
    // MARK: - Published Properties
    @Published var currentFrame: CVPixelBuffer?
    @Published var currentDepthData: ARDepthData?
    @Published var isSessionRunning = false
    @Published var hasLiDAR = false
    @Published var errorMessage: String?
    
    // MARK: - AR Session
    let arSession = ARSession()
    
    // MARK: - Initialization
    
    override init() {
        super.init()
        checkLiDARSupport()
    }
    
    // MARK: - LiDAR Support Check
    
    private func checkLiDARSupport() {
        hasLiDAR = ARWorldTrackingConfiguration.supportsFrameSemantics([.sceneDepth, .smoothedSceneDepth])
        
        if !hasLiDAR {
            print("⚠️ This device does not have LiDAR")
        } else {
            print("✅ LiDAR supported")
        }
    }
    
    // MARK: - Setup (called from view)
    
    func setupCamera() {
        // ARKit handles camera permissions automatically
        // Just mark as ready
        print("📷 CameraManager ready (ARKit mode)")
    }
    
    // MARK: - Session Control
    
    func startSession() {
        guard hasLiDAR else {
            errorMessage = "LiDAR not available on this device"
            return
        }
        
        // Configure ARKit with smoothed scene depth
        let configuration = ARWorldTrackingConfiguration()
        
        // Use smoothedSceneDepth for stable, accurate depth
        // This is the key to accurate depth like Apple's Measure app
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            configuration.frameSemantics = [.smoothedSceneDepth]
        } else {
            configuration.frameSemantics = [.sceneDepth]
        }
        
        // Set delegate
        arSession.delegate = self
        
        // Run session
        arSession.run(configuration)
        
        DispatchQueue.main.async {
            self.isSessionRunning = true
        }
        
        print("✅ ARKit session started with smoothedSceneDepth")
    }
    
    func stopSession() {
        arSession.pause()
        
        DispatchQueue.main.async {
            self.isSessionRunning = false
        }
        
        print("⏹️ ARKit session stopped")
    }
}

// MARK: - ARSessionDelegate

extension CameraManager: ARSessionDelegate {
    
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // Get camera image
        let capturedImage = frame.capturedImage
        
        // Get depth data (prefer smoothed)
        let depthData = frame.smoothedSceneDepth ?? frame.sceneDepth
        
        DispatchQueue.main.async {
            self.currentFrame = capturedImage
            self.currentDepthData = depthData
        }
    }
    
    func session(_ session: ARSession, didFailWithError error: Error) {
        DispatchQueue.main.async {
            self.errorMessage = "AR Error: \(error.localizedDescription)"
            self.isSessionRunning = false
        }
    }
    
    func sessionWasInterrupted(_ session: ARSession) {
        DispatchQueue.main.async {
            self.isSessionRunning = false
        }
    }
    
    func sessionInterruptionEnded(_ session: ARSession) {
        startSession()
    }
}

// MARK: - ARSCNView Container for SwiftUI

struct ARCameraPreview: UIViewRepresentable {
    let session: ARSession
    
    func makeUIView(context: Context) -> ARSCNView {
        let arView = ARSCNView()
        arView.session = session
        arView.automaticallyUpdatesLighting = true
        arView.rendersCameraGrain = false
        arView.rendersMotionBlur = false
        return arView
    }
    
    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}
