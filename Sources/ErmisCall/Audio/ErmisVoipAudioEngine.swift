import AVFoundation
import AudioToolbox
import CoreMedia
import os.log

/// Thread-safe circular buffer for audio samples
final class CircularAudioBuffer {
    private var buffer: [Int16]
    private var head: Int = 0  // Write position
    private var tail: Int = 0  // Read position
    private var count: Int = 0
    private let capacity: Int
    private var lock = os_unfair_lock()

    init(capacity: Int) {
        self.capacity = capacity
        self.buffer = [Int16](repeating: 0, count: capacity)
    }

    var availableSamples: Int {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return count
    }

    func write(_ samples: [Int16]) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }

        for sample in samples {
            buffer[head] = sample
            head = (head + 1) % capacity

            if count == capacity {
                // Buffer full - overwrite oldest (move tail forward)
                tail = (tail + 1) % capacity
            } else {
                count += 1
            }
        }
    }

    func read(_ count: Int) -> [Int16] {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }

        let samplesToRead = min(count, self.count)
        var result = [Int16](repeating: 0, count: count)

        for i in 0..<samplesToRead {
            result[i] = buffer[tail]
            buffer[tail] = 0  // Clear after reading
            tail = (tail + 1) % capacity
        }

        self.count -= samplesToRead
        return result
    }

    func clear() {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }

        head = 0
        tail = 0
        count = 0
        buffer = [Int16](repeating: 0, count: capacity)
    }
}

/// Core VoIP audio engine using Voice Processing IO Audio Unit
/// Handles both microphone input and speaker output with built-in echo cancellation
public final class ErmisVoIPAudioEngine {

    // MARK: - Properties

    private var audioUnit: AudioUnit?
    private let sampleRate: Double = 48000
    private let log = OSLog(subsystem: "com.ermis.voip", category: "AudioEngine")

    // Speaker output buffer
    private let speakerBuffer: CircularAudioBuffer
    private let bufferCapacity: Int  // in samples

    // Mic input buffer (for AudioUnitRender)
    private var micRenderBuffer: [Int16]

    // Callbacks
    public var onMicrophoneOutput: ((_ samples: [Int16], _ timestamp: CMTime) -> Void)?

    // Timestamp tracking
    private var micSamplePosition: Int64 = 0  // Total samples captured since start

    // State
    private var isRunning = false
    private var isConfigured = false

    // Debug stats
    private var totalSamplesEnqueued: UInt64 = 0
    private var totalSamplesPlayed: UInt64 = 0
    private var totalMicSamplesCaptured: UInt64 = 0
    private var renderCallbackCount: UInt64 = 0
    private var micCallbackCount: UInt64 = 0
    private var underrunCount: UInt64 = 0

    // MARK: - Initialization

    public init(bufferDurationMs: Int = 300) {
        // Buffer capacity in samples (e.g., 300ms at 48kHz = 14400 samples)
        self.bufferCapacity = Int(sampleRate * Double(bufferDurationMs) / 1000.0)
        self.speakerBuffer = CircularAudioBuffer(capacity: bufferCapacity)

        // Mic render buffer - 20ms frames at 48kHz = 960 samples
        self.micRenderBuffer = [Int16](repeating: 0, count: 960)

        os_log("[AudioEngine] Initialized with buffer capacity: %d samples (%dms)",
               log: log, type: .info, bufferCapacity, bufferDurationMs)
    }

    deinit {
        stop()
    }

    // MARK: - Public Methods

    /// Configure and start the audio engine
    public func start() throws {
        guard !isRunning else {
            os_log("[AudioEngine] Already running", log: log, type: .info)
            return
        }

        // Reset timestamp tracking
        micSamplePosition = 0

        try configureAudioSession()
        try configureAudioUnit()
        try startAudioUnit()

        isRunning = true
        os_log("[AudioEngine] Started successfully", log: log, type: .info)
    }

    /// Stop the audio engine
    public func stop() {
        guard isRunning else { return }
        isRunning = false

        if let au = audioUnit {
            AudioOutputUnitStop(au)
            AudioUnitUninitialize(au)
            AudioComponentInstanceDispose(au)
            audioUnit = nil
        }

        speakerBuffer.clear()
        isConfigured = false

        os_log("[AudioEngine] Stopped", log: log, type: .info)
    }

    /// Enqueue PCM samples for speaker playback
    public func enqueueForPlayback(_ samples: [Int16]) {
        guard isRunning else { return }

        speakerBuffer.write(samples)
        totalSamplesEnqueued += UInt64(samples.count)
    }

    /// Get current buffer level in milliseconds
    public var bufferedDurationMs: Double {
        let samples = speakerBuffer.availableSamples
        return Double(samples) / sampleRate * 1000.0
    }

    /// Print debug information
    public func printDebugInfo() {
        let bufferedMs = bufferedDurationMs
        os_log("""
            [AudioEngine] Debug Info:
            - Running: %{public}@
            - Speaker Buffer: %d samples (%.1fms)
            - Total Enqueued: %llu, Total Played: %llu
            - Render Callbacks: %llu, Mic Callbacks: %llu
            - Underruns: %llu
            - Mic Samples Captured: %llu
            """,
               log: log, type: .info,
               isRunning ? "true" : "false",
               speakerBuffer.availableSamples, bufferedMs,
               totalSamplesEnqueued, totalSamplesPlayed,
               renderCallbackCount, micCallbackCount,
               underrunCount,
               totalMicSamplesCaptured)
    }

    // MARK: - Audio Session Configuration

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()

        // Use .voiceChat mode - this is CRITICAL for echo cancellation
        // Note: .defaultToSpeaker can interfere with AEC on some devices
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [
            .allowBluetooth,
            .allowBluetoothA2DP
        ])

        try session.setPreferredSampleRate(sampleRate)
        try session.setPreferredIOBufferDuration(0.020) // 20ms buffer
    }

    /// Switch to speaker output (with echo cancellation still active)
    public func enableSpeaker(_ enabled: Bool) {
        do {
            let session = AVAudioSession.sharedInstance()
            if enabled {
                try session.overrideOutputAudioPort(.speaker)
            } else {
                try session.overrideOutputAudioPort(.none)
            }
            os_log("[AudioEngine] Speaker %{public}@", log: log, type: .info, enabled ? "enabled" : "disabled")
        } catch {
            os_log("[AudioEngine] Failed to set speaker: %{public}@", log: log, type: .error, error.localizedDescription)
        }
    }

    // MARK: - Audio Unit Configuration

    private func configureAudioUnit() throws {
        // Find Voice Processing IO Audio Unit
        var componentDesc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_VoiceProcessingIO,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        guard let component = AudioComponentFindNext(nil, &componentDesc) else {
            throw AudioEngineError.componentNotFound
        }

        var status = AudioComponentInstanceNew(component, &audioUnit)
        guard status == noErr, let au = audioUnit else {
            throw AudioEngineError.failedToCreateInstance(status)
        }

        // Enable output (speaker) - Bus 0
        var enableOutput: UInt32 = 1
        status = AudioUnitSetProperty(au,
                                      kAudioOutputUnitProperty_EnableIO,
                                      kAudioUnitScope_Output,
                                      0, // Output bus
                                      &enableOutput,
                                      UInt32(MemoryLayout<UInt32>.size))
        guard status == noErr else {
            throw AudioEngineError.failedToEnableOutput(status)
        }

        // Enable input (mic) - Bus 1
        var enableInput: UInt32 = 1
        status = AudioUnitSetProperty(au,
                                      kAudioOutputUnitProperty_EnableIO,
                                      kAudioUnitScope_Input,
                                      1, // Input bus
                                      &enableInput,
                                      UInt32(MemoryLayout<UInt32>.size))
        guard status == noErr else {
            throw AudioEngineError.failedToEnableInput(status)
        }

        // ========== VOICE PROCESSING SETTINGS ==========

        // Enable Echo Cancellation (should be on by default, but explicitly enable)
        var enableAEC: UInt32 = 1
        status = AudioUnitSetProperty(au,
                                      kAUVoiceIOProperty_VoiceProcessingEnableAGC,
                                      kAudioUnitScope_Global,
                                      0,
                                      &enableAEC,
                                      UInt32(MemoryLayout<UInt32>.size))
        if status != noErr {
            os_log("[AudioEngine] Warning: Could not enable AGC: %d", log: log, type: .debug, status)
        }

        // Disable bypass for voice processing (ensure AEC is active)
        var bypass: UInt32 = 0
        status = AudioUnitSetProperty(au,
                                      kAUVoiceIOProperty_BypassVoiceProcessing,
                                      kAudioUnitScope_Global,
                                      0,
                                      &bypass,
                                      UInt32(MemoryLayout<UInt32>.size))
        if status != noErr {
            os_log("[AudioEngine] Warning: Could not disable bypass: %d", log: log, type: .debug, status)
        }

        // Enable voice processing quality (high quality mode)
        var quality: UInt32 = 127 // 0-127, higher is better
        status = AudioUnitSetProperty(au,
                                      kAUVoiceIOProperty_VoiceProcessingQuality,
                                      kAudioUnitScope_Global,
                                      0,
                                      &quality,
                                      UInt32(MemoryLayout<UInt32>.size))
        if status != noErr {
            os_log("[AudioEngine] Warning: Could not set quality: %d", log: log, type: .debug, status)
        }

        // ========== AUDIO FORMAT ==========

        // Set audio format (same for input and output)
        var audioFormat = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )

        // Set format for output (speaker)
        status = AudioUnitSetProperty(au,
                                      kAudioUnitProperty_StreamFormat,
                                      kAudioUnitScope_Input,
                                      0, // Output bus
                                      &audioFormat,
                                      UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        guard status == noErr else {
            throw AudioEngineError.failedToSetOutputFormat(status)
        }

        // Set format for input (mic)
        status = AudioUnitSetProperty(au,
                                      kAudioUnitProperty_StreamFormat,
                                      kAudioUnitScope_Output,
                                      1, // Input bus
                                      &audioFormat,
                                      UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        guard status == noErr else {
            throw AudioEngineError.failedToSetInputFormat(status)
        }

        // ========== RENDER CALLBACK ==========

        // Set render callback (handles both speaker output AND mic input)
        var callback = AURenderCallbackStruct(
            inputProc: ErmisVoIPAudioEngine.renderCallback,
            inputProcRefCon: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        )
        status = AudioUnitSetProperty(au,
                                      kAudioUnitProperty_SetRenderCallback,
                                      kAudioUnitScope_Input,
                                      0, // Output bus
                                      &callback,
                                      UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        guard status == noErr else {
            throw AudioEngineError.failedToSetOutputCallback(status)
        }

        // Initialize
        status = AudioUnitInitialize(au)
        guard status == noErr else {
            throw AudioEngineError.failedToInitialize(status)
        }

        isConfigured = true
        os_log("[AudioEngine] Audio Unit configured with AEC enabled", log: log, type: .info)
    }

    private func startAudioUnit() throws {
        guard let au = audioUnit else {
            throw AudioEngineError.audioUnitNil
        }

        let status = AudioOutputUnitStart(au)
        guard status == noErr else {
            throw AudioEngineError.failedToStart(status)
        }
    }

    // MARK: - Render Callback

    /// Unified render callback - handles both speaker output AND mic input
    /// This is called by the audio unit when it needs audio data
    private static let renderCallback: AURenderCallback = { (
        inRefCon,
        ioActionFlags,
        inTimeStamp,
        inBusNumber,
        inNumberFrames,
        ioData
    ) -> OSStatus in
        let engine = Unmanaged<ErmisVoIPAudioEngine>.fromOpaque(inRefCon).takeUnretainedValue()

        guard let au = engine.audioUnit, let bufferList = ioData else { return noErr }

        let frameCount = Int(inNumberFrames)
        engine.renderCallbackCount += 1

        // ========== SPEAKER OUTPUT ==========
        // Read samples from buffer and provide to speaker
        let samples = engine.speakerBuffer.read(frameCount)
        engine.totalSamplesPlayed += UInt64(samples.count)

        // Check for underrun
        let actualSamples = samples.prefix { $0 != 0 }.count
        if actualSamples < frameCount {
            engine.underrunCount += 1
        }

        // Copy to output buffer
        let audioBuffer = bufferList.pointee.mBuffers
        if let data = audioBuffer.mData {
            let ptr = data.assumingMemoryBound(to: Int16.self)
            for i in 0..<frameCount {
                ptr[i] = samples[i]
            }
        }

        // ========== MIC INPUT ==========
        // Pull audio from input bus (mic)
        engine.micCallbackCount += 1

        // Ensure mic buffer is large enough
        if engine.micRenderBuffer.count < frameCount {
            engine.micRenderBuffer = [Int16](repeating: 0, count: frameCount)
        }

        // Prepare buffer list for AudioUnitRender
        var micBufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: UInt32(frameCount * 2),
                mData: &engine.micRenderBuffer
            )
        )

        // Pull audio from input bus (bus 1)
        var flags = AudioUnitRenderActionFlags(rawValue: 0)
        let status = AudioUnitRender(au,
                                     &flags,
                                     inTimeStamp,
                                     1, // Input bus (mic)
                                     inNumberFrames,
                                     &micBufferList)

        if status == noErr {
            let capturedSamples = Array(engine.micRenderBuffer.prefix(frameCount))
            engine.totalMicSamplesCaptured += UInt64(frameCount)

            // Generate timestamp based on sample position
            let timestamp = CMTime(
                value: CMTimeValue(engine.micSamplePosition),
                timescale: CMTimeScale(engine.sampleRate)
            )
            engine.micSamplePosition += Int64(frameCount)

            // Send to callback on main thread
            if let callback = engine.onMicrophoneOutput {
                callback(capturedSamples, timestamp)
            }
        }

        return noErr
    }
}

// MARK: - Errors

public enum AudioEngineError: Error, CustomStringConvertible {
    case componentNotFound
    case failedToCreateInstance(OSStatus)
    case failedToEnableOutput(OSStatus)
    case failedToEnableInput(OSStatus)
    case failedToSetOutputFormat(OSStatus)
    case failedToSetInputFormat(OSStatus)
    case failedToSetOutputCallback(OSStatus)
    case failedToInitialize(OSStatus)
    case failedToStart(OSStatus)
    case audioUnitNil

    public var description: String {
        switch self {
        case .componentNotFound:
            return "Voice Processing IO component not found"
        case .failedToCreateInstance(let status):
            return "Failed to create Audio Unit instance: \(status)"
        case .failedToEnableOutput(let status):
            return "Failed to enable output: \(status)"
        case .failedToEnableInput(let status):
            return "Failed to enable input: \(status)"
        case .failedToSetOutputFormat(let status):
            return "Failed to set output format: \(status)"
        case .failedToSetInputFormat(let status):
            return "Failed to set input format: \(status)"
        case .failedToSetOutputCallback(let status):
            return "Failed to set output callback: \(status)"
        case .failedToInitialize(let status):
            return "Failed to initialize Audio Unit: \(status)"
        case .failedToStart(let status):
            return "Failed to start Audio Unit: \(status)"
        case .audioUnitNil:
            return "Audio Unit is nil"
        }
    }
}
