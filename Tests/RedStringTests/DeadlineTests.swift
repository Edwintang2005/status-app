import XCTest

/// `withDeadline` bounds the widget's CloudKit calls; WidgetKit kills the
/// process past its budget, so the caller must get control back on time even
/// when the body never notices it was cancelled.
final class DeadlineTests: XCTestCase {
    func testReturnsBodyResultWhenItFinishesFirst() async throws {
        let value = try await withDeadline(1) { 42 }
        XCTAssertEqual(value, 42)
    }

    func testThrowsBodyError() async {
        struct Boom: Error {}
        do {
            _ = try await withDeadline(1) { () -> Int in throw Boom() }
            XCTFail("expected the body's error")
        } catch {
            XCTAssertTrue(error is Boom)
        }
    }

    func testGivesUpOnAnUncooperativeBody() async {
        let started = Date()
        do {
            // Sleeps without ever checking for cancellation — like an auto-imported CloudKit call.
            _ = try await withDeadline(0.2) { () -> Int in
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 5) { continuation.resume() }
                }
                return 1
            }
            XCTFail("expected a cancellation error")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "the deadline must not wait for the body")
    }

    func testCancelsTheBodyOnTheDeadline() async {
        let cancelled = expectation(description: "body observed cancellation")
        _ = try? await withDeadline(0.1) { () -> Int in
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
            cancelled.fulfill()
            return 0
        }
        await fulfillment(of: [cancelled], timeout: 2)
    }
}
