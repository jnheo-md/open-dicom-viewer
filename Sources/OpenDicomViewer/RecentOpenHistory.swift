// RecentOpenHistory.swift
// OpenDicomViewer
//
// Persists recent selections as batches so reopening preserves the selected image.
// Licensed under the MIT License. See LICENSE for details.

import Combine
import Darwin
import Foundation

final class RecentOpenHistory: ObservableObject {
    struct Entry: Codable, Identifiable, Equatable {
        let id: UUID
        fileprivate let locations: [Location]

        /// Resolve moved files when possible, without prompting or mounting a volume.
        var urls: [URL] { locations.map(\.resolvedURL) }

        var displayName: String {
            guard let first = locations.first else { return "Open Selection" }
            let name = first.url.lastPathComponent
            return locations.count == 1 ? name : "\(name) and \(locations.count - 1) more"
        }

        var pathDescription: String {
            locations.map { $0.url.path }.joined(separator: "\n")
        }

        fileprivate var identity: Set<String> {
            Set(urls.map(RecentOpenHistory.canonicalPath))
        }
    }

    fileprivate struct Location: Codable, Equatable {
        let url: URL
        let bookmark: Data?

        init(url: URL) {
            self.url = url
            bookmark = try? url.bookmarkData(
                options: .minimalBookmark,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        }

        var resolvedURL: URL {
            guard let bookmark else { return url }
            var stale = false
            return (try? URL(
                resolvingBookmarkData: bookmark,
                options: [.withoutUI, .withoutMounting],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )) ?? url
        }
    }

    @Published private(set) var entries: [Entry]

    private let defaults: UserDefaults
    private let storageKey: String
    private static let maximumEntries = 20

    init(defaults: UserDefaults = .standard, storageKey: String = "recentOpenSelections.v1") {
        self.defaults = defaults
        self.storageKey = storageKey
        if let data = defaults.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = Array(saved.filter { !$0.locations.isEmpty }.prefix(Self.maximumEntries))
        } else {
            entries = []
        }
    }

    /// Keep the selection order, especially its first file, while removing aliases
    /// and duplicate requests for the same batch from the MRU list.
    func record(urls: [URL]) {
        var seen = Set<String>()
        let uniqueURLs = urls.filter(\.isFileURL).compactMap { url -> URL? in
            let path = Self.canonicalPath(for: url)
            return seen.insert(path).inserted ? URL(fileURLWithPath: path) : nil
        }
        guard !uniqueURLs.isEmpty else { return }

        let identity = Set(uniqueURLs.map(Self.canonicalPath))
        entries.removeAll { $0.identity == identity }
        entries.insert(Entry(id: UUID(), locations: uniqueURLs.map(Location.init)), at: 0)
        entries = Array(entries.prefix(Self.maximumEntries))
        persist()
    }

    func clear() {
        entries = []
        defaults.removeObject(forKey: storageKey)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: storageKey)
    }

    /// Bookmarks may return /private/var while Foundation normalizes an input to
    /// /var. POSIX canonical paths keep both spellings (and symlinks) identical.
    private static func canonicalPath(for url: URL) -> String {
        let standardized = url.standardizedFileURL
        guard let resolved = realpath(standardized.path, nil) else {
            return standardized.resolvingSymlinksInPath().path
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
