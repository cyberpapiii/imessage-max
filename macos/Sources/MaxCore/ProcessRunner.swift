import Foundation

public struct ProcessResult: Sendable {
  public let exitCode: Int32
  public let output: String

  /// The output's last line, which is where a CLI says why it failed.
  public var lastLine: String { output.split(separator: "\n").last.map(String.init) ?? "" }
}

public enum ProcessRunner {
  /// `environment`, when given, is the child's whole environment, and its
  /// HOME is the child's working folder. `input`, when given, is the child's
  /// whole stdin; it must fit in a pipe's buffer.
  public static func run(
    _ executable: String, arguments: [String], environment: [String: String]? = nil,
    input: Data? = nil, timeout: TimeInterval = 8
  ) async throws -> ProcessResult {
    let execution = CommandExecution()
    return try await withTaskCancellationHandler {
      try await execution.start(
        executable, arguments: arguments, environment: environment, input: input,
        timeout: timeout)
    } onCancel: {
      Task { await execution.cancel() }
    }
  }
}

/// One actor owns the process, file handles, timers and continuation. Output
/// goes to a temporary file, not a pipe, so a verbose child cannot deadlock.
private actor CommandExecution {
  private var process: Process?
  private var outputFile: URL?
  private var outputHandle: FileHandle?
  private var timer: DispatchSourceTimer?
  private var escalation: DispatchSourceTimer?
  private var continuation: CheckedContinuation<ProcessResult, any Error>?
  private var failure: (any Error)?
  private var cancelled = false

  func start(
    _ executable: String, arguments: [String], environment: [String: String]?, input: Data?,
    timeout: TimeInterval
  ) async throws -> ProcessResult {
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
        if let environment {
          child.environment = environment
          if let home = environment["HOME"] { child.currentDirectoryURL = URL(fileURLWithPath: home) }
        }
        if let input {
          // Written and closed before launch, so a child that exits early
          // cannot raise SIGPIPE in this process.
          let pipe = Pipe()
          try pipe.fileHandleForWriting.write(contentsOf: input)
          try pipe.fileHandleForWriting.close()
          child.standardInput = pipe
        } else {
          child.standardInput = FileHandle.nullDevice
        }
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
      let data = (try? reader.read(upToCount: 1 << 20)) ?? Data()
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
