import XCTest

/// The celebration's shared motion rules: the beats' order, the clear zone,
/// the confetti's physics and emitters, and the fireworks show.
final class CelebrationMotionTests: XCTestCase {
    private let screen = CGSize(width: 402, height: 874)

    func testBeatsArriveInOrder() {
        for style in CelebrationStyle.allCases {
            let impact = CelebrationBeats.impact(style)
            let words = CelebrationBeats.words(afterImpact: impact)
            XCTAssertGreaterThan(impact, CelebrationBeats.heroStarts, "\(style)")
            XCTAssertGreaterThan(words, impact, "\(style)")
            XCTAssertGreaterThan(CelebrationBeats.footer(afterWords: words), words, "\(style)")
        }
        // The trophy falls further than the rest pop.
        XCTAssertGreaterThan(CelebrationBeats.travel(.trophy), CelebrationBeats.travel(.confetti))
        XCTAssertEqual(CelebrationBeats.heartbeats.filter(\.heavy).count, 2)
    }

    func testTheClearZoneFadesWhatCrossesTheWords() {
        let words = CGRect(x: 40, y: 300, width: 320, height: 120)
        XCTAssertEqual(ClearZone.fade(at: CGPoint(x: 200, y: 360), zone: words), ClearZone.floor)
        XCTAssertEqual(ClearZone.fade(at: CGPoint(x: 200, y: 300 - ClearZone.ramp), zone: words), 1, accuracy: 1e-9)
        let near = ClearZone.fade(at: CGPoint(x: 200, y: 290), zone: words)
        XCTAssertGreaterThan(near, ClearZone.floor)
        XCTAssertLessThan(near, 1)
        // No zone yet (the words not laid out): nothing fades.
        XCTAssertEqual(ClearZone.fade(at: CGPoint(x: 200, y: 360), zone: .zero), 1)
    }

    /// The air slows a piece to a float: it falls no faster than terminal velocity.
    func testConfettiSettlesToTerminalVelocity() {
        let launch = CGVector(dx: 300, dy: -1200)
        let a = ConfettiPhysics.offset(velocity: launch, sway: 0, seed: 0, t: 5)
        let b = ConfettiPhysics.offset(velocity: launch, sway: 0, seed: 0, t: 5.1)
        let fall = Double(b.dy - a.dy) / 0.1
        XCTAssertEqual(fall, ConfettiPhysics.gravity / ConfettiPhysics.drag, accuracy: 2)
        // Sideways, the launch is spent.
        XCTAssertLessThan(abs(Double(b.dx - a.dx)), 1)
    }

    func testAPieceFadesOnlyWithinItsLife() {
        XCTAssertEqual(ConfettiPhysics.opacity(t: -0.1, life: 3), 0)
        XCTAssertEqual(ConfettiPhysics.opacity(t: 1, life: 3), 1)
        XCTAssertEqual(ConfettiPhysics.opacity(t: 3, life: 3), 0)
        XCTAssertGreaterThanOrEqual(ConfettiPhysics.flutter(flip: 1, seed: .pi / 2, t: 0), 0.12)
    }

    /// Most of a cannon volley leaves at once, and every piece is gone in budget.
    func testCannonsFireAVolleyThenTrickle() {
        var rng = SeededGenerator(seed: 1)
        let pieces = ConfettiPiece.cannons(in: screen, palette: 6, glyphs: 4, using: &rng)
        let volley = pieces.filter { $0.launch < ConfettiPiece.volley }.count
        XCTAssertGreaterThanOrEqual(Double(volley) / Double(pieces.count), 0.8)
        for piece in pieces {
            XCTAssertLessThanOrEqual(piece.launch + piece.life, CelebrationBeats.particleBudget + 1e-9)
        }
        // From the two bottom corners, aimed inward and up.
        for piece in pieces where piece.launch < ConfettiPiece.volley {
            XCTAssertGreaterThan(piece.origin.y, screen.height)
            XCTAssertLessThan(piece.velocity.dy, 0)
            XCTAssertEqual(piece.origin.x < 0, piece.velocity.dx > 0)
        }
    }

    func testBurstsAndRimsEndInBudget() {
        var rng = SeededGenerator(seed: 2)
        let card = CGRect(x: 31, y: 320, width: 340, height: 190)
        let pieces = ConfettiPiece.burst(from: CGPoint(x: 200, y: 400), in: screen, palette: 4, glyphs: 3, using: &rng)
            + ConfettiPiece.rim(of: card, in: screen, palette: 6, glyphs: 4, using: &rng)
        for piece in pieces {
            XCTAssertLessThanOrEqual(piece.launch + piece.life, CelebrationBeats.particleBudget)
        }
        XCTAssertTrue(pieces.contains { $0.glyph != nil })
        XCTAssertTrue(pieces.contains { $0.glyph == nil })
    }

    /// Bursts stay up top or out at the sides, finish in budget, and tick at most five times.
    func testTheFireworksShowStaysClearOfTheWords() {
        for seed in 0..<20 {
            var rng = SeededGenerator(seed: UInt64(seed))
            let show = FireworkShow.plan(palette: 6, using: &rng)
            XCTAssertEqual(show.bursts.count, 6)
            XCTAssertLessThanOrEqual(show.duration, CelebrationBeats.particleBudget)
            for burst in show.bursts {
                let up = burst.center.y <= 0.26
                let aside = burst.center.x <= 0.22 || burst.center.x >= 0.78
                XCTAssertTrue(up || aside, "burst at \(burst.center)")
                XCTAssertLessThanOrEqual(burst.center.y, 0.48)
            }
            XCTAssertEqual(show.hapticTimes.count, FireworkShow.maxHaptics)
            XCTAssertEqual(show.hapticTimes, show.hapticTimes.sorted())
        }
    }

    func testTheSeededGeneratorRepeats() {
        var a = SeededGenerator(seed: 7), b = SeededGenerator(seed: 7)
        XCTAssertEqual((0..<5).map { _ in a.next() }, (0..<5).map { _ in b.next() })
    }
}
