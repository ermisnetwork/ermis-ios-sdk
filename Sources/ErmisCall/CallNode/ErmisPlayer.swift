//
// Copyright 2025 Ermis Inc.
//

import AVFoundation
import VideoToolbox
import CoreMedia
import AudioToolbox
import ErmisOpus
import ErmisChat
import UIKit

public class ErmisPlayer: AppLifecycleObserver {
    public var videoLayer: AVSampleBufferDisplayLayer
    public var audioRenderer: AVSampleBufferAudioRenderer?
    public let synchronizer: AVSampleBufferRenderSynchronizer

    private var videoFormatDescription: CMVideoFormatDescription?
    private var audioFormatDescription: CMFormatDescription?

    private var audioConfig: AudioConfig?
    private var videoConfig: VideoConfig?
    private var opusDecoder: OpusDecoder?

    private var isPlaying = false
    private var currentAudioTime: CMTime = .zero

    private let videoQueue = DispatchQueue(label: "ermis.player.video.queue", qos: .userInitiated)
    private let audioQueue = DispatchQueue(label: "ermis.player.audio.queue", qos: .userInitiated)

    private var audioSessionObserver: NSObjectProtocol?
    package var isReadyToPlay: Bool = false
    private var hasSetupRenderer: Bool = false

    // MARK: - Buffer Management
    private var videoBuffer: [(sampleBuffer: CMSampleBuffer, timestamp: CMTime)] = []
    private var audioBuffer: [(sampleBuffer: CMSampleBuffer, timestamp: CMTime)] = []
    private let videoBufferLock = NSLock()
    private let audioBufferLock = NSLock()

    public var maxBufferSize: Int = 5 // Maximum number of video frames to buffer

    public init() {
        synchronizer = AVSampleBufferRenderSynchronizer()
        videoLayer = AVSampleBufferDisplayLayer()
        //setupAudioSessionObservers()
    }

    deinit {
        if let observer = audioSessionObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        log.debug("TTTT PLAYER DEINIT")
        stopRequestingMedia()
        stop()
    }

    package func setupPlayerIfNeeded() {
        isReadyToPlay = true
        if !hasSetupRenderer {
            hasSetupRenderer = true
            audioRenderer = AVSampleBufferAudioRenderer()
            synchronizer.addRenderer(videoLayer)
            synchronizer.addRenderer(audioRenderer!)
            videoLayer.videoGravity = .resizeAspectFill
            startRequestingMediaData()
        }
    }

    private func setupAudioSessionObservers() {
        audioSessionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            guard let self = self else { return }

            guard let userInfo = notification.userInfo,
                  let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
                return
            }

            switch type {
            case .began:
                log.debug("[Player] Audio session interrupted", subsystems: .call)
                // Pause synchronizer
//                self.synchronizer.rate = 0

            case .ended:
                log.debug("[Player] Audio session interruption ended", subsystems: .call)
                guard let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt else {
                    return
                }
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                if options.contains(.shouldResume) {
                    // Resume playback
                    if self.isPlaying {
                        self.synchronizer.rate = 1.0
                    }
                }

            @unknown default:
                break
            }
        }
    }

    func stop() {
        synchronizer.rate = 0
        if #available(iOS 17.0, *) {
            videoLayer.sampleBufferRenderer.flush()
        } else {
            videoLayer.flush()
        }
        audioRenderer?.flush()
        isPlaying = false
    }

    private func reset() {
        stop()
        videoFormatDescription = nil
        audioFormatDescription = nil
        opusDecoder = nil
    }

    private func startRequestingMediaData() {
        if #available(iOS 17.0, *) {
            videoLayer.sampleBufferRenderer.requestMediaDataWhenReady(on: videoQueue) { [weak self] in
                self?.supplyVideoData()
            }
        } else {
            videoLayer.requestMediaDataWhenReady(on: videoQueue) { [weak self] in
                self?.supplyVideoData()
            }
        }

        audioRenderer?.requestMediaDataWhenReady(on: audioQueue) { [weak self] in
            self?.supplyAudioData()
        }
    }

    func stopRequestingMedia() {
        if #available(iOS 17.0, *) {
            videoLayer.sampleBufferRenderer.stopRequestingMediaData()
        } else {
            videoLayer.stopRequestingMediaData()
        }
        audioRenderer?.stopRequestingMediaData()
    }

    private func supplyVideoData() {
        videoBufferLock.lock()
        defer { videoBufferLock.unlock() }

        guard !videoBuffer.isEmpty else {
            return
        }

        var isReady: Bool
        if #available(iOS 17.0, *) {
            isReady = videoLayer.sampleBufferRenderer.isReadyForMoreMediaData
        } else {
            isReady = videoLayer.isReadyForMoreMediaData
        }

        while isReady, !videoBuffer.isEmpty {
            let (sampleBuffer, timestamp) = videoBuffer.removeFirst()
            if #available(iOS 17.0, *) {
                videoLayer.sampleBufferRenderer.enqueue(sampleBuffer)
                isReady = videoLayer.sampleBufferRenderer.isReadyForMoreMediaData
            } else {
                videoLayer.enqueue(sampleBuffer)
                isReady = videoLayer.isReadyForMoreMediaData
            }

            if !isPlaying {
                synchronizer.setRate(1, time: timestamp)
                isPlaying = true
            }
        }
    }

    private func supplyAudioData() {
        audioBufferLock.lock()
        defer { audioBufferLock.unlock() }

        guard !audioBuffer.isEmpty, let audioRenderer else {
            return
        }

        while audioRenderer.isReadyForMoreMediaData, !audioBuffer.isEmpty {
            let (sampleBuffer, timestamp) = audioBuffer.removeFirst()
            audioRenderer.enqueue(sampleBuffer)
//            log.debug("[Player] did enquque audio data", subsystems: .call)
            if !isPlaying {
                synchronizer.setRate(1, time: timestamp)
                isPlaying = true
            }
        }
    }

    public func parseEvent(_ data: Data) {
        guard !data.isEmpty else {
            log.warning("[Player] Receive empty data", subsystems: .call)
            return
        }
        let eventType = CallNodeEventType(with: data[0])
        let payload = Data(data.subdata(in: 1..<data.count))
        switch eventType {
            case .videoConfig:
//            log.debug("[Player] parse video config frame")
            guard let videoConfig = VideoConfig(payload: payload) else {
                return
            }
            setVideoConfig(videoConfig)
        case .audioConfig:
            guard let audioConfig = AudioConfig(payload: payload) else {
                return
            }
            setAudioConfig(audioConfig)
        case .videoKeyFrame:
//            log.debug("[Player] parse video key frame")
            guard isReadyToPlay else {
                return
            }
            guard let videoFrame = VideoKeyFrame(payload: payload) else {
                return
            }
//            log.debug("[Player] start handle video key frame")
            self.handleVideoFrame(videoFrame.encodedFrame, timestamp: videoFrame.timestamp)
        case .videoDeltaFrame:
//            log.debug("[Player] parse video delta frame")
            guard isReadyToPlay else {
                return
            }
            guard let videoFrame = VideoDeltaFrame(payload: payload) else {
                return
            }
//            log.debug("[Player] start handle delta key frame")
            self.handleVideoFrame(videoFrame.encodedFrame, timestamp: videoFrame.timestamp)
        case .audioFrame:
            guard isReadyToPlay else {
                return
            }
            guard let audioFrame = AudioFrame(payload: payload) else {
                return
            }

            self.handleAudioFrame(audioFrame.encodedFrame, timestamp: audioFrame.timestamp)
        case .orientation:
            guard let videoOrientation = VideoOrientation(payload: payload) else {
                return
            }
            log.debug("[Player] Receiver orientation event: \(videoOrientation.rotation)")
            handleDeviceOrientationEvent(videoOrientation)
        case .unknown:
            log.warning("[Player] Receive unknown event: \(data.prefix(20).toString())...")
            break
        default:
            break
        }
    }

    // MARK: - Update config
    private func setVideoConfig(_ config: VideoConfig) {
        self.videoConfig = config
        let isH265 = config.codec.lowercased().contains("hev") || config.codec.lowercased().contains("h265") ? true: false
        guard let avcCData = Data(base64Encoded: config.description) else {
            log.error("[Player] failed to decode video description", subsystems: .call)
            return
        }

        let atomKey = isH265 ? "hvcC" : "avcC"
        let extensions: CFDictionary = [
            kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String: [
                atomKey: avcCData as CFData
            ]
        ] as CFDictionary

        var formatDescription: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: isH265 ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
            width: Int32(config.codedWidth),
            height: Int32(config.codedHeight),
            extensions: extensions,
            formatDescriptionOut: &formatDescription
        )
        if status == noErr {
            videoFormatDescription = formatDescription
            log.debug("[Player] Create video format.", subsystems: .call)
        } else {
            log.error("[Player] Failed to create video format with code: \(status).", subsystems: .call)
        }

        handleDeviceOrientationEvent(VideoOrientation(rotation: CGFloat(config.orientation)))
    }

    private func setAudioConfig(_ config: AudioConfig) {
        self.audioConfig = config
        if config.codec.lowercased().contains("opus") {
            setPcmAudioFormat(with: config)
        } else {
            setAvcCAudioFormat(with: config)
        }
    }

    private func setAvcCAudioFormat(with config: AudioConfig) {
        guard let ascData = Data(base64Encoded: config.description) else {
            log.error("[Player] Failed to get ascData from config description: \(config.description)")
            return
        }
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(config.sampleRate),
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: UInt32(MPEG4ObjectID.AAC_LC.rawValue),
            mBytesPerPacket: 0,
            mFramesPerPacket: 1024,  // AAC frame size
            mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(config.numberOfChannels),
            mBitsPerChannel: 0,
            mReserved: 0
        )

        var formatDescription: CMFormatDescription?
        let status = ascData.withUnsafeBytes { ascBytes in
            CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                asbd: &asbd,
                layoutSize: 0,
                layout: nil,
                magicCookieSize: ascData.count,
                magicCookie: ascBytes.baseAddress,
                extensions: nil,
                formatDescriptionOut: &formatDescription
            )
        }

        if status == noErr, let formatDescription = formatDescription {
            guard let verifyAsbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee else {
                log.error("[Player] Failed to create audio format description")
                return
            }
            audioFormatDescription = formatDescription
            log.debug("[Player] Set AAC audio config")
        }
    }

    private func setPcmAudioFormat(with config: AudioConfig) {
        guard let ascData = Data(base64Encoded: config.description) else {
            log.error("[Player] Failed to get ascData from config description: \(config.description)")
            return
        }

        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(config.sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(config.numberOfChannels * 2),
            //0,
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(config.numberOfChannels * 2),
            mChannelsPerFrame: UInt32(config.numberOfChannels),
            mBitsPerChannel: 16,
            mReserved: 0
        )

        var formatDescription: CMFormatDescription?
        let status = ascData.withUnsafeBytes { ascBytes in
            CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                asbd: &asbd,
                layoutSize: 0,
                layout: nil,
                magicCookieSize: 0,
                magicCookie: nil,
                extensions: nil,
                formatDescriptionOut: &formatDescription
            )
        }

        if status == noErr, let formatDescription {
            guard let verifyAsbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee else {
                log.error("[Player] Failed to create audio format description", subsystems: .call)
                return
            }
            audioFormatDescription = formatDescription
            log.debug("[Player] Set PCM audio config")
        }
    }

    // MARK: - Handle video data
    private func handleVideoFrame(_ data: Data, timestamp: CMTime) {
        guard let videoFormatDescription else {
            log.warning("[Player] Video format description not configured", subsystems: .call)
            return
        }
        // Create block buffer
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: data.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: data.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )

        guard status == noErr, let blockBuffer = blockBuffer else {
            log.warning("[Player] Failed to create video block buffer", subsystems: .call)
            return
        }

        // Copy data to block buffer
        status = data.withUnsafeBytes { ptr in
            CMBlockBufferReplaceDataBytes(
                with: ptr.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: data.count
            )
        }

        guard status == noErr else {
            log.warning("[Player] Failed to copy data block buffer", subsystems: .call)
            return
        }

        // Create sample buffer
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: timestamp,
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: videoFormatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: [data.count],
            sampleBufferOut: &sampleBuffer
        )

        guard status == noErr, let sampleBuffer = sampleBuffer else {
            log.warning("[Player] Failed to create sample buffer from block buffer", subsystems: .call)
            return
        }
        guard hasSetupRenderer else {
            return
        }

        self.enqueueVideoSampleBuffer(sampleBuffer, timestamp: timestamp)
    }

    private func enqueueVideoSampleBuffer(_ sampleBuffer: CMSampleBuffer, timestamp: CMTime) {
        videoBufferLock.lock()
        defer { videoBufferLock.unlock() }

        videoBuffer.append((sampleBuffer, timestamp))
        if videoBuffer.count > maxBufferSize {
            videoBuffer.removeFirst(videoBuffer.count - maxBufferSize)
        }
    }

    // MARK: - Handle audio data
    public func handleAudioFrame(_ data: Data, timestamp: CMTime) {

        guard let audioConfig, let formatDescription = audioFormatDescription else {
            log.warning("[Player] Audio config or formatdescripion not configured", subsystems: .call)
            return
        }

        if audioConfig.codec.lowercased().contains("mp4a.40") {
            decodeAacAudio(from: data, formatDescription: formatDescription, timestamp: timestamp)
        } else {
            decodeOpusAudio(from: data, formatDescription: formatDescription, timestamp: timestamp)
        }
    }

    private func decodeAacAudio(from data: Data, formatDescription: CMFormatDescription, timestamp: CMTime) {
        // Strip ADTS header if present
        var audioData = data
        if isADTSHeader(data) {
            let headerSize = (data[1] & 0x01) == 0 ? 9 : 7
            audioData = data.subdata(in: headerSize..<data.count)
        }

        // Create block buffer
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: audioData.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: audioData.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )

        guard status == noErr, let blockBuffer = blockBuffer else {
            log.warning("[Player] Failed to create aac audio block buffer", subsystems: .call)
            return
        }

        // Copy data to blockBuffer
        status = audioData.withUnsafeBytes { ptr in
            CMBlockBufferReplaceDataBytes(
                with: ptr.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: audioData.count
            )
        }

        guard status == noErr else {
            log.warning("[Player] Failed to copy aac audio data to block buffer", subsystems: .call)
            return
        }

        // Create packet description
        var packetDesc = AudioStreamPacketDescription(
            mStartOffset: 0,
            mVariableFramesInPacket: 0,
            mDataByteSize: UInt32(audioData.count)
        )
        // Create sample buffer
        var sampleBuffer: CMSampleBuffer?
        status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            presentationTimeStamp: timestamp,
            packetDescriptions: &packetDesc,
            sampleBufferOut: &sampleBuffer
        )

        guard status == noErr, let sampleBuffer = sampleBuffer else {
            log.warning("[Player] Failed to create aac audio sample buffer", subsystems: .call)
            return
        }

        guard hasSetupRenderer else {
            return
        }
//        audioQueue.async {
        self.enqueueAudioSampleBuffer(sampleBuffer, timestamp: timestamp)
//        }
    }

    private func decodeOpusAudio(from data: Data, formatDescription: CMFormatDescription, timestamp: CMTime) {
        guard let audioConfig else {
            log.warning("[Player] Don't have audio config", subsystems: .call)
            return
        }
        // Initialize opus decoder if needed
        if opusDecoder == nil {
            do {
                opusDecoder = try OpusDecoder(sampleRate: Int32(audioConfig.sampleRate), channels: Int32(audioConfig.numberOfChannels))
            } catch {
                log.warning("[Player] Create Opus decoder failed with error: \(error)", subsystems: .call)
            }
        }
        // Decode Opus data to raw PCM
        do {
            let pcmData = try opusDecoder?.decode(data: data, frameSize: 960) ?? []
            guard let buffer = createAudioBuffer(from: pcmData, timestamp: timestamp) else {
                return
            }
            enqueueAudioSampleBuffer(buffer, timestamp: timestamp)
        } catch {
            log.warning("[Player] Failed to decode opus audio", subsystems: .call)
        }
    }

    private func enqueueAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer, timestamp: CMTime) {
        audioBufferLock.lock()
        defer { audioBufferLock.unlock() }
        
        audioBuffer.append((sampleBuffer, timestamp))
        if audioBuffer.count > maxBufferSize {
            audioBuffer.removeFirst(audioBuffer.count - maxBufferSize)
        }
    }

    private func isADTSHeader(_ data: Data) -> Bool {
        guard data.count >= 2 else {
            return false
        }
        return data[0] == 0xFF && (data[1] & 0xF0) == 0xF0
    }

    private func createAudioBuffer(from pcmData: [Int16], timestamp: CMTime) -> CMSampleBuffer? {
         guard let audioConfig else {
            return nil
        }
        let dataSize = pcmData.count * MemoryLayout<Int16>.size
        let numberOfSamples = pcmData.count / audioConfig.numberOfChannels
        var sampleBuffer: CMSampleBuffer?

        // Create block buffer
        var blockBuffer: CMBlockBuffer?
        let data = Data(bytes: pcmData, count: dataSize)
        data.withUnsafeBytes { rawBuffer in
            CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
                                               memoryBlock: nil,
                                               blockLength: dataSize,
                                               blockAllocator: nil,
                                               customBlockSource: nil,
                                               offsetToData: 0,
                                               dataLength: dataSize,
                                               flags: 0,
                                               blockBufferOut: &blockBuffer)

            if let blockBuffer {
                CMBlockBufferReplaceDataBytes(with: rawBuffer.baseAddress!, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: dataSize)
            }
        }

        var timing = CMSampleTimingInfo(duration: CMTime(value: CMTimeValue(numberOfSamples),
                                                         timescale: Int32(audioConfig.sampleRate)),
                                        presentationTimeStamp: timestamp,
                                        decodeTimeStamp: .invalid)
        CMSampleBufferCreateReady(allocator: kCFAllocatorDefault,
                                  dataBuffer: blockBuffer,
                                  formatDescription: audioFormatDescription,
                                  sampleCount: numberOfSamples,
                                  sampleTimingEntryCount: 1,
//                                  sampleTimingEntryCount: 0,
                                  sampleTimingArray: &timing,
                                  sampleSizeEntryCount: 0,
                                  sampleSizeArray: nil,
                                  sampleBufferOut: &sampleBuffer)
        return sampleBuffer
    }
    // MARK: - Handle orientation
    public func handleDeviceOrientationEvent(_ videoOrientation: VideoOrientation) {
        
    }

    // MARK: - App life cycle
    public func appDidBecomeActive() {
        guard isReadyToPlay else {
            return
        }
        if #available(iOS 17.0, *) {
            videoLayer.sampleBufferRenderer.flush()
        } else {
            videoLayer.flush()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: {
            self.startRequestingMediaData()
        })
    }

    public func appWillResignActive() {

    }

    public func appDidEnterBackground() {
        if #available(iOS 17.0, *) {
            videoLayer.sampleBufferRenderer.stopRequestingMediaData()
            videoLayer.sampleBufferRenderer.flush()
        } else {
            videoLayer.stopRequestingMediaData()
            videoLayer.flush()
        }
    }
}
