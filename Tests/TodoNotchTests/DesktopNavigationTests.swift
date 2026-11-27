import XCTest
import TodoNotchCore

final class DesktopNavigationTests: XCTestCase {
    private typealias Rules = DesktopNavigationRules

    func testNativeIDValidationAndCodexDeepLink() throws {
        let id = "demo.task-02_A"
        XCTAssertTrue(Rules.isValidNativeId(id))
        let url = try XCTUnwrap(Rules.codexURL(nativeId: id))
        XCTAssertEqual(url.absoluteString, "codex://automations/demo.task-02_A?automationSource=local")

        for malformed in ["", ".", "..", "demo/", "demo?x=1", "demo#x", "demo%2Fother", " demo", "demo\n", "任务"] {
            XCTAssertFalse(Rules.isValidNativeId(malformed), malformed.debugDescription)
            XCTAssertNil(Rules.codexURL(nativeId: malformed))
        }
    }

    func testEnglishAndChineseMarkerWithSplitStaticText() {
        let sentinel = "tn-demo.02_"
        let markers = [
            "No automations match “\(sentinel)”.",
            ["No ", "automations", " match “", sentinel, "”."].joined(separator: " "),
            "没有与“\(sentinel)”匹配的定时任务。",
            ["未找到", "与“", sentinel, "”", "匹配的", "自动化任务"].joined(separator: " "),
            ["沒有", "符合", "「", sentinel, "」的排程工作"].joined(separator: " "),
            "找不到匹配 \(sentinel) 的结果"
        ]
        for marker in markers {
            XCTAssertTrue(Rules.isEmptyResults(marker, query: sentinel), marker)
            XCTAssertFalse(Rules.isEmptyResults(marker, query: "tn-demo"), marker)
            XCTAssertFalse(Rules.isEmptyResults(marker, query: "tn-other"), marker)
        }
        XCTAssertFalse(Rules.isEmptyResults("Search \(sentinel)", query: sentinel))
        XCTAssertFalse(Rules.isEmptyResults("自动化：\(sentinel)", query: sentinel))
        XCTAssertTrue(Rules.isEmptyResults("No automations match “demo.”.", query: "demo."))
    }

    func testResultRowFingerprintExcludesControls() {
        XCTAssertEqual(Rules.rowKind(name: "Renamed task", toggleLabels: ["Pause Renamed task"]), .local)
        XCTAssertEqual(Rules.rowKind(name: "新名称", toggleLabels: ["恢复新名称"]), .local)
        XCTAssertEqual(Rules.rowKind(name: "Cloud task", toggleLabels: ["Enable Cloud task"]), .cloud)
        XCTAssertNil(Rules.rowKind(name: "New", toggleLabels: []))
        XCTAssertNil(Rules.rowKind(name: "Automations", toggleLabels: ["Run now", "Pause another row"]))
        XCTAssertNil(Rules.rowKind(name: "", toggleLabels: ["Pause "]))
        XCTAssertEqual(Rules.exposedRowID("sidecar-row-demo.task"), "demo.task")
        XCTAssertEqual(Rules.exposedRowID("demo.task"), "demo.task")
        XCTAssertNil(Rules.exposedRowID("sidecar-row"))
        XCTAssertEqual(Rules.exposedRowID("sidecar-row-sidecar-row"), "sidecar-row")
    }

    func testStableUniqueRowsAllowRenameButRejectExposedWrongID() {
        let known = Rules.Row(name: "Renamed task", nativeId: "demo")
        let noID = Rules.Row(name: "Renamed task")
        let matchingOldNameWrongID = Rules.Row(name: "Cached task", nativeId: "demo-other")
        XCTAssertEqual(decide([known]), .press(0))
        XCTAssertEqual(decide([noID]), .press(0))
        XCTAssertEqual(decide([known], expectedName: "Old name"), .press(0))
        XCTAssertEqual(decide([matchingOldNameWrongID]), .notFound)
        XCTAssertEqual(decide([Rules.Row(name: "Cloud", isLocal: false)]), .notFound)
        XCTAssertEqual(decide([known], barrier: false), .wait)
        XCTAssertEqual(decide([known], exact: false), .wait)
        XCTAssertEqual(decide([known], stable: false), .wait)
        XCTAssertEqual(decide([known], empty: true), .wait)
    }

    func testMultipleCandidatesNeverPressAndEmptyListNeedsMarker() {
        let first = Rules.Row(name: "Same")
        let second = Rules.Row(name: "Same")
        XCTAssertEqual(decide([first, second], expectedName: "Same"), .ambiguous)
        XCTAssertEqual(decide([first, Rules.Row(name: "Another")]), .ambiguous)
        XCTAssertEqual(decide([first, Rules.Row(name: "Another")], expectedName: "Missing"), .ambiguous)
        XCTAssertEqual(decide([first, second], stable: false), .wait)
        XCTAssertEqual(decide([]), .wait)
        XCTAssertEqual(decide([], empty: true), .notFound)
    }

    func testPrefixOverlappingLocalRowsDisambiguateByDisplayName() {
        let morning = Rules.Row(name: "X 每日 AI 垂直直发（早午班 09:30/11:30）")
        let evening = Rules.Row(name: "X 每日 AI 垂直直发（晚班 17:00）")
        let target = "X 每日 AI 垂直直发（早午班 09:30/11:30）"
        XCTAssertEqual(decide([morning, evening], expectedName: target), .press(0))
        XCTAssertEqual(decide([evening, morning], expectedName: target), .press(1))
        XCTAssertEqual(decide([morning, morning], expectedName: target), .ambiguous)
    }

    func testFilteredListAndFinalPathMustBeExact() throws {
        func url(_ path: String) throws -> URL {
            try XCTUnwrap(URL(string: "http://127.0.0.1:1234" + path))
        }

        XCTAssertTrue(Rules.isFilteredList(try url("/sidecars?q=demo"), query: "demo"))
        for list in ["/sidecars", "/sidecars-old?q=demo", "/sidecars?q=demo&q=old", "/sidecars?q=tn-demo", "/sidecars/demo?q=demo"] {
            XCTAssertFalse(Rules.isFilteredList(try url(list), query: "demo"), list)
        }
        XCTAssertTrue(Rules.detailMatches(try url("/sidecars/demo?q=demo"), nativeId: "demo"))
        for detail in ["/sidecars/demo-other?q=demo", "/sidecars?q=demo", "/sidecars/demo/", "/sidecars/%64emo", "/sidecars/triggers/demo"] {
            XCTAssertFalse(Rules.detailMatches(try url(detail), nativeId: "demo"), detail)
        }
    }

    func testEveryOutcomeHasBilingualCopyAndPresentation() {
        let expected: [Rules.Outcome: Rules.Presentation] = [
            .opened: .closePanel, .accepted: .closePanel, .cancelled: .none,
            .needsAccessibility: .accessibilityToast, .ambiguousMatches: .warningToast,
            .appNotInstalled: .errorToast, .launchFailed: .errorToast, .deepLinkRejected: .errorToast,
            .invalidTaskId: .errorToast, .unsupportedSource: .errorToast, .notFound: .errorToast,
            .timedOut: .errorToast, .wrongTask: .errorToast
        ]
        for outcome in Rules.Outcome.allCases {
            XCTAssertEqual(outcome.presentation, expected[outcome], outcome.rawValue)
            let chinese = L10n.taskNavigationMessage(outcome, source: .codex, lang: .zhHans)
            let english = L10n.taskNavigationMessage(outcome, source: .codex, lang: .en)
            switch outcome.presentation {
            case .closePanel, .none:
                XCTAssertNil(chinese)
                XCTAssertNil(english)
            case .accessibilityToast, .warningToast, .errorToast:
                XCTAssertFalse(chinese?.isEmpty ?? true)
                XCTAssertFalse(english?.isEmpty ?? true)
                XCTAssertNotEqual(chinese, english)
            }
        }
        XCTAssertTrue(L10n.taskNavigationMessage(.appNotInstalled, source: .codex, lang: .en)?.contains("Codex") == true)
        XCTAssertTrue(L10n.taskNavigationMessage(.launchFailed, source: .antigravity, lang: .zhHans)?.contains("Antigravity") == true)
    }

    private func decide(
        _ rows: [Rules.Row], expectedName: String? = nil,
        barrier: Bool = true, exact: Bool = true, stable: Bool = true, empty: Bool = false
    ) -> Rules.RowDecision {
        Rules.decideRows(rows, nativeId: "demo", expectedName: expectedName, sawEmptyBarrier: barrier,
                         isExactFilter: exact, isStable: stable, isEmptyResult: empty)
    }
}
