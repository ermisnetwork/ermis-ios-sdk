//
// Copyright 2025 Ermis Inc.
//

import Foundation
import CoreMedia
import AudioToolbox
import ErmisChat
import ErmisOpus
import Combine

public struct DecodedAudioFrame {
    public let timestamp: CMTime
    public let samples: [Int16]
    public let sampleRate: Int
    public let channels: Int
}

public protocol StreamDecoder {
    var audioHardwareFramerate: Int { get set }
    var audioBufferPublisher: PassthroughSubject<[Int16], Never> { get }
    var videoBufferPublisher: PassthroughSubject<(CMSampleBuffer, CMTime), Never> { get }

    func setVideoConfig(_ config: VideoConfig)
    func setAudioConfig(_ config: AudioConfig)
    func decodeVideoFrame(data: Data, timestamp: CMTime)
    func decodeAudioFrame(_ frame: AudioFrame)
}

public class DefaultStreamDecoder: StreamDecoder {

    private var audioConfig: AudioConfig?
    private var videoConfig: VideoConfig?
    private var opusDecoder: OpusDecoder?

    private var videoFormatDescription: CMVideoFormatDescription?
    private var audioFormatDescription: CMFormatDescription?

    private var audioConverter: AudioConverter?

    public var audioHardwareFramerate = 48_000

    public var audioBufferPublisher: PassthroughSubject<[Int16], Never> = .init()
    public var videoBufferPublisher: PassthroughSubject<(CMSampleBuffer, CMTime), Never> = .init()

    private var cancelBags: Set<AnyCancellable> = []

    // MARK: - Config

    public func setVideoConfig(_ config: VideoConfig) {
        self.videoConfig = config
        let isH265 = config.codec.lowercased().contains("hev") || config.codec.lowercased().contains("h265") ? true: false
        guard let avcCData = Data(base64Encoded: config.description) else {
            log.error("[Decoder] failed to decode video description", subsystems: .call)
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
            log.debug("[Decoder] Create video format.", subsystems: .call)
        } else {
            log.error("[Decoder] Failed to create video format with code: \(status).", subsystems: .call)
        }
    }

    public func setAudioConfig(_ config: AudioConfig) {
        self.audioConfig = config
        if config.codec.lowercased().contains("opus") {
            setPcmAudioFormat(with: config)
        } else {
            setAvcCAudioFormat(with: config)
        }
    }

    private func setAvcCAudioFormat(with config: AudioConfig) {
        guard let ascData = Data(base64Encoded: config.description) else {
            log.error("[Decoder] Failed to get ascData from config description: \(config.description)")
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
                log.error("[Decoder] Failed to create audio format description")
                return
            }
            audioFormatDescription = formatDescription
            log.debug("[Decoder] Set AAC audio config")
        }
    }

    private func setPcmAudioFormat(with config: AudioConfig) {
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
        let status = CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                asbd: &asbd,
                layoutSize: 0,
                layout: nil,
                magicCookieSize: 0,
                magicCookie: nil,
                extensions: nil,
                formatDescriptionOut: &formatDescription
        )

        if status == noErr, let formatDescription {
            guard let verifyAsbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee else {
                log.error("[Decoder] Failed to create audio format description", subsystems: .call)
                return
            }
            audioFormatDescription = formatDescription
            log.debug("[Decoder] Set PCM audio config")
        }
    }

    // MARK: - Video frame
    public func decodeVideoFrame(data: Data, timestamp: CMTime) {
        guard let videoFormatDescription else {
            log.warning("[Decoder] Video format description not configured", subsystems: .call)
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
            log.warning("[Decoder] Failed to create video block buffer", subsystems: .call)
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
            log.warning("[Decoder] Failed to copy data block buffer", subsystems: .call)
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
            log.warning("[Decoder] Failed to create sample buffer from block buffer", subsystems: .call)
            return
        }

        videoBufferPublisher.send((sampleBuffer, timestamp))
    }

    // MARK: - Audio frame

    public func decodeAudioFrame(_ frame: AudioFrame) {
        guard let audioConfig, let formatDescription = audioFormatDescription else {
            log.warning("[Decoder] Audio config or formatdescripion not configured", subsystems: .call)
            return
        }
        if audioConfig.codec.lowercased().contains("mp4a.40") {
            if isADTSHeader(frame.encodedFrame) {
                let headerSize = (frame.encodedFrame[1] & 0x01) == 0 ? 9 : 7
                return decodeAacAudio(from: Data(frame.encodedFrame.subdata(in: headerSize..<frame.encodedFrame.count)), formatDescription: formatDescription, timestamp: frame.timestamp)
            } else {
                return decodeAacAudio(from: frame.encodedFrame, formatDescription: formatDescription, timestamp: frame.timestamp)
            }
        } else {
            decodeOpusAudio(from: frame.encodedFrame, formatDescription: formatDescription, timestamp: frame.timestamp)
        }
    }

    private func decodeAacAudio(from data: Data, formatDescription: CMFormatDescription, timestamp: CMTime) {
        resampleAacAudio(from: data, formatDescription: formatDescription, timestamp: timestamp)
    }

    private func createAudioBufferFromAACData(_ data: Data, formatDescription: CMAudioFormatDescription, timestamp: CMTime) -> CMSampleBuffer? {
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
            log.warning("[Decoder] Failed to create aac audio block buffer", subsystems: .call)
            return nil
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
            log.warning("[Decoder] Failed to copy aac audio data to block buffer", subsystems: .call)
            return nil
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
            log.warning("[Decoder] Failed to create aac audio sample buffer", subsystems: .call)
            return nil
        }

        return sampleBuffer
    }

    private func resampleAacAudio(from data: Data, formatDescription: CMFormatDescription, timestamp: CMTime) {
        guard let audioFormatDescription else {
            return
        }
        if audioConverter == nil {
            do {
                audioConverter = try AudioConverter(outputSampleRate: audioHardwareFramerate, numberOfChannels: audioConfig?.numberOfChannels ?? 2)
                audioConverter!.decodedFramePublisher
                    .sink { [weak self] decodedFrame in
                        self?.audioBufferPublisher.send(decodedFrame.samples)
                    }
                    .store(in: &cancelBags)
            } catch {
                log.error("[Decoder] Failed to create aac resampler. \(error)")
            }
        }
        guard let audioConverter else {
            return
        }

        do {
            let samples = try audioConverter.decode(aacData: data, timestamp: timestamp)
        } catch {
            log.error("[Decoder] Failed to decode aac data. \(error)")
        }
    }

    private func decodeOpusAudio(from data: Data, formatDescription: CMFormatDescription, timestamp: CMTime) {
        guard let audioConfig else {
            log.warning("[Decoder] Don't have audio config", subsystems: .call)
            return
        }
        // Initialize opus decoder if needed
        if opusDecoder == nil {
            do {
                opusDecoder = try OpusDecoder(sampleRate: Int32(audioConfig.sampleRate), channels: Int32(audioConfig.numberOfChannels))
            } catch {
                log.warning("[Decoder] Create Opus decoder failed with error: \(error)", subsystems: .call)
            }
        }
        // Decode Opus data to raw PCM
        do {
            let pcmData = try opusDecoder?.decode(data: data, frameSize: 960) ?? []
            log.debug("[Decoder] Opus decoded: input=\(data.count) bytes, output=\(pcmData.count) samples")
            audioBufferPublisher.send(pcmData)
        } catch {
            log.warning("[Decoder] Failed to decode opus audio", subsystems: .call)
        }
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

    private func createAudioBuffer(from pcmData: Data, timestamp: CMTime) -> CMSampleBuffer? {
        guard let audioConfig else {
            return nil
        }
        let dataSize = pcmData.count
        let numberOfSamples = pcmData.count / 2 * audioConfig.numberOfChannels
        var sampleBuffer: CMSampleBuffer?

        // Create block buffer
        var blockBuffer: CMBlockBuffer?
        pcmData.withUnsafeBytes { rawBuffer in
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

    private func isADTSHeader(_ data: Data) -> Bool {
        guard data.count >= 2 else {
            return false
        }
        return data[0] == 0xFF && (data[1] & 0xF0) == 0xF0
    }
}

private final class AACInputContext {
    var data: Data
    var packetDesc: AudioStreamPacketDescription

    init(data: Data) {
        self.data = data
        self.packetDesc = AudioStreamPacketDescription(
            mStartOffset: 0,
            mVariableFramesInPacket: 0,
            mDataByteSize: UInt32(data.count)
        )
    }
}
