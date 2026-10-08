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

    @MainActor func testScrubFractionFollowsCentredCappedBars() {
        // Home's row: 48 bars at 3 pt + 2 pt gaps span 238 pt, centred in 300 pt.
        let bars = WaveformBars(levels: Array(repeating: 0.5, count: 48), spacing: 2, maxBarWidth: 3)
        XCTAssertEqual(bars.fraction(atX: 31, in: 300), 0, accuracy: 0.001, "first drawn bar, not 10%")
        XCTAssertEqual(bars.fraction(atX: 150, in: 300), 0.5, accuracy: 0.001)
        XCTAssertEqual(bars.fraction(atX: 269, in: 300), 1, accuracy: 0.001)
        XCTAssertEqual(bars.fraction(atX: 5, in: 300), 0, "the empty margin clamps")
        XCTAssertEqual(bars.fraction(atX: 295, in: 300), 1)
    }

    @MainActor func testScrubFractionIsPlainRatioWhenBarsFillTheWidth() {
        // The gallery's card: bars never reach `maxBarWidth`, so nothing changes there.
        let bars = WaveformBars(levels: Array(repeating: 0.5, count: 48), spacing: 3, maxBarWidth: 7)
        XCTAssertEqual(bars.fraction(atX: 80, in: 320), 0.25, accuracy: 0.001)
    }
}
