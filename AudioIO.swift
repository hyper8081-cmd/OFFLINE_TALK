import AVFoundation
import Foundation

/// Minimal PCM audio path for the first PTT prototype.
/// Network/audio quality and real-time behavior still require device validation.
final class AudioIO: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let stateLock = NSLock()
    private var transmitting = false
    private var started = false
    private var queuedPlaybackSamples = 0
    private var playbackGeneration = 0
    private let preferredInputSampleRate: Double = 48_000
    private let wireSampleRate: Double = 16_000
    private let maximumQueuedPlaybackSamples = 4_800

    var onCapturedPCM: ((Data) -> Void)?

    func start(completion: @escaping (Result<Void, Error>) -> Void) {
        let permissionHandler: (Bool) -> Void = { [weak self] granted in
            guard let self else { return }
            guard granted else {
                completion(.failure(AudioIOError.microphonePermissionDenied))
                return
            }
            do {
                try self.configureAndStart()
                completion(.success(()))
            } catch {
                completion(.failure(error))
            }
        }
        if #available(iOS 17.0, *) {
            AVAudioApplication.requestRecordPermission(completionHandler: permissionHandler)
        } else {
            AVAudioSession.sharedInstance().requestRecordPermission(permissionHandler)
        }
    }

    func setTransmitting(_ value: Bool) {
        stateLock.lock()
        transmitting = value
        stateLock.unlock()
    }

    func play(pcm16Mono data: Data) {
        guard started, data.count >= 2 else { return }
        let frameCount = data.count / MemoryLayout<Int16>.size
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                         sampleRate: wireSampleRate,
                                         channels: 1,
                                         interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(frameCount)),
              let channel = buffer.int16ChannelData?[0] else { return }

        data.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            guard bytes.count >= frameCount * MemoryLayout<Int16>.size else { return }
            for frame in 0..<frameCount {
                let lowByte = UInt16(bytes[frame * 2])
                let highByte = UInt16(bytes[frame * 2 + 1]) << 8
                channel[frame] = Int16(bitPattern: lowByte | highByte)
            }
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)

        stateLock.lock()
        let shouldRestart = queuedPlaybackSamples + frameCount > maximumQueuedPlaybackSamples
        if shouldRestart {
            playbackGeneration &+= 1
            queuedPlaybackSamples = 0
        }
        let generation = playbackGeneration
        queuedPlaybackSamples += frameCount
        stateLock.unlock()

        if shouldRestart {
            player.stop()
            player.play()
        }
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self else { return }
            self.stateLock.lock()
            if self.playbackGeneration == generation {
                self.queuedPlaybackSamples = max(0, self.queuedPlaybackSamples - frameCount)
            }
            self.stateLock.unlock()
        }
    }

    func stop() {
        setTransmitting(false)
        stateLock.lock()
        playbackGeneration &+= 1
        queuedPlaybackSamples = 0
        stateLock.unlock()
        guard started else { return }
        engine.inputNode.removeTap(onBus: 0)
        player.stop()
        engine.stop()
        engine.detach(player)
        started = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func configureAndStart() throws {
        guard !started else { return }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord,
                                mode: .voiceChat,
                                options: [.defaultToSpeaker, .allowBluetooth])
        try session.setPreferredSampleRate(preferredInputSampleRate)
        try session.setActive(true)

        let input = engine.inputNode
        try? input.setVoiceProcessingEnabled(true)
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.channelCount > 0,
              inputFormat.sampleRate >= wireSampleRate,
              inputFormat.sampleRate <= 192_000,
              inputFormat.commonFormat == .pcmFormatFloat32 else {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw AudioIOError.unsupportedMicrophoneFormat
        }

        guard let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                               sampleRate: wireSampleRate,
                                               channels: 1,
                                               interleaved: false) else {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw AudioIOError.unsupportedMicrophoneFormat
        }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: outputFormat)

        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            self.stateLock.lock()
            let shouldSend = self.transmitting
            self.stateLock.unlock()
            guard shouldSend,
                  let floatData = buffer.floatChannelData,
                  buffer.frameLength > 0 else { return }

            let inputFrameCount = Int(buffer.frameLength)
            let inputRate = buffer.format.sampleRate
            guard inputRate >= self.wireSampleRate, inputRate <= 192_000 else { return }
            let outputFrameCount = max(1, Int((Double(inputFrameCount) * self.wireSampleRate / inputRate).rounded(.down)))
            var samples = [Int16](repeating: 0, count: outputFrameCount)
            let channelCount = Int(buffer.format.channelCount)
            for outputFrame in 0..<outputFrameCount {
                let sourceStart = Double(outputFrame) * inputRate / self.wireSampleRate
                let sourceEnd = Double(outputFrame + 1) * inputRate / self.wireSampleRate
                let firstFrame = Int(sourceStart.rounded(.down))
                let lastFrame = min(inputFrameCount - 1, Int(sourceEnd.rounded(.up)) - 1)
                var value: Float = 0
                for channel in 0..<channelCount {
                    var channelValue: Double = 0
                    for inputFrame in firstFrame...lastFrame {
                        let overlap = min(sourceEnd, Double(inputFrame + 1))
                            - max(sourceStart, Double(inputFrame))
                        channelValue += Double(floatData[channel][inputFrame]) * overlap
                    }
                    value += Float(channelValue / (sourceEnd - sourceStart))
                }
                value /= Float(channelCount)
                let clipped = max(-1, min(1, value))
                samples[outputFrame] = Int16(clipped * Float(Int16.max))
            }
            let littleEndianSamples = samples.map { $0.littleEndian }
            let pcm = littleEndianSamples.withUnsafeBytes { Data($0) }
            self.onCapturedPCM?(pcm)
        }

        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            engine.detach(player)
            engine.stop()
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw error
        }
        player.play()
        started = true
    }
}

enum AudioIOError: LocalizedError {
    case microphonePermissionDenied
    case unsupportedMicrophoneFormat

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "マイクの使用が許可されていません。設定でマイクを許可してください。"
        case .unsupportedMicrophoneFormat:
            return "この端末のマイク形式に対応できません。"
        }
    }
}
