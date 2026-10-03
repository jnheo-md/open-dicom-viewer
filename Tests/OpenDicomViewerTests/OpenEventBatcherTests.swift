import Foundation
import Testing
@testable import OpenDicomViewer

@MainActor
@Test func finderOpenEventsAreDeliveredAsOneOrderedBatch() async throws {
    var batches: [[URL]] = []
    let batcher = OpenEventBatcher { batches.append($0) }
    let first = URL(fileURLWithPath: "/tmp/study/first.dcm")
    let second = URL(fileURLWithPath: "/tmp/other/second.dcm")
    batcher.enqueue([first])
    batcher.enqueue([second, first])
    #expect(batches.isEmpty)
    try await Task.sleep(nanoseconds: 250_000_000)
    #expect(batches == [[first, second]])
    batcher.enqueue([second])
    batcher.flush()
    #expect(batches == [[first, second], [second]])
}

@MainActor
@Test func externalOpenIgnoresNonFileURLs() {
    var batches: [[URL]] = []
    let batcher = OpenEventBatcher { batches.append($0) }
    batcher.enqueue([URL(string: "https://example.com/image.dcm")!])
    batcher.flush()
    #expect(batches.isEmpty)
}
