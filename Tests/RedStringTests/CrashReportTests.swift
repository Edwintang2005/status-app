import XCTest

/// MetricKit's diagnostics as Diagnostics shows them: read leniently from the
/// payload's JSON, kept newest first without repeats, and stored per device.
final class CrashReportTests: XCTestCase {
    private let appID = "com.edwintang.redstring"

    private func payload(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    private var crashAndHang: Data {
        payload([
            "timeStampEnd": "2026-11-05 09:41:00 +0000",
            "crashDiagnostics": [[
                "diagnosticMetaData": [
                    "appVersion": "1.6.3", "appBuildVersion": "42",
                    "exceptionType": 1, "signal": 11,
                    "terminationReason": "Namespace RUNNINGBOARD, Code 0xdead10cc",
                    "bundleIdentifier": "\(appID).NotificationService",
                ],
                "callStackTree": ["callStacks": [
                    ["threadAttributed": false, "callStackRootFrames": [["binaryName": "libsystem_kernel.dylib"]]],
                    ["threadAttributed": true,
                     "callStackRootFrames": [["binaryName": "RedString", "offsetIntoBinaryTextSegment": 1234]]],
                ]],
            ]],
            "hangDiagnostics": [[
                "diagnosticMetaData": ["appVersion": "1.6.3", "appBuildVersion": "42",
                                       "hangDuration": "3 sec", "bundleIdentifier": appID],
            ]],
        ])
    }

    func testACrashAndAHangAreReadFromThePayload() throws {
        let reports = CrashReport.parse(crashAndHang, receivedAt: .distantPast, appBundleID: appID)
        XCTAssertEqual(reports.map(\.kind), [.crash, .hang])
        let crash = try XCTUnwrap(reports.first)
        XCTAssertEqual(crash.at, Date(timeIntervalSince1970: 1_793_871_660), "the payload's own end, not receipt")
        XCTAssertEqual(crash.process, "NotificationService", "an extension is named")
        XCTAssertEqual(crash.build, "42")
        let detail = try XCTUnwrap(crash.detail)
        XCTAssertTrue(detail.contains("EXC_BAD_ACCESS") && detail.contains("SIGSEGV"))
        XCTAssertTrue(detail.contains("0xdead10cc"))
        XCTAssertTrue(detail.contains("RedString +1234"), "the blamed thread's frame")
        XCTAssertNil(reports[1].process, "the app itself isn't named")
        XCTAssertEqual(reports[1].detail, "3 sec")
    }

    func testAnythingMalformedIsSkippedNotThrown() {
        let received = Date(timeIntervalSince1970: 1_000).wholeSeconds
        XCTAssertTrue(CrashReport.parse(Data("not json".utf8), receivedAt: received, appBundleID: appID).isEmpty)
        let bare = CrashReport.parse(payload(["crashDiagnostics": [[:]], "hangDiagnostics": "nonsense"]),
                                     receivedAt: received, appBundleID: appID)
        XCTAssertEqual(bare.count, 1)
        XCTAssertEqual(bare.first?.at, received, "no stamp: when it arrived")
        XCTAssertNil(bare.first?.detail)
    }

    func testMergingKeepsTheNewestOnceEachUpToTheLimit() {
        let old = (0..<5).map { CrashReport(kind: .hang, at: Date(timeIntervalSince1970: TimeInterval($0)), detail: "\($0) sec") }
        let again = [old[4], CrashReport(kind: .crash, at: Date(timeIntervalSince1970: 10))]
        let merged = CrashReport.merged(again, into: old, limit: 4)
        XCTAssertEqual(merged.map(\.at.timeIntervalSince1970), [10, 4, 3, 2], "newest first, a repeat once, capped")
    }

    func testReportsRoundTripTheStore() {
        let store = SharedStore(defaults: temporaryDefaults())
        XCTAssertTrue(store.crashReports.isEmpty)
        let reports = CrashReport.parse(crashAndHang, receivedAt: .distantPast, appBundleID: appID)
        store.crashReports = reports
        XCTAssertEqual(store.crashReports, reports)
        XCTAssertTrue(reports[0].summary.contains("1.6.3 (42)"))
    }
}
