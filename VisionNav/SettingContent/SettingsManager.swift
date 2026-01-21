//
//  SettingsManager.swift - Fixed and Optimized
//
import Foundation
import SwiftUI
import Combine
import MediaPlayer
import AVFoundation

// MARK: - 0. SYSTEM VOLUME INTEGRATION

/// Protocol for components that handle volume control actions.
protocol VolumeControl {
    var voiceVolume: Double { get set }
    func setSystemVolume(to level: Double)
}

/// Manages interaction with the system volume control (physical buttons).
class SystemVolumeManager: ObservableObject {

    private var volumeView: MPVolumeView?
    private var volumeObserver: NSKeyValueObservation?

    init() {
        #if !targetEnvironment(simulator)
        // Defer critical system setup to ensure it runs after UI stabilization
        DispatchQueue.main.async { [weak self] in
            self?.setupAudioSession()
            self?.setupVolumeView()
        }
        #endif
        setupVolumeObserver()
    }

    deinit {
        volumeObserver?.invalidate()
    }

    private func setupAudioSession() {
        let audioSession = AVAudioSession.sharedInstance()
        do {
            // Set category for media playback to ensure physical buttons control media volume
            try audioSession.setCategory(.playback, mode: .default, options: [])
            try audioSession.setActive(true)
        } catch {
            print("CRITICAL AUDIO SETUP ERROR: Failed to set up or activate audio session: \(error.localizedDescription)")
        }
    }
    
    // The KVO observer detects changes from the physical buttons
    private func setupVolumeObserver() {
        volumeObserver = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new]) { [weak self] session, change in
            guard self != nil else { return }

            let newVolume = Double(session.outputVolume)
            
            // Post notification, marking the change as coming from a "physical" source
            NotificationCenter.default.post(
                name: .systemVolumeDidChange,
                object: nil,
                userInfo: ["volume": newVolume, "source": "physical"]
            )
        }
    }

    private func setupVolumeView() {
        // MPVolumeView must be rendered to capture physical button presses
        volumeView = MPVolumeView(frame: .zero)
        volumeView?.alpha = 0.0001 // Invisible
        volumeView?.clipsToBounds = true
        volumeView?.showsVolumeSlider = true
        
        // Hide the AirPlay button by removing it from subviews
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let volumeView = self?.volumeView else { return }
            for subview in volumeView.subviews {
                if let button = subview as? UIButton {
                    button.isHidden = true
                    button.alpha = 0
                    button.isUserInteractionEnabled = false
                }
            }
        }
    }

    /// Returns the hidden MPVolumeView for SwiftUI to render.
    func getVolumeView() -> UIView {
        return volumeView ?? UIView()
    }

    /// Sets the system volume using the exposed (but hidden) UISlider.
    func setVolume(to level: Double) {
        #if !targetEnvironment(simulator)
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  let volumeSlider = self.volumeView?.subviews.first(where: { $0 is UISlider }) as? UISlider
            else { return }
            
            // Only update if needed
            if abs(Double(volumeSlider.value) - level) > 0.001 {
                volumeSlider.value = Float(level)
                volumeSlider.sendActions(for: .valueChanged)
            }
        }
        #endif
    }
}

// Custom Notification Name for volume synchronization
extension Notification.Name {
    static let systemVolumeDidChange = Notification.Name("systemVolumeDidChangeNotification")
}

/// A thin wrapper to include the MPVolumeView in the SwiftUI hierarchy.
struct SystemVolumeViewRepresentable: UIViewRepresentable {
    var manager: SystemVolumeManager

    func makeUIView(context: Context) -> UIView {
        return manager.getVolumeView()
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}


// MARK: - 1. SETTINGS MANAGER (State & Persistence)

/// PERFORMANCE OPTIMIZATION: Uses an internal value to reduce repeated disk access.
@propertyWrapper
struct UserDefaultPublished<Value> {
    let key: String
    let defaultValue: Value
    private let defaults = UserDefaults.standard
    
    var wrappedValue: Value {
        get {
            return defaults.object(forKey: key) as? Value ?? defaultValue
        }
        nonmutating set {
            defaults.set(newValue, forKey: key)
        }
    }

    var projectedValue: Binding<Value> {
        Binding(
            get: { self.wrappedValue },
            set: { self.wrappedValue = $0 }
        )
    }

    init(key: String, defaultValue: Value) {
        self.key = key
        self.defaultValue = defaultValue
        
        if defaults.object(forKey: key) == nil {
            defaults.set(defaultValue, forKey: key)
        }
    }
}


/// Manages all persistent and temporary settings for the VisionNav app using UserDefaults.
class SettingsManager: ObservableObject, VolumeControl {

    let systemVolumeManager = SystemVolumeManager()
    private var cancellables = Set<AnyCancellable>()
    
    // Audio feedback player
    private var volumeFeedbackPlayer: AVAudioPlayer?
    // Flag to prevent double audio feedback during physical button sync
    private var isSyncingFromPhysicalButton: Bool = false
    // Timer to debounce volume feedback
    private var volumeFeedbackTimer: Timer?
    
    deinit {
        volumeFeedbackTimer?.invalidate()
    }

    // Audio Settings
    @Published var voiceVolume: Double {
        didSet {
            UserDefaults.standard.set(voiceVolume, forKey: "voiceVolume")
            
            // 1. Set system volume
            setSystemVolume(to: voiceVolume)
            
            // 2. Provide audio feedback with the NEW volume level
            if !isSyncingFromPhysicalButton {
                // Debounce: Cancel previous timer and start a new one
                volumeFeedbackTimer?.invalidate()
                volumeFeedbackTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
                    self?.playVolumeTestSound()
                }
            }
        }
    }

    @Published var speechRate: Double {
        didSet {
            UserDefaults.standard.set(speechRate, forKey: "speechRate")
            hapticFeedback()
        }
    }

    // General Settings
    @Published var notificationsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(notificationsEnabled, forKey: "notificationsEnabled")
            hapticFeedback()
        }
    }

    let appVersion: String = "1.0.0"

    // MARK: - Initialization
    
    init() {
        // Load saved values or use defaults
        self.voiceVolume = UserDefaults.standard.object(forKey: "voiceVolume") as? Double ?? 0.75
        self.speechRate = UserDefaults.standard.object(forKey: "speechRate") as? Double ?? 0.5
        self.notificationsEnabled = UserDefaults.standard.object(forKey: "notificationsEnabled") as? Bool ?? true
        
        // Set up physical button synchronization
        setupVolumeSync()
    }
    
    // MARK: - VolumeControl Conformance

    func setSystemVolume(to level: Double) {
        systemVolumeManager.setVolume(to: level)
    }
    
    // MARK: - ACCESSIBILITY IMPLEMENTATION

    /// Provides a light tap haptic feedback (now always enabled).
    func hapticFeedback() {
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()
    }
    
    /// Plays a test sound at the current volume level to demonstrate the new setting.
    private func playVolumeTestSound() {
        // First try to use a custom sound file if available
        if let url = Bundle.main.url(forResource: "volume_tick", withExtension: "mp3") {
            playCustomSound(url: url)
            return
        }
        
        // Fallback: Generate a simple tone programmatically
        generateAndPlayTestTone()
    }
    
    /// Plays a custom audio file at the current volume level.
    private func playCustomSound(url: URL) {
        do {
            volumeFeedbackPlayer = try AVAudioPlayer(contentsOf: url)
            volumeFeedbackPlayer?.volume = Float(voiceVolume)
            volumeFeedbackPlayer?.prepareToPlay()
            volumeFeedbackPlayer?.play()
        } catch {
            print("INFO: Custom volume feedback audio not available: \(error.localizedDescription)")
            // Fallback to generated tone
            generateAndPlayTestTone()
        }
    }
    
    /// Generates and plays a simple beep tone at the current volume level.
    private func generateAndPlayTestTone() {
        // Create a simple audio buffer with a tone
        let sampleRate = 44100.0
        let duration = 0.15 // Short beep
        let frequency = 800.0 // Pleasant tone frequency
        
        let frameCount = Int(sampleRate * duration)
        
        guard let audioFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let audioBuffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: AVAudioFrameCount(frameCount)) else {
            return
        }
        
        audioBuffer.frameLength = AVAudioFrameCount(frameCount)
        
        // Generate a simple sine wave
        guard let samples = audioBuffer.floatChannelData?[0] else { return }
        
        let amplitude = Float(voiceVolume) * 0.3 // Scale amplitude by volume
        let twoPi = 2.0 * Double.pi
        let frequencyTimesTwoPi = twoPi * frequency
        
        for i in 0..<frameCount {
            let time = Double(i) / sampleRate
            let sineValue = sin(frequencyTimesTwoPi * time)
            samples[i] = amplitude * Float(sineValue)
        }
        
        // Play the generated tone
        let audioEngine = AVAudioEngine()
        let playerNode = AVAudioPlayerNode()
        
        audioEngine.attach(playerNode)
        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: audioFormat)
        
        do {
            try audioEngine.start()
            playerNode.scheduleBuffer(audioBuffer, at: nil, options: [], completionHandler: nil)
            playerNode.play()
            
            // Stop engine after playback
            DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.1) {
                audioEngine.stop()
            }
        } catch {
            print("INFO: Could not play generated tone: \(error.localizedDescription)")
        }
    }

    private func setupVolumeSync() {
        // Synchronize with physical button volume changes
        NotificationCenter.default.publisher(for: .systemVolumeDidChange)
            .compactMap { notification -> (Double, String?)? in
                guard let volume = notification.userInfo?["volume"] as? Double else { return nil }
                let source = notification.userInfo?["source"] as? String
                return (volume, source)
            }
            .throttle(for: .milliseconds(200), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] (newVolume, source) in
                guard let self = self else { return }
                
                let currentVolume = self.voiceVolume
                // Check tolerance to prevent synchronization loop
                if abs(currentVolume - newVolume) > 0.01 {
                    
                    // 1. Set the flag: This change is coming from the physical button
                    self.isSyncingFromPhysicalButton = (source == "physical")
                    
                    // 2. Update the published property. This triggers 'didSet', where audio feedback is suppressed.
                    self.voiceVolume = newVolume
                    
                    // 3. Reset the flag immediately after the update cycle finishes
                    DispatchQueue.main.async {
                        self.isSyncingFromPhysicalButton = false
                    }
                }
            }
            .store(in: &cancellables)
    }
}
