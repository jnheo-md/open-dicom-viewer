import Testing
@testable import OpenDicomViewer

@Test
func safeSubscriptReturnsElementInBounds() {
    let values = [10, 20, 30]
    #expect(values[safe: 1] == 20)
}

@Test
func safeSubscriptReturnsNilOutOfBounds() {
    let values = [10, 20, 30]
    #expect(values[safe: 3] == nil)
}
