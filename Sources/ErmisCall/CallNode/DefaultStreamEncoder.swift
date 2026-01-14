//
// Copyright 2025 Ermis Inc.
//

import AVFAudio
import AVFoundation
import AudioToolbox
import VideoToolbox
import CoreMedia
import CoreVideo
import ErmisOpus
import Combine
import ErmisChat

public protocol AppLifecycleObserver: AnyObject {
    func appDidBecomeActive()
    func appWillResignActive()
    func appDidEnterBackground()
}

public protocol StreamEncoder: AppLifecycleObserver {
    var audioConfigPublisher: CurrentValueSubject<AudioConfig?, Never> { get }
    var videoConfigPublisher: CurrentValueSubject<VideoConfig?, Never> { get }
    var videoKeyFramePublisher: PassthroughSubject<(VideoKeyFrame), Never> { get }
    var videoDeltaFramePublisher: PassthroughSubject<(VideoDeltaFrame), Never> { get }
    var audioFramePublisher: PassthroughSubject<AudioFrame, Never> { get }

    var isReadyToEncodeVideo: Bool { get set }
    var isReadyToEncodeAudio: Bool { get set }
    var forceKeyFrame: Bool { get set }

    func setupVideoEncoder(width: Int32,
                           height: Int32,
                           videoCodec: CMVideoCodecType,
                           audioCodec: AudioCodec,
                           bitrate: Int,
                           fps: Double) throws
    func encodeVideo(_ sampleBuffer: CMSampleBuffer, isKeyFrame: Bool)
    func encodeAudio(_ pcmSample: [Int16], timestamp: CMTime)

}

public class DefaultStreamEncoder: StreamEncoder {
    private var compressionSession: VTCompressionSession?

    private var startTime: CMTime?

    // The duration between two keyframe.
    private var keyframeInterval: Double = 2

    private var audioBuffer: [Int16] = []
    private var audioBufferStartTimestamp: CMTime = .zero
    private var audioCodec: AudioCodec = .aac
    private var audioConverter: AudioConverterRef?
    private var opusEncoder: OpusEncoder?

    public var forceKeyFrame: Bool = true

    private let encoderQueue = DispatchQueue(label: "network.ermis.encoder-queue")
    private var isSessionValid = false

    private lazy var sourceDescriptionFormat: AudioStreamBasicDescription = {
        return AudioStreamBasicDescription(
            mSampleRate: audioCodec.sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger
            | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )
    }()

    private lazy var aacDescriptionFormat: AudioStreamBasicDescription = {
        return AudioStreamBasicDescription(
            mSampleRate: audioCodec.sampleRate,
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: AudioFormatFlags(MPEG4ObjectID.AAC_LC.rawValue),
            mBytesPerPacket: 0,
            mFramesPerPacket: UInt32(audioCodec.frameSize),
            mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(audioCodec.numberOfChannels),
            mBitsPerChannel: 0,
            mReserved: 0
        )
    }()

    // Video fps
    var fps: Double = 30
    // Video codec
    var videoCodec: CMVideoCodecType = kCMVideoCodecType_HEVC

    var width: Int32 = 1280
    var height: Int32 = 720
    var bitrate: Int = 800_000

    // Publisher
    public var audioConfigPublisher = CurrentValueSubject<AudioConfig?, Never>(nil)
    public var videoConfigPublisher = CurrentValueSubject<VideoConfig?, Never>(nil)
    public var videoKeyFramePublisher = PassthroughSubject<(VideoKeyFrame), Never>()
    public var videoDeltaFramePublisher = PassthroughSubject<(VideoDeltaFrame), Never>()
    public var audioFramePublisher = PassthroughSubject<AudioFrame, Never>()

    public var isReadyToEncodeVideo: Bool = false
    public var isReadyToEncodeAudio: Bool = false

    var hasVideoConfig: Bool {
        return videoConfigPublisher.value != nil
    }

    var hasAudioConfig: Bool {
        return audioConfigPublisher.value != nil
    }

    // MARK: - Setup

    deinit {
        NotificationCenter.default.removeObserver(self)
        if let session = self.compressionSession {
            VTCompressionSessionInvalidate(session)
            self.compressionSession = nil
        }
        self.isSessionValid = false
        log.debug("[Encoder] Compression session invalidated", subsystems: .call)
    }

    public func setupVideoEncoder(
        width: Int32 = 1280,
        height: Int32 = 720,
        videoCodec: CMVideoCodecType = kCMVideoCodecType_H264,
        audioCodec: AudioCodec = .aac,
        bitrate: Int = 800_000,
        fps: Double = 30
    ) throws {
        self.width = width
        self.height = height
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.bitrate = bitrate
        self.fps = fps

        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width,
            height: height,
            codecType: videoCodec,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: videoEncodingCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &compressionSession
        )

        guard status == noErr, let compressionSession else {
            log.error("[Encoder] Failed to init video encoder")
            throw NSError(domain: "Ermis", code: 999, userInfo: nil)
        }

        // Configure session properties
        let properties: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_ProfileLevel: videoCodec == kCMVideoCodecType_H264 ? kVTProfileLevel_H264_Main_AutoLevel : kVTProfileLevel_HEVC_Main_AutoLevel, // or appropriate for your codec
            kVTCompressionPropertyKey_AllowFrameReordering: false, // for low latency
            kVTCompressionPropertyKey_MaxKeyFrameInterval: keyframeInterval * fps,
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: keyframeInterval,
            kVTCompressionPropertyKey_AverageBitRate: bitrate,
            kVTCompressionPropertyKey_ExpectedFrameRate: fps
        ]

        for (key, value) in properties {
            let propStatus = VTSessionSetProperty(compressionSession, key: key, value: value as CFTypeRef)
            if propStatus != noErr {
                log.warning("[Encoder] Failed to set \(key): \(propStatus)")
            }
        }

        isSessionValid = true
        log.debug("[Encoder] Video encoder initialized")
    }

    // MARK: - Encoding video
    public func encodeVideo(_ sampleBuffer: CMSampleBuffer, isKeyFrame: Bool = false) {
        guard let compressionSession,
              let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              CVPixelBufferGetWidth(imageBuffer) > 0,
              CVPixelBufferGetHeight(imageBuffer) > 0
        else {
            log.warning("[Encoder] COMPRESSION SESSION OR IMAGE BUFFER IS NIL")
            return
        }

        let presentationTimeStamp = isReadyToEncodeVideo ? CMSampleBufferGetPresentationTimeStamp(
            sampleBuffer
        ) : .zero

        let duration = CMSampleBufferGetDuration(sampleBuffer)
        let frameProps =
        [
            kVTEncodeFrameOptionKey_ForceKeyFrame: isKeyFrame || forceKeyFrame,
        ] as CFDictionary

        let status = VTCompressionSessionEncodeFrame(
            compressionSession,
            imageBuffer: imageBuffer,
            presentationTimeStamp: presentationTimeStamp,
            duration: duration,
            frameProperties: frameProps,
            sourceFrameRefcon: nil,
            infoFlagsOut: nil
        )
        if status != noErr {
            log.warning("[Encoder] Error encoding video frame: \(status)", subsystems: .call)
            if status == kVTInvalidSessionErr {
                self.handleInvalidSession()
            } else if status == kVTVideoEncoderMalfunctionErr {
                self.handleInvalidSession()
            }
        } else if presentationTimeStamp != .zero {
            forceKeyFrame = false
        }
    }

    private lazy var videoEncodingCallback: VTCompressionOutputCallback = {
        (refcon, sourceFrameRefcon, status, infoFlags, sampleBuffer) in
        guard status == noErr,
              let sampleBuffer = sampleBuffer,
              let refcon = refcon
        else {
            log.warning("[Encoder] Video encoding callback: failed with error: \(status)", subsystems: .call)
            return
        }

        let encoder = Unmanaged<DefaultStreamEncoder>.fromOpaque(refcon)
            .takeUnretainedValue()

        // Check if this is a keyframe
        var isKeyFrame = false
        if let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) {
            let attachments = unsafeBitCast(
                CFArrayGetValueAtIndex(attachmentsArray, 0),
                to: CFDictionary.self
            )
            let notSync = CFDictionaryContainsKey(
                attachments,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync)
                    .toOpaque()
            )

            isKeyFrame = !notSync
        }

        if isKeyFrame && !encoder.hasVideoConfig {
            if let formatDescription = CMSampleBufferGetFormatDescription(
                sampleBuffer
            ) {
                let dimention = CMVideoFormatDescriptionGetDimensions(
                    formatDescription
                )
                encoder.extractVideoConfig(
                    from: sampleBuffer,
                    width: Int(dimention.width),
                    height: Int(dimention.height),
                    fps: encoder.fps,
                    codecType: CMFormatDescriptionGetMediaSubType(
                        formatDescription
                    )
                )
            }
        }

        guard encoder.isReadyToEncodeVideo else {
            let videoConfig = encoder.videoConfigPublisher.value
            encoder.videoConfigPublisher.send(videoConfig)
            log.debug("[Encoder] Video not ready to encode, send config only")
            return
        }
        // Extract encoded data
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return
        }

        var length = 0
        var totalLenth = 0
        var dataPointer: UnsafeMutablePointer<Int8>?

        CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: &length,
            totalLengthOut: &totalLenth,
            dataPointerOut: &dataPointer
        )

        guard let pointer = dataPointer, totalLenth > 0 else {
            log.debug("[Encoder] data pointer nil or lenth < 0: \(dataPointer), \(totalLenth)")
            return
        }

        let data = Data(bytes: pointer, count: totalLenth)
        let presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        guard presentationTimeStamp != .zero else {
            log.debug("[Encoder] PTS is zero")
            return
        }

        let seconds = CMTimeGetSeconds(presentationTimeStamp)
        let nalus = encoder.splitAVCCNALUs(from: data)

        for nalu in nalus {
            if isKeyFrame {
                let videoKeyFrame = VideoKeyFrame(timestamp: presentationTimeStamp, encodedFrame: nalu)
                encoder.videoKeyFramePublisher.send(videoKeyFrame)
            } else {
                let videoDeltaFrame = VideoDeltaFrame(timestamp: presentationTimeStamp, encodedFrame: nalu)
                encoder.videoDeltaFramePublisher.send(videoDeltaFrame)
            }
        }
    }

    // Get video config from avcc sample buffer.
    private func extractVideoConfig(
        from sampleBuffer: CMSampleBuffer,
        width: Int,
        height: Int,
        fps: Double,
        codecType: CMVideoCodecType
    ) {
        guard
            let formatDescription = CMSampleBufferGetFormatDescription(
                sampleBuffer
            )
        else {
            return
        }
        // Extract SPS and PPS for H.264
        if codecType == kCMVideoCodecType_H264 {
            extractH264VideoConfig(
                from: formatDescription,
                width: width,
                height: height,
                fps: fps
            )
        } else if codecType == kCMVideoCodecType_HEVC {
            extractHEVCVideoConfig(
                from: formatDescription,
                width: width,
                height: height,
                fps: fps
            )
        }
    }

    private func extractH264VideoConfig(
        from formatDescription: CMFormatDescription,
        width: Int,
        height: Int,
        fps: Double
    ) {
        var spsSize: Int = 0
        var spsCount: Int = 0
        var sps: UnsafePointer<UInt8>?

        var ppsSize: Int = 0
        var ppsCount: Int = 0
        var pps: UnsafePointer<UInt8>?

        let spsStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDescription,
            parameterSetIndex: 0,
            parameterSetPointerOut: &sps,
            parameterSetSizeOut: &spsSize,
            parameterSetCountOut: &spsCount,
            nalUnitHeaderLengthOut: nil
        )

        let ppsStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDescription,
            parameterSetIndex: 1,
            parameterSetPointerOut: &pps,
            parameterSetSizeOut: &ppsSize,
            parameterSetCountOut: &ppsCount,
            nalUnitHeaderLengthOut: nil
        )

        guard spsStatus == noErr,
              ppsStatus == noErr,
              let spsData = sps,
              let ppsData = pps
        else {
            return
        }

        // Get avccData by combine sps and pps
        var avccData = Data()

        // Header
        avccData.append(0x01)
        avccData.append(spsData[1])  // AVCProfileIndication
        avccData.append(spsData[2])  // profile_compatibility
        avccData.append(spsData[3])  // AVCLevelIndication
        avccData.append(0xFF)  // lengthSizeMinusOne (4 bytes)
        // SPS
        avccData.append(0xE1)  // numOfSequenceParameterSets (1)
        avccData.append(UInt8((spsSize >> 8) & 0xFF))
        avccData.append(UInt8(spsSize & 0xFF))
        avccData.append(Data(bytes: spsData, count: spsSize))
        // PPS
        avccData.append(0x01)  // numOfPictureParameterSets (1)
        avccData.append(UInt8((ppsSize >> 8) & 0xFF))
        avccData.append(UInt8(ppsSize & 0xFF))
        avccData.append(Data(bytes: ppsData, count: ppsSize))

        let base64Description = avccData.base64EncodedString()

        // Generate codec string
        let profile = String(format: "%02X", spsData[1])
        let comparibility = String(format: "%02X", spsData[2])
        let level = String(format: "%02X", spsData[3])
        let codecString = "avc1.\(profile)\(comparibility)\(level)"

        log.debug("""
           [Encoder] extract video config:
            - Codec String: \(codecString)
            - Profile: 0x\(profile) (\(getProfileName(spsData[1])))
            - Level: 0x\(level) (\(getLevelName(spsData[3])))
        """, subsystems: .call)

        let videoConfig = VideoConfig(
            codec: codecString,
            codedWidth: width,
            codedHeight: height,
            frameRate: fps,
            orientation: 90,
            description: base64Description
        )
        videoConfigPublisher.send(videoConfig)
    }

    private func extractHEVCVideoConfig(
        from formatDescription: CMFormatDescription,
        width: Int,
        height: Int,
        fps: Double
    ) {
        let codecType = CMFormatDescriptionGetMediaSubType(formatDescription)
        guard codecType == kCMVideoCodecType_HEVC else {
            log.warning("[Encoder] Invalid codec type, expected HEVC but receive: \(codecType)", subsystems: .call)
            return
        }

        guard
            let atoms = CMFormatDescriptionGetExtension(
                formatDescription,
                extensionKey:
                    kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms
            ) as? [String: Data], let hvcC = atoms["hvcC"]
        else {
            log.warning("[Encoder] Can't not find atoms when extract hevc config", subsystems: .call)
            return
        }

        // Parse codec string
        guard let codecString = parseHEVCCodecStringFromHvcC(hvcC) else {
            log.warning("[Encoder] Can't parse codec string from hvcC data.", subsystems: .call)
            return
        }

        let description = hvcC.base64EncodedString()

        let videoConfig = VideoConfig(
            codec: codecString,
            codedWidth: width,
            codedHeight: height,
            frameRate: fps,
            orientation: 90,
            description: description
        )
        videoConfigPublisher.send(videoConfig)
    }

    private func parseHEVCCodecStringFromHvcC(_ hvcC: Data) -> String? {
        // hvcC atom structure (ISO/IEC 14496-15):
        // [0] configurationVersion (1 byte)
        // [1] general_profile_space (2 bits) + general_tier_flag (1 bit) + general_profile_idc (5 bits)
        // [2-5] general_profile_compatibility_flags (32 bits)
        // [6-11] general_constraint_indicator_flags (48 bits)
        // [12] general_level_idc (8 bits)

        guard hvcC.count >= 13 else {
            log.warning("[Encoder] hvcC too small: \(hvcC.count) bytes.", subsystems: .call)
            return nil
        }
        let byte1 = hvcC[1]
        let profileSpace = (byte1 >> 6) & 0x03
        let tierFlag = (byte1 >> 5) & 0x01
        let profileIdc = byte1 & 0x1F
        // Parse byte 1: profile_space (2 bits) + tier_flag (1 bit) + profile_idc (5 bits)
        let compatibilityFlags =
        UInt32(hvcC[2] << 24) | UInt32(hvcC[3] << 16) | UInt32(hvcC[4] << 8)
        | UInt32(hvcC[5])

        // Parse general constraint flags (48 bits)
        var constraintBytes: [UInt8] = []
        for i in 6..<12 {
            constraintBytes.append(hvcC[i])
        }

        // Build codec string
        var codecString = "hev1"

        // Level idc
        let levelIdc = hvcC[12]

        let profileSpaceString = ["", "A", "B", "C"][Int(profileSpace)]
        codecString += ".\(profileSpaceString)\(profileIdc)"

        // Profile compatibility
        let compatHex = String(format: "%X", compatibilityFlags)
        codecString += ".\(compatHex)"

        // Tier and Level
        let tier = tierFlag == 1 ? "H" : "L"
        codecString += ".\(tier)\(levelIdc)"

        // Constraint bytes (only include non-zero trailing bytes)
        // Find the last non-zero byte
        var lastNonZeroIndex = -1
        for (index, byte) in constraintBytes.enumerated() {
            if byte != 0 {
                lastNonZeroIndex = index
            }
        }

        // Add constraint bytes up to last non-zero
        if lastNonZeroIndex >= 0 {
            for i in 0...lastNonZeroIndex {
                let byte = constraintBytes[i]
                codecString += ".\(String(format: "%X", byte))"
            }
        }

        return codecString
    }

    private func getProfileName(_ profile: UInt8) -> String {
        switch profile {
        case 66: return "Baseline"
        case 77: return "Main"
        case 88: return "Extended"
        case 100: return "High"
        case 110: return "High 10"
        case 122: return "High 4:2:2"
        case 244: return "High 4:4:4"
        default: return "Unknown"
        }
    }

    private func getLevelName(_ level: UInt8) -> String {
        let levelValue = Double(level) / 10.0
        return "Level \(levelValue)"
    }

    private func splitAVCCNALUs(from data: Data) -> [Data] {
        var nalus: [Data] = []
        var offset = 0

        while offset + 4 <= data.count {
            // Copy bytes safely (no alignment assumptions)
            let lengthBytes = data[offset..<offset + 4]
            let naluLength = lengthBytes.reduce(UInt32(0)) {
                ($0 << 8) | UInt32($1)
            }

            let naluStart = offset
            let naluEnd = offset + 4 + Int(naluLength)

            guard naluEnd <= data.count else {
                log.warning("[Encoder] Invalid NALU length \(naluLength), exceeds buffer size \(data.count)", subsystems: .call)
                break
            }

            let shouldInclude: Bool

            if videoCodec == kCMVideoCodecType_H264 {
                let naluType = data[naluStart + 4] & 0x1F
                shouldInclude = naluType != 7 && naluType != 8 && naluType != 6
            } else {
                let naluType = (data[naluStart + 4] >> 1) & 0x3F
                shouldInclude = naluType != 32 && naluType != 33 && naluType != 34 && naluType != 39
            }
            // Remove SEI nalu type 39 in hevc, and 06 in h264, not sure it effect.
            if shouldInclude {
                nalus.append(data[naluStart..<naluEnd])
            }
            offset = naluEnd
        }
        return nalus
    }

    // MARK: - Encode Audio
    public func encodeAudio(_ pcmSample: [Int16], timestamp: CMTime) {
        accumulateFrame(pcmSample, presentationTimeStamp: isReadyToEncodeAudio ? timestamp : .zero)
    }

    // Split sample buffer to each audio frame
    private func extractAudioFrame(from sampleBuffer: CMSampleBuffer)
    -> [Int16]?
    {
        var audioBufferList = AudioBufferList()
        var blockBuffer: CMBlockBuffer?

        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &audioBufferList,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )

        guard status == noErr else {
            log.warning("[Encoder] Failed to get audio buffer list : \(status)", subsystems: .call)
            return nil
        }

        let audioBuffer = audioBufferList.mBuffers
        guard let audioData = audioBuffer.mData else {
            return nil
        }

        let sampleCount =
        Int(audioBuffer.mDataByteSize) / MemoryLayout<Int16>.size
        let pcmPointer = audioData.assumingMemoryBound(to: Int16.self)

        var samples = [Int16](repeating: 0, count: sampleCount)
        for i in 0..<sampleCount {
            samples[i] = pcmPointer[i]
        }

        return samples
    }

    private func accumulateFrame(
        _ samples: [Int16],
        presentationTimeStamp: CMTime
    ) {
        let duration = CMTimeSubtract(presentationTimeStamp, audioBufferStartTimestamp)
        let seconds = CMTimeGetSeconds(duration)
        if seconds > 0.1 {
            // Reset buffer
            audioBufferStartTimestamp = presentationTimeStamp
            audioBuffer.removeAll()
        }

        let frameDuration = CMTime(value: CMTimeValue(audioCodec.frameSize),
                                   timescale: CMTimeScale(audioCodec.sampleRate))
        audioBuffer.append(contentsOf: samples)
        while audioBuffer.count >= audioCodec.frameSize {
            let frame = Array(audioBuffer.prefix(audioCodec.frameSize))
            audioBuffer.removeFirst(audioCodec.frameSize)
            guard var data = encodeFrame(frame) else {
                if presentationTimeStamp != .zero {
                    audioBufferStartTimestamp = CMTimeAdd(audioBufferStartTimestamp, frameDuration)
                }
                log.debug("[Encoder] Failed to encoded audio frame")
                return
            }

            guard presentationTimeStamp != .zero else {
                log.debug("[Encoder] Presentation timestamp is zero")
                return
            }

            let audioFrame = AudioFrame(timestamp: audioBufferStartTimestamp, encodedFrame: data)
            audioFramePublisher.send(audioFrame)
            audioBufferStartTimestamp = CMTimeAdd(audioBufferStartTimestamp, frameDuration)
        }
    }

    private func encodeFrame(_ pcmFrame: [Int16]) -> Data? {
        switch audioCodec {
        case .opus:
            encodeOpusFrame(pcmFrame)
        case .aac:
            encodeAACFrame(pcmFrame)
        }
    }

    private func encodeOpusFrame(_ pcmFrame: [Int16]) -> Data? {
        if !hasAudioConfig {
            let description = generateRawOpusDescription(
                sampleRate: Int(audioCodec.sampleRate),
                channels: Int(audioCodec.numberOfChannels)
            )
            let audioConfig = AudioConfig(
                sampleRate: Int(audioCodec.sampleRate),
                numberOfChannels: Int(audioCodec.numberOfChannels),
                codec: "opus",
                description: description
            )
            audioConfigPublisher.send(audioConfig)
        }

        guard isReadyToEncodeAudio else {
            let audioConfig = audioConfigPublisher.value
            audioConfigPublisher.send(audioConfig)
            return nil
        }
        do {
            if opusEncoder == nil {
                opusEncoder = try OpusEncoder(
                    sampleRate: Int32(audioCodec.sampleRate),
                    channels: audioCodec.numberOfChannels
                )
            }

            let opusData = try opusEncoder?.encode(
                pcm: pcmFrame,
                frameSize: Int32(audioCodec.frameSize)
            )
            return opusData
        } catch {
            log.error("[Encoder] Failed to encoder PCM")
            return nil
        }
    }

    private func encodeAACFrame(_ pcmFrame: [Int16]) -> Data? {

        if !hasAudioConfig {
            let description = createAudioSpecificConfig(
                sampleRate: Int(aacDescriptionFormat.mSampleRate),
                channels: Int(aacDescriptionFormat.mChannelsPerFrame)
            )
            let audioConfig = AudioConfig(
                sampleRate: Int(aacDescriptionFormat.mSampleRate),
                numberOfChannels: Int(aacDescriptionFormat.mChannelsPerFrame),
                codec: "mp4a.40.2",
                description: description
            )
            audioConfigPublisher.send(audioConfig)
        }

        guard isReadyToEncodeAudio else {
            let audioConfig = audioConfigPublisher.value
            audioConfigPublisher.send(audioConfig)
            log.warning("[Encoder] Not ready to encode audio")
            return nil
        }

        if self.audioConverter == nil {
            var status = AudioConverterNew(
                &sourceDescriptionFormat,
                &aacDescriptionFormat,
                &audioConverter
            )
            guard status == noErr, let audioConverter else {
                log.warning("[Encoder] create audio converter failed with status: \(status)")
                return nil
            }

            var bitRate: UInt32 = audioCodec.bitrate
            status = AudioConverterSetProperty(
                audioConverter,
                kAudioConverterEncodeBitRate,
                UInt32(MemoryLayout<UInt32>.size),
                &bitRate
            )

            if status != noErr {
                log.warning("[Encoder] Failed to setup AAC bitrate: \(status)")
                return nil
            }

            var quality = kAudioConverterQuality_High
            AudioConverterSetProperty(
                audioConverter,
                kAudioConverterCodecQuality,
                UInt32(MemoryLayout<UInt32>.size),
                &quality
            )
            log.debug("[Encoder] AAC encoder initialized (\(audioCodec.sampleRate)Hz, \(audioCodec.bitrate)bps)")
        }

        guard let audioConverter else {
            return nil
        }

        guard pcmFrame.count == audioCodec.frameSize else {
            return nil
        }

        let pcmData = pcmFrame.withUnsafeBufferPointer { buffer in
            Data(
                bytes: buffer.baseAddress!,
                count: buffer.count * MemoryLayout<Int16>.size
            )
        }

        let maxOutputSize = pcmData.count
        var outputBuffer = [UInt8](repeating: 0, count: maxOutputSize)
        var outputDataPacketSize: UInt32 = 1

        var outputBufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: UInt32(audioCodec.numberOfChannels),
                mDataByteSize: UInt32(maxOutputSize),
                mData: &outputBuffer
            )
        )

        var inputData = pcmData

        let status = inputData.withUnsafeMutableBytes {
            inputBytes -> OSStatus in
            var context = ConverterContext(
                data: inputBytes.baseAddress,
                dataSize: pcmData.count,
                channels: UInt32(audioCodec.numberOfChannels),
                bytesPerPacket: sourceDescriptionFormat.mBytesPerPacket
            )

            return AudioConverterFillComplexBuffer(
                audioConverter,
                {
                    (
                        converter,
                        ioNumberDataPackets,
                        ioData,
                        outDataPacketDescription,
                        inUserData
                    ) -> OSStatus in
                    guard let userData = inUserData else {
                        log.error("[Encoder] No user data")
                        return -1
                    }

                    let context = userData.assumingMemoryBound(
                        to: ConverterContext.self
                    )

                    if context.pointee.data == nil {
                        ioNumberDataPackets.pointee = 0
                        return -1
                    }

                    ioData.pointee.mNumberBuffers = 1
                    ioData.pointee.mBuffers.mData = UnsafeMutableRawPointer(
                        mutating: context.pointee.data
                    )
                    ioData.pointee.mBuffers.mDataByteSize = UInt32(
                        context.pointee.dataSize
                    )
                    ioData.pointee.mBuffers.mNumberChannels =
                    context.pointee.channels

                    ioNumberDataPackets.pointee =
                    UInt32(context.pointee.dataSize)
                    / context.pointee.bytesPerPacket

                    context.pointee.data = nil
                    context.pointee.dataSize = 0

                    return noErr
                },
                &context,
                &outputDataPacketSize,
                &outputBufferList,
                nil
            )
        }

        guard status == noErr else {
            log.warning("[Encoder] AAC encoding failed: \(status)")
            return nil
        }

        let outputSize = Int(outputBufferList.mBuffers.mDataByteSize)
        if !hasAudioConfig {
            let description = createAudioSpecificConfig(
                sampleRate: Int(aacDescriptionFormat.mSampleRate),
                channels: Int(aacDescriptionFormat.mChannelsPerFrame)
            )
            let audioConfig = AudioConfig(
                sampleRate: Int(aacDescriptionFormat.mSampleRate),
                numberOfChannels: Int(aacDescriptionFormat.mChannelsPerFrame),
                codec: "mp4a.40.2",
                description: description
            )
            audioConfigPublisher.send(audioConfig)
        }
        return Data(bytes: outputBuffer, count: outputSize)
    }

    private func generateRawOpusDescription(sampleRate: Int, channels: Int)
    -> String
    {
        var data = Data()

        // "OpusHead"
        data.append(contentsOf: [
            0x4F, 0x70, 0x75, 0x73, 0x48, 0x65, 0x61, 0x64,
        ])

        // Version
        data.append(0x01)

        // Channel count
        data.append(UInt8(channels))

        // Pre-skip (312 samples = 6.5ms at 48kHz, little-endian)
        data.append(contentsOf: [0x38, 0x01])

        // Sample rate (little-endian)
        var rate = UInt32(sampleRate).littleEndian
        data.append(contentsOf: withUnsafeBytes(of: &rate) { Data($0) })

        // Output gain (0 dB)
        data.append(contentsOf: [0x00, 0x00])

        // Channel mapping family
        data.append(0x00)

        return data.base64EncodedString()
    }

    // Get audio description in Audio config.
    private func createAudioSpecificConfig(sampleRate: Int, channels: Int)
    -> String
    {
        let sampleRateIndices: [Int: Int] = [
            96000: 0, 88200: 1, 64000: 2, 48000: 3,
            44100: 4, 32000: 5, 24000: 6, 22050: 7,
            16000: 8, 12000: 9, 11025: 10, 8000: 11,
        ]

        guard let sampleRateIndex = sampleRateIndices[sampleRate] else {
            fatalError("Unsupported sample rate")
        }

        let profile = 2  // AAC-LC (mp4a.40.2)

        // Construct 2-byte ASC
        let byte1 = UInt8((profile << 3) | (sampleRateIndex >> 1))
        let byte2 = UInt8(((sampleRateIndex & 0x1) << 7) | (channels << 3))

        let asc = Data([byte1, byte2])
        return asc.base64EncodedString()
    }
    // MARK: - Handle app cycle
    public func appWillResignActive() {
        // Don't invalidate immediately, wait for background
    }

    public func appDidEnterBackground() {
        invalidateSession()
    }

    public func appDidBecomeActive() {
        // Small delay to ensure camera is ready
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.recreateSession()
        }
    }

    private func recreateSession() {
        invalidateSession()
        encoderQueue.async(execute: { [weak self] in
            guard let self else {
                return
            }
            do {
                try setupVideoEncoder(width: width,
                                      height: height,
                                      videoCodec: videoCodec,
                                      audioCodec: audioCodec,
                                      bitrate: bitrate,
                                      fps: fps)
            } catch {
                log.error("[Encoder] Failed to recreate session: \(error)")
            }
        })
    }

    private func invalidateSession() {
        encoderQueue.async {
            if let session = self.compressionSession {
                VTCompressionSessionInvalidate(session)
                self.compressionSession = nil
            }
            self.isSessionValid = false
            log.debug("[Encoder] Compression session invalidated", subsystems: .call)
        }
    }

    private func handleInvalidSession() {
        log.debug("[Encoder] handle invalidate session")
        isSessionValid = false

        // Recreate session on main queue to avoid race conditions
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.recreateSession()
        }
    }
}

fileprivate struct ConverterContext {
    var data: UnsafeRawPointer?
    var dataSize: Int
    var channels: UInt32
    var bytesPerPacket: UInt32
}
