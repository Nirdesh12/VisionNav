//
// SettingView.swift - Fixed and Optimized
//
import SwiftUI
import Foundation

struct SettingView: View {
    @StateObject var settingsManager = SettingsManager()
    @Environment(\.dismiss) var dismiss

    private let horizontalPadding: CGFloat = 25

    private var groupedBackgroundColor: Color {
        Color(uiColor: .systemGroupedBackground)
    }

    private var backButtonColor: Color {
        Color(uiColor: .systemGray5)
    }

    var body: some View {
        ZStack {
            // Background
            groupedBackgroundColor.ignoresSafeArea()
            
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {

                    // --- Title Header ---
                    Text("Settings")
                        .font(.largeTitle.bold())
                        .padding(.top, 10)
                        .padding(.horizontal, horizontalPadding)
                    
                    // MARK: - AUDIO SECTION
                    SettingsSectionHeader(title: "AUDIO")
                        .padding(.horizontal, horizontalPadding)

                    VStack(spacing: 20) {
                        // Volume Control View
                        OptimizedVolumeControlView(settingsManager: settingsManager)

                        // Speech Rate Slider
                        SliderSettingCard<SettingsManager>(
                            value: $settingsManager.speechRate,
                            range: 0.0...1.0,
                            iconName: "speedometer",
                            title: "Speech Rate",
                            subtitle: "How fast voice speaks",
                            tintColor: Color.purple
                        )
                    }
                    .padding(.horizontal, horizontalPadding)

                    // MARK: - GENERAL SECTION
                    SettingsSectionHeader(title: "GENERAL")
                        .padding(.horizontal, horizontalPadding)

                    VStack(spacing: 20) {
                        ToggleSettingCard(
                            isOn: $settingsManager.notificationsEnabled,
                            iconName: "bell.fill",
                            title: "Notifications",
                            subtitle: "App alerts and updates",
                            tintColor: Color.orange
                        )
                    }
                    .padding(.horizontal, horizontalPadding)

                    // MARK: - FOOTER
                    VStack {
                        Text("VisionNav")
                            .font(.headline)
                            .foregroundColor(.blue)
                        Text("Version \(settingsManager.appVersion). Made with accessibility in mind.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 20)
                    .padding(.horizontal, horizontalPadding)

                }
                .padding(.bottom, 50)
            }
            
            // CRITICAL: Include the hidden volume view (positioned outside ScrollView for better performance)
            VStack {
                Spacer()
                SystemVolumeViewRepresentable(manager: settingsManager.systemVolumeManager)
                    .frame(width: 0, height: 0)
                    .opacity(0)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    settingsManager.hapticFeedback()
                    dismiss()
                } label: {
                    Image(systemName: "arrow.backward")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.primary)
                        .padding(8)
                        .background(backButtonColor)
                        .clipShape(Circle())
                }
            }
        }
    }
}

// MARK: - PERFORMANCE HELPER VIEW
/// Extracts the frequently changing volume control into its own View struct.
struct OptimizedVolumeControlView: View {
    @ObservedObject var settingsManager: SettingsManager
    
    var body: some View {
        SliderSettingCard(
            value: $settingsManager.voiceVolume,
            range: 0.0...1.0,
            iconName: "speaker.wave.3.fill",
            title: "Voice Volume",
            subtitle: "Adjust audio feedback level",
            tintColor: Color.indigo,
            volumeController: settingsManager
        )
    }
}


// MARK: - PREVIEW

struct SettingView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            SettingView()
        }
        .previewDisplayName("Default View")
    }
}
