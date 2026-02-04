//
// Copyright 2025 Ermis Inc.
//

import Foundation
import AudioToolbox
import Combine
import CoreMedia

public class AudioConverter {

    // MARK: - Properties

    private var audioConverter: AudioConverterRef?
    private var resamplerConverter: AudioConverterRef?

    private let inputSampleRate: Double = 48000
    private let outputSampleRate: Double
    private let numberOfChannels: Int
    private let frameSize: Int = 1024  // AAC frame size

    private var inputBuffer: Data = Data()
    private var inputPacketDescriptions: [AudioStreamPacketDescription] = []

    public let decodedFramePublisher = PassthroughSubject<DecodedAudioFrame, Never>()

    // Input format (AAC)
    private lazy var aacFormat: AudioStreamBasicDescription = {
        return AudioStreamBasicDescription(
            mSampleRate: inputSampleRate,
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: AudioFormatFlags(MPEG4ObjectID.AAC_LC.rawValue),
            mBytesPerPacket: 0,
            mFramesPerPacket: UInt32(frameSize),
            mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(numberOfChannels),
            mBitsPerChannel: 0,
            mReserved: 0
        )
    }()

    // Intermediate PCM format (at input sample rate)
    private lazy var pcmFormatAtInputRate: AudioStreamBasicDescription = {
        return AudioStreamBasicDescription(
            mSampleRate: inputSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(2 * 1),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(2 * 1),
            mChannelsPerFrame: UInt32(1),
            mBitsPerChannel: 16,
            mReserved: 0
        )
    }()

    // Output PCM format (at desired sample rate)
    private lazy var pcmFormatAtOutputRate: AudioStreamBasicDescription = {
        return AudioStreamBasicDescription(
            mSampleRate: outputSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(2 * numberOfChannels),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(2 * numberOfChannels),
            mChannelsPerFrame: UInt32(numberOfChannels),
            mBitsPerChannel: 16,
            mReserved: 0
        )
    }()

    // MARK: - Initialization

    public init(outputSampleRate: Int, numberOfChannels: Int) {
        self.outputSampleRate = Double(outputSampleRate)
        self.numberOfChannels = numberOfChannels
    }

    deinit {
        if let converter = audioConverter {
            AudioConverterDispose(converter)
        }
        if let resampler = resamplerConverter {
            AudioConverterDispose(resampler)
        }
    }

    // MARK: - Setup

    private func setupDecoder() -> Bool {
        guard audioConverter == nil else { return true }

        var status = AudioConverterNew(
            &aacFormat,
            &pcmFormatAtInputRate,
            &audioConverter
        )

        guard status == noErr, audioConverter != nil else {
            print("[AudioConverter] Failed to create AAC decoder: \(status)")
            return false
        }

        print("[AudioConverter] AAC decoder initialized")
        return true
    }

    private func setupResampler() -> Bool {
        // Skip if sample rates match
        guard inputSampleRate != outputSampleRate else { return true }
        guard resamplerConverter == nil else { return true }

        let status = AudioConverterNew(
            &pcmFormatAtInputRate,
            &pcmFormatAtOutputRate,
            &resamplerConverter
        )

        guard status == noErr, resamplerConverter != nil else {
            print("[AACDecoder] Failed to create resampler: \(status)")
            return false
        }

        // Set quality for resampling
        var quality = kAudioConverterQuality_High
        AudioConverterSetProperty(
            resamplerConverter!,
            kAudioConverterSampleRateConverterQuality,
            UInt32(MemoryLayout<UInt32>.size),
            &quality
        )

        print("[AudioConverter] Resampler initialized (\(inputSampleRate)Hz -> \(outputSampleRate)Hz)")
        return true
    }

    // MARK: - Decoding

    /// Decode an AAC frame from your encoder
    /// - Parameters:
    ///   - aacData: The encoded AAC data from AudioFrame.encodedFrame
    ///   - timestamp: The timestamp from AudioFrame.timestamp
    /// - Returns: Decoded PCM samples at the configured output sample rate
    public func decode(aacData: Data, timestamp: CMTime) -> DecodedAudioFrame? {
        guard setupDecoder(), setupResampler() else {
            return nil
        }

        guard let audioConverter = audioConverter else {
            return nil
        }

        // Decode AAC to PCM at input sample rate
        let outputFrameCount = frameSize
        let outputBufferSize = outputFrameCount * numberOfChannels * MemoryLayout<Int16>.size
        var outputBuffer = [UInt8](repeating: 0, count: outputBufferSize)

        var outputBufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: UInt32(numberOfChannels),
                mDataByteSize: UInt32(outputBufferSize),
                mData: &outputBuffer
            )
        )

        var outputDataPacketSize = UInt32(outputFrameCount)

        var packetDescription = AudioStreamPacketDescription(
            mStartOffset: 0,
            mVariableFramesInPacket: 0,
            mDataByteSize: UInt32(aacData.count)
        )

        var context = DecoderContext(
            data: aacData,
            packetDescription: packetDescription
        )

        let status = AudioConverterFillComplexBuffer(
            audioConverter,
            decoderInputCallback,
            &context,
            &outputDataPacketSize,
            &outputBufferList,
            nil
        )

        guard status == noErr || status == 1 else {
            print("[AudioConverter] Decode failed: \(status)")
            return nil
        }

        let decodedSize = Int(outputBufferList.mBuffers.mDataByteSize)
        let decodedSamples = outputBuffer.prefix(decodedSize).withUnsafeBytes { buffer in
            Array(buffer.bindMemory(to: Int16.self))
        }

        // Resample if needed
        let finalSamples: [Int16]
        if inputSampleRate != outputSampleRate {
            finalSamples = resample(samples: decodedSamples) ?? decodedSamples
        } else {
            finalSamples = decodedSamples
        }

        let frame = DecodedAudioFrame(
            timestamp: timestamp,
            samples: finalSamples,
            sampleRate: Int(outputSampleRate),
            channels: numberOfChannels
        )

        decodedFramePublisher.send(frame)
        return frame
    }

    /// Convert decoded audio frame to CMSampleBuffer
    public func createSampleBuffer(from frame: DecodedAudioFrame) -> CMSampleBuffer? {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Double(frame.sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(2 * frame.channels),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(2 * frame.channels),
            mChannelsPerFrame: UInt32(frame.channels),
            mBitsPerChannel: 16,
            mReserved: 0
        )

        var formatDescription: CMAudioFormatDescription?
        var status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )

        guard status == noErr, let format = formatDescription else {
            print("[AudioConverter] Failed to create format description: \(status)")
            return nil
        }

        let dataSize = frame.samples.count * MemoryLayout<Int16>.size
        var blockBuffer: CMBlockBuffer?

        status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: dataSize,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: dataSize,
            flags: 0,
            blockBufferOut: &blockBuffer
        )

        guard status == noErr, let buffer = blockBuffer else {
            print("[AudioConverter] Failed to create block buffer: \(status)")
            return nil
        }

        // Copy sample data
        status = frame.samples.withUnsafeBytes { ptr in
            CMBlockBufferReplaceDataBytes(
                with: ptr.baseAddress!,
                blockBuffer: buffer,
                offsetIntoDestination: 0,
                dataLength: dataSize
            )
        }

        guard status == noErr else {
            print("[AudioConverter] Failed to copy data to block buffer: \(status)")
            return nil
        }

        var sampleBuffer: CMSampleBuffer?
        let sampleCount = frame.samples.count / frame.channels

        status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: buffer,
            formatDescription: format,
            sampleCount: sampleCount,
            presentationTimeStamp: frame.timestamp,
            packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer
        )

        guard status == noErr else {
            print("[AudioConverter] Failed to create sample buffer: \(status)")
            return nil
        }

        return sampleBuffer
    }

    // MARK: - Resampling

    private func resample(samples: [Int16]) -> [Int16]? {
        guard let resampler = resamplerConverter else { return nil }

        let ratio = outputSampleRate / inputSampleRate
        let outputFrameCount = Int(Double(samples.count / numberOfChannels) * ratio)
        let outputBufferSize = outputFrameCount * numberOfChannels * MemoryLayout<Int16>.size

        var outputBuffer = [UInt8](repeating: 0, count: outputBufferSize)
        var outputBufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: UInt32(numberOfChannels),
                mDataByteSize: UInt32(outputBufferSize),
                mData: &outputBuffer
            )
        )

        var outputPacketCount = UInt32(outputFrameCount)

        let inputData = samples.withUnsafeBytes { Data($0) }
        var context = ResamplerContext(data: inputData, consumed: false)

        let status = AudioConverterFillComplexBuffer(
            resampler,
            resamplerInputCallback,
            &context,
            &outputPacketCount,
            &outputBufferList,
            nil
        )

        guard status == noErr || status == 1 else {
            print("[AudioConverter] Resample failed: \(status)")
            return nil
        }

        let outputSize = Int(outputBufferList.mBuffers.mDataByteSize)
        return outputBuffer.prefix(outputSize).withUnsafeBytes { buffer in
            Array(buffer.bindMemory(to: Int16.self))
        }
    }

    // MARK: - Reset

    public func reset() {
        if let converter = audioConverter {
            AudioConverterReset(converter)
        }
        if let resampler = resamplerConverter {
            AudioConverterReset(resampler)
        }
    }

    public func stop() {
        print("[AudioConverter] Stop requested")

        if let converter = audioConverter {
            AudioConverterDispose(converter)
            audioConverter = nil
        }

        if let resampler = resamplerConverter {
            AudioConverterDispose(resampler)
            resamplerConverter = nil
        }

        inputBuffer.removeAll()
        inputPacketDescriptions.removeAll()

        print("[AudioConverter] Fully disposed")
    }

}

// MARK: - Callback Contexts

private struct DecoderContext {
    var data: Data
    var packetDescription: AudioStreamPacketDescription
    var consumed: Bool = false
}

private struct ResamplerContext {
    var data: Data
    var consumed: Bool
}

// MARK: - Callbacks

private let decoderInputCallback: AudioConverterComplexInputDataProc = {
    (converter, ioNumberDataPackets, ioData, outDataPacketDescription, inUserData) -> OSStatus in

    guard let userData = inUserData else {
        ioNumberDataPackets.pointee = 0
        return -1
    }

    let context = userData.assumingMemoryBound(to: DecoderContext.self)

    if context.pointee.consumed {
        ioNumberDataPackets.pointee = 0
        return 1  // End of data
    }

    context.pointee.data.withUnsafeBytes { ptr in
        ioData.pointee.mNumberBuffers = 1
        ioData.pointee.mBuffers.mData = UnsafeMutableRawPointer(mutating: ptr.baseAddress)
        ioData.pointee.mBuffers.mDataByteSize = UInt32(context.pointee.data.count)
        ioData.pointee.mBuffers.mNumberChannels = 1
    }

    // Fix: outDataPacketDescription is UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>
    // We need to point it to our packet description
    if let outDesc = outDataPacketDescription {
        withUnsafeMutablePointer(to: &context.pointee.packetDescription) { descPtr in
            outDesc.pointee = descPtr
        }
    }

    ioNumberDataPackets.pointee = 1
    context.pointee.consumed = true

    return noErr
}

private let resamplerInputCallback: AudioConverterComplexInputDataProc = {
    (converter, ioNumberDataPackets, ioData, outDataPacketDescription, inUserData) -> OSStatus in

    guard let userData = inUserData else {
        ioNumberDataPackets.pointee = 0
        return -1
    }

    let context = userData.assumingMemoryBound(to: ResamplerContext.self)

    if context.pointee.consumed {
        ioNumberDataPackets.pointee = 0
        return 1
    }

    context.pointee.data.withUnsafeBytes { ptr in
        ioData.pointee.mNumberBuffers = 1
        ioData.pointee.mBuffers.mData = UnsafeMutableRawPointer(mutating: ptr.baseAddress)
        ioData.pointee.mBuffers.mDataByteSize = UInt32(context.pointee.data.count)
        ioData.pointee.mBuffers.mNumberChannels = 1
    }

    ioNumberDataPackets.pointee = UInt32(context.pointee.data.count / 2)  // Int16 samples
    context.pointee.consumed = true

    return noErr
}
