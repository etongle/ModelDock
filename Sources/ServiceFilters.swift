import Foundation

enum ServiceStateFilter: String, CaseIterable, Hashable {
    case all, started, stopped
    var title: String {
        switch self { case .all: return "全部"; case .started: return "已启动"; case .stopped: return "已停止" }
    }
    func matches(_ status: ServiceStatus, hasProcess: Bool) -> Bool {
        let active = hasProcess || [.starting, .running, .stopping].contains(status)
        switch self { case .all: return true; case .started: return active; case .stopped: return !active }
    }
    func matches(_ external: ObservedService) -> Bool {
        // Discovered listeners are never stopped configurations. Unverified ports belong only in All.
        switch self { case .all: return true; case .started: return external.ready; case .stopped: return false }
    }
}

@MainActor extension AppStore {
    func serviceMatchesState(_ spec: ServiceSpec) -> Bool {
        guard serviceStateFilter != .all else { return true }
        let hasProcess: Bool
        if let pid = spec.pid, let birth = spec.processStart, birth > 0 { hasProcess = processStartTime(pid) == birth }
        else { hasProcess = false }
        return serviceStateFilter.matches(services.status(spec), hasProcess: hasProcess)
    }
    var hasServiceFilters: Bool { !serviceEngineFilter.isEmpty || serviceStateFilter != .all }
    func clearServiceFilters() {
        serviceEngineFilter = ""; serviceStateFilter = .all; selectVisibleService()
    }
    func showExternalService(_ service: ObservedService) {
        gatewaySelected = false
        if !serviceEngineFilter.isEmpty && serviceEngineFilter != service.engineID { serviceEngineFilter = "" }
        if !serviceStateFilter.matches(service) { serviceStateFilter = .all }
        selectedExternal = service.port; tab = .services
    }
}
