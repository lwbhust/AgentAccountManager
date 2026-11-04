import XCTest
import Core

final class CSVExportTests: XCTestCase {
    func testEscapeQuotesCommasAndNewlines() {
        XCTAssertEqual(CSVExport.escape("普通文本"), "普通文本")
        XCTAssertEqual(CSVExport.escape("a,b"), "\"a,b\"")
        XCTAssertEqual(CSVExport.escape("他说\"好\""), "\"他说\"\"好\"\"\"")
        XCTAssertEqual(CSVExport.escape("第一行\n第二行"), "\"第一行\n第二行\"")
    }

    func testTaskCSVContainsHeaderAndRow() throws {
        let task = TraeTask(
            id: "m1",
            accountId: UUID(),
            sessionId: "s1",
            title: "整理任务, 并导出",
            status: .completed,
            agentName: "SOLO Agent",
            modelName: "DeepSeek-V4.1-Flash",
            credits: 4.06,
            createdAt: Date(timeIntervalSince1970: 1792915776),
            updatedAt: Date(timeIntervalSince1970: 1792915776)
        )
        let csv = CSVExport.taskCSV([task])
        XCTAssertTrue(csv.hasPrefix("\u{FEFF}"), "带 BOM 便于 Excel 识别中文")
        XCTAssertTrue(csv.contains("时间,任务,状态,积分消耗,模型,Agent"))
        XCTAssertTrue(csv.contains("\"整理任务, 并导出\""), "包含逗号的字段必须加引号")
        XCTAssertTrue(csv.contains("4.06"))
        XCTAssertTrue(csv.contains("已完成"))
        XCTAssertFalse(csv.contains("138"), "导出不应包含手机号")
    }

    func testTaskCSVShowsUncollectedCreditsAsUnknown() {
        let task = TraeTask(
            id: "m2",
            accountId: UUID(),
            sessionId: "s1",
            title: "未结束任务",
            status: .inProgress,
            agentName: nil,
            modelName: nil,
            credits: nil,
            createdAt: Date(timeIntervalSince1970: 1792915776),
            updatedAt: Date(timeIntervalSince1970: 1792915776)
        )
        let csv = CSVExport.taskCSV([task])
        XCTAssertTrue(csv.contains("未采集"), "未采集消耗不能按 0 导出")
    }

    func testCreditCSVContainsFailureAndSource() {
        let snapshot = CreditSnapshot(
            id: UUID(),
            accountId: UUID(),
            credits: nil,
            totalCredits: nil,
            queryAt: Date(timeIntervalSince1970: 1792915776),
            source: .manualEntry,
            status: .failed,
            errorMessage: "网络错误"
        )
        let csv = CSVExport.creditCSV([snapshot])
        XCTAssertTrue(csv.contains("时间,积分,总额度,来源,状态,说明"))
        XCTAssertTrue(csv.contains("失败"))
        XCTAssertTrue(csv.contains("网络错误"))
        XCTAssertTrue(csv.contains("未记录"))
    }

    func testFileNameSanitizesInvalidCharacters() {
        let name = CSVExport.fileName(
            type: .tasks,
            accountName: "工作/测试:账号",
            date: Date(timeIntervalSince1970: 1792915776)
        )
        XCTAssertTrue(name.hasPrefix("TRAE任务-工作-测试-账号-"))
        XCTAssertTrue(name.hasSuffix(".csv"))
        XCTAssertFalse(name.contains("/"))
        XCTAssertFalse(name.contains(":"))
    }
}
