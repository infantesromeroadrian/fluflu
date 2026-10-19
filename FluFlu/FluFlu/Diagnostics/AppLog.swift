import Foundation
import OSLog

/// Registro de diagnóstico con dos salidas: el log unificado (Consola) y un fichero propio.
/// El fichero existe porque los mensajes `info` del log unificado viven en memoria y desaparecen
/// al cerrar la app, así que un fallo contado a posteriori no se podía reconstruir.
nonisolated struct AppLog: Sendable {
    static let subsystem = "com.adrianinfantes.FluFlu"

    private let logger: Logger
    private let category: String

    init(category: String) {
        self.category = category
        logger = Logger(subsystem: Self.subsystem, category: category)
    }

    func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        LogFile.shared.append(level: "INFO", category: category, message)
    }

    func warning(_ message: String) {
        logger.warning("\(message, privacy: .public)")
        LogFile.shared.append(level: "WARN", category: category, message)
    }

    func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        LogFile.shared.append(level: "ERROR", category: category, message)
    }
}

/// Fichero `~/Library/Logs/FluFlu/FluFlu.log` con una rotación: al superar `rotationSize` pasa a
/// `FluFlu.log.1` y se empieza otro. Escribir nunca falla hacia fuera: un registro roto no debe
/// tumbar un dictado.
nonisolated final class LogFile: @unchecked Sendable {
    static let shared = LogFile(directory: FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/FluFlu"))
    static var url: URL { shared.url }

    let directory: URL
    let url: URL
    let rotatedURL: URL
    private let rotationSize: UInt64

    private let lock = NSLock()
    private var handle: FileHandle?
    private let timestamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = .current
        return formatter
    }()

    init(directory: URL, rotationSize: UInt64 = 2 * 1024 * 1024) {
        self.directory = directory
        url = directory.appending(path: "FluFlu.log")
        rotatedURL = directory.appending(path: "FluFlu.log.1")
        self.rotationSize = rotationSize
    }

    func append(level: String, category: String, _ message: String) {
        let line = "\(timestamp.string(from: .now)) \(level) [\(category)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        lock.withLock {
            do {
                try rotateIfNeeded()
                try openIfNeeded().write(contentsOf: data)
            } catch {
                handle = nil
            }
        }
    }

    private func openIfNeeded() throws -> FileHandle {
        if let handle { return handle }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let opened = try FileHandle(forWritingTo: url)
        try opened.seekToEnd()
        handle = opened
        return opened
    }

    private func rotateIfNeeded() throws {
        guard let current = handle, try current.offset() >= rotationSize else { return }
        try current.close()
        handle = nil
        try? FileManager.default.removeItem(at: rotatedURL)
        try FileManager.default.moveItem(at: url, to: rotatedURL)
    }
}
