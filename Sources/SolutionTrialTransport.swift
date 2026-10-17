import Foundation

enum SolutionTrialConnection: String, CaseIterable { case gateway = "方案网关", direct = "直接连接服务" }

@MainActor struct SolutionTrialTransport {
    let connection: SolutionTrialConnection
    let deployment: SolutionDeployment
    let gateway: GatewayProcess?
    let endpoint: String?
    let apiKey: String?

    init(connection: SolutionTrialConnection, deployment: SolutionDeployment, store: AppStore) throws {
        self.connection = connection; self.deployment = deployment
        if connection == .gateway {
            store.synchronizeGateway()
            guard store.gateway.solutionReady(deployment), store.gateway.ownsProcess(), let process = store.gateway.process,
                  process.port == store.gateway.settings.port else { throw LaunchError.message("请先启动方案网关并等待组件就绪") }
            gateway = process; endpoint = store.gateway.solutionEndpoint(deployment); apiKey = store.gateway.settings.apiKey
        } else { gateway = nil; endpoint = nil; apiKey = nil }
    }
    func model(_ role: SolutionRole, spec: ServiceSpec, store: AppStore) throws -> String {
        if connection == .gateway { return role.gatewayModel }
        let reported = store.services.reportedModels[spec.port] ?? []
        let model = store.models.first { $0.id == spec.modelID }
        if let exact = reported.first(where: { $0 == spec.modelPath || $0 == spec.modelName || $0 == model?.repository }) { return exact }
        guard reported.count == 1, let only = reported.first else { throw LaunchError.message("方案模型或服务配置已变化，请修复方案") }
        return only
    }
    private func pinned(_ role: SolutionRole, spec: ServiceSpec, store: AppStore) -> Bool {
        guard let pid = spec.pid, let birth = spec.processStart, processStartTime(pid) == birth,
              store.services.records.contains(where: { $0.id == spec.id && $0.pid == pid && $0.processStart == birth && $0.port == spec.port }),
              store.solutions.deployments.contains(where: { $0.id == deployment.id && $0.state == .configured && $0.components.contains { $0.role == role && $0.serviceID == spec.id } }) else { return false }
        guard let gateway else { return true }
        return processStartTime(gateway.pid) == gateway.birth && store.gateway.process?.pid == gateway.pid && store.gateway.process?.birth == gateway.birth && store.gateway.process?.port == gateway.port && store.gateway.ownsProcess()
    }
    private func verifyListener(store: AppStore) async throws {
        guard let gateway else { return }
        let listeners = await PortIdentity.snapshot(ports: [gateway.port])[gateway.port] ?? []
        guard !listeners.isEmpty, listeners.allSatisfy({ $0.belongs(pid: gateway.pid, birth: gateway.birth) }) else { throw LaunchError.message("方案网关监听进程已变化，请重新启动试用") }
    }
    func request(_ role: SolutionRole, spec: ServiceSpec, path: String, body: Data, type: String = "application/json", store: AppStore) async throws -> Data {
        guard pinned(role, spec: spec, store: store) else { throw LaunchError.message("服务进程已变化，请重新启动试用") }
        try await verifyListener(store: store)
        let address = endpoint.map { $0 + String(path.dropFirst(3)) } ?? "http://127.0.0.1:\(spec.port)" + path
        var request = URLRequest(url: URL(string: address)!); request.httpMethod = "POST"; request.timeoutInterval = 300
        request.httpBody = body; request.setValue(type, forHTTPHeaderField: "Content-Type")
        if let apiKey { request.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization") }
        let session = URLSession(configuration: .ephemeral, delegate: GatewayRedirectGuard(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard pinned(role, spec: spec, store: store) else { throw LaunchError.message("服务进程已变化，请重新启动试用") }
        try await verifyListener(store: store)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let detail = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["error"] as? [String: Any]
            throw LaunchError.message(detail?["message"] as? String ?? "服务请求失败，请查看日志")
        }
        return data
    }
}
