import Foundation

extension ConnectionFiles {
    static func authenticatedProbe(_ target: ConnectionTarget) async throws -> ProbeResult {
        if target.engineID != "gateway", !target.isRemote, target.apiKey?.isEmpty != false { return await NetworkProbe.models(port: target.port) }
        let models: [[String: Any]]
        do { models = try await GatewayAddress.modelList(try GatewayAddress.validated(target.endpoint), apiKey: target.apiKey ?? "") }
        catch { throw LaunchError.message("原接口当前不可达或认证已变化，请在模型管理中重新接入。") }
        if target.engineID == "gateway" {
            guard let model = models.first(where: { $0["id"] as? String == target.model }), let revision = target.backendRevision,
                  model["backend_revision"] as? String == revision else { throw LaunchError.message("网关路由的服务、模型或输入模式已变化，请重新接入。") }
        }
        return .init(alive: true, ready: true, models: models.compactMap { $0["id"] as? String }, code: 200)
    }
    static func validateRemote(_ target: ConnectionTarget) async throws {
        guard target.isRemote, let registration = target.registration, let sourceID = target.sourceID,
              let revision = target.remoteRevision else { throw LaunchError.message("外部服务的登记信息无效。") }
        let settings = try JSONDecoder().decode(GatewaySettings.self, from: Data(contentsOf: URL(fileURLWithPath: registration)))
        guard let entry = settings.endpoints.first(where: { "remote:\($0.id)" == sourceID }), entry.revision == revision,
              entry.url == target.endpoint, entry.apiKey == (target.apiKey ?? ""), entry.models.contains(where: { $0.id == target.model }) else { throw LaunchError.message("外部服务配置已变化，请重新接入。") }
        if target.pid > 0 {
            let listeners = await PortIdentity.snapshot(ports: [target.port])[target.port] ?? []
            guard processStartTime(target.pid) == target.birth, !listeners.isEmpty,
                  listeners.allSatisfy({ $0.belongs(pid: target.pid, birth: target.birth) }) else { throw LaunchError.message("本机外部服务已停止或监听进程已改变。") }
        }
        let models = try await GatewayAddress.modelList(try GatewayAddress.validated(target.endpoint), apiKey: target.apiKey ?? "")
        guard models.contains(where: { $0["id"] as? String == target.model }) else { throw LaunchError.message("外部服务已不再提供此模型。") }
    }
}
