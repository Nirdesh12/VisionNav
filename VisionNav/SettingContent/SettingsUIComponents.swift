//
// SettingsUIComponents.swift
//
import SwiftUI
import Foundation

// MARK: - CUSTOM UI COMPONENTS

/// Reusable card component for housing settings content.
struct SettingsCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    private var cardBackgroundColor: Color {
        Color(uiColor: .systemBackground)
    }

    private var subtleBorderColor: Color {
        Color(uiColor: .systemGray5)
    }

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .padding(20)
        .background(cardBackgroundColor)
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(subtleBorderColor, lineWidth: 1)
        )
        .shadow(color: Color.primary.opacity(0.1), radius: 8, x: 0, y: 4)
    }
}

/// A card for slider controls (Volume, Rate).
struct SliderSettingCard<V: VolumeControl>: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var iconName: String
    var title: String
    var subtitle: String
    var tintColor: Color
    var volumeController: V? = nil

    var body: some View {
        SettingsCard {
            HStack(alignment: .top, spacing: 16) {
                // Icon
                Image(systemName: iconName)
                    .font(.title2)
                    .foregroundColor(tintColor)
                    .padding(10)
                    .background(tintColor.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 4) {
                    // Title and Percentage
                    HStack {
                        Text(title)
                            .font(.headline)
                            .fontWeight(.medium)
                            .foregroundColor(.primary)
                        Spacer()
                        // Display value as percentage, rounded to nearest percent
                        Text("\(Int(round(value * 100)))%")
                            .font(.headline)
                            .fontWeight(.semibold)
                            .foregroundColor(tintColor)
                    }

                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }

            // Slider
            Slider(value: $value, in: range)
                .tint(tintColor)
                .padding(.top, 10)
        }
        // This onChange is largely redundant due to the SettingsManager's didSet,
        // but included for robust UI control.
        .onChange(of: value) {
            if title == "Voice Volume", let controller = volumeController {
                controller.setSystemVolume(to: value)
            }
        }
    }
}

/// A card for toggle controls (Haptic, Contrast, Notifications).
struct ToggleSettingCard: View {
    @Binding var isOn: Bool
    var iconName: String
    var title: String
    var subtitle: String
    var tintColor: Color

    var body: some View {
        SettingsCard {
            HStack(spacing: 16) {
                // Icon
                Image(systemName: iconName)
                    .font(.title2)
                    .foregroundColor(tintColor)
                    .padding(10)
                    .background(tintColor.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)

                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                Spacer()

                // Toggle
                Toggle("", isOn: $isOn)
                    .labelsHidden()
                    .tint(tintColor)
            }
        }
    }
}

struct SettingsSectionHeader: View {
    var title: String

    var body: some View {
        HStack {
            Text(title)
                .font(.subheadline)
                .fontWeight(.bold)
                .foregroundColor(Color.secondary)
                .textCase(.uppercase)
            Spacer()
        }
        .padding(.top, 10)
    }
}
