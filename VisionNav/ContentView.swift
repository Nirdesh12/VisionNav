//
//  ContentView.swift
//  VisionNav
//

import SwiftUI
import MapKit
import CoreLocation
import Combine

// MARK: - Pattern Components

struct PixelGridPattern: View {
    @State private var rotateTarget = false
    
    var body: some View {
        ZStack {
            HStack(spacing: 12) {
                ForEach(0..<6, id: \.self) { _ in
                    Rectangle()
                        .fill(Color.white.opacity(0.4))
                        .frame(width: 1.5)
                        .rotationEffect(.degrees(45))
                }
            }
            .offset(x: -20)
            .blur(radius: 0.5)
            
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

struct RouteLinePattern: View {
    @State private var lineOffset: CGFloat = 0
    
    var body: some View {
        Path { path in
            path.move(to: CGPoint(x: 0, y: 30))
            path.addCurve(to: CGPoint(x: 250, y: 70), control1: CGPoint(x: 80, y: -20), control2: CGPoint(x: 180, y: 120))
        }
        .stroke(Color.white.opacity(0.4),
                style: StrokeStyle(lineWidth: 4, lineCap: .round, dash: [10, 8], dashPhase: lineOffset))
        .onAppear {
            withAnimation(Animation.linear(duration: 4).repeatForever(autoreverses: false)) {
                lineOffset -= 16
            }
        }
    }
}

// MARK: - Button Style

struct ScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, newValue in
                if newValue {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
            }
    }
}

// MARK: - Quick Access Button

struct QuickAccessButton<Destination: View>: View {
    var title: String
    var iconName: String
    var color: Color
    var destination: Destination
    
    init(title: String, iconName: String, color: Color, @ViewBuilder destination: () -> Destination) {
        self.title = title
        self.iconName = iconName
        self.color = color
        self.destination = destination()
    }
    
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

// MARK: - Feature Card

struct FeatureCard<Pattern: View, Destination: View>: View {
    var title: String
    var subtitle: String
    var iconName: String
    var gradientColors: [Color]
    var pattern: Pattern
    var destination: Destination
    
    @State private var animateGradient = false
    @State private var animateArrow = false
    
    init(
        title: String,
        subtitle: String,
        iconName: String,
        gradientColors: [Color],
        pattern: Pattern,
        @ViewBuilder destination: () -> Destination
    ) {
        self.title = title
        self.subtitle = subtitle
        self.iconName = iconName
        self.gradientColors = gradientColors
        self.pattern = pattern
        self.destination = destination()
    }
    
    var body: some View {
        NavigationLink(destination: destination) {
            HStack(spacing: 20) {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.2))
                        .frame(width: 60, height: 60)
                    
                    Image(systemName: iconName)
                        .font(.system(size: 30))
                        .foregroundColor(.white)
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                    
                    Text(subtitle)
                        .font(.body)
                        .foregroundColor(Color.white.opacity(0.9))
                        .lineLimit(2)
                }
                
                Spacer()
                
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

// MARK: - Content View

struct ContentView: View {
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 32) {
                
                // Header
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
                
                // Feature Cards
                VStack(spacing: 20) {
                    FeatureCard(
                        title: "Object Detection",
                        subtitle: "Identify objects in real-time",
                        iconName: "camera.fill",
                        gradientColors: [Color.blue, Color.blue.opacity(0.7)],
                        pattern: PixelGridPattern()
                    ) {
                        ObjectDetectionView()
                    }
                    
                    FeatureCard(
                        title: "Navigation",
                        subtitle: "Get audio directions",
                        iconName: "location.fill",
                        gradientColors: [Color.green, Color.green.opacity(0.7)],
                        pattern: RouteLinePattern()
                    ) {
                        RouteNavigationView()
                    }
                }
                
                // Quick Access
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

#Preview {
    ContentView()
}
