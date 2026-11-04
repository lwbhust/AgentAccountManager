import XCTest
import Core

/// 内存版钥匙串实现：模拟真实 Keychain 的成功、不存在、权限拒绝与写入失败语义。
private final class InMemoryKeychain: KeychainStoring, @unchecked Sendable {
    private var storage: [String: Data] = [:]
    private let lock = NSLock()

    /// 注入的故障模式：权限拒绝（读 nil、写/删 false）与写入失败（写 false）。
    var permissionDenied = false
    var writeFailure = false

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func setString(_ value: String, for key: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        return setData(data, for: key)
    }

    func string(for key: String) -> String? {
        guard let data = data(for: key) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func setData(_ data: Data, for key: String) -> Bool {
        withLock {
            if writeFailure || permissionDenied { return false }
            storage[key] = data
            return true
        }
    }

    func data(for key: String) -> Data? {
        withLock {
            guard !permissionDenied else { return nil }
            return storage[key]
        }
    }

    func delete(for key: String) -> Bool {
        withLock {
            // 与真实 Keychain 一致：删除不存在的 key 也算成功（errSecItemNotFound）。
            if permissionDenied { return false }
            return storage.removeValue(forKey: key) != nil || true
        }
    }

    func deleteAll() -> Bool {
        withLock {
            if permissionDenied { return false }
            storage.removeAll()
            return true
        }
    }

    func setPhone(_ phone: String, for accountId: UUID) -> Bool {
        setString(phone, for: "phone:\(accountId.uuidString)")
    }

    func phone(for accountId: UUID) -> String? {
        string(for: "phone:\(accountId.uuidString)")
    }

    func deletePhone(for accountId: UUID) -> Bool {
        delete(for: "phone:\(accountId.uuidString)")
    }
}

/// KeychainStoring 注入测试矩阵：保存、读取、更新、删除、不存在、权限错误、写入失败与脱敏边界。
final class KeychainServiceTests: XCTestCase {
    private var keychain: InMemoryKeychain!
    private var accountId: UUID!

    override func setUp() {
        super.setUp()
        keychain = InMemoryKeychain()
        accountId = UUID()
    }

    func testSaveAndReadPhone() {
        XCTAssertTrue(keychain.setPhone("13812341234", for: accountId))
        XCTAssertEqual(keychain.phone(for: accountId), "13812341234")
    }

    func testUpdateOverwritesPreviousValue() {
        XCTAssertTrue(keychain.setPhone("13812341234", for: accountId))
        XCTAssertTrue(keychain.setPhone("13900001111", for: accountId))
        XCTAssertEqual(keychain.phone(for: accountId), "13900001111")
    }

    func testDeleteRemovesValue() {
        XCTAssertTrue(keychain.setPhone("13812341234", for: accountId))
        XCTAssertTrue(keychain.deletePhone(for: accountId))
        XCTAssertNil(keychain.phone(for: accountId))
    }

    func testMissingKeyReadsNilAndDeleteSucceeds() {
        XCTAssertNil(keychain.phone(for: accountId))
        // 与真实 Keychain 一致：删除不存在的条目视为成功。
        XCTAssertTrue(keychain.deletePhone(for: accountId))
    }

    func testPermissionDeniedReadsNilAndWritesFail() {
        keychain.permissionDenied = true
        XCTAssertFalse(keychain.setPhone("13812341234", for: accountId))
        XCTAssertNil(keychain.phone(for: accountId))
        XCTAssertFalse(keychain.deletePhone(for: accountId))
        XCTAssertFalse(keychain.deleteAll())
    }

    func testWriteFailureReportsFalseWithoutCorruptingStorage() {
        XCTAssertTrue(keychain.setPhone("13812341234", for: accountId))
        keychain.writeFailure = true
        // 写入失败不影响既有值
        XCTAssertFalse(keychain.setString("新值", for: "other"))
        XCTAssertEqual(keychain.string(for: "other"), nil)
        XCTAssertEqual(keychain.phone(for: accountId), "13812341234")
    }

    func testDeleteAllClearsEveryEntry() {
        let other = UUID()
        XCTAssertTrue(keychain.setPhone("13812341234", for: accountId))
        XCTAssertTrue(keychain.setPhone("13900001111", for: other))
        XCTAssertTrue(keychain.deleteAll())
        XCTAssertNil(keychain.phone(for: accountId))
        XCTAssertNil(keychain.phone(for: other))
    }

    func testPhoneStoredVerbatimNotMasked() {
        // Keychain 存完整手机号（脱敏只发生在展示与日志层），这里锁定该边界。
        let full = "13812341234"
        XCTAssertTrue(keychain.setPhone(full, for: accountId))
        XCTAssertEqual(keychain.phone(for: accountId), full)
        XCTAssertNotEqual(keychain.phone(for: accountId), Masking.maskPhone(full))
    }

    // MARK: - 与 BackupRestore 的集成

    /// 清空本地数据时，注入的钥匙串实现中的手机号也应被清除。
    func testWipeWithInjectedKeychainClearsDatabaseAndKeychain() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wipe-injected-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let db = try DatabaseService(databaseURL: dir.appendingPathComponent("main.sqlite"))
        let service = AccountService(database: db)
        let account = try service.create(
            platform: .trae, displayName: "清空", phoneMasked: "138****1234"
        )
        XCTAssertTrue(keychain.setPhone("13812341234", for: account.id))

        try BackupRestore(database: db, keychain: keychain).deleteAllData()

        XCTAssertNil(keychain.phone(for: account.id), "钥匙串中的手机号应被清除")
        XCTAssertFalse(FileManager.default.fileExists(atPath: db.databaseURL.path), "数据库文件应被删除")
    }
}
