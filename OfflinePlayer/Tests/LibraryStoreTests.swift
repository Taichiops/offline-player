import AVFoundation
import XCTest
@testable import OfflinePlayer

@MainActor
final class LibraryStoreTests: XCTestCase {
    func testDuplicateFileNameGetsNumberSuffix() async throws {
        let sandbox = try makeSandbox()
        let song = try makeSilentAudio(named: "song.wav", in: sandbox.picked)
        let store = sandbox.makeStore()

        await store.importFiles([song])
        await store.importFiles([song])
        await store.importFiles([song])

        XCTAssertEqual(store.tracks.map(\.fileName), ["song.wav", "song (2).wav", "song (3).wav"])
        XCTAssertTrue(sandbox.documentExists("song (2).wav"))
        XCTAssertEqual(store.importFailures, [])
    }

    func testImportedTitleFallsBackToFileName() async throws {
        let sandbox = try makeSandbox()
        let song = try makeSilentAudio(named: "My Song.caf", in: sandbox.picked)
        let store = sandbox.makeStore()

        await store.importFiles([song])

        XCTAssertEqual(store.tracks.first?.title, "My Song")
        XCTAssertNil(store.tracks.first?.artist)
        XCTAssertEqual(store.tracks.first?.duration ?? 0, 0.1, accuracy: 0.01)
    }

    func testUnsupportedExtensionsAreIgnored() async throws {
        let sandbox = try makeSandbox()
        try Data("notes".utf8).write(to: sandbox.documents.appendingPathComponent("notes.txt"))
        try Data("not audio".utf8).write(to: sandbox.documents.appendingPathComponent("song.ogg"))
        _ = try makeSilentAudio(named: "tone.caf", in: sandbox.documents)
        let store = sandbox.makeStore()

        await store.rescan()
        XCTAssertEqual(store.tracks.map(\.fileName), ["tone.caf"])

        let ogg = sandbox.picked.appendingPathComponent("other.ogg")
        try Data("not audio".utf8).write(to: ogg)
        await store.importFiles([ogg])

        XCTAssertEqual(store.tracks.map(\.fileName), ["tone.caf"])
        XCTAssertEqual(store.importFailures.count, 1)
        XCTAssertFalse(sandbox.documentExists("other.ogg"))
    }

    func testLibraryOrderIsSavedAndLoaded() async throws {
        let sandbox = try makeSandbox()
        let files = try ["a.caf", "b.caf", "c.caf"].map { try makeSilentAudio(named: $0, in: sandbox.picked) }
        let store = sandbox.makeStore()
        await store.importFiles(files)

        store.move(from: IndexSet(integer: 2), to: 0)
        XCTAssertEqual(store.tracks.map(\.fileName), ["c.caf", "a.caf", "b.caf"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: sandbox.support.appendingPathComponent("library.json").path))

        let reloaded = sandbox.makeStore()
        XCTAssertEqual(reloaded.tracks, store.tracks)
    }

    func testRescanRemovesMissingFiles() async throws {
        let sandbox = try makeSandbox()
        let files = try ["a.caf", "b.caf"].map { try makeSilentAudio(named: $0, in: sandbox.picked) }
        let store = sandbox.makeStore()
        await store.importFiles(files)

        try FileManager.default.removeItem(at: sandbox.documents.appendingPathComponent("a.caf"))
        await store.rescan()

        XCTAssertEqual(store.tracks.map(\.fileName), ["b.caf"])
        XCTAssertEqual(sandbox.makeStore().tracks.map(\.fileName), ["b.caf"])
    }

    func testRescanPicksUpFilesAddedThroughFiles() async throws {
        let sandbox = try makeSandbox()
        let album = sandbox.documents.appendingPathComponent("Album")
        try FileManager.default.createDirectory(at: album, withIntermediateDirectories: true)
        _ = try makeSilentAudio(named: "02 Second.caf", in: album)
        _ = try makeSilentAudio(named: "01 First.caf", in: album)
        let store = sandbox.makeStore()

        await store.rescan()

        XCTAssertEqual(store.tracks.map(\.fileName), ["Album/01 First.caf", "Album/02 Second.caf"])
        XCTAssertEqual(store.tracks.map(\.title), ["01 First", "02 Second"])
    }

    func testDeleteRemovesFileAndEntry() async throws {
        let sandbox = try makeSandbox()
        let files = try ["a.caf", "b.caf"].map { try makeSilentAudio(named: $0, in: sandbox.picked) }
        let store = sandbox.makeStore()
        await store.importFiles(files)

        store.delete(at: IndexSet(integer: 0))

        XCTAssertEqual(store.tracks.map(\.fileName), ["b.caf"])
        XCTAssertFalse(sandbox.documentExists("a.caf"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: files[0].path), "the picked original must stay where it was")
    }

    // MARK: - Helpers

    /// Throwaway Documents, Application Support, and "picked in Files" folders for one test.
    private struct Sandbox {
        let documents: URL
        let support: URL
        let picked: URL

        @MainActor func makeStore() -> LibraryStore {
            LibraryStore(documentsDirectory: documents, supportDirectory: support)
        }

        func documentExists(_ name: String) -> Bool {
            FileManager.default.fileExists(atPath: documents.appendingPathComponent(name).path)
        }
    }

    private func makeSandbox() throws -> Sandbox {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryStoreTests-\(UUID().uuidString)", isDirectory: true)
        let sandbox = Sandbox(
            documents: root.appendingPathComponent("Documents", isDirectory: true),
            support: root.appendingPathComponent("Application Support", isDirectory: true),
            picked: root.appendingPathComponent("Picked", isDirectory: true)
        )
        for directory in [sandbox.documents, sandbox.picked] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return sandbox
    }

    /// Writes 0.1 s of 16-bit silence. The file type (.caf, .wav, …) follows the extension.
    private func makeSilentAudio(named name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4_410))
            buffer.frameLength = buffer.frameCapacity
            let samples = try XCTUnwrap(buffer.floatChannelData)
            samples[0].update(repeating: 0, count: Int(buffer.frameLength))
            try file.write(from: buffer)
        } // The file is closed when `file` goes out of scope.
        return url
    }
}
