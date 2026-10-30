import AVFoundation
import Foundation
import Observation
import OSLog
import SwiftUI

/// Owns the music library: the audio files copied into Documents and their saved order.
@MainActor
@Observable
final class LibraryStore {
    static let supportedExtensions: Set<String> = ["mp3", "m4a", "aac", "wav", "aif", "aiff", "caf", "flac", "alac"]

    private(set) var tracks: [Track] = []
    /// One line per file that could not be imported. The UI shows these and clears the list.
    var importFailures: [String] = []
    var isImporting: Bool { importsInProgress > 0 }

    @ObservationIgnored let documentsDirectory: URL
    @ObservationIgnored private let libraryFileURL: URL
    @ObservationIgnored private let fileManager = FileManager.default
    @ObservationIgnored private let logger = Logger(subsystem: "OfflinePlayer", category: "Library")
    /// File names that an import is still copying, so a rescan running at the same time skips them.
    @ObservationIgnored private var reservedNames: Set<String> = []
    private var importsInProgress = 0

    init(documentsDirectory: URL = .documentsDirectory, supportDirectory: URL = .applicationSupportDirectory) {
        self.documentsDirectory = documentsDirectory
        self.libraryFileURL = supportDirectory.appendingPathComponent("library.json")
        load()
    }

    func fileURL(for track: Track) -> URL {
        documentsDirectory.appendingPathComponent(track.fileName)
    }

    static func isSupported(_ fileName: String) -> Bool {
        supportedExtensions.contains((fileName as NSString).pathExtension.lowercased())
    }

    // MARK: - Import

    /// Copies the picked files into Documents. Files that fail are skipped and listed in `importFailures`.
    func importFiles(_ urls: [URL]) async {
        importsInProgress += 1
        defer { importsInProgress -= 1 }

        var failures: [String] = []
        for source in urls {
            do {
                add(try await importFile(from: source))
            } catch {
                logger.error("Import failed for \(source.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                failures.append("\(source.lastPathComponent): \(error.localizedDescription)")
            }
        }
        save()
        importFailures += failures
    }

    private func importFile(from source: URL) async throws -> Track {
        guard Self.isSupported(source.lastPathComponent) else { throw ImportError.unsupportedFormat }

        let fileName = uniqueFileName(for: source.lastPathComponent)
        let destination = documentsDirectory.appendingPathComponent(fileName)
        reservedNames.insert(fileName)
        defer { reservedNames.remove(fileName) }

        // Copying can take a while (large files, iCloud downloads), so keep it off the main thread.
        try await Task.detached(priority: .userInitiated) {
            try Self.copy(from: source, to: destination)
        }.value

        do {
            let info = try await Self.readInfo(of: destination)
            guard info.isPlayable else { throw ImportError.notPlayable }
            return Self.makeTrack(fileName: fileName, info: info)
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }
    }

    /// "song.mp3" → "song (2).mp3" → "song (3).mp3" … until the name is free.
    func uniqueFileName(for original: String) -> String {
        let base = (original as NSString).deletingPathExtension
        let ext = (original as NSString).pathExtension
        var candidate = original
        var number = 2
        while reservedNames.contains(candidate)
            || fileManager.fileExists(atPath: documentsDirectory.appendingPathComponent(candidate).path) {
            candidate = ext.isEmpty ? "\(base) (\(number))" : "\(base) (\(number)).\(ext)"
            number += 1
        }
        return candidate
    }

    nonisolated private static func copy(from source: URL, to destination: URL) throws {
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }

        // The coordinator makes iCloud Drive download the file first if it is not on the device yet.
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) { readableURL in
            do {
                try FileManager.default.copyItem(at: readableURL, to: destination)
            } catch {
                copyError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let copyError { throw copyError }
    }

    // MARK: - Scan

    /// Syncs the list with Documents: adds files dropped in through Files or Finder
    /// and drops entries whose files are gone.
    func rescan() async {
        let onDisk = audioFilesOnDisk()
        let onDiskSet = Set(onDisk)

        var changed = false
        let kept = tracks.filter { onDiskSet.contains($0.fileName) }
        if kept.count != tracks.count {
            tracks = kept
            changed = true
        }

        let known = Set(tracks.map(\.fileName)).union(reservedNames)
        let newNames = onDisk
            .filter { !known.contains($0) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        for name in newNames {
            let info = try? await Self.readInfo(of: documentsDirectory.appendingPathComponent(name))
            add(Self.makeTrack(fileName: name, info: info))
            changed = true
        }

        if changed { save() }
    }

    /// Supported audio files under Documents, as paths relative to Documents. Hidden items are skipped.
    private func audioFilesOnDisk() -> [String] {
        guard let enumerator = fileManager.enumerator(atPath: documentsDirectory.path) else { return [] }
        var result: [String] = []
        while let path = enumerator.nextObject() as? String {
            let name = (path as NSString).lastPathComponent
            if name.hasPrefix(".") {
                enumerator.skipDescendants()
                continue
            }
            let isFile = enumerator.fileAttributes?[.type] as? FileAttributeType == .typeRegular
            if isFile && Self.isSupported(name) {
                result.append(path)
            }
        }
        return result
    }

    // MARK: - Edit

    func delete(at offsets: IndexSet) {
        for index in offsets {
            try? fileManager.removeItem(at: fileURL(for: tracks[index]))
        }
        tracks.remove(atOffsets: offsets)
        save()
    }

    func move(from source: IndexSet, to destination: Int) {
        tracks.move(fromOffsets: source, toOffset: destination)
        save()
    }

    /// Appends a track unless one with the same file is already in the list.
    private func add(_ track: Track) {
        guard !tracks.contains(where: { $0.fileName == track.fileName }) else { return }
        tracks.append(track)
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: libraryFileURL) else { return }
        do {
            let saved = try JSONDecoder().decode([Track].self, from: data)
            tracks = saved.filter { fileManager.fileExists(atPath: fileURL(for: $0).path) }
        } catch {
            logger.error("Could not read library.json: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func save() {
        do {
            try fileManager.createDirectory(at: libraryFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(tracks).write(to: libraryFileURL, options: .atomic)
        } catch {
            logger.error("Could not save library.json: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Metadata

    private struct TrackInfo: Sendable {
        var title: String?
        var artist: String?
        var duration: Double?
        var isPlayable: Bool
    }

    nonisolated private static func readInfo(of url: URL) async throws -> TrackInfo {
        let asset = AVURLAsset(url: url)
        let (isPlayable, isProtected, duration, metadata) =
            try await asset.load(.isPlayable, .hasProtectedContent, .duration, .commonMetadata)
        let seconds = duration.seconds
        return TrackInfo(
            title: await string(for: .commonIdentifierTitle, in: metadata),
            artist: await string(for: .commonIdentifierArtist, in: metadata),
            duration: seconds.isFinite && seconds > 0 ? seconds : nil,
            isPlayable: isPlayable && !isProtected
        )
    }

    nonisolated private static func string(for identifier: AVMetadataIdentifier, in metadata: [AVMetadataItem]) async -> String? {
        guard let item = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: identifier).first,
              let value = try? await item.load(.stringValue) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    nonisolated private static func makeTrack(fileName: String, info: TrackInfo?) -> Track {
        let fallbackTitle = ((fileName as NSString).lastPathComponent as NSString).deletingPathExtension
        return Track(
            id: UUID(),
            fileName: fileName,
            title: info?.title ?? fallbackTitle,
            artist: info?.artist,
            duration: info?.duration
        )
    }
}

enum ImportError: LocalizedError {
    case unsupportedFormat
    case notPlayable

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            "This file type isn't supported."
        case .notPlayable:
            "This file can't be played. It may be copy-protected or damaged."
        }
    }
}
