import Foundation
import os.log

/// 统一日志工具，强制对手机号进行脱敏。
/// 不允许将密码、Token、Cookie 或完整手机号写入日志。
///
/// Console 中可按 subsystem（固定 `com.agentaccountmanager`）+ category（模块名）过滤；
/// 每条日志自带系统时间戳。调用方在 message 中写明 operation 与 result，
/// 不要输出完整手机号、密钥或原始日志全文。
public struct AppLogger: Sendable {
    private let logger: Logger
    private let subsystem: String

    /// - Parameters:
    ///   - subsystem: 日志子系统，默认为本应用。
    ///   - category: 模块名（database/switch/credit/task/account/...），用于 Console 过滤。
    public init(subsystem: String = "com.agentaccountmanager", category: String = "app") {
        self.subsystem = subsystem
        self.logger = Logger(subsystem: subsystem, category: category)
    }

    /// 记录信息日志（自动脱敏手机号）。
    public func info(_ message: String) {
        logger.info("\(Masking.redactPhone(in: message), privacy: .public)")
    }

    /// 记录调试日志（自动脱敏手机号）。
    public func debug(_ message: String) {
        logger.debug("\(Masking.redactPhone(in: message), privacy: .public)")
    }

    /// 记录错误日志（自动脱敏手机号）。
    public func error(_ message: String) {
        logger.error("\(Masking.redactPhone(in: message), privacy: .public)")
    }

    /// 记录错误并附带脱敏后的错误对象描述。
    public func error(_ message: String, error: Error) {
        let desc = Masking.redactPhone(in: error.localizedDescription)
        logger.error("\(Masking.redactPhone(in: message), privacy: .public): \(desc, privacy: .public)")
    }
}
