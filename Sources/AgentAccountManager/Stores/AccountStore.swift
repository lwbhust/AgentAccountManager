import Foundation
import Core

/// 账号列表领域状态：列表加载、筛选排序、收藏与选中项。
///
/// 只管理内存态与 UserDefaults 偏好；数据库访问由调用方传入服务实例。
/// 「运行中」判断经 isRunningProvider 注入（运行状态属于 RunningStore），
/// 避免 Store 之间直接依赖。
@MainActor
final class AccountStore: ObservableObject {
    @Published private(set) var accounts: [Account] = []
    @Published var selectedPlatform: Platform?
    @Published var selectedAccountId: UUID? {
        didSet { persistSelection() }
    }
    @Published var searchText: String = ""
    /// 搜索框是否展开（⌘F 由菜单命令触发）。
    @Published var isSearchPresented: Bool = false
    @Published var accountFilter: AppState.AccountFilter = .all
    @Published var accountSort: AppState.AccountSort = .recent
    @Published private(set) var favoriteAccountIds: Set<UUID> = []
    /// 账号数据版本号：账号新增/编辑/删除/登录核对后递增，工作台据此刷新。
    @Published private(set) var revision: Int = 0

    /// 「运行中」判断（AppState 注入，转发 RunningStore）。
    var isRunningProvider: (Account) -> Bool = { _ in false }

    /// 上次查看的账号，下次打开应用直接回到工作区。
    private static let lastSelectionKey = "lastSelectedAccountId"
    private static let favoritesKey = "favoriteAccountIds"
    private var didRestoreSelection = false

    // MARK: - 列表加载

    /// 重新加载账号列表（保持当前选中项仍然有效）。
    func reload(service: AccountService?) throws {
        guard let service else { return }
        accounts = try service.listAll()
        pruneFavorites()
        if let id = selectedAccountId, !accounts.contains(where: { $0.id == id }) {
            selectedAccountId = nil
        }
        restoreSelectionIfNeeded()
        revision &+= 1
    }

    /// 首次加载时恢复上次查看的账号，让应用直接进入工作区。
    private func restoreSelectionIfNeeded() {
        guard !didRestoreSelection else { return }
        didRestoreSelection = true
        guard selectedAccountId == nil,
              let raw = UserDefaults.standard.string(forKey: Self.lastSelectionKey),
              let id = UUID(uuidString: raw),
              accounts.contains(where: { $0.id == id }) else { return }
        selectedAccountId = id
    }

    private func persistSelection() {
        if let id = selectedAccountId {
            UserDefaults.standard.set(id.uuidString, forKey: Self.lastSelectionKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.lastSelectionKey)
        }
    }

    // MARK: - 派生列表

    /// 当前平台 + 显示范围 + 搜索关键字过滤后的账号，并按所选方式排序。
    var filteredAccounts: [Account] {
        let keyword = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        let matched = accounts.filter { account in
            if let platform = selectedPlatform, account.platform != platform { return false }
            if !matchesFilter(account) { return false }
            guard !keyword.isEmpty else { return true }
            let haystack = [
                account.displayName,
                account.phoneMasked,
                account.planType ?? "",
                account.note ?? ""
            ].joined(separator: " ").lowercased()
            return haystack.contains(keyword)
        }
        return sorted(matched)
    }

    private func matchesFilter(_ account: Account) -> Bool {
        switch accountFilter {
        case .all:
            return true
        case .running:
            return isRunningProvider(account)
        }
    }

    /// 按所选方式排序；「最近使用」把从未使用的账号排在后面。
    private func sorted(_ list: [Account]) -> [Account] {
        switch accountSort {
        case .recent:
            return list.sorted { lhs, rhs in
                switch (lhs.lastUsedAt, rhs.lastUsedAt) {
                case let (l?, r?): return l > r
                case (nil, _?): return false
                case (_?, nil): return true
                case (nil, nil):
                    if lhs.platform != rhs.platform {
                        return lhs.platform == .trae
                    }
                    return lhs.createdAt < rhs.createdAt
                }
            }
        case .name:
            return list.sorted {
                $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            }
        case .favorite:
            return list.sorted { lhs, rhs in
                let lhsFavorite = favoriteAccountIds.contains(lhs.id)
                let rhsFavorite = favoriteAccountIds.contains(rhs.id)
                if lhsFavorite != rhsFavorite { return lhsFavorite }
                return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
            }
        }
    }

    var selectedAccount: Account? {
        guard let id = selectedAccountId else { return nil }
        return accounts.first { $0.id == id }
    }

    func account(id: UUID) -> Account? {
        accounts.first { $0.id == id }
    }

    /// 跨窗口导航：选中指定账号；如果它被当前筛选或搜索挡住，先恢复可见范围。
    ///
    /// 只在用户显式点击「在账号管理器中查看」时调用，后台同步不使用。
    func selectAccount(id: UUID) {
        guard accounts.contains(where: { $0.id == id }) else { return }
        if !filteredAccounts.contains(where: { $0.id == id }) {
            selectedPlatform = nil
            accountFilter = .all
            searchText = ""
            isSearchPresented = false
        }
        selectedAccountId = id
    }

    /// 指定平台下的账号数量（nil 表示全部）。
    func count(of platform: Platform?) -> Int {
        guard let platform else { return accounts.count }
        return accounts.filter { $0.platform == platform }.count
    }

    // MARK: - 收藏

    /// 该账号是否被收藏（视图层快捷标记，不写入账号表）。
    func isFavorite(_ accountId: UUID) -> Bool {
        favoriteAccountIds.contains(accountId)
    }

    /// 切换收藏状态；收藏变化会立即影响列表排序与筛选。
    /// （小组件快照同步由调用方在变更后触发。）
    func toggleFavorite(_ accountId: UUID) {
        if favoriteAccountIds.contains(accountId) {
            favoriteAccountIds.remove(accountId)
        } else {
            favoriteAccountIds.insert(accountId)
        }
        persistFavorites()
    }

    func loadFavorites() {
        let stored = UserDefaults.standard.stringArray(forKey: Self.favoritesKey) ?? []
        favoriteAccountIds = Set(stored.compactMap { UUID(uuidString: $0) })
    }

    /// 删除已不存在的账号收藏，避免 UserDefaults 里残留无效 ID。
    private func pruneFavorites() {
        guard !favoriteAccountIds.isEmpty else { return }
        let valid = Set(accounts.map(\.id))
        let cleaned = favoriteAccountIds.intersection(valid)
        if cleaned != favoriteAccountIds {
            favoriteAccountIds = cleaned
            persistFavorites()
        }
    }

    private func persistFavorites() {
        UserDefaults.standard.set(
            favoriteAccountIds.map(\.uuidString).sorted(),
            forKey: Self.favoritesKey
        )
    }
}
