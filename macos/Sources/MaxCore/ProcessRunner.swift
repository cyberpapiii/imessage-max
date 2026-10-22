import Foundation

public struct ProcessResult: Sendable {
  public let exitCode: Int32
  public let output: String
}

public enum ProcessRunner {
  public static func run(_ executable: String, arguments: [String], timeout: TimeInterval = 8)
    async throws -> ProcessResult
  {
    let execution = CommandExecution()
    return try await withTaskCancellationHandler {
      try await execution.start(executable, arguments: arguments, timeout: timeout)
    } onCancel: {
      Task { await execution.cancel() }
    }
  }
}

/// Process, file handles, timers, and continuation have one actor owner. Output
/// uses a temporary file rather than pipes so a verbose child cannot deadlock.
private actor CommandExecution {
  private var process: Process?
  private var outputFile: URL?
  private var outputHandle: FileHandle?
  private var timer: DispatchSourceTimer?
  private var escalation: DispatchSourceTimer?
  private var continuation: CheckedContinuation<ProcessResult, any Error>?
  private var failure: (any Error)?
  private var cancelled = false

  func start(_ executable: String, arguments: [String], timeout: TimeInterval) async throws
    -> ProcessResult
  {
    guard !cancelled, !Task.isCancelled else { throw CancellationError() }
    return try await withCheckedThrowingContinuation { continuation in
      self.continuation = continuation
      do {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(
          "imessage-max-command-\(UUID().uuidString)")
        guard
          FileManager.default.createFile(
            atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
        else {
          throw CoreError.commandFailed("Could not prepare the service command.")
        }
        outputFile = file
        let handle = try FileHandle(forWritingTo: file)
        outputHandle = handle
        let child = Process()
        child.executableURL = URL(fileURLWithPath: executable)
        child.arguments = arguments
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = handle
        child.standardError = handle
        child.terminationHandler = { process in
          let code = process.terminationStatus
          Task { await self.finish(code: code) }
        }
        process = child
        try child.run()
        let timer = DispatchSource.makeTimerSource()
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler { @Sendable in Task { await self.stop(error: CoreError.timeout) } }
        self.timer = timer
        timer.resume()
      } catch {
        complete(.failure(error))
      }
    }
  }

  func cancel() {
    cancelled = true
    stop(error: CancellationError())
  }

  private func stop(error: any Error) {
    guard let process, process.isRunning, continuation != nil, failure == nil else { return }
    failure = error
    process.terminate()
    let escalation = DispatchSource.makeTimerSource()
    escalation.schedule(deadline: .now() + 0.5)
    escalation.setEventHandler { @Sendable in Task { await self.killIfRunning() } }
    self.escalation = escalation
    escalation.resume()
  }

  private func killIfRunning() {
    if let process, process.isRunning { kill(process.processIdentifier, SIGKILL) }
  }

  private func finish(code: Int32) {
    if let failure {
      complete(.failure(failure))
      return
    }
    let output: String
    if let file = outputFile, let reader = try? FileHandle(forReadingFrom: file) {
      let data = (try? reader.read(upToCount: 65536)) ?? Data()
      try? reader.close()
      output = String(decoding: data, as: UTF8.self)
    } else {
      output = ""
    }
    complete(.success(ProcessResult(exitCode: code, output: output)))
  }

  private func complete(_ result: Result<ProcessResult, any Error>) {
    guard let continuation else { return }
    self.continuation = nil
    timer?.cancel()
    escalation?.cancel()
    timer = nil
    escalation = nil
    process?.terminationHandler = nil
    process = nil
    try? outputHandle?.close()
    outputHandle = nil
    if let file = outputFile { try? FileManager.default.removeItem(at: file) }
    outputFile = nil
    continuation.resume(with: result)
  }
}
