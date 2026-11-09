import AVFoundation
import Speech
import XCTest
@testable import iMessageMax

final class AudioAttachmentTests: XCTestCase {
    private var files: [URL] = []

    override func tearDown() {
        for url in files { try? FileManager.default.removeItem(at: url) }
        super.tearDown()
    }

    private func fetch(_ url: URL, attributedBody: Data? = nil) async throws -> AttachmentReply {
        let fixture = try ToolTestDatabase(name: "audio")
        try fixture.insertMessage(rowId: 1, guid: "m1", date: 1_000_000_000, isFromMe: false, attributedBody: attributedBody)
        try fixture.insertAttachment(rowId: 4, filename: url.path, mimeType: "audio/x-caf", uti: "com.apple.coreaudio-format", transferName: "Audio Message.caf")
        try fixture.joinMessageAttachment(messageId: 1, attachmentId: 4)
        let tool = GetAttachment(db: fixture.database(), resolver: ContactResolver(seedCache: [:]))
        return try attachmentReply(try await tool.execute(
            attachmentId: "att4",
            allowedRoots: [FileManager.default.temporaryDirectory.path]
        ))
    }

    private func tone(seconds: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-tone.caf")
        files.append(url)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(seconds * 16_000)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let samples = try XCTUnwrap(buffer.floatChannelData)[0]
        for i in 0..<Int(frames) { samples[i] = 0.2 * sin(2 * .pi * 440 * Float(i) / 16_000) }
        try file.write(from: buffer)
        return url
    }

    @available(*, deprecated)
    func testVoiceMessageReturnsTheTranscriptMessagesStored() async throws {
        let url = try tone(seconds: 3)
        let transcript = "Running ten minutes late, save me a seat"
        let reply = try await fetch(url, attributedBody: voiceMessageBody(transcript: transcript))

        XCTAssertEqual(reply.metadata["type"] as? String, "audio")
        XCTAssertEqual(reply.metadata["transcript_source"] as? String, "messages")
        XCTAssertEqual(try XCTUnwrap(reply.metadata["duration_s"] as? Double), 3, accuracy: 0.1)
        XCTAssertNil(reply.metadata["transcript_unavailable"])
        XCTAssertEqual(reply.texts, [transcript])
        XCTAssertTrue(reply.images.isEmpty)
    }

    /// Typedstream writes a string of 128 bytes or more with a 0x81 length,
    /// and one of 32 KB or more with 0x82.
    @available(*, deprecated)
    func testStoredTranscriptsOfEveryLengthWidth() {
        for count in [1, 127, 128, 32_767, 32_768] {
            let text = String(repeating: "a", count: count - 1) + "!"
            XCTAssertEqual(AudioTranscript.storedTranscript(in: voiceMessageBody(transcript: text)), text, "length \(count)")
        }
    }

    @available(*, deprecated)
    func testBodyWithoutATranscriptHasNone() {
        let body = NSArchiver.archivedData(withRootObject: NSAttributedString(string: "\u{FFFC}", attributes: [
            NSAttributedString.Key("__kIMFileTransferGUIDAttributeName"): "AB12",
        ]))
        XCTAssertNil(AudioTranscript.storedTranscript(in: body))
        XCTAssertNil(AudioTranscript.storedTranscript(in: Data("IMAudioTranscription".utf8)), "a key at the end of the data reads nothing")
    }

    func testSpokenAudioWithoutAStoredTranscriptIsTranscribedOnThisMac() async throws {
        guard #available(macOS 26, *) else { throw XCTSkip("SpeechTranscriber needs macOS 26") }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current),
              await SpeechTranscriber.installedLocales.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) })
        else { throw XCTSkip("No on-device speech model is installed for \(Locale.current.identifier)") }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-spoken.aiff")
        files.append(url)
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", url.path, "The quarterly report is due on Friday at noon"]
        try say.run()
        say.waitUntilExit()
        XCTAssertEqual(say.terminationStatus, 0)

        let reply = try await fetch(url)

        XCTAssertEqual(reply.metadata["transcript_source"] as? String, "on_device")
        XCTAssertEqual(reply.metadata["locale"] as? String, locale.identifier(.bcp47))
        let text = try XCTUnwrap(reply.texts.first).lowercased()
        XCTAssertTrue(text.contains("quarterly report") && text.contains("friday"), text)
    }

    func testAudioWithNoSpeechSaysWhyThereIsNoTranscript() async throws {
        let reply = try await fetch(try tone(seconds: 2))

        XCTAssertEqual(try XCTUnwrap(reply.metadata["duration_s"] as? Double), 2, accuracy: 0.1)
        XCTAssertNil(reply.metadata["transcript_source"])
        XCTAssertNotNil(reply.metadata["transcript_unavailable"] as? String)
        XCTAssertTrue(reply.texts.isEmpty)
    }
}

/// The attributedBody of a voice message as Messages writes it: one
/// attachment character whose attributes carry the transfer GUID and the
/// transcript.
@available(*, deprecated)
func voiceMessageBody(transcript: String) -> Data {
    let body = NSAttributedString(string: "\u{FFFC}", attributes: [
        NSAttributedString.Key("__kIMFileTransferGUIDAttributeName"): "4C339597-EBBB-4978-9B87-521C0471A848",
        NSAttributedString.Key("IMAudioTranscription"): transcript,
        NSAttributedString.Key("__kIMMessagePartAttributeName"): NSNumber(value: 0),
    ])
    return NSArchiver.archivedData(withRootObject: body)
}
