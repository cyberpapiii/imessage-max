import AVFoundation
import Foundation
import MCP
import Speech
import Synchronization

/// What an audio attachment says. Messages keeps its own transcript of a
/// voice message in the message's attributedBody; other audio is
/// transcribed on this Mac. Neither needs a permission beyond Full Disk Access.
enum AudioTranscript {
    enum Source: String, Encodable, Sendable {
        /// The transcript Messages shows under the voice message.
        case messages
        /// Transcribed on this Mac by SpeechTranscriber.
        case onDevice = "on_device"
    }

    struct Detail: Encodable, Sendable {
        let durationS: Double?
        let transcriptSource: Source?
        let locale: String?
        let transcriptUnavailable: String?

        private enum CodingKeys: String, CodingKey {
            case durationS = "duration_s"
            case transcriptSource = "transcript_source"
            case locale
            case transcriptUnavailable = "transcript_unavailable"
        }
    }

    /// Longer audio is not transcribed on this Mac, so a call stays within
    /// a client's tool timeout.
    static let maxOnDeviceSeconds: Double = 600

    static func content(of file: AttachmentFile, db: Database) async throws -> TypedAttachmentContent {
        let duration = try? await AVURLAsset(url: URL(fileURLWithPath: file.path)).load(.duration).seconds
        let seconds = duration.flatMap { $0.isFinite ? ($0 * 10).rounded() / 10 : nil }

        if let stored = try storedTranscript(attachmentRowId: file.rowId, db: db) {
            return TypedAttachmentContent(
                detail: Detail(durationS: seconds, transcriptSource: .messages, locale: nil, transcriptUnavailable: nil),
                blocks: [.plainText(stored)]
            )
        }

        let result: OnDeviceResult
        if let seconds, seconds > maxOnDeviceSeconds {
            result = .unavailable("The audio is longer than \(Int(maxOnDeviceSeconds / 60)) minutes, so it is not transcribed on this Mac.")
        } else if #available(macOS 26, *) {
            let url = URL(fileURLWithPath: file.path)
            result = await bounded(within: onDeviceTimeLimit) { await OnDeviceTranscriber.transcribe(url) }
        } else {
            result = .unavailable("Transcribing audio on this Mac needs macOS 26 or later.")
        }

        switch result {
        case .transcript(let text, let locale):
            return TypedAttachmentContent(
                detail: Detail(durationS: seconds, transcriptSource: .onDevice, locale: locale, transcriptUnavailable: nil),
                blocks: [.plainText(text)]
            )
        case .unavailable(let reason):
            return TypedAttachmentContent(
                detail: Detail(durationS: seconds, transcriptSource: nil, locale: nil, transcriptUnavailable: reason),
                blocks: []
            )
        }
    }

    static func storedTranscript(attachmentRowId: Int, db: Database) throws -> String? {
        let bodies: [Data?] = try db.query(
            """
            SELECT m.attributedBody
            FROM message_attachment_join maj
            JOIN message m ON m.ROWID = maj.message_id
            WHERE maj.attachment_id = ?
            """,
            params: [attachmentRowId]
        ) { row in row.blob(0) }
        return bodies.lazy.compactMap { $0.flatMap(storedTranscript(in:)) }.first
    }

    private static let transcriptionKey = Data("IMAudioTranscription".utf8)

    /// Reads the `IMAudioTranscription` attribute from a typedstream
    /// attributedBody. After the key's string comes the end of that object
    /// (0x86), then the value: 0x92 0x84, a reference to the NSString class,
    /// the "+" type (a reference, or 0x84 0x01 0x2B when written in full),
    /// then the length and the UTF-8 bytes.
    static func storedTranscript(in attributedBody: Data) -> String? {
        let data = attributedBody.startIndex == 0 ? attributedBody : Data(attributedBody)
        guard let key = data.range(of: transcriptionKey) else { return nil }
        var index = key.upperBound
        func next() -> UInt8? {
            guard index < data.count else { return nil }
            defer { index += 1 }
            return data[index]
        }
        guard next() == 0x86, next() == 0x92, next() == 0x84 else { return nil }
        guard let classReference = next(), classReference >= 0x92 else { return nil }
        guard let type = next() else { return nil }
        if type == 0x84 {
            guard next() == 0x01, next() == 0x2B else { return nil }
        } else if type < 0x92 {
            return nil
        }
        guard let (length, start) = MessageTextExtractor.typedstreamLength(in: data, at: index),
              length > 0, start + length <= data.count
        else { return nil }
        let text = String(data: data[start..<(start + length)], encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : nil
    }
}

extension AudioTranscript {
    /// A hung transcription must not hold the tool call past a client's tool
    /// timeout, or hold up an update that waits for no call in flight.
    static let onDeviceTimeLimit: Duration = .seconds(45)

    /// `work`'s result, or `.unavailable` once `limit` passes. The work is
    /// cancelled then, and never awaited: a task group would wait for a
    /// transcription that ignores cancellation.
    static func bounded(
        within limit: Duration,
        _ work: @escaping @Sendable () async -> OnDeviceResult
    ) async -> OnDeviceResult {
        let run = BoundedRun()
        let gate = AsyncTimeout.ResumeGate()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<OnDeviceResult, Never>) in
                run.arm(continuation)
                run.start(Task {
                    let result = await work()
                    gate.cancelAndResume()
                    run.finish(result)
                })
                Task {
                    await AsyncTimeout.sleep(limit, gate: gate)
                    run.cancelWork()
                    run.finish(.unavailable("Transcribing the audio took longer than \(limit.components.seconds) s, so it was stopped."))
                }
            }
        } onCancel: {
            run.cancelWork()
        }
    }

    private final class BoundedRun: Sendable {
        private struct State {
            var continuation: CheckedContinuation<OnDeviceResult, Never>?
            var task: Task<Void, Never>?
            var cancelled = false
        }
        private let state = Mutex(State())

        func arm(_ continuation: CheckedContinuation<OnDeviceResult, Never>) {
            state.withLock { $0.continuation = continuation }
        }

        func start(_ task: Task<Void, Never>) {
            let cancelled = state.withLock { state -> Bool in
                state.task = task
                return state.cancelled
            }
            if cancelled { task.cancel() }
        }

        func cancelWork() {
            state.withLock { state -> Task<Void, Never>? in
                state.cancelled = true
                return state.task
            }?.cancel()
        }

        func finish(_ result: OnDeviceResult) {
            state.withLock { state -> CheckedContinuation<OnDeviceResult, Never>? in
                defer { state.continuation = nil }
                return state.continuation
            }?.resume(returning: result)
        }
    }
}

enum OnDeviceResult: Sendable {
    case transcript(String, locale: String)
    case unavailable(String)
}

@available(macOS 26, *)
enum OnDeviceTranscriber {
    static func transcribe(_ url: URL) async -> OnDeviceResult {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) else {
            return .unavailable("On-device transcription does not support this Mac's language (\(Locale.current.identifier)).")
        }
        let tag = locale.identifier(.bcp47)
        let installed = await SpeechTranscriber.installedLocales
        guard installed.contains(where: { $0.identifier(.bcp47) == tag }) else {
            return .unavailable("The on-device speech model for \(tag) is not installed on this Mac.")
        }
        do {
            let file = try AVAudioFile(forReading: url)
            let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            async let text = collect(transcriber.results)
            if let last = try await analyzer.analyzeSequence(from: file) {
                try await analyzer.finalizeAndFinish(through: last)
            } else {
                await analyzer.cancelAndFinishNow()
            }
            let transcript = try await text.trimmingCharacters(in: .whitespacesAndNewlines)
            return transcript.isEmpty ? .unavailable("No speech was recognized in the audio.") : .transcript(transcript, locale: tag)
        } catch {
            return .unavailable("The audio could not be transcribed on this Mac.")
        }
    }

    private static func collect(_ results: some AsyncSequence<SpeechTranscriber.Result, any Error>) async throws -> String {
        var segments: [String] = []
        for try await result in results {
            let segment = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
            if !segment.isEmpty { segments.append(segment) }
        }
        return segments.joined(separator: " ")
    }
}
