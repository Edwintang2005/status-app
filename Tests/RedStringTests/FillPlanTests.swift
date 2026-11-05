import CoreGraphics
import XCTest

/// The doodle's bucket fill: what a tap fills, and that its passes cover it
/// without crossing a line into the area beyond.
final class FillPlanTests: XCTestCase {
    /// A grid from rows of text: `#` is a line, anything else empty.
    private func grid(_ rows: [String]) -> (coverage: [UInt8], width: Int, height: Int) {
        let width = rows[0].count
        return (rows.flatMap { $0.map { $0 == "#" ? UInt8(255) : 0 } }, width, rows.count)
    }

    /// The cells a pass's centre line runs through; every segment is straight across or down.
    private func cells(_ passes: [[CGPoint]], width: Int) -> Set<Int> {
        var covered = Set<Int>()
        for path in passes {
            let cells = path.map { (x: Int($0.x), y: Int($0.y)) }
            covered.insert(cells[0].y * width + cells[0].x)
            for (from, to) in zip(cells, cells.dropFirst()) {
                XCTAssertTrue(from.x == to.x || from.y == to.y, "a pass never cuts a corner")
                for y in min(from.y, to.y)...max(from.y, to.y) {
                    for x in min(from.x, to.x)...max(from.x, to.x) { covered.insert(y * width + x) }
                }
            }
        }
        return covered
    }

    private let ring = [
        "..........",
        ".######...",
        ".#....#...",
        ".#....#...",
        ".######...",
        "..........",
    ]

    func testATapInsideFillsInsideAndReachesOneCellUnderTheLine() throws {
        let (coverage, width, height) = grid(ring)
        let passes = try XCTUnwrap(FillPlan.passes(coverage: coverage, width: width, height: height,
                                                   tap: CGPoint(x: 3.5, y: 2.5)))
        let covered = cells(passes, width: width)
        let inside = (2...3).flatMap { y in (2...5).map { y * width + $0 } }
        XCTAssertTrue(Set(inside).isSubset(of: covered), "every enclosed cell")
        let underLine = (1...4).flatMap { y in (1...6).map { y * width + $0 } }
        XCTAssertTrue(covered.isSubset(of: Set(underLine)), "never past the line")
        XCTAssertEqual(passes.count, 1, "one convex area is one pass")
    }

    func testATapOutsideGoesAroundTheShapeWithoutCrossingIt() throws {
        let (coverage, width, height) = grid(ring)
        let passes = try XCTUnwrap(FillPlan.passes(coverage: coverage, width: width, height: height,
                                                   tap: .zero))
        let covered = cells(passes, width: width)
        XCTAssertTrue(covered.isDisjoint(with: [2 * width + 3, 3 * width + 4]), "the inside stays empty")
        let inside = Set((2...3).flatMap { y in (2...5).map { y * width + $0 } })
        let outside = coverage.indices.filter { coverage[$0] == 0 && !inside.contains($0) }
        XCTAssertTrue(Set(outside).isSubset(of: covered), "all the way round")
        XCTAssertGreaterThan(passes.count, 1, "split where the shape divides the rows")
    }

    func testATapOnALineOrOffTheGridFillsNothing() {
        let (coverage, width, height) = grid(ring)
        XCTAssertNil(FillPlan.passes(coverage: coverage, width: width, height: height, tap: CGPoint(x: 1.5, y: 1.5)))
        XCTAssertNil(FillPlan.passes(coverage: coverage, width: width, height: height, tap: CGPoint(x: 10.5, y: 0)))
        XCTAssertNil(FillPlan.passes(coverage: coverage, width: width, height: height, tap: CGPoint(x: -1, y: 2)))
    }

    /// A one-cell diagonal line holds: the fill spreads through edges, not corners.
    func testADiagonalLineHolds() throws {
        let (coverage, width, height) = grid([
            "#....",
            ".#...",
            "..#..",
            "...#.",
            "....#",
        ])
        let region = FillPlan.flood(coverage.map { $0 >= FillPlan.inkThreshold }, width: width, height: height,
                                    from: (4, 0))
        XCTAssertFalse(region[4 * width], "the far corner is out of reach")
        XCTAssertTrue(region[1 * width + 4])
    }

    /// A soft edge below the threshold is filled under, not left as a gap.
    func testASoftEdgeIsFilledUnder() throws {
        let width = 3, height = 1
        let passes = try XCTUnwrap(FillPlan.passes(coverage: [0, 100, 255], width: width, height: height,
                                                   tap: CGPoint(x: 0.5, y: 0.5)))
        XCTAssertEqual(cells(passes, width: width), [0, 1, 2], "the soft cell, then one under the line")
    }

    /// A pass steps down only through a cell both rows share, so a U-shaped area
    /// is covered without a pass running through the line between its arms.
    func testAUShapeIsCoveredWithoutJumpingItsGap() throws {
        let rows = [
            "#########",
            "#..###..#",
            "#..###..#",
            "#.......#",
            "#########",
        ]
        let (coverage, width, height) = grid(rows)
        let passes = try XCTUnwrap(FillPlan.passes(coverage: coverage, width: width, height: height,
                                                   tap: CGPoint(x: 1.5, y: 1.5)))
        let covered = cells(passes, width: width)
        for path in passes {
            for (from, to) in zip(path, path.dropFirst()) where from.y == to.y {
                // Row 2's divider cells border the bottom and are filled under, like any line's edge.
                guard Int(from.y) == 1 else { continue }
                XCTAssertFalse(min(from.x, to.x) < 4 && max(from.x, to.x) > 4, "no pass runs through the divider")
            }
        }
        let empty = coverage.indices.filter { coverage[$0] == 0 }
        XCTAssertTrue(Set(empty).isSubset(of: covered))
    }
}
