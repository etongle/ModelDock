import Foundation
import Combine
import Security

@MainActor
protocol ModelTokenStorage {
    func read() throws -> String?
    func write(_ token: String?) throws
}

@MainActor
final class MemoryModelTokenStorage: ModelTokenStorage {
    private var value: String?
    func read() throws -> String? { value }
    func write(_ token: String?) throws { value = token }
}

@MainActor
struct KeychainModelTokenStorage: ModelTokenStorage {
    private var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "local.null.ModelManager.model-access", kSecAttrAccount as String: "huggingface"] }
    func read() throws -> String? {
        var request = query; request[kSecReturnData as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data, let value = String(data: data, encoding: .utf8) else { throw failure(status) }
        return value
    }
    func write(_ token: String?) throws {
        guard let token else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status) }; return
        }
        let data = Data(token.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query; item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "ModelDock · Hugging Face"
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let inserted = SecItemAdd(item as CFDictionary, nil)
            guard inserted == errSecSuccess else { throw failure(inserted) }
        } else if status != errSecSuccess { throw failure(status) }
    }
    private func failure(_ status: OSStatus) -> Error { LaunchError.message(L10n.format("无法访问系统钥匙串（{0}）。请解锁钥匙串后重试。", [String(status)])) }
}

@MainActor
final class ModelAccessTokens: ObservableObject {
    @Published private(set) var huggingFaceConfigured = false
    @Published var error: String?
    @Published var notice: String?
    private let storage: any ModelTokenStorage
    private var cached: String?
    private var loaded = false
    init(storage: any ModelTokenStorage) { self.storage = storage }
    static func validated(_ input: String) throws -> String {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 4096, value.utf8.allSatisfy({ (33...126).contains($0) }) else { throw LaunchError.message("请输入有效访问令牌，不要包含空格或换行。") }
        return value
    }
    func refresh() {
        do { cached = try storage.read(); loaded = true; huggingFaceConfigured = cached?.isEmpty == false; error = nil }
        catch { self.error = error.localizedDescription }
    }
    func credential(for address: String, override: String = "") -> String {
        if !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return override.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let url = URL(string: ModelCatalog.normalizedAddress(address)), url.scheme == "https", url.host?.lowercased() == "huggingface.co", url.user == nil, url.password == nil else { return "" }
        if !loaded { refresh() }
        return cached ?? ""
    }
    @discardableResult func save(_ input: String) -> Bool {
        do {
            let value = try Self.validated(input); try storage.write(value)
            cached = value; loaded = true; huggingFaceConfigured = true; error = nil; notice = "全局 Hugging Face 令牌已保存。下载、续传和模型更新会自动使用。"; return true
        } catch { self.error = error.localizedDescription; notice = nil; return false }
    }
    func remove() {
        do { try storage.write(nil); cached = nil; loaded = true; huggingFaceConfigured = false; error = nil; notice = "全局令牌已移除，已下载文件保留。" }
        catch { self.error = error.localizedDescription; notice = nil }
    }
}
