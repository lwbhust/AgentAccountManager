import Foundation
import CryptoKit

/// 手机号脱敏与摘要工具。
public enum Masking {
    /// 将手机号脱敏为 138****1234 形式。
    /// 保留前 3 位与后 4 位，中间用 * 替换。
    /// 若输入不足 7 位则全部用 * 替换。
    public static func maskPhone(_ phone: String) -> String {
        let digits = phone.filter { $0.isNumber }
        guard digits.count >= 7 else {
            return String(repeating: "*", count: max(digits.count, 1))
        }
        let prefix = String(digits.prefix(3))
        let suffix = String(digits.suffix(4))
        return "\(prefix)****\(suffix)"
    }

    /// 计算完整手机号的 SHA-256 摘要（小写十六进制）。
    /// 用于账号去重，不明文存储手机号。
    public static func phoneHash(_ phone: String) -> String {
        let data = Data(phone.utf8)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// 对日志文本中的手机号进行脱敏，匹配 11 位连续数字（中国大陆手机号特征）。
    public static func redactPhone(in text: String) -> String {
        let pattern = #"1\d{10}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "1**********")
    }
}
