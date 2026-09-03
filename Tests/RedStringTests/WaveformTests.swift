import XCTest

final class WaveformTests: XCTestCase {
    func testCondenseKeepsPeaks() {
        var samples = Array(repeating: 0.1, count: 96)
        samples[10] = 0.9
        let condensed = Waveform.condense(samples, into: 48)
        XCTAssertEqual(condensed.count, 48)
        XCTAssertEqual(condensed[5], 0.9, "a syllable must not be averaged away")
        XCTAssertEqual(condensed.filter { $0 == 0.9 }.count, 1)
    }

    func testCondenseHandlesUnevenBuckets() {
        let samples = (0..<100).map { Double($0) / 100 }
        let condensed = Waveform.condense(samples, into: 48)
        XCTAssertEqual(condensed.count, 48)
        XCTAssertEqual(condensed.last, 0.99, "the final bucket must reach the last sample")
        XCTAssertEqual(condensed, condensed.sorted(), "monotonic input stays monotonic")
    }

    func testCondenseReturnsShortInputUnchanged() {
        let samples = [0.2, 0.4, 0.6]
        XCTAssertEqual(Waveform.condense(samples, into: 48), samples)
        XCTAssertEqual(Waveform.condense(samples, into: 0), [])
    }

    func testFlatIsEvenAndNeverEmpty() {
        XCTAssertEqual(Waveform.flat(count: 4), [0.3, 0.3, 0.3, 0.3])
        XCTAssertEqual(Waveform.flat(count: 0).count, 1)
    }
}
