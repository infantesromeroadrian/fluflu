import Foundation
import Testing
@testable import FluFlu

@Suite("LogFile")
struct LogFileTests {
    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "FluFluTests-\(UUID().uuidString)")
    }

    @Test func appendWritesTimestampedLineWithLevelAndCategory() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = LogFile(directory: directory)

        file.append(level: "INFO", category: "audio", "capturing from Mic")

        let contents = try String(contentsOf: file.url, encoding: .utf8)
        #expect(contents.hasSuffix(" INFO [audio] capturing from Mic\n"))
        #expect(contents.contains("T"), "la línea empieza por una fecha ISO 8601")
    }

    @Test func rotatesOnceTheFileReachesTheLimit() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = LogFile(directory: directory, rotationSize: 120)

        file.append(level: "INFO", category: "a", String(repeating: "x", count: 100))
        file.append(level: "INFO", category: "a", "second")
        file.append(level: "INFO", category: "a", "third")

        let current = try String(contentsOf: file.url, encoding: .utf8)
        let rotated = try String(contentsOf: file.rotatedURL, encoding: .utf8)
        // La rotación ocurre antes de la primera escritura que encuentra el fichero lleno:
        // la línea larga queda en `.1` y las dos siguientes abren el fichero nuevo.
        #expect(rotated.contains("xxxxx"))
        #expect(!rotated.contains("second"))
        #expect(!current.contains("xxxxx"))
        #expect(current.contains("second"))
        #expect(current.contains("third"))
    }
}

@Suite("LaunchAtLogin")
@MainActor
struct LaunchAtLoginTests {
    @Test func withoutTheArgumentNothingHappens() {
        // El bundle de tests no vive en /Applications; sin argumento no debe ni consultar el sistema.
        LaunchAtLogin.applyCommandLineRequest(arguments: ["FluFlu"])
        #expect(!LaunchAtLogin.isInstalled)
    }

    @Test func requestOutsideApplicationsIsIgnored() {
        let before = LaunchAtLogin.isEnabled
        LaunchAtLogin.applyCommandLineRequest(arguments: ["FluFlu", LaunchAtLogin.enableArgument])
        #expect(LaunchAtLogin.isEnabled == before)
    }
}
