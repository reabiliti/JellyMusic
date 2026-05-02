import XCTest
@testable import JellyMusic

final class PlaybackQueuePolicyTests: XCTestCase {
    func testNextStopsAtEndWhenRepeatIsOff() {
        XCTAssertNil(PlaybackQueuePolicy.nextIndex(
            queueCount: 3,
            currentIndex: 2,
            repeatMode: .off,
            shuffle: false,
            automatic: true
        ))
    }

    func testRepeatAllWrapsToBeginning() {
        XCTAssertEqual(PlaybackQueuePolicy.nextIndex(
            queueCount: 3,
            currentIndex: 2,
            repeatMode: .all,
            shuffle: false,
            automatic: true
        ), 0)
    }

    func testRepeatOneKeepsCurrentIndexForAutomaticAdvance() {
        XCTAssertEqual(PlaybackQueuePolicy.nextIndex(
            queueCount: 3,
            currentIndex: 1,
            repeatMode: .one,
            shuffle: false,
            automatic: true
        ), 1)
    }

    func testPreviousReturnsCurrentIndexAtBeginning() {
        XCTAssertEqual(PlaybackQueuePolicy.previousIndex(queueCount: 3, currentIndex: 0), 0)
    }
}
