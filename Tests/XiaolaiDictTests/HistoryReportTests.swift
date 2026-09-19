import Testing

@testable import XiaolaiDict

struct HistoryReportArgumentTests {
    @Test func theReportIsACommand() {
        #expect(LaunchArguments.parse(["--history-report"]) == .success(.historyReport))
    }

    @Test func itTakesNoArguments() {
        #expect(throws: (any Error).self) {
            try LaunchArguments.parse(["--history-report", "extra"]).get()
        }
    }

    @Test func itIsListedInTheUsage() {
        #expect(LaunchArguments.usage.contains("--history-report"))
    }
}
