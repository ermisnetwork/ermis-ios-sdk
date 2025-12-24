import AVFoundation
import os.log

/// High-level VoIP manager that coordinates audio engine with encoder/decoder
///
/// Usage:
/// ```swift
/// let voipManager = ErmisVoIPManager()
///
/// // Set up callbacks
/// voipManager.onMicrophoneOutput = { pcmSamples in
///     // Send to your Opus encoder
///     encoder.encode(pcmSamples)
/// }
///
/// // Start the audio engine
/// try voipManager.start()
///
/// // Feed decoded audio for playback
/// decoder.audioBufferPublisher
///     .sink { pcmData in
///         voipManager.playAudio(pcmData)
///     }
///     .store(in: &cancellables)
///
/// // Stop when done
/// voipManager.stop()
/// ```
public final class ErmisVoIPManager {

    // MARK: - Properties

    private let audioEngine: ErmisVoIPAudioEngine
    private let log = OSLog(subsystem: "com.ermis.voip", category: "VoIPManager")

    /// Callback for microphone PCM output - connect this to your encoder
    public var onMicrophoneOutput: (([Int16], CMTime) -> Void)? {
        didSet {
            audioEngine.onMicrophoneOutput = onMicrophoneOutput
        }
    }

    /// Whether the audio engine is currently running
    public private(set) var isRunning = false

    // MARK: - Initialization

    /// Initialize the VoIP manager
    /// - Parameter bufferDurationMs: Speaker buffer duration in milliseconds (default: 300ms)
    public init(bufferDurationMs: Int = 300) {
        self.audioEngine = ErmisVoIPAudioEngine(bufferDurationMs: bufferDurationMs)
        os_log("[VoIPManager] Initialized", log: log, type: .info)
    }

    deinit {
        stop()
    }

    // MARK: - Public Methods

    /// Start the VoIP audio engine (mic + speaker)
    public func start() throws {
        guard !isRunning else {
            os_log("[VoIPManager] Already running", log: log, type: .info)
            return
        }

        try audioEngine.start()
        isRunning = true
        os_log("[VoIPManager] Started", log: log, type: .info)
    }

    /// Stop the VoIP audio engine
    public func stop() {
        guard isRunning else { return }

        audioEngine.stop()
        isRunning = false
        os_log("[VoIPManager] Stopped", log: log, type: .info)
    }

    /// Play decoded PCM audio through the speaker
    /// - Parameter samples: PCM Int16 samples (typically 960 samples for 20ms at 48kHz)
    public func playAudio(_ samples: [Int16]) {
        audioEngine.enqueueForPlayback(samples)
    }

    /// Get current speaker buffer level in milliseconds
    public var bufferedDurationMs: Double {
        return audioEngine.bufferedDurationMs
    }

    /// Print debug information
    public func printDebugInfo() {
        audioEngine.printDebugInfo()
    }
}

// MARK: - Alternative: Separate Input/Output Control

/// Extended VoIP manager with separate control for mic and speaker
/// Use this if you need to start/stop mic and speaker independently
public final class ErmisVoIPManagerAdvanced {

    // MARK: - Properties

    private let audioEngine: ErmisVoIPAudioEngine
    private let log = OSLog(subsystem: "com.ermis.voip", category: "VoIPManagerAdv")

    private var isMicEnabled = true
    private var isSpeakerEnabled = true

    /// Callback for microphone PCM output
    public var onMicrophoneOutput: (([Int16], CMTime) -> Void)?

    /// Whether the audio engine is running
    public private(set) var isRunning = false

    // MARK: - Initialization

    public init(bufferDurationMs: Int = 300) {
        self.audioEngine = ErmisVoIPAudioEngine(bufferDurationMs: bufferDurationMs)

        // Wrap the callback to check if mic is enabled
        audioEngine.onMicrophoneOutput = { [weak self] (samples, timestamp) in
            guard let self = self, self.isMicEnabled else { return }
            self.onMicrophoneOutput?(samples, timestamp)
        }
    }

    deinit {
        stop()
    }

    // MARK: - Public Methods

    public func start() throws {
        guard !isRunning else { return }
        try audioEngine.start()
        isRunning = true
    }

    public func stop() {
        guard isRunning else { return }
        audioEngine.stop()
        isRunning = false
    }

    /// Mute/unmute the microphone (still captures but doesn't send)
    public func setMicrophoneEnabled(_ enabled: Bool) {
        isMicEnabled = enabled
        os_log("[VoIPManagerAdv] Microphone %{public}@", log: log, type: .info,
               enabled ? "enabled" : "disabled")
    }

    /// Mute/unmute the speaker
    public func setSpeakerEnabled(_ enabled: Bool) {
        isSpeakerEnabled = enabled
        os_log("[VoIPManagerAdv] Speaker %{public}@", log: log, type: .info,
               enabled ? "enabled" : "disabled")
    }

    /// Play decoded PCM audio
    public func playAudio(_ samples: [Int16]) {
        guard isSpeakerEnabled else { return }
        audioEngine.enqueueForPlayback(samples)
    }

    public var bufferedDurationMs: Double {
        return audioEngine.bufferedDurationMs
    }

    public func printDebugInfo() {
        audioEngine.printDebugInfo()
    }
}
