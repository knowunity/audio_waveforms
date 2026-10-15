import Flutter
import Accelerate
import AVFoundation

public class WaveformExtractor {

    public private(set) var audioFile: AVAudioFile?
    private var result: FlutterResult
    var flutterChannel: FlutterMethodChannel
    private var waveformData = Array<Float>()
    var progress: Float = 0.0
    var channelCount: Int = 1
    private var currentProgress: Float = 0.0
    private let abortWaveformDataQueue = DispatchQueue(
        label: "WaveformExtractor",
        attributes: .concurrent
    )

    private var _abortGetWaveformData: Bool = false

    public var abortGetWaveformData: Bool {
        get { _abortGetWaveformData }
        set {
            abortWaveformDataQueue.async(flags: .barrier) {
                self._abortGetWaveformData = newValue
            }
        }
    }
    public init(url: URL, flutterResult: @escaping FlutterResult, channel: FlutterMethodChannel) throws {
        result = flutterResult
        self.flutterChannel = channel
        do {
            audioFile = try AVAudioFile(forReading: url)
        } catch {
            audioFile = nil
            result(FlutterError(code: Constants.audioWaveforms, message: error.localizedDescription, details: "Couldn't initialise AVAudioFile from \(url.absoluteString)"))

        }
    }

    deinit {
        audioFile = nil
    }

    public func extractWaveform(
        samplesPerPixel: Int?,
        offset: Int? = 0,
        length: UInt? = nil,
        playerKey: String,
        onExtractionComplete: ([Float]?) -> Void
    ) async -> Void {
        guard let audioFile = audioFile else { return }
        
        /// Prevent division by zero, + minimum resolution
        let samplesPerPixel = max(1, samplesPerPixel ?? 100)

        /// AVAudioFile can't position or decode files without a fixed frame count per packet, such as Opus in MP4
        /// (Chrome's MediaRecorder output), and `framePosition` raises an Objective-C exception Swift can't catch.
        if audioFile.fileFormat.streamDescription.pointee.mFramesPerPacket == 0 {
            await extractWaveformWithAssetReader(
                url: audioFile.url,
                sampleRate: audioFile.processingFormat.sampleRate,
                samplesPerPixel: samplesPerPixel,
                playerKey: playerKey,
                onExtractionComplete: onExtractionComplete
            )
            return
        }

        let currentFrame = audioFile.framePosition
        let totalFrames = AVAudioFrameCount(audioFile.length)
        var framesPerBuffer = totalFrames / AVAudioFrameCount(samplesPerPixel)
        
        guard let rmsBuffer = AVAudioPCMBuffer(
            pcmFormat: audioFile.processingFormat,
            frameCapacity: framesPerBuffer
        ) else { return }
        
        let channelCount = Int(audioFile.processingFormat.channelCount)
        let waveformStorage = WaveformStorage(
            channelCount: channelCount,
            size: samplesPerPixel
        )
        
        let startIndex = max(
            0, offset ?? Int(currentFrame / Int64(framesPerBuffer))
        )
        let endIndex = min(
            samplesPerPixel, startIndex + (length.map { Int($0) } ?? samplesPerPixel)
        )
        
        if startIndex > endIndex {
            sendErrorToFlutter(
                message: "Offset is larger than total length.",
                details: "Please select less number of samples"
            )
            return
        }
        
        var startFrame: AVAudioFramePosition = offset == nil
        ? currentFrame
        : Int64(startIndex * Int(framesPerBuffer))
        
        for i in startIndex..<endIndex {
            if abortGetWaveformData {
                audioFile.framePosition = currentFrame
                abortGetWaveformData = false
                return
            }
            
            do {
                audioFile.framePosition = startFrame
                try audioFile.read(into: rmsBuffer, frameCount: framesPerBuffer)
            } catch {
                sendErrorToFlutter(
                    message: "Couldn't read buffer. \(error.localizedDescription)"
                )
                return
            }
            
            guard let floatData = rmsBuffer.floatChannelData else { return }
            
            for channel in 0..<channelCount {
                /// Calculating RMS(Root mean square)
                var rmsValue: Float = 0.0
                vDSP_rmsqv(
                    floatData[channel], 1, &rmsValue,
                    vDSP_Length(rmsBuffer.frameLength)
                )
                await waveformStorage.update(
                    channel: channel, index: i, value: rmsValue
                )
            }
            
            let progress = Float(i - startIndex + 1) / Float(endIndex - startIndex)
            await sendWaveformDataToFlutter(
                waveformStorage: waveformStorage,
                progress: progress,
                playerKey: playerKey
            )
            
            startFrame += AVAudioFramePosition(framesPerBuffer)
            if startFrame + AVAudioFramePosition(framesPerBuffer) > totalFrames {
                framesPerBuffer = totalFrames - AVAudioFrameCount(startFrame)
                if framesPerBuffer <= 0 { break }
            }
        }
        
        audioFile.framePosition = currentFrame
        let waveformData = await waveformStorage.getData()
        let data = getChannelMean(data: waveformData)
        onExtractionComplete(data);
    }

    private func extractWaveformWithAssetReader(
        url: URL,
        sampleRate: Double,
        samplesPerPixel: Int,
        playerKey: String,
        onExtractionComplete: ([Float]?) -> Void
    ) async {
        guard #available(iOS 15.0, *) else {
            sendErrorToFlutter(message: "Can't extract waveform data from this audio format before iOS 15.")
            return
        }

        let asset = AVURLAsset(url: url)
        let reader: AVAssetReader
        let output: AVAssetReaderTrackOutput
        let totalFrames: Int
        do {
            guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
                sendErrorToFlutter(message: "Audio file has no audio track.")
                return
            }
            totalFrames = Int(try await asset.load(.duration).seconds * sampleRate)
            reader = try AVAssetReader(asset: asset)
            output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsNonInterleaved: false,
                AVLinearPCMIsBigEndianKey: false,
            ])
            reader.add(output)
        } catch {
            sendErrorToFlutter(message: "Couldn't open audio track. \(error.localizedDescription)")
            return
        }

        let framesPerPixel = totalFrames / samplesPerPixel
        guard framesPerPixel > 0, reader.startReading() else {
            sendErrorToFlutter(
                message: "Couldn't read audio track.",
                details: reader.error?.localizedDescription
            )
            return
        }

        let waveformStorage = WaveformStorage(channelCount: 1, size: samplesPerPixel)
        var pixel = 0
        var framesInPixel = 0
        var sumOfSquares: Float = 0
        var samples = [Float]()

        while let sampleBuffer = output.copyNextSampleBuffer() {
            if abortGetWaveformData {
                reader.cancelReading()
                abortGetWaveformData = false
                return
            }
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer),
                  let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
                  let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
            else { continue }
            let channelCount = Int(streamDescription.pointee.mChannelsPerFrame)

            let sampleCount = CMBlockBufferGetDataLength(blockBuffer) / MemoryLayout<Float>.size
            samples = [Float](repeating: 0, count: sampleCount)
            CMBlockBufferCopyDataBytes(
                blockBuffer,
                atOffset: 0,
                dataLength: sampleCount * MemoryLayout<Float>.size,
                destination: &samples
            )

            let frameCount = sampleCount / channelCount
            var frame = 0
            while frame < frameCount {
                let isLastPixel = pixel == samplesPerPixel - 1
                let chunk = isLastPixel
                ? frameCount - frame
                : min(frameCount - frame, framesPerPixel - framesInPixel)
                var chunkSumOfSquares: Float = 0
                samples.withUnsafeBufferPointer { buffer in
                    vDSP_svesq(
                        buffer.baseAddress! + frame * channelCount,
                        channelCount,
                        &chunkSumOfSquares,
                        vDSP_Length(chunk)
                    )
                }
                sumOfSquares += chunkSumOfSquares
                framesInPixel += chunk
                frame += chunk

                if !isLastPixel, framesInPixel == framesPerPixel {
                    await waveformStorage.update(
                        channel: 0, index: pixel, value: sqrt(sumOfSquares / Float(framesInPixel))
                    )
                    pixel += 1
                    framesInPixel = 0
                    sumOfSquares = 0
                    await sendWaveformDataToFlutter(
                        waveformStorage: waveformStorage,
                        progress: Float(pixel) / Float(samplesPerPixel),
                        playerKey: playerKey
                    )
                }
            }
        }

        guard reader.status == .completed else {
            sendErrorToFlutter(
                message: "Couldn't read audio track.",
                details: reader.error?.localizedDescription
            )
            return
        }
        if framesInPixel > 0 {
            await waveformStorage.update(
                channel: 0, index: pixel, value: sqrt(sumOfSquares / Float(framesInPixel))
            )
            await sendWaveformDataToFlutter(waveformStorage: waveformStorage, progress: 1, playerKey: playerKey)
        }
        let waveformData = await waveformStorage.getData()
        onExtractionComplete(getChannelMean(data: waveformData))
    }

    func getChannelMean(data: FloatChannelData) -> [Float] {
        var resultWaveform = [Float]()

        if channelCount == 2, !data[0].isEmpty, !data[1].isEmpty {
            resultWaveform = zip(data[0], data[1]).map { ($0 + $1) / 2 }
        } else if !data[0].isEmpty {
            resultWaveform = data[0]
        } else if !data[1].isEmpty {
            resultWaveform = data[1]
        } else {
            sendErrorToFlutter(
                message: "Cannot get waveform mean",
                details: "Both audio channels are null"
            )
        }
        return resultWaveform
    }

    public func cancel() {
        abortGetWaveformData = true
    }

    private func sendWaveformDataToFlutter(
        waveformStorage: WaveformStorage,
        progress: Float,
        playerKey: String
    ) async {
        let waveformData = await waveformStorage.getData()
        let meanData = getChannelMean(data: waveformData)

        DispatchQueue.main.async {
            self.flutterChannel.invokeMethod(
                Constants.onCurrentExtractedWaveformData,
                arguments: [
                    Constants.waveformData: meanData,
                    Constants.progress: progress,
                    Constants.playerKey: playerKey
                ]
            )
        }
    }

    private func sendErrorToFlutter(message: String, details: String? = nil) {
        DispatchQueue.main.async {
            self.result(
                FlutterError(
                    code: Constants.audioWaveforms,
                    message: message,
                    details: details
                )
            )
        }
    }
}

actor WaveformStorage {
    private var data: [[Float]]

    init(channelCount: Int, size: Int) {
        data = Array(repeating: [Float](repeating: 0, count: size), count: channelCount)
    }

    func update(channel: Int, index: Int, value: Float) {
        data[channel][index] = value
    }

    func getData() -> [[Float]] {
        return data
    }
}
