//
//  ObjectDetectionView.swift
//  VisionNav - Main View with ARKit Depth
//

import SwiftUI
import ARKit
import Combine

struct ObjectDetectionView: View {
    
    @Environment(\.dismiss) var dismiss
    
    @StateObject private var cameraManager = CameraManager()
    @StateObject private var detectionModel = ObjectDetectionModel()
    
    @State private var fovScale: Float = 0.6
    @State private var showDebugInfo = false
    @State private var detectedObject: DetectedObject?
    @State private var currentDepth: DepthResult?
    
    // Update timer
    let timer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()
    
    var focusBox: CGRect {
        let size = CGFloat(fovScale) * 0.5
        return CGRect(
            x: 0.5 - size / 2,
            y: 0.5 - size / 2,
            width: size,
            height: size
        )
    }
    
    var body: some View {
        ZStack {
            // AR Camera Preview
            ARCameraPreview(session: cameraManager.arSession)
                .ignoresSafeArea()
            
            // Focus Box and Depth Overlay
            GeometryReader { geometry in
                let boxSize = CGSize(
                    width: geometry.size.width * CGFloat(fovScale) * 0.5,
                    height: geometry.size.width * CGFloat(fovScale) * 0.5
                )
                
                // Focus box border
                Rectangle()
                    .stroke(depthColor, lineWidth: 3)
                    .frame(width: boxSize.width, height: boxSize.height)
                    .position(
                        x: geometry.size.width / 2,
                        y: geometry.size.height / 2
                    )
                
                // Corner markers
                FocusCorners(size: boxSize, color: depthColor)
                    .position(
                        x: geometry.size.width / 2,
                        y: geometry.size.height / 2
                    )
                
                // Depth display in center
                if let depth = currentDepth {
                    DepthDisplayView(
                        depth: depth,
                        object: detectedObject,
                        color: depthColor
                    )
                    .position(
                        x: geometry.size.width / 2,
                        y: geometry.size.height / 2
                    )
                }
            }
            
            // Top Controls
            VStack {
                TopControlsView(
                    cameraManager: cameraManager,
                    detectionModel: detectionModel,
                    showDebugInfo: $showDebugInfo,
                    dismiss: dismiss
                )
                
                Spacer()
                
                // Bottom Controls
                VStack(spacing: 12) {
                    FeatureToggles(detectionModel: detectionModel)
                    FOVSliderControl(fovScale: $fovScale)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 30)
            }
            
            // Error Banner
            if let error = cameraManager.errorMessage ?? detectionModel.errorMessage {
                VStack {
                    Spacer()
                    ErrorBanner(message: error)
                        .padding(.bottom, 150)
                }
            }
        }
        .onAppear {
            cameraManager.setupCamera()
            cameraManager.startSession()
        }
        .onDisappear {
            cameraManager.stopSession()
        }
        .onReceive(timer) { _ in
            processCurrentFrame()
        }
    }
    
    // MARK: - Process Frame
    
    private func processCurrentFrame() {
        guard cameraManager.isSessionRunning else { return }
        
        detectionModel.detectInFocusBox(
            in: cameraManager.currentFrame,
            depthData: cameraManager.currentDepthData,
            focusBox: focusBox
        ) { obj, depth in
            self.detectedObject = obj
            if let d = depth {
                self.currentDepth = d
            }
        }
    }
    
    // MARK: - Depth Color
    
    private var depthColor: Color {
        guard let depth = currentDepth?.distance else { return .cyan }
        
        switch depth {
        case ..<0.3: return .red
        case 0.3..<0.6: return .orange
        case 0.6..<1.0: return .yellow
        case 1.0..<1.5: return .green
        default: return .cyan
        }
    }
}

// MARK: - Depth Display View

struct DepthDisplayView: View {
    let depth: DepthResult
    let object: DetectedObject?
    let color: Color
    
    var body: some View {
        VStack(spacing: 4) {
            Text(depth.distanceString)
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundColor(.white)
            
            if let obj = object {
                Text(obj.label)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(color.opacity(0.85))
        )
    }
}

// MARK: - Focus Corners

struct FocusCorners: View {
    let size: CGSize
    let color: Color
    
    var body: some View {
        ZStack {
            // Top-left
            CornerShape()
                .stroke(color, lineWidth: 4)
                .frame(width: 20, height: 20)
                .offset(x: -size.width/2 + 10, y: -size.height/2 + 10)
            
            // Top-right
            CornerShape()
                .stroke(color, lineWidth: 4)
                .frame(width: 20, height: 20)
                .rotationEffect(.degrees(90))
                .offset(x: size.width/2 - 10, y: -size.height/2 + 10)
            
            // Bottom-left
            CornerShape()
                .stroke(color, lineWidth: 4)
                .frame(width: 20, height: 20)
                .rotationEffect(.degrees(-90))
                .offset(x: -size.width/2 + 10, y: size.height/2 - 10)
            
            // Bottom-right
            CornerShape()
                .stroke(color, lineWidth: 4)
                .frame(width: 20, height: 20)
                .rotationEffect(.degrees(180))
                .offset(x: size.width/2 - 10, y: size.height/2 - 10)
        }
    }
}

struct CornerShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return path
    }
}

#Preview {
    ObjectDetectionView()
}
