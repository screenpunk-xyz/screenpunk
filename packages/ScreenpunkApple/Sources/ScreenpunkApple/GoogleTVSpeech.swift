import AVFoundation
import Foundation

/// In-memory synthesis only: never calls speak(), opens an input, or plays audio.
@MainActor
final class GoogleTVSpeech {
    private var synthesizer: AVSpeechSynthesizer?
    private var pending: CheckedContinuation<Data, Error>?
    private var timeout: Task<Void, Never>?
    private var generation = UUID()

    func cancel() { finish(.failure(CancellationError())) }
    private func finish(_ result: Result<Data, Error>) {
        generation = UUID()
        timeout?.cancel(); timeout = nil
        synthesizer?.stopSpeaking(at: .immediate); synthesizer = nil
        let continuation = pending; pending = nil
        continuation?.resume(with: result)
    }
    func render(_ text: String) async throws -> Data {
        guard pending == nil, GoogleTVConfiguration.validPhrase(text) else { throw GoogleTVError.message("Use an approved phrase of at most 160 UTF-8 bytes.") }
        try Task.checkCancellation()
        let token = UUID(); generation = token
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                pending = continuation
                let collector = GoogleTVSpeechSamples()
                let synth = AVSpeechSynthesizer(); synthesizer = synth
                let utterance = AVSpeechUtterance(string: text)
                utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
                utterance.rate = AVSpeechUtteranceDefaultSpeechRate
                timeout = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { return }
                    self?.finish(.failure(GoogleTVError.message("Local speech synthesis timed out. No voice command was sent.")))
                }
                synth.write(utterance) { [weak self] buffer in
                    let result = collector.append(buffer)
                    if let result { Task { @MainActor in
                        guard self?.generation == token else { return }
                        self?.finish(result)
                    } }
                }
            }
        }, onCancel: { Task { @MainActor [weak self] in self?.cancel() } })
    }
}

/// Speech callbacks may arrive off actor. Bound and copy samples before returning.
final class GoogleTVSpeechSamples: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var rate: Double?
    private var finished = false
    func append(_ buffer: AVAudioBuffer) -> Result<Data, Error>? {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return nil }
        do {
            guard let pcm = buffer as? AVAudioPCMBuffer else { throw GoogleTVError.message("Speech returned unsupported audio.") }
            if pcm.frameLength == 0 {
                finished = true
                guard let rate, !samples.isEmpty else { throw GoogleTVError.message("Local speech voice is unavailable.") }
                return .success(try GoogleTVAudio.convert(samples: samples, sampleRate: rate))
            }
            guard pcm.format.channelCount == 1, let values = pcm.floatChannelData?[0],
                  rate == nil || rate == pcm.format.sampleRate,
                  samples.count + Int(pcm.frameLength) <= Int(pcm.format.sampleRate * 12) else {
                throw GoogleTVError.message("Speech audio is unsupported or exceeds 12 seconds.")
            }
            rate = pcm.format.sampleRate
            samples.append(contentsOf: UnsafeBufferPointer(start: values, count: Int(pcm.frameLength)))
            return nil
        } catch { finished = true; return .failure(error) }
    }
}

enum GoogleTVAudio {
    static let maxBytes = 12 * 8000 * 2
    static func convert(samples: [Float], sampleRate: Double) throws -> Data {
        guard sampleRate.isFinite, sampleRate >= 8000, sampleRate <= 192000, !samples.isEmpty,
              samples.count <= Int(sampleRate * 12), samples.allSatisfy({ $0.isFinite }),
              let inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 8000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat),
              let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 4096) else {
            throw GoogleTVError.message("Cannot convert speech audio.")
        }
        var offset = 0
        var data = Data()
        // Drain to endOfStream, not just the first nonempty conversion buffer.
        // Supply only the frames requested by the converter so no source tail is lost.
        while true {
            output.frameLength = 0
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { requested, state in
                guard offset < samples.count else { state.pointee = .endOfStream; return nil }
                let count = min(Int(requested), samples.count - offset)
                guard count > 0, let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(count)) else {
                    state.pointee = .noDataNow; return nil
                }
                input.frameLength = AVAudioFrameCount(count)
                samples.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress! + offset, count: count) }
                offset += count; state.pointee = .haveData; return input
            }
            guard status != .error, error == nil, data.count + Int(output.frameLength) * 2 <= maxBytes else {
                throw GoogleTVError.message("Speech conversion failed or exceeded 12 seconds.")
            }
            if output.frameLength > 0 {
                guard let values = output.int16ChannelData?[0] else { throw GoogleTVError.message("Speech conversion returned invalid PCM.") }
                for i in 0..<Int(output.frameLength) {
                    let value = UInt16(bitPattern: values[i])
                    data.append(UInt8(value & 255)); data.append(UInt8(value >> 8))
                }
            }
            if status == .endOfStream { break }
            guard output.frameLength > 0 else { throw GoogleTVError.message("Speech conversion ended before all audio was drained.") }
        }
        let expectedFrames = Double(samples.count) * 8000 / sampleRate
        guard offset == samples.count, !data.isEmpty, abs(Double(data.count / 2) - expectedFrames) <= 1 else {
            throw GoogleTVError.message("Speech conversion produced incomplete audio.")
        }
        return data
    }

    static let bytesPerSecond = 8000 * 2
    static let chunkBytes = 20480
    static func chunks(_ audio: Data) throws -> [Data] {
        guard !audio.isEmpty, audio.count <= maxBytes, audio.count % 2 == 0 else { throw GoogleTVError.message("Invalid voice PCM size.") }
        // Match androidtvremote2's prerecorded-audio path: 20 KiB maximum,
        // only pad a final packet smaller than 8 KiB; no extra silence packet.
        return stride(from: 0, to: audio.count, by: chunkBytes).map { start in
            var chunk = Data(audio[start..<min(start + chunkBytes, audio.count)])
            if chunk.count < 8192 { chunk.append(Data(repeating: 0, count: 8192 - chunk.count)) }
            return chunk
        }
    }
    static func metrics(_ audio: Data) -> (peak: Int, rms: Double, nonzero: Int) {
        var peak = 0; var squares = 0.0; var nonzero = 0
        let bytes = Array(audio)
        for i in stride(from: 0, to: bytes.count - 1, by: 2) {
            let sample = Int(Int16(bitPattern: UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8))
            peak = max(peak, abs(sample)); squares += Double(sample) * Double(sample)
            if sample != 0 { nonzero += 1 }
        }
        return (peak, sqrt(squares / Double(max(1, audio.count / 2))), nonzero)
    }
}
