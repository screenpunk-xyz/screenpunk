import XCTest
import AVFoundation
@testable import ScreenpunkApple

final class GoogleTVVoiceTests: XCTestCase {
    typealias W = GoogleTVWire
    func testLegacyPermissionsDecodeWithoutVoiceApproval() throws {
        let data = Data(#"{"host":"tv.local","pin":"","dashboardIDs":["test"],"appLinks":[]}"#.utf8)
        let config = try JSONDecoder().decode(GoogleTVConfiguration.self, from: data)
        XCTAssertEqual(config.dashboardIDs, ["test"])
        XCTAssertNil(config.voicePhrases)
        XCTAssertTrue(GoogleTVConfiguration.validPhrase("Watch CNBC on YouTube TV"))
        for phrase in ["", "  ", "Watch\nCNBC", String(repeating: "é", count: 81)] {
            XCTAssertFalse(GoogleTVConfiguration.validPhrase(phrase))
        }
    }
    func testChunkBoundsAndTailSilence() throws {
        let audio = Data(repeating: 37, count: 20482)
        let chunks = try GoogleTVAudio.chunks(audio)
        XCTAssertEqual(chunks.map(\.count), [20480, 8192])
        let joined = chunks.reduce(Data(), +)
        XCTAssertEqual(joined.prefix(audio.count), audio)
        XCTAssertEqual(joined.count - audio.count, 8190)
        XCTAssertTrue(joined.dropFirst(audio.count).allSatisfy { $0 == 0 })
        for invalid in [Data(), Data([1]), Data(repeating: 0, count: GoogleTVAudio.maxBytes + 2)] {
            XCTAssertThrowsError(try GoogleTVAudio.chunks(invalid))
        }
    }
    func testResamplingProducesSignedLittleEndianEightKilohertz() throws {
        let angularStep = 2.0 * Double.pi * 440.0 / 24000.0
        let samples: [Float] = (0..<24000).map { Float(Foundation.sin(Double($0) * angularStep) * 0.5) }
        let pcm = try GoogleTVAudio.convert(samples: samples, sampleRate: 24000)
        XCTAssertEqual(pcm.count, 16000, accuracy: 64)
        let values = stride(from: 0, to: pcm.count, by: 2).map { Int16(bitPattern: UInt16(pcm[$0]) | UInt16(pcm[$0 + 1]) << 8) }
        XCTAssertGreaterThan(values.max()!, 15000)
        XCTAssertLessThan(values.min()!, -15000)
        let crossings = zip(values, values.dropFirst()).filter { $0 < 0 && $1 >= 0 }.count
        XCTAssertEqual(crossings, 440, accuracy: 3)
        XCTAssertThrowsError(try GoogleTVAudio.convert(samples: [.nan], sampleRate: 24000))
    }
    @MainActor
    func testVoiceHandshakeUsesTVSessionAndEndsAfterBoundedChunks() async throws {
        var packets: [W.Message] = []
        var session: GoogleTVSession!
        session = GoogleTVSession { data, completion in
            do {
                var framer = W.Framer()
                let message = try W.parse(try framer.append(data)[0]); packets.append(message)
                if message.payloads[10] != nil {
                    XCTAssertEqual(try message.nested(10).numbers[1], 84)
                    try session.handle(W.parse(W.bytes(30, W.number(1, 71))))
                }
                completion(nil)
            } catch { completion(error) }
        }
        try session.handle(W.parse(W.bytes(1, W.number(1, 623))))
        try session.handle(W.parse(W.bytes(40, W.number(1, 1))))
        try await session.voice(audio: Data(repeating: 1, count: 20482))
        XCTAssertEqual(packets.compactMap { $0.payloads.keys.first }, [1, 10, 30, 31, 31, 32])
        for message in packets.dropFirst(2) {
            let field = message.payloads.keys.first!
            XCTAssertEqual(try message.nested(field).numbers[1], 71)
        }
        XCTAssertEqual(try packets[3].nested(31).payloads[2]?.count, 20480)
        let sentAudio = try packets.filter { $0.payloads[31] != nil }.reduce(Data()) { try $0 + $1.nested(31).payloads[2]! }
        XCTAssertEqual(sentAudio.prefix(20482), Data(repeating: 1, count: 20482))
        XCTAssertTrue(sentAudio.dropFirst(20482).allSatisfy { $0 == 0 })
        session.close()
    }
    @MainActor
    func testUnsupportedVoiceSendsNothingAndCancellationPreventsPayload() async throws {
        var sent = 0
        let session = GoogleTVSession { _, done in sent += 1; done(nil) }
        try session.handle(W.parse(W.bytes(1, W.number(1, 615))))
        try session.handle(W.parse(W.bytes(40, W.number(1, 1))))
        do { try await session.voice(audio: Data([0, 0])); XCTFail("unsupported voice") } catch { }
        XCTAssertEqual(sent, 1)
        try session.handle(W.parse(W.bytes(1, W.number(1, 623))))
        let task = Task { try await session.voice(audio: Data([0, 0])) }
        await Task.yield()
        task.cancel()
        do { try await task.value; XCTFail("cancelled session") } catch { }
        XCTAssertFalse(session.ready)
        XCTAssertLessThanOrEqual(sent, 3) // configure twice, at most Search; no begin/audio/end.
        try session.handle(W.parse(W.bytes(30, W.number(1, 99))))
        XCTAssertLessThanOrEqual(sent, 3) // late handshake cannot revive a cancelled request.
    }
    @MainActor
    func testSynthesisCancellationCompletesWithoutWaitingForSpeechCallback() async {
        let speech = GoogleTVSpeech()
        let task = Task { try await speech.render("Watch CNBC on YouTube TV") }
        task.cancel()
        do { _ = try await task.value; XCTFail("cancelled synthesis") } catch { }
    }
    @MainActor
    func testUnapprovedPhraseRejectsBeforeSynthesisOrNetwork() async {
        var config = GoogleTVConfiguration()
        config.host = "tv.local"; config.pin = Data(repeating: 1, count: 32)
        config.dashboardIDs = ["test"]; config.voicePhrases = ["Watch CNBC"]
        let connection = GoogleTVScreenConnection(loadConfiguration: { config })
        for parameters in [["text": "Watch Golf"], ["text": "Watch CNBC", "host": "other"]] {
            do { _ = try await connection.request(dashboardID: "test", operation: "voice", parameters: parameters); XCTFail("unapproved") }
            catch { XCTAssertTrue(error.localizedDescription.contains("not approved")) }
        }
    }
    @MainActor
    func testInstalledLocalVoiceRendersWithoutPlayback() async throws {
        guard ProcessInfo.processInfo.environment["SCREENPUNK_TEST_LOCAL_TTS"] == "1" else {
            throw XCTSkip("Opt-in local speech service integration; no TV connection.")
        }
        let speech = GoogleTVSpeech()
        let audio = try await speech.render("Watch CNBC on YouTube TV")
        XCTAssertGreaterThan(audio.count, 8000)
        XCTAssertLessThanOrEqual(audio.count, GoogleTVAudio.maxBytes)
        XCTAssertTrue(audio.contains { $0 != 0 })
        let chunks = try GoogleTVAudio.chunks(audio)
        print("TTS_PCM frames=\(audio.count / 2) seconds=\(Double(audio.count) / 16000) packets=\(chunks.count) streamedPCMSeconds=\(Double(chunks.reduce(0) { $0 + $1.count }) / 16000)")
    }

    @MainActor
    func testDisconnectMidStreamStopsRemainingChunksWithoutReplay() async throws {
        var audioPackets = 0
        var endPackets = 0
        var session: GoogleTVSession!
        session = GoogleTVSession { data, completion in
            do {
                var framer = W.Framer()
                let message = try W.parse(try framer.append(data)[0])
                if message.payloads[10] != nil { try session.handle(W.parse(W.bytes(30, Data()))) }
                if message.payloads[31] != nil {
                    XCTAssertEqual(try message.nested(31).numbers[1], 0)
                    audioPackets += 1
                    session.close(GoogleTVError.message("Test disconnect"))
                }
                if message.payloads[32] != nil { endPackets += 1 }
                completion(nil)
            } catch { completion(error) }
        }
        try session.handle(W.parse(W.bytes(1, W.number(1, 623))))
        try session.handle(W.parse(W.bytes(40, W.number(1, 1))))
        do { try await session.voice(audio: Data(repeating: 1, count: 50000)); XCTFail("disconnect") } catch { }
        XCTAssertEqual(audioPackets, 1)
        XCTAssertEqual(endPackets, 0)
        XCTAssertFalse(session.ready)
    }

    func testAllSynthesisCallbacksIncludingTailAreConverted() throws {
        let rate = 44100.0
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        let collector = GoogleTVSpeechSamples()
        let count = 5 * 44100 + 123
        var samples = [Float](repeating: 0, count: count)
        // Distinct final-second tone detects a dropped tail, not merely nonempty PCM.
        for i in count - 44100..<count { samples[i] = Float(Foundation.sin(Double(i) * (2.0 * Double.pi * 730.0 / rate)) * 0.5) }
        for start in stride(from: 0, to: count, by: 777) {
            let frames = min(777, count - start)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
            buffer.frameLength = AVAudioFrameCount(frames)
            samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress! + start, count: frames) }
            XCTAssertNil(collector.append(buffer))
        }
        let end = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1)!
        let actual = try XCTUnwrap(collector.append(end)).get()
        XCTAssertEqual(actual, try GoogleTVAudio.convert(samples: samples, sampleRate: rate))
        XCTAssertEqual(Double(actual.count / 2), Double(count) * 8000 / rate, accuracy: 1)
        XCTAssertTrue(actual.suffix(8000).contains { $0 != 0 })
        XCTAssertNil(collector.append(end), "terminal callback is consumed once")
    }

    func testConverterDrainsMaximumLengthAndNonintegralSampleRates() throws {
        for rate in [22050.0, 24000.0, 44100.0, 48000.0] {
            let count = Int(rate * 12)
            var samples = [Float](repeating: 0, count: count)
            for i in count - 5000..<count { samples[i] = 0.25 }
            let pcm = try GoogleTVAudio.convert(samples: samples, sampleRate: rate)
            XCTAssertEqual(pcm.count, 192000)
            XCTAssertTrue(pcm.suffix(1000).contains { $0 != 0 })
        }
    }

    @MainActor
    func testWaitsForReadinessAndTransportBeforeSendingEnd() async throws {
        let search = expectation(description: "Search sent")
        let audioWrite = expectation(description: "Audio write pending")
        var fields: [Int] = []
        var pendingWrite: ((Error?) -> Void)?
        let session = GoogleTVSession { data, done in
            do {
                var framer = W.Framer(); let message = try W.parse(try framer.append(data)[0])
                let field = try XCTUnwrap(message.payloads.keys.first); fields.append(field)
                if field == 10 { search.fulfill() }
                if field == 31 { pendingWrite = done; audioWrite.fulfill() } else { done(nil) }
            } catch { done(error) }
        }
        try session.handle(W.parse(W.bytes(1, W.number(1, 623))))
        try session.handle(W.parse(W.bytes(40, W.number(1, 1))))
        let task = Task { try await session.voice(audio: Data(repeating: 1, count: 8192)) }
        await fulfillment(of: [search], timeout: 2)
        XCTAssertEqual(fields, [1, 10])
        try session.handle(W.parse(W.bytes(30, W.number(1, 18))))
        await fulfillment(of: [audioWrite], timeout: 2)
        XCTAssertEqual(fields, [1, 10, 30, 31], "End waits for audio transport completion")
        pendingWrite?(nil)
        let result = try await task.value
        XCTAssertEqual(fields, [1, 10, 30, 31, 32])
        XCTAssertEqual(result["audioPackets"] as? Int, 1)
        XCTAssertEqual(result["pcmPeak"] as? Int, 257)
        XCTAssertEqual(result["pcmNonzeroFrames"] as? Int, 4096)
        session.close()
    }

    @MainActor
    func testTransportFailureDoesNotSendRemainingAudioOrEnd() async throws {
        var fields: [Int] = []
        var session: GoogleTVSession!
        session = GoogleTVSession { data, done in
            do {
                var framer = W.Framer(); let message = try W.parse(try framer.append(data)[0])
                let field = try XCTUnwrap(message.payloads.keys.first); fields.append(field)
                if field == 10 { try session.handle(W.parse(W.bytes(30, W.number(1, 18)))) }
                done(field == 31 ? GoogleTVError.message("Injected write failure") : nil)
            } catch { done(error) }
        }
        try session.handle(W.parse(W.bytes(1, W.number(1, 623))))
        try session.handle(W.parse(W.bytes(40, W.number(1, 1))))
        do { try await session.voice(audio: Data(repeating: 1, count: 50000)); XCTFail("write failure") } catch { }
        XCTAssertEqual(fields, [1, 10, 30, 31])
        XCTAssertFalse(session.ready)
    }

    func testPCMStatisticsDecodeSignedLittleEndian() {
        let metrics = GoogleTVAudio.metrics(Data([0, 128, 255, 127, 0, 0, 1, 0]))
        XCTAssertEqual(metrics.peak, 32768)
        XCTAssertEqual(metrics.nonzero, 3)
        XCTAssertEqual(metrics.rms, sqrt((32768.0 * 32768 + 32767.0 * 32767 + 1) / 4), accuracy: 0.001)
    }
    @MainActor
    func testBurstPayloadIsUnchangedAndOnlyEndIsHeld() async throws {
        var elapsed: UInt64 = 0
        var events: [(Int, UInt64)] = []
        var pcm = Data()
        var session: GoogleTVSession!
        session = GoogleTVSession(sleep: { elapsed += $0 }) { data, done in
            do {
                var framer = W.Framer(); let message = try W.parse(try framer.append(data)[0])
                let field = try XCTUnwrap(message.payloads.keys.first); events.append((field, elapsed))
                if field == 10 { try session.handle(W.parse(W.bytes(30, W.number(1, 31)))) }
                if field == 31 { pcm += try XCTUnwrap(message.nested(31).payloads[2]) }
                done(nil)
            } catch { done(error) }
        }
        try session.handle(W.parse(W.bytes(1, W.number(1, 623))))
        try session.handle(W.parse(W.bytes(40, W.number(1, 1))))
        let audio = Data((0..<34958).map { UInt8($0 % 251) })
        let result = try await session.voice(audio: audio)
        XCTAssertEqual(pcm, audio)
        XCTAssertEqual(events.map { $0.0 }, [1, 10, 30, 31, 31, 32])
        XCTAssertEqual(events.map { $0.1 }, [0, 0, 0, 0, 0, 2_184_875_000])
        XCTAssertEqual(result["endHoldSeconds"] as? Double, 2.184875)
        session.close()
    }

    @MainActor
    func testCancelDisconnectAndRevocationDuringEndHoldPreventEnd() async throws {
        for mode in ["cancel", "disconnect", "revoke"] {
            let holding = expectation(description: mode)
            var ends = 0
            var approved = true
            var session: GoogleTVSession!
            session = GoogleTVSession(sleep: { _ in
                holding.fulfill()
                if mode == "revoke" { approved = false }
                else { try await Task.sleep(nanoseconds: 60_000_000_000) }
            }) { data, done in
                do {
                    var framer = W.Framer(); let message = try W.parse(try framer.append(data)[0])
                    if message.payloads[10] != nil { try session.handle(W.parse(W.bytes(30, W.number(1, 31)))) }
                    if message.payloads[32] != nil { ends += 1 }
                    done(nil)
                } catch { done(error) }
            }
            try session.handle(W.parse(W.bytes(1, W.number(1, 623))))
            try session.handle(W.parse(W.bytes(40, W.number(1, 1))))
            let task = Task { try await session.voice(audio: Data(repeating: 1, count: 8192)) {
                if !approved { throw GoogleTVError.message("Revoked") }
            } }
            await fulfillment(of: [holding], timeout: 2)
            if mode == "cancel" { task.cancel() }
            if mode == "disconnect" { session.close() }
            do { _ = try await task.value; XCTFail("Expected \(mode)") } catch { }
            XCTAssertEqual(ends, 0)
            XCTAssertFalse(session.ready)
        }
    }

}
