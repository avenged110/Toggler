// MARK: - DebugLogKit.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
//
// STANDARDIZED LOGGING UTILITY — one file, drop into any project.
//
// Call sites hand messages to an ordered pipe; an actor formats them, buffers them, and
// flushes to disk on a timer or when the buffer fills. Everything a project might want to
// vary — file name, location, size cap, timestamp format — is a value on
// `LoggerConfiguration` rather than an edit to this file.
//
// WIRING IT UP
// ────────────
// One call, as early as possible in launch (before the first log line):
//
//   Logger.bootstrap(
//       .init(fileName: "Toggler.log",
//             destination: .containerLibraryLogs,
//             isEnabled: { Preferences.loggingEnabled }))
//   Logger.prepareLogDirectory()   // after preference defaults are registered
//
// Then:
//
//   struct Foo: Loggable { static let logTag = "[Foo]" }   // tag optional
//   log("something happened")                              // instance or static
//   Logger.log("something happened", cName: "[Foo]")
//
// And at teardown:
//
//   await Logger.shutdownLoggingAwaiting()    // app termination (preferred)
//   Logger.shutdownLogging()                  // fire-and-forget (logging toggled off)
//   Logger.shutdownLoggingBlocking()          // synchronous terminate hooks

import Foundation
import os
import Synchronization

// MARK: - Configuration

/// Where the log file lives.
public enum LogDestination: Sendable {
    /// `<container>/Library/Logs/<fileName>` in a sandboxed app, `~/Library/Logs/…`
    /// otherwise. Resolved via `FileManager.url(for: .libraryDirectory …)` — NOT by
    /// hand-appending `Library/Containers/<bundleID>/Data/…` to the home directory, which
    /// in a sandboxed process double-nests the path and buries the log where nobody looks.
    case containerLibraryLogs

    /// `<container>/Library/Application Support/<fileName>`.
    case applicationSupport

    /// `~/Library/Logs/<subdirectory>/<fileName>` — for unsandboxed apps that want a
    /// user-visible, app-named log folder.
    case userLibraryLogs(subdirectory: String)

    /// Caller-supplied base directory, re-read on every resolution. Use this when the log
    /// follows a user-chosen data folder; returning `nil` falls back to the temporary
    /// directory. Pair with `Logger.invalidateLogFileURLCache()` when the folder moves.
    case custom(@Sendable () -> URL?)
}

/// Severity. Not rendered into the output unless `includesLevelInOutput` is set; it
/// gates messages through `minimumLevel` either way.
public enum LogLevel: Int, Sendable, Comparable, CustomStringConvertible {
    case debug = 0, info, warning, error

    public var description: String {
        switch self {
        case .debug: "DEBUG"
        case .info: "INFO"
        case .warning: "WARN"
        case .error: "ERROR"
        }
    }

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// An additional consumer of formatted log lines — `os_log`, a crash reporter, an in-app
/// console. Sinks receive every line that passes the enabled/level checks, on the logger's
/// own executor, and must not block.
public protocol LogSink: Sendable {
    func receive(line: String, level: LogLevel, category: String?, occurredAt: Date)
}

/// Everything a project can vary, in one value. Installed by `Logger.bootstrap`.
public struct LoggerConfiguration: Sendable {
    /// Log file name, e.g. `"Toggler.log"`.
    public var fileName: String

    /// Where the file lives.
    public var destination: LogDestination

    /// Whether logging is on. The single source of truth, read on every message — pass
    /// the project's own preference, e.g. `{ Preferences.loggingEnabled }`.
    public var isEnabled: @Sendable () -> Bool

    /// Trim threshold. When the file exceeds this, the newest half is kept, cut at a
    /// newline so no record is truncated mid-line.
    public var maxFileSizeBytes: UInt64

    /// How long a buffered line may wait before it is written. One flush is armed when
    /// the buffer gains its first line and fires once; nothing is scheduled while the
    /// buffer is empty, so an idle process is never woken just to find nothing to write.
    public var flushInterval: TimeInterval

    /// Flush immediately once the in-memory buffer reaches this size.
    public var flushThresholdBytes: Int

    /// Timestamp format. Seconds by default; pass `"yyyy-MM-dd'T'HH:mm:ss.SSS"` where a
    /// log records event sequences that land inside one second and second granularity
    /// would hide the ordering the log exists to explain.
    public var timestampFormat: String

    /// Echo each line to stdout as well as the file.
    public var echoToConsole: Bool

    /// Escape control characters, so an interpolated string the app did not author cannot
    /// split one record into two. See `singleLine`.
    public var sanitizesControlCharacters: Bool

    /// Drop messages below this level. `.debug` (the default) drops nothing.
    public var minimumLevel: LogLevel

    /// Render the level into each line, after the timestamp.
    public var includesLevelInOutput: Bool

    /// Extra consumers of each line.
    public var sinks: [any LogSink]

    public init(fileName: String,
                destination: LogDestination = .containerLibraryLogs,
                isEnabled: @escaping @Sendable () -> Bool,
                maxFileSizeBytes: UInt64 = 15 * 1024 * 1024,
                flushInterval: TimeInterval = 10.0,
                flushThresholdBytes: Int = 16 * 1024,
                timestampFormat: String = "yyyy-MM-dd'T'HH:mm:ss",
                echoToConsole: Bool = true,
                sanitizesControlCharacters: Bool = true,
                minimumLevel: LogLevel = .debug,
                includesLevelInOutput: Bool = false,
                sinks: [any LogSink] = []) {
        self.fileName = fileName
        self.destination = destination
        self.isEnabled = isEnabled
        self.maxFileSizeBytes = maxFileSizeBytes
        self.flushInterval = flushInterval
        self.flushThresholdBytes = flushThresholdBytes
        self.timestampFormat = timestampFormat
        self.echoToConsole = echoToConsole
        self.sanitizesControlCharacters = sanitizesControlCharacters
        self.minimumLevel = minimumLevel
        self.includesLevelInOutput = includesLevelInOutput
        self.sinks = sinks
    }

    /// Used until `Logger.bootstrap` runs. Names the file after the bundle and reads the
    /// `preferences.loggingEnabled` default, so a missing bootstrap degrades to logging
    /// somewhere sane rather than crashing or silently discarding.
    static let fallback: LoggerConfiguration = {
        let name = (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? ProcessInfo.processInfo.processName
        let sanitized = name.replacingOccurrences(of: " ", with: "")
        return LoggerConfiguration(
            fileName: "\(sanitized).log",
            destination: .containerLibraryLogs,
            isEnabled: { UserDefaults.standard.bool(forKey: "preferences.loggingEnabled") })
    }()
}

// MARK: - Configuration Storage

// Written once by `Logger.bootstrap`, read from every isolation context. A lock rather
// than an actor because `Logger.isLoggingEnabled` and `Logger.safeLogFileURL` are
// synchronous properties, read directly from SwiftUI bodies and AppKit delegates. The
// state lives inside the `Mutex`, so the compiler checks the `Sendable` conformance.
private final class ConfigurationBox: Sendable {
    static let shared = ConfigurationBox()

    private struct State {
        var stored: LoggerConfiguration?
        var didWarn = false
    }
    private let state = Mutex(State())

    var current: LoggerConfiguration {
        state.withLock { state in
            if let stored = state.stored { return stored }
            if !state.didWarn {
                state.didWarn = true
                writeToStandardError("[LOG] WARNING: Logger.bootstrap(_:) was never called; using defaults.\n")
            }
            return .fallback
        }
    }

    func set(_ configuration: LoggerConfiguration) {
        state.withLock { $0.stored = configuration }
    }
}

private var configuration: LoggerConfiguration { ConfigurationBox.shared.current }

// MARK: - Protocol and Extension

/// Conform a type to get `log(...)` for free, tagged with the type's own name.
public protocol Loggable { static var logTag: String { get } }

// These guard on the enabled check before dispatching, so conforming types need not
// repeat it.
//
// `message` is an `@autoclosure`: the caller's interpolation is not evaluated when logging
// is off, so a hot path that builds an involved diagnostic string pays nothing. It is
// non-escaping and evaluated in the caller's own isolation context, so it raises no
// concurrency concerns.
public extension Loggable {
    static var logTag: String { "[\(String(describing: Self.self))]" }

    func log(_ message: @autoclosure () -> String, level: LogLevel = .info) {
        guard Logger.isLoggingEnabled else { return }
        Logger.log(message(), level: level, cName: Self.logTag)
    }

    static func log(_ message: @autoclosure () -> String, level: LogLevel = .info) {
        guard Logger.isLoggingEnabled else { return }
        Logger.log(message(), level: level, cName: Self.logTag)
    }

    /// Awaitable counterpart to `log(_:)`, for the call sites that must know the message
    /// reached the buffer before proceeding — most notably immediately before a shutdown
    /// that flushes and discards that buffer.
    static func logAwaiting(_ message: String, level: LogLevel = .info) async {
        await Logger.logAwaiting(message, level: level, cName: Self.logTag)
    }
}

// MARK: - File-Level Helpers

/// Resolves the log file URL for the configured destination, creating the directory if
/// needed and falling back to the temporary directory when that is impossible.
private func resolveSafeLogFileURL() -> URL {
    let config = configuration
    let fileManager = FileManager.default

    func temporaryFallback(_ reason: String) -> URL {
        writeToStandardError("[LOG] WARNING: \(reason) — falling back to temporary directory for logs.\n")
        return fileManager.temporaryDirectory.appendingPathComponent(config.fileName)
    }

    /// Makes sure `directory` exists and is a directory, then returns the file inside it.
    func file(in directory: URL) -> URL? {
        // Resolved first so a symlink to a directory counts as one, and a dangling or
        // looping symlink (still a link after resolving) counts as nothing — the same
        // answers `fileExists(atPath:isDirectory:)` gives, without its pointer argument.
        let existing = try? directory.resolvingSymlinksInPath()
            .resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        if existing?.isDirectory == false, existing?.isSymbolicLink == false {
            // A regular file where a directory belongs. Remove it rather than failing.
            do { try fileManager.removeItem(at: directory) }
            catch {
                writeToStandardError("[LOG] ERROR: Could not remove non-directory at \(directory.path): \(error.localizedDescription)\n")
                return nil
            }
        }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory.appendingPathComponent(config.fileName, isDirectory: false)
        } catch {
            writeToStandardError("[LOG] ERROR: Failed to create log directory (\(directory.path)): \(error.localizedDescription)\n")
            return nil
        }
    }

    switch config.destination {
    case .containerLibraryLogs:
        // `create: true` materializes Library on a first launch into a brand-new container.
        guard let library = try? fileManager.url(for: .libraryDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true)
        else { return temporaryFallback("Could not locate the Library directory") }
        return file(in: library.appendingPathComponent("Logs", isDirectory: true))
            ?? temporaryFallback("Could not prepare the Logs directory")

    case .applicationSupport:
        guard let support = try? fileManager.url(for: .applicationSupportDirectory,
                                                 in: .userDomainMask,
                                                 appropriateFor: nil, create: true)
        else { return temporaryFallback("Application Support is unavailable") }
        return file(in: support)
            ?? temporaryFallback("Could not prepare the Application Support directory")

    case .userLibraryLogs(let subdirectory):
        guard let library = try? fileManager.url(for: .libraryDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true)
        else { return temporaryFallback("Could not locate the Library directory") }
        let directory = library
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent(subdirectory, isDirectory: true)
        return file(in: directory) ?? temporaryFallback("Could not prepare \(subdirectory)")

    case .custom(let provider):
        guard let base = provider() else {
            return temporaryFallback("The custom log directory is unavailable")
        }
        return file(in: base) ?? temporaryFallback("Could not prepare \(base.path)")
    }
}

/// The size of the file, or nil if it cannot be determined.
private func fileSize(of fileURL: URL) -> UInt64? {
    guard let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
          size >= 0 else { return nil }
    return UInt64(size)
}

/// Keeps the newest half of `maxFileSizeBytes`, aligned to the next newline so no record
/// is cut mid-line (or mid-UTF-8-sequence).
///
/// PRECONDITION: only called when the file is already known to exceed the cap; the guard
/// below is a defense-in-depth backstop, not a branch that fires on normal paths.
/// `knownSize` is the size the caller already measured, so no second stat is needed.
private func trimLogFile(at fileURL: URL, knownSize size: UInt64) {
    let cap = configuration.maxFileSizeBytes
    guard size > cap else { return }

    let keepBytes = cap / 2
    guard keepBytes > 0, size > keepBytes else { return }

    guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return }
    defer { try? handle.close() }

    let rawOffset = size - keepBytes
    do {
        try handle.seek(toOffset: rawOffset)
    } catch {
        writeToStandardError("[LOG] WARNING: Failed to seek during log trim: \(error.localizedDescription)\n")
        return
    }

    let lookAhead: Data
    do {
        lookAhead = try handle.read(upToCount: 512) ?? Data()
    } catch {
        writeToStandardError("[LOG] WARNING: Failed to read look-ahead during log trim: \(error.localizedDescription)\n")
        return
    }

    var aligned = rawOffset
    if let newline = lookAhead.range(of: Data([UInt8(ascii: "\n")])) {
        aligned = rawOffset + UInt64(newline.upperBound)
    }

    do {
        try handle.seek(toOffset: aligned)
        guard let tail = try handle.readToEnd(), !tail.isEmpty else { return }
        try tail.write(to: fileURL, options: .atomic)
    } catch {
        writeToStandardError("[LOG] WARNING: Failed trimming log file: \(error.localizedDescription)\n")
    }
}

/// Performs the append. Always writes once invoked; whether to accept or drop a message is
/// decided upstream.
///
/// TRIM BEFORE OPENING THE HANDLE. The trim writes atomically, which replaces the file with
/// a new inode; a FileHandle opened beforehand would still address the old, unlinked one
/// and its writes would vanish.
private func performLogWrite(data: Data, to fileURL: URL) {
    let fileManager = FileManager.default

    if !fileManager.fileExists(atPath: fileURL.path) {
        do {
            try Data().write(to: fileURL, options: .atomic)
        } catch {
            writeToStandardError("[LOG] ERROR: Failed to create log file at \(fileURL.path): \(error.localizedDescription)\n")
            return
        }
    }

    // Trimming happens after the cap is passed, not before, so the file may overshoot by
    // at most one flush.
    if let size = fileSize(of: fileURL), size > configuration.maxFileSizeBytes {
        trimLogFile(at: fileURL, knownSize: size)
    }

    do {
        let handle = try FileHandle(forUpdating: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    } catch {
        writeToStandardError("[LOG] ERROR: Failed to write to log file: \(error.localizedDescription)\n")
    }
}

/// Empties the file. Call only from `LoggerCore`, which serializes it against the write
/// chain — an unserialized clear replaces the inode underneath an in-flight append,
/// discarding either the append or the clear depending on which lands last.
private func performLogClear(at fileURL: URL) -> Bool {
    do {
        try Data().write(to: fileURL, options: .atomic)
        return true
    } catch {
        writeToStandardError("[LOG] ERROR: Failed to clear log file at \(fileURL.path): \(error.localizedDescription)\n")
        return false
    }
}

// MARK: - LoggerCore

/// Owns every piece of mutable logging state, on its own actor executor.
public actor LoggerCore {
    public static let shared = LoggerCore()

    /// In-memory write buffer.
    private var writeBuffer = Data()

    /// The pending deferred flush; nil while the buffer is empty.
    private var flushTask: Task<Void, Never>?

    /// Tail of the serial disk-write chain. Each flush links its write after the previous
    /// one's completion, so writes never run concurrently — independent FileHandles each
    /// doing seek-to-end + append could otherwise clobber one another — and always land in
    /// the order they were buffered.
    private var writeTask: Task<Void, Never>?

    /// Cached log file URL, resolved once on first use.
    private var cachedLogFileURL: URL?

    /// Read-side mirror of `cachedLogFileURL` for the synchronous `Logger` facade.
    /// Lock-protected, because it is read and written from every isolation context — the
    /// facade from SwiftUI bodies and AppKit delegates, the actor from its own executor.
    /// Idempotent resolution does not make an unsynchronized `URL` safe: a racing read can
    /// observe a half-written reference and over-release it.
    ///
    /// `generation` counts invalidations. Resolution runs outside the lock, so a resolver
    /// takes the generation first and stores only if it is unchanged: a URL resolved from a
    /// configuration that was replaced mid-resolution is never cached over the invalidation.
    ///
    /// The cache lives inside its lock, so there is no way to touch it unlocked.
    private struct FacadeURLCache: Sendable {
        var url: URL?
        var generation = 0
    }
    private static let facadeURLCache = OSAllocatedUnfairLock(initialState: FacadeURLCache())

    fileprivate static func facadeURLSnapshot() -> (url: URL?, generation: Int) {
        facadeURLCache.withLock { ($0.url, $0.generation) }
    }

    /// Caches `url` unless an invalidation happened since `generation` was read. Returns
    /// whether it was cached.
    @discardableResult
    fileprivate static func storeFacadeURL(_ url: URL, ifGeneration generation: Int) -> Bool {
        facadeURLCache.withLock { cache in
            guard cache.generation == generation else { return false }
            cache.url = url
            return true
        }
    }

    /// Drops the cached URL and starts a new generation. Returns whether a URL was cached.
    @discardableResult
    fileprivate static func invalidateFacadeURL() -> Bool {
        facadeURLCache.withLock { cache in
            let hadURL = cache.url != nil
            cache.url = nil
            cache.generation &+= 1
            return hadURL
        }
    }

    private var dateFormatter: DateFormatter
    private var dateFormatterFormat: String

    private init() {
        let format = configuration.timestampFormat
        let formatter = DateFormatter()
        formatter.dateFormat = format
        formatter.timeZone = .current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        self.dateFormatter = formatter
        self.dateFormatterFormat = format
    }

    // MARK: Public API (actor-isolated)

    /// Formats a message, echoes it, hands it to any sinks, and appends it to the buffer.
    ///
    /// `occurredAt` comes from the call site, so the timestamp is when the event happened
    /// rather than when this actor got to it. `force` bypasses the enabled check — see
    /// `Logger.logForced`.
    fileprivate func log(_ message: String, level: LogLevel, category: String?,
                         occurredAt: Date, force: Bool = false) {
        let config = configuration
        // Re-checked here as well as at the facade, in case the actor is called directly.
        guard force || config.isEnabled() else { return }
        guard force || level >= config.minimumLevel else { return }

        // Bootstrap can land after this actor is created, so the formatter is reconciled
        // lazily rather than frozen at init.
        if dateFormatterFormat != config.timestampFormat {
            dateFormatterFormat = config.timestampFormat
            dateFormatter.dateFormat = config.timestampFormat
        }

        let timestamp = dateFormatter.string(from: occurredAt)
        let levelPrefix = config.includesLevelInOutput ? "[\(level.description)] " : ""
        let categoryPrefix = category.map { "\($0) " } ?? ""
        let body = config.sanitizesControlCharacters ? Self.singleLine(message) : message
        let line = "[\(timestamp)] \(levelPrefix)\(categoryPrefix)\(body)\n"

        if config.echoToConsole {
            print(line, terminator: "")
        }
        for sink in config.sinks {
            sink.receive(line: line, level: level, category: category, occurredAt: occurredAt)
        }

        guard let data = line.data(using: .utf8) else { return }

        writeBuffer.append(data)
        if writeBuffer.count >= config.flushThresholdBytes {
            flushBufferedLogs()
        } else {
            scheduleFlushIfNeeded()
        }
    }

    /// Collapses a message to exactly one line.
    ///
    /// A no-op for the single-line messages log sites normally build. It exists for
    /// messages interpolating strings the app did not author — a file name from disk, a
    /// device's own model string — where an embedded newline would split one entry in two
    /// and the second half would read as a genuine record. Control characters are escaped
    /// rather than dropped, so a message that genuinely held one still shows it.
    private static func singleLine(_ message: String) -> String {
        guard message.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
        else { return message }
        var out = String.UnicodeScalarView()
        for scalar in message.unicodeScalars {
            switch scalar.value {
            case 0x0A: out.append(contentsOf: "\\n".unicodeScalars)
            case 0x0D: out.append(contentsOf: "\\r".unicodeScalars)
            case 0x09: out.append(contentsOf: "\\t".unicodeScalars)
            case 0..<0x20, 0x7F:
                let hex = String(scalar.value, radix: 16, uppercase: true)
                out.append(contentsOf: "\\x\(hex.count < 2 ? "0" : "")\(hex)".unicodeScalars)
            default: out.append(scalar)
            }
        }
        return String(out)
    }

    /// Flushes buffered logs and cancels the pending deferred flush.
    ///
    /// No enabled check, so messages buffered before logging was disabled are still
    /// written. The remaining buffer is written INLINE, so awaiting this guarantees the
    /// data is on disk before the caller resumes.
    public func shutdown() async {
        flushTask?.cancel()
        flushTask = nil
        // Drain writes already in flight first, so the inline write below appends after
        // them rather than racing an atomic trim/replace they may perform.
        await writeTask?.value
        writeTask = nil
        flushBufferedLogsSynchronously()
    }

    /// Empties the log file, behind every queued write so the clear can neither be undone
    /// by an in-flight append nor discard one.
    fileprivate func clearLogFile() async -> Bool {
        await writeTask?.value
        writeTask = nil
        // Anything still buffered belongs to the pre-clear log and would otherwise be
        // appended to the freshly emptied file moments later.
        writeBuffer.removeAll(keepingCapacity: true)
        return performLogClear(at: resolvedLogFileURL())
    }

    /// Forgets the resolved URL so the next write re-resolves it.
    fileprivate func invalidateLogFileURLCache() {
        cachedLogFileURL = nil
        LoggerCore.invalidateFacadeURL()
    }

    // MARK: Private helpers (actor-isolated)

    private func resolvedLogFileURL() -> URL {
        if let url = cachedLogFileURL { return url }
        let generation = LoggerCore.facadeURLSnapshot().generation
        let url = resolveSafeLogFileURL()
        // Mirrored so `Logger.safeLogFileURL` need not re-walk the filesystem. Kept here only
        // if the mirror took it: a resolution that straddled an invalidation is used for this
        // write but re-resolved on the next, rather than pinning the old location all session.
        if LoggerCore.storeFacadeURL(url, ifGeneration: generation) {
            cachedLogFileURL = url
        }
        return url
    }

    /// Arms a single deferred flush, `flushInterval` after the first line to reach an empty
    /// buffer. Later lines ride along with it; the flush disarms it, and the next line to
    /// arrive after that arms the next one.
    ///
    /// Deliberately not a repeating loop: a loop wakes the process on every interval for
    /// as long as it lives, whether or not anything was logged — in a long-running
    /// background process, that is nearly every wake-up it has.
    private func scheduleFlushIfNeeded() {
        guard flushTask == nil else { return }

        // Captures this actor directly so the timer does not go through
        // `LoggerCore.shared`.
        let interval = configuration.flushInterval
        flushTask = Task.detached(priority: .utility) { [core = self] in
            do {
                try await Task.sleep(for: .seconds(interval))
            } catch {
                return // Canceled: the buffer was flushed some other way.
            }
            await core.flushBufferedLogs()
        }
    }

    /// Flushes the buffer in a single write and disarms the deferred flush. The buffer is
    /// swapped out before the disk call so new `log()` calls are never blocked waiting on
    /// I/O.
    private func flushBufferedLogs() {
        // Disarmed even when there is nothing to write: whichever path got here, the
        // buffer is now empty, and the next line must arm a fresh full interval.
        flushTask?.cancel()
        flushTask = nil
        guard !writeBuffer.isEmpty else { return }

        let toWrite = writeBuffer
        writeBuffer = Data()
        let fileURL = resolvedLogFileURL()

        // Off the actor's executor so it stays responsive, and chained after the previous
        // write so ordering holds and two handles never race a seek-to-end append.
        let previous = writeTask
        writeTask = Task.detached(priority: .utility) {
            await previous?.value
            performLogWrite(data: toWrite, to: fileURL)
        }
    }

    /// Terminal-path flush, written INLINE on the actor's executor: at termination a
    /// detached write is not guaranteed to run before macOS reclaims the process.
    private func flushBufferedLogsSynchronously() {
        guard !writeBuffer.isEmpty else { return }

        let toWrite = writeBuffer
        writeBuffer = Data()
        performLogWrite(data: toWrite, to: resolvedLogFileURL())
    }
}

// MARK: - Ordered Hand-Off From Call Sites To LoggerCore

private struct LogEntry: Sendable {
    let message: String
    let level: LogLevel
    let category: String?
    let occurredAt: Date
    let force: Bool
}

/// A barrier rides the queue as an ordinary command so it cannot overtake the messages
/// ahead of it; the consumer resumes it once everything queued before it has been handed
/// to `LoggerCore`.
private enum LogCommand: Sendable {
    case message(LogEntry)
    case barrier(CheckedContinuation<Void, Never>)
}

/// A single serial consumer feeding `LoggerCore`. Call sites hand messages over with
/// `yield` — synchronous, thread-safe and order-preserving — so the actor sees them in the
/// order they were produced.
///
/// The ordering is the point. A `Task.detached` per message carries no ordering guarantee
/// between tasks, so two lines logged in sequence can land in the file inverted; in a log
/// that is a chronology of state transitions, a reordered pair reads as the opposite of
/// what happened. This also avoids allocating a task per line.
private enum LogPipe {
    private static let continuation: AsyncStream<LogCommand>.Continuation = {
        let (stream, continuation) = AsyncStream<LogCommand>.makeStream(
            of: LogCommand.self, bufferingPolicy: .unbounded)
        Task.detached(priority: .utility) {
            for await command in stream {
                switch command {
                case .message(let entry):
                    await LoggerCore.shared.log(entry.message,
                                                level: entry.level,
                                                category: entry.category,
                                                occurredAt: entry.occurredAt,
                                                force: entry.force)
                case .barrier(let waiter):
                    waiter.resume()
                }
            }
        }
        return continuation
    }()

    static func send(_ entry: LogEntry) {
        continuation.yield(.message(entry))
    }

    /// Waits until every message handed over before this call has reached `LoggerCore`'s
    /// buffer. Deliberately NOT terminal: teardown keeps logging through the ordinary path
    /// after awaiting a barrier, and finishing the stream would discard exactly those
    /// final messages.
    static func flushBarrier() async {
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
            // Anything other than `.enqueued` means the command will never reach the
            // consumer, so the barrier has to resume itself or the caller hangs.
            if case .enqueued = continuation.yield(.barrier(waiter)) { return }
            waiter.resume()
        }
    }
}

// MARK: - Public Logger Facade (Call-Site API)

/// The static facade used throughout an app. Value-only (a caseless enum): all mutable
/// state lives in `LoggerCore`.
public enum Logger {

    // MARK: Setup

    /// Installs the app's configuration. Call once, as early in launch as possible —
    /// before the first log line and before `prepareLogDirectory()`.
    public static func bootstrap(_ configuration: LoggerConfiguration) {
        ConfigurationBox.shared.set(configuration)
        // A log line or `safeLogFileURL` read before this call resolved and cached a URL
        // from the fallback configuration; without this the app would keep writing there
        // all session, ignoring the `fileName` and `destination` just supplied.
        //
        // The generation always advances, so a resolution already under way from the fallback
        // configuration is not cached. The actor task is skipped when nothing has been cached
        // yet, which is the ordinary case: `bootstrap` is the first thing a launch does, so
        // the actor holds no stale URL either — and the task would otherwise instantiate
        // `LoggerCore` (and its DateFormatter) on the launch path, for a logger that is
        // usually switched off.
        guard LoggerCore.invalidateFacadeURL() else { return }
        Task.detached(priority: .utility) {
            await LoggerCore.shared.invalidateLogFileURLCache()
        }
    }

    /// The active configuration — for reading `fileName` in a diagnostics panel, say.
    public static var currentConfiguration: LoggerConfiguration { configuration }

    // MARK: State

    /// Whether logging is currently on, per the configured predicate.
    public static var isLoggingEnabled: Bool { configuration.isEnabled() }

    /// A safe, writable URL for the log file.
    ///
    /// Resolution walks the filesystem and creates the log directory, so the result is
    /// cached here as well as inside the actor — this is read on every Reveal/Clear press
    /// and every restart of the log-file monitor.
    public static var safeLogFileURL: URL {
        // Re-resolves when an invalidation lands mid-resolution, so the caller gets the new
        // location. Bounded: after a few contested attempts the latest URL is returned
        // uncached, and the next read tries again.
        var resolved: URL
        var attempts = 0
        repeat {
            let (cached, generation) = LoggerCore.facadeURLSnapshot()
            if let cached { return cached }
            resolved = resolveSafeLogFileURL()
            if LoggerCore.storeFacadeURL(resolved, ifGeneration: generation) { return resolved }
            attempts += 1
        } while attempts < 3
        return resolved
    }

    /// The directory containing the log file — what a file-system monitor watches.
    public static var logDirectoryURL: URL { safeLogFileURL.deletingLastPathComponent() }

    /// Forces the log directory and file into existence. Call once at launch, AFTER
    /// `bootstrap` and after preference defaults are registered — it reads the enabled
    /// predicate. Resolution creates the directory, so this only ensures the file.
    public static func prepareLogDirectory() {
        guard isLoggingEnabled else { return }

        let fileManager = FileManager.default
        let fileURL = safeLogFileURL

        if !fileManager.fileExists(atPath: fileURL.path) {
            do { try Data().write(to: fileURL, options: .atomic) }
            catch {
                writeToStandardError("[LOG] ERROR: Failed to create log file at \(fileURL.path): \(error.localizedDescription)\n")
            }
        }
    }

    /// Forgets the resolved log URL so the next write re-resolves it, for a log living in
    /// a user-relocatable data folder (`LogDestination.custom`).
    ///
    /// The facade mirror is cleared synchronously, so the very next `safeLogFileURL` read
    /// re-resolves; the actor clears its own copy when it drains, so a flush already in
    /// flight still targets the old file. That is correct — those bytes were buffered for
    /// the old location.
    public static func invalidateLogFileURLCache() {
        LoggerCore.invalidateFacadeURL()
        Task.detached(priority: .utility) {
            await LoggerCore.shared.invalidateLogFileURLCache()
        }
    }

    // MARK: Logging

    /// The main entry point. Returns immediately; all work happens asynchronously.
    ///
    /// Call sites are expected to guard on `isLoggingEnabled` first — the `Loggable`
    /// extension does it for you.
    public static func log(_ message: String, level: LogLevel = .info, cName: String? = nil) {
        // `Date()` is read on the calling thread, so the timestamp is the moment of the
        // event rather than the moment the logger drained it.
        LogPipe.send(LogEntry(message: message, level: level, category: cName,
                              occurredAt: Date(), force: false))
    }

    /// Records a message even though logging has just been switched off.
    ///
    /// For one call site: the moment the user disables logging. `@AppStorage` commits the
    /// new preference before SwiftUI's `onChange` runs, so by then every enabled check
    /// rejects the message and the one line explaining why the log goes silent is never
    /// written. Follow it with `shutdownLogging()`, which flushes it.
    public static func logForced(_ message: String, level: LogLevel = .info,
                                 cName: String? = nil) {
        LogPipe.send(LogEntry(message: message, level: level, category: cName,
                              occurredAt: Date(), force: true))
    }

    /// Awaitable `log`, for call sites that must know the message reached `LoggerCore`'s
    /// buffer before proceeding — most notably just before a shutdown that flushes it.
    public static func logAwaiting(_ message: String, level: LogLevel = .info,
                                   cName: String? = nil) async {
        guard isLoggingEnabled else { return }
        LogPipe.send(LogEntry(message: message, level: level, category: cName,
                              occurredAt: Date(), force: false))
        await LogPipe.flushBarrier()
    }

    // MARK: Clearing

    /// Empties the log file, serialized behind the write chain so the clear can neither be
    /// undone by nor discard an in-flight append. Returns true on success.
    ///
    /// Always prefer this to writing empty `Data` at the file yourself — see
    /// `performLogClear` for what an unserialized clear does.
    @discardableResult
    public static func clearLog() async -> Bool {
        // Barrier first: anything still in the pipe has not reached the buffer yet and
        // would be written to the file just after it was emptied.
        await LogPipe.flushBarrier()
        return await LoggerCore.shared.clearLogFile()
    }

    /// Fire-and-forget `clearLog()`, for button actions that cannot await.
    public static func clearLogFile() {
        Task.detached(priority: .utility) { _ = await clearLog() }
    }

    // MARK: Teardown

    /// Flushes remaining messages and cancels the pending deferred flush. Call when logging is
    /// disabled at runtime: messages buffered before the disable would otherwise be lost.
    public static func shutdownLogging() {
        Task.detached(priority: .utility) { await shutdownLoggingAwaiting() }
    }

    /// Awaitable teardown for the app-termination path, where the process must not exit
    /// until the final buffer has reached disk. The preferred form.
    public static func shutdownLoggingAwaiting() async {
        // Barrier first: anything still queued in the pipe has not reached the buffer that
        // `shutdown()` is about to flush and discard. This is what captures teardown
        // messages logged through the ordinary fire-and-forget path.
        await LogPipe.flushBarrier()
        await LoggerCore.shared.shutdown()
    }

    /// Synchronous teardown for `applicationWillTerminate`-style hooks that cannot await.
    /// Blocks until the buffer is on disk. `LoggerCore` runs on its own executor, not the
    /// main actor, so this cannot deadlock against the main thread.
    public static func shutdownLoggingBlocking() {
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            await shutdownLoggingAwaiting()
            semaphore.signal()
        }
        semaphore.wait()
    }
}

// MARK: - Standard Error

/// The kit's own diagnostics, for when the log file itself is what failed. Same unbuffered
/// write as `fputs(_, stderr)`, without handing a C `FILE*` around; a closed stderr is
/// ignored, as `fputs` ignored it.
nonisolated private func writeToStandardError(_ message: String) {
    try? FileHandle.standardError.write(contentsOf: Data(message.utf8))
}
