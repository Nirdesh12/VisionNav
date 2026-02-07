//
//  SettingView.swift
//  VisionNav
//

import SwiftUI

struct SettingView: View {
    @StateObject var settingsManager = SettingsManager()
    @Environment(\.dismiss) var dismiss

    private let horizontalPadding: CGFloat = 25

    var body: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground).ignoresSafeArea()
            
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {

                    Text("Settings")
                        .font(.largeTitle.bold())
                        .padding(.top, 10)
                        .padding(.horizontal, horizontalPadding)
                    
                    // MARK: - AUDIO SECTION
                    SettingsSectionHeader(title: "AUDIO")
                        .padding(.horizontal, horizontalPadding)

                    VStack(spacing: 20) {
                        // Volume Control
                        SliderSettingCard(
                            value: $settingsManager.voiceVolume,
                            range: 0.0...1.0,
                            iconName: "speaker.wave.3.fill",
                            title: "Voice Volume",
                            subtitle: "Adjust audio feedback level",
                            tintColor: Color.indigo,
                            volumeController: settingsManager
                        )

                        // Speech Rate
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
            
            // Hidden volume view
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
                        .background(Color(uiColor: .systemGray5))
                        .clipShape(Circle())
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        SettingView()
    }
}
