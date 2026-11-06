import CoreGraphics

/// The doodle's bucket fill, on a grid of one cell per point: the empty cells a
/// tap reaches, then back-and-forth passes covering them, which
/// `DrawingController` draws as strokes under the lines. Pure, so the tests reach it.
enum FillPlan {
    /// Coverage at or above this is a line; a softer edge is filled under.
    static let inkThreshold: UInt8 = 128
    /// Stroke size that leaves no gap between 1-pt rows: PencilKit draws it
    /// about 2 pt wide, so a pass reaches half a point past its cells.
    static let strokeSize: CGFloat = 3
    /// Lines are thickened by this many cells before the flood, so a gap up to
    /// about twice it — a line stopping just short of another — still holds.
    static let gapRadius = 3

    /// Stroke paths in points, or `nil` when the tap is on a line or off the grid.
    /// - Parameter coverage: the lines' alpha, row by row, `width` × `height`.
    static func passes(coverage: [UInt8], width: Int, height: Int, tap: CGPoint) -> [[CGPoint]]? {
        guard width > 0, height > 0, coverage.count == width * height else { return nil }
        let x = Int(tap.x.rounded(.down)), y = Int(tap.y.rounded(.down))
        guard (0..<width).contains(x), (0..<height).contains(y) else { return nil }
        let ink = coverage.map { $0 >= inkThreshold }
        guard !ink[y * width + x] else { return nil }
        // A narrow space the thickened lines would close is filled with a
        // smaller radius, down to none: what the tap is on always fills.
        var region: [Bool] = []
        for radius in stride(from: gapRadius, through: 0, by: -1) {
            let closed = radius == 0 ? ink : thickened(ink, width: width, height: height, by: radius)
            guard !closed[y * width + x] else { continue }
            region = reaching(flood(closed, width: width, height: height, from: (x, y)),
                              within: ink, width: width, height: height, by: radius)
            break
        }
        return chains(runs(grown(region, width: width, height: height), width: width, height: height)).map(path)
    }

    /// Whether the tap is on a line: the bucket recolours that line instead.
    static func isLine(coverage: [UInt8], width: Int, height: Int, at tap: CGPoint) -> Bool {
        let x = Int(tap.x.rounded(.down)), y = Int(tap.y.rounded(.down))
        guard coverage.count == width * height, (0..<width).contains(x), (0..<height).contains(y) else { return false }
        return coverage[y * width + x] >= inkThreshold
    }

    /// The newest line within `slop` of `point`, each line given as points along
    /// its centre (about a point apart) with the stroke's half-width there.
    static func lineHit(_ lines: [[(point: CGPoint, radius: CGFloat)]], at point: CGPoint, slop: CGFloat) -> Int? {
        lines.indices.reversed().first { index in
            lines[index].contains { hypot($0.point.x - point.x, $0.point.y - point.y) <= $0.radius + slop }
        }
    }

    /// Every cell within `radius` of a line (a square, one row then one column at a time).
    static func thickened(_ ink: [Bool], width: Int, height: Int, by radius: Int) -> [Bool] {
        var across = [Bool](repeating: false, count: ink.count)
        for y in 0..<height {
            let row = y * width
            for x in 0..<width where ink[row + x] {
                for nx in max(0, x - radius)...min(width - 1, x + radius) { across[row + nx] = true }
            }
        }
        var out = across
        for x in 0..<width {
            for y in 0..<height where across[y * width + x] {
                for ny in max(0, y - radius)...min(height - 1, y + radius) { out[ny * width + x] = true }
            }
        }
        return out
    }

    /// Grows `region` back by `radius` cells through empty ones, undoing the
    /// thickening up to the real lines; a diagonal step never squeezes between two line cells.
    static func reaching(_ region: [Bool], within ink: [Bool], width: Int, height: Int, by radius: Int) -> [Bool] {
        var out = region
        var edge = region.indices.filter { region[$0] }
        for _ in 0..<radius {
            var next: [Int] = []
            for cell in edge {
                let x = cell % width, y = cell / width
                for ny in max(0, y - 1)...min(height - 1, y + 1) {
                    for nx in max(0, x - 1)...min(width - 1, x + 1) {
                        let target = ny * width + nx
                        guard !out[target], !ink[target] else { continue }
                        if nx != x, ny != y, ink[y * width + nx], ink[ny * width + x] { continue }
                        out[target] = true
                        next.append(target)
                    }
                }
            }
            edge = next
        }
        return out
    }

    /// The empty cells reachable from `seed` through edges, never corners: a
    /// diagonal line one cell thick still holds.
    static func flood(_ ink: [Bool], width: Int, height: Int, from seed: (x: Int, y: Int)) -> [Bool] {
        var filled = [Bool](repeating: false, count: ink.count)
        var stack = [seed]
        while let next = stack.popLast() {
            let (x, y) = next
            let row = y * width
            guard !filled[row + x], !ink[row + x] else { continue }
            var left = x, right = x
            while left > 0, !ink[row + left - 1], !filled[row + left - 1] { left -= 1 }
            while right < width - 1, !ink[row + right + 1], !filled[row + right + 1] { right += 1 }
            for cell in left...right { filled[row + cell] = true }
            for adjacent in [y - 1, y + 1] where (0..<height).contains(adjacent) {
                let nextRow = adjacent * width
                var cell = left
                while cell <= right {
                    if !ink[nextRow + cell], !filled[nextRow + cell] {
                        stack.append((cell, adjacent))
                        while cell <= right, !ink[nextRow + cell], !filled[nextRow + cell] { cell += 1 }
                    }
                    cell += 1
                }
            }
        }
        return filled
    }

    /// One cell further each way, under the lines, so no ground shows between fill and line.
    static func grown(_ region: [Bool], width: Int, height: Int) -> [Bool] {
        var out = region
        for y in 0..<height {
            for x in 0..<width where region[y * width + x] {
                for ny in max(0, y - 1)...min(height - 1, y + 1) {
                    for nx in max(0, x - 1)...min(width - 1, x + 1) { out[ny * width + nx] = true }
                }
            }
        }
        return out
    }

    struct Run: Equatable {
        let y: Int
        let start: Int
        let end: Int // inclusive

        func overlaps(_ other: Run) -> Bool { max(start, other.start) <= min(end, other.end) }
    }

    static func runs(_ region: [Bool], width: Int, height: Int) -> [[Run]] {
        (0..<height).map { y in
            var found: [Run] = []
            var x = 0
            while x < width {
                guard region[y * width + x] else { x += 1; continue }
                let start = x
                while x < width, region[y * width + x] { x += 1 }
                found.append(Run(y: y, start: start, end: x - 1))
            }
            return found
        }
    }

    /// Runs stacked one per row with no branch between them: a pass may step
    /// down only where nothing splits or joins, or it would cross a line.
    static func chains(_ rows: [[Run]]) -> [[Run]] {
        var chains: [[Run]] = []
        var open: [Int] = [] // chain index per run of the previous row
        var previous: [Run] = []
        for row in rows {
            var next: [Int] = []
            for run in row {
                let above = previous.indices.filter { previous[$0].overlaps(run) }
                if above.count == 1, row.filter({ $0.overlaps(previous[above[0]]) }).count == 1 {
                    chains[open[above[0]]].append(run)
                    next.append(open[above[0]])
                } else {
                    chains.append([run])
                    next.append(chains.count - 1)
                }
            }
            open = next
            previous = row
        }
        return chains
    }

    /// Along each run, then down through a cell both rows share. Every corner
    /// is tripled: PencilKit's spline otherwise cuts it and falls short of the ends.
    static func path(_ chain: [Run]) -> [CGPoint] {
        var cells: [(x: Int, y: Int)] = []
        var rightward = true
        for (index, run) in chain.enumerated() {
            if index > 0 {
                let last = chain[index - 1]
                let step = rightward ? min(last.end, run.end) : max(last.start, run.start)
                cells += [(step, last.y), (step, run.y)]
                rightward.toggle()
            }
            cells += rightward ? [(run.start, run.y), (run.end, run.y)] : [(run.end, run.y), (run.start, run.y)]
        }
        var points: [CGPoint] = []
        for cell in cells {
            let point = CGPoint(x: CGFloat(cell.x) + 0.5, y: CGFloat(cell.y) + 0.5)
            if points.last != point { points += [point, point, point] }
        }
        return points
    }
}
