//
//  ContentView.swift
//  VisionNav
//
//  Created by Nirdesh Pudasaini on 30/11/2025.
//
import SwiftUI
import MapKit
import CoreLocation
import Combine

// MARK: - 0. PLACEHOLDER VIEWS (Dummy Pages)

// ObjectDetectionView is now in its own file: ObjectDetectionView.swift
// See that file for the complete implementation with YOLOv8m and LiDAR

/// Placeholder for the Navigation Feature
struct NavigationMapView: View {
    var body: some View {
        ZStack {
            Color.green.opacity(0.1).ignoresSafeArea()
            VStack(spacing: 15) {
                Image(systemName: "map.fill")
                    .font(.largeTitle)
                    .foregroundColor(.green)
                Text("Navigation Feature Map")
                    .font(.title)
                    .fontWeight(.bold)
                Text("This is a placeholder for the actual MapView implementation that uses GPS and path calculation.")
                    .font(.subheadline)
                    .foregroundColor(.gray)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
        }
        .navigationTitle("Navigation")
    }
}

/// Placeholder for the Settings View
//struct SettingView: View {
//    var body: some View {
//        ZStack {
//            Color.gray.opacity(0.1).ignoresSafeArea()
//            VStack(spacing: 15) {
//                Image(systemName: "gearshape.fill")
//                    .font(.largeTitle)
//                    .foregroundColor(.gray)
//                Text("App Settings")
//                    .font(.title)
//                    .fontWeight(.bold)
//                Text("Configuration options for VisionNav will be placed here.")
//                    .font(.subheadline)
//                    .foregroundColor(.gray)
//                    .multilineTextAlignment(.center)
//                    .padding(.horizontal)
//            }
//        }
//        .navigationTitle("Settings")
//    }
//}
//
///// Placeholder for the Help View
//struct HelpView: View {
//    var body: some View {
//        ZStack {
//            Color.orange.opacity(0.1).ignoresSafeArea()
//            VStack(spacing: 15) {
//                Image(systemName: "questionmark.circle.fill")
//                    .font(.largeTitle)
//                    .foregroundColor(.orange)
//                Text("Help and Documentation")
//                    .font(.title)
//                    .fontWeight(.bold)
//                Text("User guide and support information will be accessible on this page.")
//                    .font(.subheadline)
//                    .foregroundColor(.gray)
//                    .multilineTextAlignment(.center)
//                    .padding(.horizontal)
//            }
//        }
//        .navigationTitle("Help")
//    }
//}


// MARK: - 1. THEME-SPECIFIC PATTERN COMPONENTS

/// Pattern for Object Detection
struct PixelGridPattern: View {
    @State private var rotateTarget = false
    let patternOpacity: CGFloat = 0.4
    
    var body: some View {
        ZStack {
            HStack(spacing: 12) {
                ForEach(0..<6) { _ in
                    Rectangle()
                        .fill(Color.white.opacity(patternOpacity))
                        .frame(width: 1.5)
                        .rotationEffect(.degrees(45))
                }
            }
            .offset(x: -20)
            .blur(radius: 0.5)
            
            // Animated Lidar Target Ring
            Circle()
                .stroke(Color.white.opacity(0.5), lineWidth: 1)
                .frame(width: 80, height: 80)
                .rotationEffect(.degrees(rotateTarget ? 360 : 0))
                .animation(
                    Animation.linear(duration: 8).repeatForever(autoreverses: false),
                    value: rotateTarget
                )
        }
        .onAppear {
            rotateTarget.toggle()
        }
    }
}

/// Pattern for Navigation
struct RouteLinePattern: View {
    @State private var lineOffset: CGFloat = 0
    let patternOpacity: CGFloat = 0.4
    
    var body: some View {
        Path { path in
            path.move(to: CGPoint(x: 0, y: 30))
            path.addCurve(to: CGPoint(x: 250, y: 70), control1: CGPoint(x: 80, y: -20), control2: CGPoint(x: 180, y: 120))
        }
        .stroke(Color.white.opacity(patternOpacity),
                style: StrokeStyle(lineWidth: 4,
                                   lineCap: .round,
                                   dash: [10, 8],
                                   dashPhase: lineOffset))
        .onAppear {
            withAnimation(Animation.linear(duration: 4).repeatForever(autoreverses: false)) {
                lineOffset -= 16
            }
        }
    }
}

// MARK: - 2. UTILITY COMPONENTS

/// Custom Button Style for Scale Animation (Tactile Feedback)
struct ScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { oldValue, newValue in
                if newValue {
                    let generator = UIImpactFeedbackGenerator(style: .light)
                    generator.impactOccurred()
                }
            }
    }
}

/// Reusable Quick Access Button Component
struct QuickAccessButton<Destination: View>: View {
    var title: String
    var iconName: String
    var color: Color
    @ViewBuilder var destination: Destination
    
    var body: some View {
        NavigationLink(destination: destination) {
            VStack(spacing: 12) {
                Image(systemName: iconName)
                    .font(.system(size: 24))
                    .foregroundColor(color)
                    .padding(12)
                    .background(color.opacity(0.1))
                    .clipShape(Circle())
                
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
            .background(Color(.systemBackground))
            .cornerRadius(20)
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(Color.primary.opacity(0.1), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.1), radius: 8, x: 0, y: 4)
        }
        .buttonStyle(ScaleButtonStyle())
    }
}

// MARK: - 3. GENERIC FEATURE CARD

/// Animated Feature Card with Custom Pattern
struct FeatureCard<Pattern: View, Destination: View>: View {
    var title: String
    var subtitle: String
    var iconName: String
    var gradientColors: [Color]
    var pattern: Pattern
    @ViewBuilder var destination: Destination
    
    @State private var animateGradient = false
    @State private var animateArrow = false
    
    var body: some View {
        NavigationLink(destination: destination) {
            HStack(spacing: 20) {
                // Icon Circle
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.2))
                        .frame(width: 60, height: 60)
                    
                    Image(systemName: iconName)
                        .font(.system(size: 30))
                        .foregroundColor(.white)
                }
                
                // Text Content
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                        .minimumScaleFactor(0.8)
                    
                    Text(subtitle)
                        .font(.body)
                        .foregroundColor(Color.white.opacity(0.9))
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                }
                
                Spacer()
                
                // Animated Arrow
                Image(systemName: "chevron.right")
                    .foregroundColor(Color.white.opacity(0.8))
                    .font(.system(size: 20, weight: .semibold))
                    .offset(x: animateArrow ? 4 : 0)
                    .animation(
                        Animation.easeInOut(duration: 1.0).repeatForever(autoreverses: true),
                        value: animateArrow
                    )
            }
            .padding(25)
            .frame(maxWidth: .infinity)
            .frame(height: 200)
            .background(
                ZStack {
                    pattern
                    
                    LinearGradient(
                        colors: gradientColors,
                        startPoint: animateGradient ? .topLeading : .bottomLeading,
                        endPoint: animateGradient ? .bottomTrailing : .topTrailing
                    )
                    .animation(
                        Animation.linear(duration: 3.0).repeatForever(autoreverses: true),
                        value: animateGradient
                    )
                    .blendMode(.screen)
                    .clipShape(RoundedRectangle(cornerRadius: 24))
                }
            )
            .cornerRadius(24)
            .shadow(color: gradientColors.first!.opacity(0.3), radius: 10, x: 0, y: 5)
        }
        .buttonStyle(ScaleButtonStyle())
        .onAppear {
            animateGradient.toggle()
            animateArrow.toggle()
        }
    }
}

// MARK: - 4. CONTENT VIEW

struct ContentView: View {
    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 32) {
                
                // MARK: - Header Section
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Text("VisionNav")
                            .font(.system(size: 34, weight: .bold))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [.blue, .purple],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                        
                        Image(systemName: "sparkles")
                            .font(.title2)
                            .foregroundColor(.purple)
                    }
                    
                    Text("Choose a feature to begin")
                        .font(.body)
                        .foregroundColor(.gray)
                }
                .padding(.top, 20)
                
                // MARK: - Feature Cards Section
                VStack(spacing: 20) {
                    
                    // 1. OBJECT DETECTION Card
                    FeatureCard(
                        title: "Object Detection",
                        subtitle: "Identify objects in real-time",
                        iconName: "camera.fill",
                        gradientColors: [Color.blue, Color.blue.opacity(0.7)],
                        pattern: PixelGridPattern()
                    ) {
                        ObjectDetectionView()
                    }
                    
                    // 2. NAVIGATION Card
                    FeatureCard(
                        title: "Navigation",
                        subtitle: "Get audio directions",
                        iconName: "location.fill",
                        gradientColors: [Color.green, Color.green.opacity(0.7)],
                        pattern: RouteLinePattern()
                    ) {
                        NavigationMapView()
                    }
                }
                
                // MARK: - Quick Access Section
                VStack(alignment: .leading, spacing: 16) {
                    Text("QUICK ACCESS")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundColor(.gray)
                        .tracking(1)
                    
                    HStack(spacing: 16) {
                        QuickAccessButton(
                            title: "Settings",
                            iconName: "gearshape.fill",
                            color: .gray
                        ) {
                            SettingView()
                        }
                        
                        QuickAccessButton(
                            title: "Help",
                            iconName: "questionmark.circle.fill",
                            color: .orange
                        ) {
                            HelpView()
                        }
                    }
                }
                .padding(.top, 20)
            }
            .padding(28)
            .navigationBarHidden(true)
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
        }
    }
}

// MARK: - 5. PREVIEW

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            ContentView()
                .preferredColorScheme(.light)
            ContentView()
                .preferredColorScheme(.dark)
        }
    }
}
