//
//  HelpView.swift
//  VisionNav
//

import SwiftUI

// MARK: - Helper Components

struct NumberedStep: View {
    let number: Int
    let text: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.caption.bold())
                .foregroundColor(.white)
                .frame(width: 20, height: 20)
                .background(Color.secondary.opacity(0.8))
                .clipShape(Circle())
            
            Text(text)
                .font(.subheadline)
                .foregroundColor(.primary)
            
            Spacer()
        }
    }
}

struct FeatureGuideCard<Content: View>: View {
    var title: String
    var subtitle: String
    var iconName: String
    var iconColor: Color
    var stepsContent: Content

    init(
        title: String,
        subtitle: String,
        iconName: String,
        iconColor: Color,
        @ViewBuilder stepsContent: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.iconName = iconName
        self.iconColor = iconColor
        self.stepsContent = stepsContent()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                Image(systemName: iconName)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(iconColor)
                    .padding(14)
                    .background(iconColor.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.title2)
                        .fontWeight(.bold)
                    
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
            
            stepsContent
        }
        .padding(20)
        .background(Color(uiColor: .systemBackground))
        .cornerRadius(20)
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(Color(uiColor: .systemGray5), lineWidth: 1)
        )
        .shadow(color: Color.primary.opacity(0.1), radius: 8, x: 0, y: 4)
    }
}

// MARK: - Main Help View

struct HelpView: View {
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Help & Tutorials")
                    .font(.largeTitle.bold())
                    .padding(.top, 10)
                
                // Audio Tutorial Card
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 20) {
                        Image(systemName: "book.fill")
                            .font(.system(size: 32))
                            .foregroundColor(.white)
                        
                        VStack(alignment: .leading) {
                            Text("Audio Tutorial")
                                .font(.title)
                                .fontWeight(.bold)
                                .foregroundColor(.white)
                            Text("Complete guided walkthrough")
                                .font(.subheadline)
                                .foregroundColor(.white.opacity(0.9))
                        }
                    }
                    
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    } label: {
                        HStack {
                            Image(systemName: "play.fill")
                            Text("Play Full Tutorial")
                                .fontWeight(.semibold)
                        }
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity)
                        .background(Color.white)
                        .foregroundColor(Color.purple)
                        .cornerRadius(12)
                    }
                }
                .padding(25)
                .background(LinearGradient(colors: [.purple, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing))
                .cornerRadius(20)
                
                // Object Detection Card
                FeatureGuideCard(
                    title: "Object Detection",
                    subtitle: "Identify objects in real-time with audio feedback.",
                    iconName: "camera.fill",
                    iconColor: .blue
                ) {
                    VStack(spacing: 8) {
                        NumberedStep(number: 1, text: "Tap \"Start Detection\" button")
                        NumberedStep(number: 2, text: "Point camera at objects")
                        NumberedStep(number: 3, text: "Listen to audio descriptions")
                        NumberedStep(number: 4, text: "Tap again to stop")
                    }
                }
                
                // Navigation Mode Card
                FeatureGuideCard(
                    title: "Navigation Mode",
                    subtitle: "Get turn-by-turn audio guidance safely.",
                    iconName: "location.fill",
                    iconColor: .green
                ) {
                    VStack(spacing: 8) {
                        NumberedStep(number: 1, text: "Set your destination")
                        NumberedStep(number: 2, text: "Start navigation")
                        NumberedStep(number: 3, text: "Follow audio directions")
                        NumberedStep(number: 4, text: "Receive obstacle alerts")
                    }
                }
                
                // Quick Tips
                VStack(alignment: .leading, spacing: 15) {
                    HStack {
                        Image(systemName: "lightbulb.fill")
                            .foregroundColor(.orange)
                        Text("Quick Tips")
                            .font(.title3.bold())
                    }
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("• Use headphones for clearer audio")
                        Text("• Haptic feedback is always enabled")
                        Text("• Adjust speech rate in Settings")
                    }
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                }
                .padding(20)
                .background(Color.orange.opacity(0.1))
                .cornerRadius(16)
                
                // Contact Support
                VStack {
                    Text("Need more help?")
                        .font(.headline)
                        .foregroundColor(.gray)
                    
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    } label: {
                        Text("Contact Support")
                            .fontWeight(.bold)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                    }
                }
                .padding(.vertical, 10)
            }
            .padding(.horizontal, 25)
            .padding(.bottom, 30)
        }
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    dismiss()
                } label: {
                    Image(systemName: "arrow.backward")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.primary)
                        .padding(8)
                        .background(Color(uiColor: .systemGray5))
                        .clipShape(Circle())
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        HelpView()
    }
}
