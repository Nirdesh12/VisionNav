//
//  UIComponents.swift
//  VisionNav - UI Components
//

import SwiftUI

// MARK: - Feature Toggles

struct FeatureToggles: View {
    @ObservedObject var detectionModel: ObjectDetectionModel
    
    var body: some View {
        HStack(spacing: 16) {
            Button {
                detectionModel.toggleSpeech()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: detectionModel.speechEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                        .font(.system(size: 14))
                    Text("Speech")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(detectionModel.speechEnabled ? .white : .white.opacity(0.5))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    Capsule()
                        .fill(detectionModel.speechEnabled ? Color.blue : Color.gray.opacity(0.5))
                )
            }
            
            Button {
                detectionModel.toggleHaptics()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: detectionModel.hapticsEnabled ? "hand.tap.fill" : "hand.raised.slash.fill")
                        .font(.system(size: 14))
                    Text("Haptics")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(detectionModel.hapticsEnabled ? .white : .white.opacity(0.5))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    Capsule()
                        .fill(detectionModel.hapticsEnabled ? Color.purple : Color.gray.opacity(0.5))
                )
            }
        }
    }
}

// MARK: - FOV Slider Control

struct FOVSliderControl: View {
    @Binding var fovScale: Float
    
    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "viewfinder.circle")
                    .font(.system(size: 14))
                Text("Detection Zone")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(String(format: "%.0f%%", fovScale * 100))
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundColor(.cyan)
            }
            .foregroundColor(.white)
            
            HStack(spacing: 12) {
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: 20))
                    .foregroundColor(.cyan.opacity(0.7))
                
                Slider(value: $fovScale, in: 0.3...1.5)
                    .tint(.cyan)
                
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 20))
                    .foregroundColor(.cyan.opacity(0.7))
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.black.opacity(0.75))
        )
        .padding(.horizontal, 16)
    }
}

// MARK: - Top Controls View

struct TopControlsView: View {
    @ObservedObject var cameraManager: CameraManager
    @ObservedObject var detectionModel: ObjectDetectionModel
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
                    .background(Circle().fill(Color.black.opacity(0.65)))
            }
            
            Spacer()
            
            VStack(alignment: .trailing, spacing: 6) {
                // LiDAR Status
                HStack(spacing: 6) {
                    Image(systemName: cameraManager.hasLiDAR ? "sensor.tag.radiowaves.forward.fill" : "sensor.tag.radiowaves.forward")
                        .font(.system(size: 11))
                    Text(cameraManager.hasLiDAR ? "ARKit LiDAR" : "No LiDAR")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundColor(cameraManager.hasLiDAR ? .green : .orange)
                
                // Model Status
                HStack(spacing: 6) {
                    Circle()
                        .fill(detectionModel.isModelLoaded ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                    Text(detectionModel.isModelLoaded ? "Model Ready" : "Loading...")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(.white)
                
                // FPS
                HStack(spacing: 8) {
                    Text(String(format: "%.0f FPS", detectionModel.fps))
                        .font(.system(size: 10, weight: .medium))
                    Text("•")
                        .font(.system(size: 8))
                    Text(String(format: "%.0fms", detectionModel.inferenceTime))
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundColor(.white.opacity(0.85))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.black.opacity(0.65))
            )
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
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
        )
    }
}

// MARK: - Preview

#Preview {
    ObjectDetectionView()
}
