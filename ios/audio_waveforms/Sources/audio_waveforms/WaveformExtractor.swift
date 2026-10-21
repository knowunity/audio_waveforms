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
            result(FlutterError(code: Constants.audioWaveforms, message: error.localizedDescription, details: "Couldn't initialise AVAudioFile from \(url.absoluteString): \(error)"))

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
                samplesPerPixel: samplesPerPixel,
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

    /// Decodes the whole file in order, so it needs neither seeking nor a known duration.
    private func extractWaveformWithAssetReader(
        url: URL,
        samplesPerPixel: Int,
        onExtractionComplete: ([Float]?) -> Void
    ) async {
        /// The plugin builds scheme-less URLs from plain paths; AVAudioFile accepts them, AVURLAsset doesn't.
        let asset = AVURLAsset(url: URL(fileURLWithPath: url.path))
        let reader: AVAssetReader
        let output: AVAssetReaderTrackOutput
        do {
            guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
                sendErrorToFlutter(message: "Audio file has no audio track.", details: url.lastPathComponent)
                return
            }
            reader = try AVAssetReader(asset: asset)
            output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
                AVNumberOfChannelsKey: 1,
            ])
            reader.add(output)
        } catch {
            sendErrorToFlutter(message: "Couldn't open audio track. \(error.localizedDescription)", details: "\(error)")
            return
        }
        guard reader.startReading() else {
            sendErrorToFlutter(message: "Couldn't read audio track.", details: "\(String(describing: reader.error))")
            return
        }

        /// Sums of squares over short blocks, binned into pixels once the total frame count is known.
        let blockSize = 256
        var blockSums = [Float]()
        var blockFrames = [Int]()
        while let sampleBuffer = output.copyNextSampleBuffer() {
            if abortGetWaveformData {
                reader.cancelReading()
                abortGetWaveformData = false
                return
            }
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            var samples = [Float](repeating: 0, count: CMBlockBufferGetDataLength(blockBuffer) / MemoryLayout<Float>.size)
            CMBlockBufferCopyDataBytes(
                blockBuffer,
                atOffset: 0,
                dataLength: samples.count * MemoryLayout<Float>.size,
                destination: &samples
            )
            samples.withUnsafeBufferPointer { buffer in
                for start in stride(from: 0, to: buffer.count, by: blockSize) {
                    let count = min(blockSize, buffer.count - start)
                    var sum: Float = 0
                    vDSP_svesq(buffer.baseAddress! + start, 1, &sum, vDSP_Length(count))
                    blockSums.append(sum)
                    blockFrames.append(count)
                }
            }
        }

        let totalFrames = blockFrames.reduce(0, +)
        guard reader.status == .completed, totalFrames > 0 else {
            sendErrorToFlutter(message: "Couldn't read audio track.", details: "\(String(describing: reader.error))")
            return
        }

        var pixelSums = [Float](repeating: 0, count: samplesPerPixel)
        var pixelFrames = [Int](repeating: 0, count: samplesPerPixel)
        var frame = 0
        for (sum, count) in zip(blockSums, blockFrames) {
            let pixel = frame * samplesPerPixel / totalFrames
            pixelSums[pixel] += sum
            pixelFrames[pixel] += count
            frame += count
        }
        onExtractionComplete(zip(pixelSums, pixelFrames).map { $1 > 0 ? sqrt($0 / Float($1)) : 0 })
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
