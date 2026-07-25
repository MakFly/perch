import Foundation
import Testing

@testable import PerchKit

/// The username is the giveaway, and it is in every path Perch handles.
@Test func homeDirectoriesAreShortened() {
    #expect(
        DiagnosticReport.scrub("/Users/kevin/lab/thing", home: "/Users/kevin")
            == "~/lab/thing")
    #expect(
        DiagnosticReport.scrub("/opt/other", home: "/Users/kevin") == "/opt/other")
    // An empty home must not turn every path into nonsense.
    #expect(DiagnosticReport.scrub("/Users/kevin/x", home: "") == "/Users/kevin/x")
}

/// A project name is a client name often enough that it should not travel — but two lines
/// about the same project have to stay recognisably about the same project.
@Test func projectNamesAreStablyAnonymised() {
    let once = DiagnosticReport.anonymise("secret-client-project")
    let again = DiagnosticReport.anonymise("secret-client-project")

    #expect(once == again)
    #expect(once != DiagnosticReport.anonymise("another-project"))
    #expect(!once.contains("secret"))
    #expect(once.hasPrefix("project-"))
}

@Test func theReportReadsAsColumns() {
    var report = DiagnosticReport()
    report.section("System")
    report.field("macOS", "26.5")

    #expect(report.text.contains("## System"))
    #expect(report.text.contains("macOS                  26.5"))
}
