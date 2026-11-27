import SwiftUI
import XCTest

/// The red string hangs differently each entry, always inside its frame.
final class ThreadSlackTests: XCTestCase {
    private let frame = CGRect(x: 0, y: 0, width: 128, height: 14)

    func testEverySlackStaysInsideItsFrame() {
        for minute in 0..<3_000 {
            let slack = ThreadSlack(seed: Date(timeIntervalSince1970: 1_780_000_000 + Double(minute) * 3_917))
            let wave = slack.wave(in: frame)
            for step in 1...40 {
                let point = wave.trimmedPath(from: 0, to: Double(step) / 40).currentPoint!
                XCTAssertTrue(frame.insetBy(dx: -0.01, dy: -0.01).contains(point), "\(slack) leaves the frame at \(point)")
            }
        }
    }

    func testTheSameEntryHangsTheSameWayAndTheNextOneDoesnt() {
        let entry = Date(timeIntervalSince1970: 1_795_000_000)
        XCTAssertEqual(ThreadSlack(seed: entry), ThreadSlack(seed: entry))
        XCTAssertNotEqual(ThreadSlack(seed: entry), ThreadSlack(seed: entry.addingTimeInterval(86_400)))
    }

    func testTheKnotsStayLevelWithEachOther() {
        let slack = ThreadSlack(seed: Date(timeIntervalSince1970: 1_795_000_000))
        let wave = slack.wave(in: frame)
        let start = wave.trimmedPath(from: 0, to: 0.001).currentPoint!
        let end = wave.currentPoint!
        XCTAssertEqual(start.y, end.y, accuracy: 0.5)
        XCTAssertEqual(start.x, frame.minX, accuracy: 0.5)
        XCTAssertEqual(end.x, frame.maxX, accuracy: 0.5)
    }
}
