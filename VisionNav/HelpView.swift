//
//  HelpView.swift
//  VisionNav
//
//  Created by Nirdesh Pudasaini on 30/11/2025.

import SwiftUI

// MARK: - HAPTIC EXTENSION/MODIFIER (Placeholder - Replace with SettingsManager)

/// A simple extension to apply haptic feedback to a View's action.
/// NOTE: In a real app, this should call SettingsManager().hapticFeedback()
extension View {
    func withHapticFeedback(action: @escaping () -> Void) -> some View {
        Button {
            // For a standalone file, we use the raw generator.
            // In a real app, inject SettingsManager here:
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            self.contentShape(Rectangle())
        }
        .buttonStyle(.plain) // Use plain style to avoid visual side effects
    }
}

// MARK: - 1. Helper Components

/// A reusable component for the numbered step lists.
struct NumberedStep: View {
    let number: Int
    let text: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.caption.bold())
                .foregroundColor(.white)
                .frame(width: 20, height: 20)
                // Use a standard color for the circle background
                .background(Color.secondary.opacity(0.8))
                .clipShape(Circle())
            
            Text(text)
                .font(.subheadline)
                .foregroundColor(.primary)
            
            Spacer()
        }
    }
}

/// A reusable component for the main feature cards (Object Detection, Navigation).
struct FeatureGuideCard<Content: View>: View {
    var title: String
    var subtitle: String
    var iconName: String
    var iconColor: Color
    @ViewBuilder var stepsContent: Content

    // Helper to get system background color robustly
    private var cardBackgroundColor: Color {
        Color(uiColor: .systemBackground)
    }
    
    // Helper to get system gray for borders
    private var subtleBorderColor: Color {
        Color(uiColor: .systemGray5)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                // Icon Circle
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
                        .foregroundColor(.primary)
                    
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
            
            // Steps Content (Passed in by the caller)
            stepsContent
        }
        .padding(20)
        // Use the robust color reference
        .background(cardBackgroundColor)
        .cornerRadius(20)
        // Add subtle, theme-aware border
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(subtleBorderColor, lineWidth: 1)
        )
        // Ensure shadow opacity works across modes
        .shadow(color: Color.primary.opacity(0.1), radius: 8, x: 0, y: 4)
    }
}


// MARK: - 2. Main Help Page View (Renamed to HelpView)

struct HelpView: View {
    // Environment variable required to manually dismiss the view and go back
    @Environment(\.dismiss) var dismiss
    
    // Define a custom light orange color that is theme-agnostic (RGB)
    private let lightTipBackground = Color(red: 1.0, green: 0.95, blue: 0.85) // Consistent very light orange/cream
    
    // Helper for grouped background color
    private var groupedBackgroundColor: Color {
        Color(uiColor: .systemGroupedBackground)
    }
    
    // Helper for navigation back button color
    private var backButtonColor: Color {
        Color(uiColor: .systemGray5)
    }
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // --- Title Header (Moved to be inline with the scroll content) ---
                Text("Help & Tutorials")
                    .font(.largeTitle.bold())
                    .padding(.top, 10)
                
                // --- 1. Audio Tutorial Card ---
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
                    
                    // BUTTON WITH HAPTIC
                    Button {
                        // Action: Simulate playing the tutorial
                        print("Playing full tutorial...")
                    } label: {
                        HStack {
                            Image(systemName: "play.fill")
                            Text("Play Full Tutorial")
                                .fontWeight(.semibold)
                        }
                        .padding(.vertical, 10)
                        .padding(.horizontal, 20)
                        .frame(maxWidth: .infinity)
                        // Use a fixed light color for the button for contrast
                        .background(Color.white)
                        .foregroundColor(Color.purple)
                        .cornerRadius(12)
                    }
                    .withHapticFeedback {} // Apply haptic feedback here
                }
                .padding(25)
                .background(LinearGradient(colors: [.purple, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing))
                .cornerRadius(20)
                
                // --- 2. Object Detection Card ---
                FeatureGuideCard(
                    title: "Object Detection",
                    subtitle: "Point your camera at objects and VisionNav will identify them in real-time, announcing what it sees through audio feedback.",
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
                
                // --- 3. Navigation Mode Card ---
                FeatureGuideCard(
                    title: "Navigation Mode",
                    subtitle: "Get turn-by-turn audio guidance to reach your destination safely with obstacle detection and path optimization.",
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
                
                // --- 4. Quick Tips Section ---
                VStack(alignment: .leading, spacing: 15) {
                    HStack {
                        Image(systemName: "lightbulb.fill")
                            .foregroundColor(.orange)
                        Text("Quick Tips")
                            .font(.title3.bold())
                            .foregroundColor(.black)
                    }
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("• Use headphones for clearer audio feedback in noisy environments")
                        Text("• Haptic feedback is **always enabled** for tactile confirmation of actions") // Updated tip
                        Text("• Adjust speech rate in Settings for comfortable listening")
                        Text("• Ensure your volume is set appropriately for audio guidance")
                    }
                    .font(.subheadline)
                    .foregroundColor(Color.black.opacity(0.8))
                }
                .padding(20)
                .background(lightTipBackground)
                .cornerRadius(16)
                
                // --- 5. Contact Support ---
                VStack(alignment: .center) {
                    Text("Need more help?")
                        .font(.headline)
                        .foregroundColor(.gray)
                    
                    // BUTTON WITH HAPTIC
                    Button {
                        // Action: Open support email or chat
                        print("Contacting Support...")
                    } label: {
                        Text("Contact Support")
                            .fontWeight(.bold)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                    }
                    .withHapticFeedback {} // Apply haptic feedback here
                }
                .padding(.vertical, 10)

            }
            .padding(.horizontal, 25)
            .padding(.bottom, 30)

        }
        // Use the robust grouped background color
        .background(groupedBackgroundColor.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        
        // Custom Toolbar for Back Button
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                // BUTTON WITH HAPTIC
                Button {
                    // Manual trigger for the back button
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    dismiss() // Navigate back when pressed
                } label: {
                    Image(systemName: "arrow.backward") // Back arrow icon
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.primary)
                        .padding(8)
                        // Use the robust system gray color for the button background
                        .background(backButtonColor)
                        .clipShape(Circle())
                }
            }
        }
    }
}

// Preview structure for the new file
struct HelpView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            NavigationView { // Wrap in NavigationView for testing
                HelpView()
            }
            .previewDisplayName("Light Mode")

            NavigationView {
                HelpView()
            }
            .preferredColorScheme(.dark) // Added Dark Mode Preview
            .previewDisplayName("Dark Mode")
        }
    }
}
