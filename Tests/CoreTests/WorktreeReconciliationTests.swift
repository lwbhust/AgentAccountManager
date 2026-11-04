import XCTest
@testable import Core

/// WorktreeReconciliation 纯函数矩阵：全部用注入的探测闭包，不依赖真实 Git。
final class WorktreeReconciliationTests: XCTestCase {
    private let repoMain = "/tmp/repo-main"

    /// 与实现一致的路径归一化（复用被测函数，保证两侧口径相同）。
    private func normalize(_ raw: String) -> String {
        WorktreeReconciliation.normalizedPath(raw)
    }

    private func workstation(
        name: String = "工位 1",
        path: String?,
        branch: String? = "workbench/ns/lane1",
        activatedAt: Date? = nil
    ) -> Workstation {
        Workstation(
            projectId: UUID(),
            displayName: name,
            worktreePath: path,
            branchName: branch,
            lastActivatedAt: activatedAt
        )
    }

    private func record(_ path: String, branch: String? = "workbench/ns/lane1") -> GitWorktreeService.WorktreeRecord {
        GitWorktreeService.WorktreeRecord(
            path: normalize(path),
            branch: branch,
            head: "abc123"
        )
    }

    private func health(
        _ ws: Workstation,
        registered: [GitWorktreeService.WorktreeRecord] = [],
        exists: Set<String> = [],
        statuses: [String: GitWorktreeService.WorktreeStatus] = [:],
        statusCalls: inout [String]
    ) -> WorkstationReconciliation {
        let report = WorktreeReconciliation.reconcile(
            workstations: [ws],
            registered: registered,
            repoMainPath: repoMain,
            fileExists: { exists.contains(normalize($0)) },
            statusProvider: { path in
                statusCalls.append(path)
                return statuses[normalize(path)]
            }
        )
        return report.workstations[0]
    }

    /// 登记与目录一致：healthy，并读取工作区状态。
    func testHealthyReadsStatus() {
        var calls: [String] = []
        let path = "/tmp/wt-lane1"
        let status = GitWorktreeService.WorktreeStatus(branch: "workbench/ns/lane1", isClean: true, changedFileCount: 0)
        let result = health(
            workstation(path: path),
            registered: [record(path)],
            exists: [path],
            statuses: [path: status],
            statusCalls: &calls
        )
        XCTAssertEqual(result.health, .healthy)
        XCTAssertEqual(result.status?.branch, "workbench/ns/lane1")
        XCTAssertEqual(result.isBranchMismatch, false)
        XCTAssertEqual(result.needsAttention, false)
        XCTAssertEqual(calls, [normalize(path)])
    }

    /// 从未激活且无任何痕迹：notStarted（正常状态），不读取状态。
    func testNotStartedSkipsStatus() {
        var calls: [String] = []
        let path = "/tmp/wt-lane1"
        let result = health(workstation(path: path), statusCalls: &calls)
        XCTAssertEqual(result.health, .notStarted)
        XCTAssertNil(result.status)
        XCTAssertTrue(calls.isEmpty)
    }

    /// 曾经激活、现在目录与登记都不存在：vanished（异常退出/被外部清理）。
    func testVanishedAfterActivation() {
        var calls: [String] = []
        let result = health(
            workstation(path: "/tmp/wt-lane1", activatedAt: Date()),
            statusCalls: &calls
        )
        XCTAssertEqual(result.health, .vanished)
        XCTAssertEqual(result.needsAttention, true)
    }

    /// Git 有登记但目录丢失：directoryMissing，登记被认领、不计入未纳管。
    func testDirectoryMissing() {
        var calls: [String] = []
        let path = "/tmp/wt-lane1"
        let report = WorktreeReconciliation.reconcile(
            workstations: [workstation(path: path)],
            registered: [record(path)],
            repoMainPath: repoMain,
            fileExists: { _ in false },
            statusProvider: { _ in
                calls.append("unexpected")
                return nil
            }
        )
        XCTAssertEqual(report.workstations[0].health, .directoryMissing)
        XCTAssertEqual(report.workstations[0].needsAttention, true)
        XCTAssertTrue(report.unmanaged.isEmpty)
        XCTAssertTrue(calls.isEmpty, "目录已丢失时不应读取状态")
    }

    /// 目录存在但 Git 不认：registrationMissing；不读取状态（可能是其他仓库的内容）。
    func testRegistrationMissingSkipsForeignStatus() {
        var calls: [String] = []
        let path = "/tmp/wt-lane1"
        let result = health(workstation(path: path), exists: [path], statusCalls: &calls)
        XCTAssertEqual(result.health, .registrationMissing)
        XCTAssertNil(result.status)
        XCTAssertTrue(calls.isEmpty)
    }

    /// 没规划路径的工位按未开工处理。
    func testMissingPathTreatedAsNotStarted() {
        var calls: [String] = []
        let result = health(workstation(path: nil), statusCalls: &calls)
        XCTAssertEqual(result.health, .notStarted)
    }

    /// 实际工作分支与登记分支不一致：分支漂移需要留意。
    func testBranchMismatchNeedsAttention() {
        var calls: [String] = []
        let path = "/tmp/wt-lane1"
        let status = GitWorktreeService.WorktreeStatus(branch: "workbench/ns/other", isClean: true, changedFileCount: 0)
        let result = health(
            workstation(path: path, branch: "workbench/ns/lane1"),
            registered: [record(path, branch: "workbench/ns/other")],
            exists: [path],
            statuses: [path: status],
            statusCalls: &calls
        )
        XCTAssertEqual(result.health, .healthy)
        XCTAssertEqual(result.isBranchMismatch, true)
        XCTAssertEqual(result.needsAttention, true)
    }

    /// 未纳管 worktree：排除已认领与仓库主工作区；目录存在才读状态。
    func testUnmanagedExcludesBoundAndRepoMain() {
        let bound = "/tmp/wt-lane1"
        let extra = "/tmp/wt-extra"
        let extraStatus = GitWorktreeService.WorktreeStatus(branch: "extra", isClean: false, changedFileCount: 2)
        let report = WorktreeReconciliation.reconcile(
            workstations: [workstation(path: bound)],
            registered: [
                record(repoMain, branch: "main"),
                record(bound),
                record(extra, branch: "extra")
            ],
            repoMainPath: repoMain,
            fileExists: { path in
                let normalized = normalize(path)
                return normalized == normalize(bound) || normalized == normalize(extra)
            },
            statusProvider: { [extraStatus] path in
                normalize(path) == normalize(extra) ? extraStatus : nil
            }
        )
        XCTAssertEqual(report.workstations[0].health, .healthy)
        XCTAssertEqual(report.unmanaged.count, 1)
        XCTAssertEqual(report.unmanaged[0].branch, "extra")
        XCTAssertEqual(report.unmanaged[0].directoryExists, true)
        XCTAssertEqual(report.unmanaged[0].status?.changedFileCount, 2, "目录存在且可能有未提交工作时应给出状态")
    }

    /// 未纳管 worktree 目录丢失：仍报告登记（prune 候选），不读状态。
    func testUnmanagedWithoutDirectory() {
        let report = WorktreeReconciliation.reconcile(
            workstations: [],
            registered: [record("/tmp/wt-gone", branch: "gone")],
            repoMainPath: repoMain,
            fileExists: { _ in false }
        )
        XCTAssertEqual(report.unmanaged.count, 1)
        XCTAssertEqual(report.unmanaged[0].directoryExists, false)
        XCTAssertNil(report.unmanaged[0].status)
    }
}
