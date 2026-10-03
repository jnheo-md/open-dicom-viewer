import Foundation
import Testing
@testable import OpenDicomViewer

private func withRecentHistoryDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
    let name = "OpenDicomViewerTests.RecentOpenHistory.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    try body(defaults)
}

@Test
func recentHistoryPersistsSelectionOrderAndBatch() throws {
    try withRecentHistoryDefaults { defaults in
        let history = RecentOpenHistory(defaults: defaults)
        let first = URL(fileURLWithPath: "/test/scan/image-20.dcm")
        let second = URL(fileURLWithPath: "/test/scan/image-01.dcm")
        history.record(urls: [first, second])

        let restored = RecentOpenHistory(defaults: defaults)
        let entry = try #require(restored.entries.first)
        #expect(restored.entries.count == 1)
        #expect(entry.urls == [first, second])
        #expect(entry.id == history.entries.first?.id)
        #expect(entry.displayName == "image-20.dcm and 1 more")
    }
}

@Test
func recentHistoryDeduplicatesPathsAndMovesBatchToFront() throws {
    try withRecentHistoryDefaults { defaults in
        let history = RecentOpenHistory(defaults: defaults)
        let first = URL(fileURLWithPath: "/test/scan/first.dcm")
        let alias = URL(fileURLWithPath: "/test/scan/../scan/first.dcm")
        let second = URL(fileURLWithPath: "/test/scan/second.dcm")
        let other = URL(fileURLWithPath: "/test/other")
        history.record(urls: [first, alias, second])
        history.record(urls: [other])
        history.record(urls: [second, alias, first])

        #expect(history.entries.count == 2)
        let entry = try #require(history.entries.first)
        #expect(entry.urls == [second, first])
        #expect(history.entries.last?.urls == [other])
        #expect(RecentOpenHistory(defaults: defaults).entries == history.entries)
    }
}

@Test
func recentHistoryDeduplicatesSymbolicLinks() throws {
    try withRecentHistoryDefaults { defaults in
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("image.dcm")
        let link = directory.appendingPathComponent("alias.dcm")
        try Data().write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let history = RecentOpenHistory(defaults: defaults)
        history.record(urls: [link, target])
        let entry = try #require(history.entries.first)
        #expect(entry.urls.count == 1)
        let resolvedURL = try #require(entry.urls.first)
        let resolvedValues = try resolvedURL.resourceValues(forKeys: [.fileResourceIdentifierKey])
        let targetValues = try target.resourceValues(forKeys: [.fileResourceIdentifierKey])
        let resolvedID = try #require(resolvedValues.fileResourceIdentifier)
        let targetID = try #require(targetValues.fileResourceIdentifier)
        #expect(resolvedID.isEqual(targetID))

        // Reopening the real path or bookmark must reuse the same MRU entry,
        // even when macOS spells /var differently after bookmark resolution.
        history.record(urls: [target])
        history.record(urls: entry.urls)
        #expect(history.entries.count == 1)
        let restored = RecentOpenHistory(defaults: defaults)
        restored.record(urls: [link, target])
        #expect(restored.entries.count == 1)
    }
}

@Test
func recentHistoryCapsAtTwentyAndClearsPersistence() {
    withRecentHistoryDefaults { defaults in
        let history = RecentOpenHistory(defaults: defaults)
        for index in 0..<25 {
            history.record(urls: [URL(fileURLWithPath: "/test/study-\(index)")])
        }
        #expect(history.entries.count == 20)
        #expect(history.entries.first?.displayName == "study-24")
        #expect(history.entries.last?.displayName == "study-5")
        #expect(RecentOpenHistory(defaults: defaults).entries.count == 20)

        history.clear()
        #expect(history.entries.isEmpty)
        #expect(RecentOpenHistory(defaults: defaults).entries.isEmpty)
    }
}

@Test
func recentHistoryIgnoresEmptyAndNonFileRequestsAndRecoversInvalidStorage() {
    withRecentHistoryDefaults { defaults in
        defaults.set(Data("invalid JSON".utf8), forKey: "recentOpenSelections.v1")
        let history = RecentOpenHistory(defaults: defaults)
        history.record(urls: [])
        history.record(urls: [URL(string: "https://example.com/image.dcm")!])
        #expect(history.entries.isEmpty)

        let url = URL(fileURLWithPath: "/test/recovery")
        history.record(urls: [url])
        #expect(RecentOpenHistory(defaults: defaults).entries.first?.urls == [url])
    }
}
