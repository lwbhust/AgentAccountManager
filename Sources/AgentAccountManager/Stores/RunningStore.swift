import Foundation
import AppKit
import Core

/// 运行状态领域状态：TRAE 独立实例与 WorkBuddy 客户端是否在运行。
@MainActor
final class RunningStore: ObservableObject {
    /// 正在运行的 TRAE 独立实例对应的账号 ID（按 `--user-data-dir` 区分）。
    @Published private(set) var runningTraeAccountIds: Set<UUID> = []
    /// WorkBuddy 客户端是否在运行（平台级，无法区分账号）。
    @Published private(set) var isWorkBuddyAppRunning: Bool = false

    /// 是否已有一次运行状态查询在执行，避免上一轮 `ps` 未返回时重复发起。
    private var isRefreshing = false
    /// 状态更新后的回调（由 AppState 注入，用于同步小组件快照）。
    var onUpdate: (() -> Void)?

    /// 刷新「哪些账号的 TRAE 独立实例正在运行」。
    ///
    /// 这是一次外部进程查询（`ps`），只应在列表重新加载、切换完成后、
    /// 应用激活或定时刷新时调用，渲染路径不得直接调用。
    func refresh(traeService: TraeService) {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task.detached(priority: .utility) { [weak self] in
            let ids = traeService.runningIsolatedAccountIds()
            await self?.finish(ids)
        }
    }

    private func finish(_ ids: Set<UUID>) {
        isRefreshing = false
        if ids != runningTraeAccountIds {
            runningTraeAccountIds = ids
        }
        let workbuddyRunning = NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == Platform.workbuddy.bundleIdentifier
        }
        if workbuddyRunning != isWorkBuddyAppRunning {
            isWorkBuddyAppRunning = workbuddyRunning
        }
        onUpdate?()
    }

    /// 账号是否处于「运行中」。
    /// TRAE 按账号实例判断；WorkBuddy 只有一个客户端，只能按平台级提示。
    func isRunning(_ account: Account) -> Bool {
        switch account.platform {
        case .trae:
            return runningTraeAccountIds.contains(account.id)
        case .workbuddy:
            return isWorkBuddyAppRunning
        }
    }
}
