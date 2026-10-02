import Foundation
import NetworkExtension
import SystemExtensions

let providerIdentifier = "com.ccswitch.network-probe.provider"

func emit(_ values: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([10]))
}

final class Installer: NSObject, OSSystemExtensionRequestDelegate {
    var continuation: CheckedContinuation<Void, Error>?

    func activate() async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let request = OSSystemExtensionRequest.activationRequest(
                forExtensionWithIdentifier: providerIdentifier, queue: .main)
            request.delegate = self
            OSSystemExtensionManager.shared.submitRequest(request)
        }
    }

    func request(_ request: OSSystemExtensionRequest,
                 actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        return .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        emit(["status": "approval_required", "extension": request.identifier])
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        continuation!.resume(throwing: error)
        continuation = nil
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        emit(["status": "activation_completed", "result": result.rawValue])
        continuation!.resume()
        continuation = nil
    }
}

@main
struct Controller {
    static func main() async {
        do {
            guard CommandLine.arguments.count >= 2 else {
                throw NSError(domain: "NetworkProbe", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "需要指定测试操作"])
            }
            switch CommandLine.arguments[1] {
            case "export-test-profile":
                guard CommandLine.arguments.count == 4 else {
                    throw NSError(domain: "AppEgress", code: 43,
                                  userInfo: [NSLocalizedDescriptionKey: "需要提供测试配置与描述文件输出路径"])
                }
                try TestProfile.write(configurationPath: CommandLine.arguments[2],
                                      outputPath: CommandLine.arguments[3])
                emit(["status": "profile_created", "target": "com.ccswitch.egress-client-probe"])
            case "inspect-tunnels", "remove-test-tunnels":
                let managers = try await NETunnelProviderManager.loadAllFromPreferences()
                let owned = managers.filter {
                    ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == providerIdentifier
                }
                if CommandLine.arguments[1] == "remove-test-tunnels" {
                    for manager in owned {
                        let paths = (manager.protocolConfiguration as? NETunnelProviderProtocol)?
                            .providerConfiguration?["applicationPaths"] as? [String] ?? []
                        guard paths.isEmpty else {
                            throw NSError(domain: "AppEgress", code: 44,
                                          userInfo: [NSLocalizedDescriptionKey: "配置包含正式应用，不能通过测试清理操作删除"])
                        }
                        try await manager.removeFromPreferences()
                    }
                    emit(["status": "test_tunnels_removed", "count": owned.count])
                } else {
                    emit(["status": "tunnels", "managers": owned.map {
                        ["class": String(describing: type(of: $0)), "enabled": $0.isEnabled,
                         "connection": $0.connection.status.rawValue,
                         "routingMethod": $0.routingMethod.rawValue,
                         "appRules": $0.appRules.map { $0.matchSigningIdentifier }] as [String: Any]
                    }])
                }
            case "activate":
                try await Installer().activate()
            case "configure-transparent":
                guard CommandLine.arguments.count == 3 else {
                    throw NSError(domain: "NetworkProbe", code: 48,
                                  userInfo: [NSLocalizedDescriptionKey: "需要透明代理测试配置路径"])
                }
                let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
                guard var settings = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let mode = settings["probeMode"] as? String, ["deny", "proxy"].contains(mode),
                      (settings["applicationPaths"] as? [String] ?? []).isEmpty else {
                    throw NSError(domain: "NetworkProbe", code: 49,
                                  userInfo: [NSLocalizedDescriptionKey: "配置必须仅包含测试应用和有效的代理模式"])
                }
                if mode == "proxy" {
                    guard let upstream = settings["upstream"] as? String else {
                        throw NSError(domain: "NetworkProbe", code: 14,
                                      userInfo: [NSLocalizedDescriptionKey: "缺少代理地址"])
                    }
                    _ = try Upstream(url: upstream)
                    if let front = settings["frontProxy"] as? String, !front.isEmpty {
                        _ = try Upstream(url: front)
                        guard front != upstream else {
                            throw NSError(domain: "NetworkProbe", code: 41,
                                          userInfo: [NSLocalizedDescriptionKey: "前置代理与最终代理不能相同"])
                        }
                    }
                }
                settings["transparentMode"] = true
                settings["applicationPaths"] = [String]()
                let appManagers = try await NEAppProxyProviderManager.loadAllFromPreferences()
                for manager in appManagers {
                    guard let configuration = manager.protocolConfiguration as? NETunnelProviderProtocol,
                          configuration.providerBundleIdentifier == providerIdentifier else { continue }
                    guard (configuration.providerConfiguration?["applicationPaths"] as? [String] ?? []).isEmpty,
                          [.invalid, .disconnected].contains(manager.connection.status) else {
                        throw NSError(domain: "NetworkProbe", code: 50,
                                      userInfo: [NSLocalizedDescriptionKey: "请停止现有 per-app 测试连接后启用透明代理验证"])
                    }
                }
                let managers = try await transparentManagers()
                guard managers.count <= 1 else {
                    throw NSError(domain: "NetworkProbe", code: 51,
                                  userInfo: [NSLocalizedDescriptionKey: "存在多个透明代理测试配置"])
                }
                let manager = managers.first ?? NETransparentProxyManager()
                if manager.connection.status != .invalid && manager.connection.status != .disconnected {
                    manager.isOnDemandEnabled = false
                    try await manager.saveToPreferences()
                    manager.connection.stopVPNTunnel()
                    try await waitForDisconnection(manager)
                }
                let configuration = NETunnelProviderProtocol()
                configuration.providerBundleIdentifier = providerIdentifier
                configuration.serverAddress = "127.0.0.1"
                configuration.providerConfiguration = settings
                manager.protocolConfiguration = configuration
                manager.localizedDescription = "CC Switch 测试应用透明代理"
                manager.isEnabled = true
                manager.isOnDemandEnabled = false
                manager.onDemandRules = []
                try await manager.saveToPreferences()
                try await manager.loadFromPreferences()
                try manager.connection.startVPNTunnel()
                for _ in 0..<200 {
                    if manager.connection.status == .connected { break }
                    try await Task.sleep(for: .milliseconds(50))
                }
                guard manager.connection.status == .connected else {
                    throw NSError(domain: "NetworkProbe", code: 52,
                                  userInfo: [NSLocalizedDescriptionKey: "透明代理测试连接未启动"])
                }
                emit(["status": "transparent_configured", "target": "com.ccswitch.egress-client-probe"])
            case "transparent-status":
                let managers = try await transparentManagers()
                emit(["status": "transparent_preferences", "managers": managers.map {
                    ["enabled": $0.isEnabled, "connection": $0.connection.status.rawValue,
                     "transparentMode": true, "testApplicationOnly": true,
                     "mode": ($0.protocolConfiguration as? NETunnelProviderProtocol)?
                        .providerConfiguration?["probeMode"] ?? "unknown"] as [String: Any]
                }])
            case "stop-transparent":
                let managers = try await transparentManagers()
                for manager in managers {
                    manager.isOnDemandEnabled = false
                    try await manager.saveToPreferences()
                    manager.connection.stopVPNTunnel()
                    try await waitForDisconnection(manager)
                }
                emit(["status": "transparent_stopped", "count": managers.count])
            case "provider-status-transparent":
                let managers = try await transparentManagers()
                guard managers.count == 1, let session = managers[0].connection as? NETunnelProviderSession else {
                    throw NSError(domain: "NetworkProbe", code: 16,
                                  userInfo: [NSLocalizedDescriptionKey: "透明代理测试扩展没有连接"])
                }
                let response: Data? = try await withCheckedThrowingContinuation { continuation in
                    do {
                        try session.sendProviderMessage(Data("provider-status".utf8)) {
                            continuation.resume(returning: $0)
                        }
                    } catch { continuation.resume(throwing: error) }
                }
                guard let response else {
                    throw NSError(domain: "NetworkProbe", code: 17,
                                  userInfo: [NSLocalizedDescriptionKey: "透明代理测试扩展没有响应"])
                }
                FileHandle.standardOutput.write(response)
                FileHandle.standardOutput.write(Data([10]))
            case "application-status":
                let managers = try await transparentManagers()
                let filter = NEFilterManager.shared()
                try await filter.loadFromPreferences()
                let settings = (managers.first?.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration
                let paths = settings?["applicationPaths"] as? [String]
                    ?? filter.providerConfiguration?.vendorConfiguration?["applicationPaths"] as? [String] ?? []
                emit(["installed": true, "proxyConnected": managers.first?.connection.status == .connected,
                      "filterEnabled": filter.isEnabled,
                      "applicationPaths": paths, "loopbackPorts": settings?["loopbackPorts"] as? [UInt16] ?? [],
                      "testApplicationOnly": paths.isEmpty])
            case "protect-applications":
                let data = FileHandle.standardInput.readDataToEndOfFile()
                guard var settings = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let upstream = settings["upstream"] as? String,
                      settings["probeMode"] as? String == "proxy" else {
                    throw NSError(domain: "NetworkProbe", code: 31,
                                  userInfo: [NSLocalizedDescriptionKey: "需要指定代理与应用路径"])
                }
                _ = try Upstream(url: upstream)
                let policy = try ApplicationPolicy(configuration: settings)
                guard !policy.paths.isEmpty, policy.paths.allSatisfy({ FileManager.default.fileExists(atPath: $0) }) else {
                    throw NSError(domain: "NetworkProbe", code: 32,
                                  userInfo: [NSLocalizedDescriptionKey: "受保护应用尚未安装"])
                }
                let managers = try await transparentManagers()
                guard managers.count <= 1 else {
                    throw NSError(domain: "NetworkProbe", code: 33,
                                  userInfo: [NSLocalizedDescriptionKey: "存在多个代理配置"])
                }
                let manager = managers.first ?? NETransparentProxyManager()
                settings["transparentMode"] = true
                if settings["frontProxy"] == nil {
                    settings["frontProxy"] = (manager.protocolConfiguration as? NETunnelProviderProtocol)?
                        .providerConfiguration?["frontProxy"]
                }
                if let front = settings["frontProxy"] as? String, !front.isEmpty {
                    _ = try Upstream(url: front)
                    guard front != upstream else {
                        throw NSError(domain: "AppEgress", code: 41,
                                      userInfo: [NSLocalizedDescriptionKey: "前置代理与最终代理不能相同"])
                    }
                }
                if manager.isEnabled {
                    manager.isOnDemandEnabled = false
                    try await manager.saveToPreferences()
                    manager.connection.stopVPNTunnel()
                    for _ in 0..<200 {
                        if manager.connection.status == .disconnected { break }
                        try await Task.sleep(for: .milliseconds(50))
                    }
                    guard manager.connection.status == .disconnected else {
                        throw NSError(domain: "NetworkProbe", code: 34,
                                      userInfo: [NSLocalizedDescriptionKey: "代理尚未停止，配置没有改变"])
                    }
                }
                let filter = NEFilterManager.shared()
                try await filter.loadFromPreferences()
                let filterConfiguration = NEFilterProviderConfiguration()
                filterConfiguration.filterSockets = true
                filterConfiguration.filterDataProviderBundleIdentifier = providerIdentifier
                filterConfiguration.vendorConfiguration = ["applicationPaths": policy.paths]
                filter.providerConfiguration = filterConfiguration
                filter.localizedDescription = "CC Switch 应用连接保护"
                filter.isEnabled = true
                try await filter.saveToPreferences()
                let configuration = NETunnelProviderProtocol()
                configuration.providerBundleIdentifier = providerIdentifier
                configuration.serverAddress = "127.0.0.1"
                configuration.providerConfiguration = settings
                manager.protocolConfiguration = configuration
                manager.localizedDescription = "CC Switch 应用出站代理"
                manager.isEnabled = true
                let rule = NEOnDemandRuleConnect()
                rule.interfaceTypeMatch = .any
                manager.onDemandRules = [rule]
                manager.isOnDemandEnabled = true
                try await manager.saveToPreferences()
                try await manager.loadFromPreferences()
                guard (manager.protocolConfiguration as? NETunnelProviderProtocol)?
                    .providerConfiguration?["applicationPaths"] as? [String] == policy.paths else {
                    throw NSError(domain: "AppEgress", code: 42,
                                  userInfo: [NSLocalizedDescriptionKey: "系统没有保存完整的应用配置，启用已停止"])
                }
                try manager.connection.startVPNTunnel()
                for _ in 0..<200 {
                    if manager.connection.status == .connected { break }
                    try await Task.sleep(for: .milliseconds(50))
                }
                guard manager.connection.status == .connected else {
                    throw NSError(domain: "NetworkProbe", code: 35,
                                  userInfo: [NSLocalizedDescriptionKey: "代理尚未启动，连接保护继续保持启用"])
                }
                emit(["status": "protected", "applicationPaths": policy.paths])
            case "disable-protection":
                let managers = try await transparentManagers()
                for manager in managers { try await manager.removeFromPreferences() }
                let filter = NEFilterManager.shared()
                try await filter.loadFromPreferences()
                if filter.providerConfiguration != nil { try await filter.removeFromPreferences() }
                emit(["status": "disabled"])
            case "refresh-filter":
                let manager = NEFilterManager.shared()
                try await manager.loadFromPreferences()
                if manager.isEnabled {
                    guard let configuration = manager.providerConfiguration,
                          configuration.filterDataProviderBundleIdentifier == providerIdentifier else {
                        throw NSError(domain: "NetworkProbe", code: 54,
                                      userInfo: [NSLocalizedDescriptionKey: "连接保护配置与当前扩展不匹配"])
                    }
                    manager.providerConfiguration = configuration
                    try await manager.saveToPreferences()
                }
                emit(["status": "filter_refreshed", "enabled": manager.isEnabled])
            case "configure-filter":
                let manager = NEFilterManager.shared()
                try await manager.loadFromPreferences()
                let configuration = NEFilterProviderConfiguration()
                configuration.filterSockets = true
                configuration.filterPackets = false
                configuration.filterDataProviderBundleIdentifier = providerIdentifier
                manager.providerConfiguration = configuration
                manager.localizedDescription = "CC Switch 测试应用连接限制"
                manager.isEnabled = true
                try await manager.saveToPreferences()
                emit(["status": "filter_configured", "target": "com.ccswitch.egress-client-probe"])
            case "filter-status":
                let manager = NEFilterManager.shared()
                try await manager.loadFromPreferences()
                emit(["status": "filter_preferences", "enabled": manager.isEnabled])
            case "start-installed":
                let managers = try await NEAppProxyProviderManager.loadAllFromPreferences()
                guard managers.count == 1,
                      (managers[0].protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == providerIdentifier else {
                    throw NSError(domain: "AppEgress", code: 45,
                                  userInfo: [NSLocalizedDescriptionKey: "需要唯一的已安装应用代理配置"])
                }
                try managers[0].connection.startVPNTunnel()
                emit(["status": "start_requested"])
            case "apply-test-rule":
                let managers = try await NEAppProxyProviderManager.loadAllFromPreferences()
                guard managers.count == 1,
                      let configuration = managers[0].protocolConfiguration as? NETunnelProviderProtocol,
                      configuration.providerBundleIdentifier == providerIdentifier,
                      (configuration.providerConfiguration?["applicationPaths"] as? [String] ?? []).isEmpty else {
                    throw NSError(domain: "AppEgress", code: 46,
                                  userInfo: [NSLocalizedDescriptionKey: "配置必须仅包含测试应用"])
                }
                let rules = try ApplicationPolicy(configuration: nil).appRules()
                managers[0].appRules = rules
                managers[0].isEnabled = true
                managers[0].isOnDemandEnabled = true
                managers[0].onDemandRules = [NEOnDemandRuleConnect()]
                try await managers[0].saveToPreferences()
                try await managers[0].loadFromPreferences()
                emit(["status": "rules_saved", "rules": (managers[0].copyAppRules() ?? []).map {
                    ["identifier": $0.matchSigningIdentifier, "path": $0.matchPath ?? ""]
                }])
            case "remove-filter":
                let manager = NEFilterManager.shared()
                try await manager.loadFromPreferences()
                try await manager.removeFromPreferences()
                emit(["status": "filter_removed"])
            case "status":
                let managers = try await NEAppProxyProviderManager.loadAllFromPreferences()
                emit(["status": "preferences", "managers": managers.map {
                    ["enabled": $0.isEnabled, "connection": $0.connection.status.rawValue,
                     "routingMethod": $0.routingMethod.rawValue, "appRuleCount": $0.appRules.count,
                     "copiedAppRuleCount": $0.copyAppRules()?.count ?? 0,
                     "mode": ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration?["probeMode"] ?? "unknown"] as [String: Any]
                }])
            case "configure":
                let existing = try await NEAppProxyProviderManager.loadAllFromPreferences()
                guard existing.count <= 1 else {
                    throw NSError(domain: "NetworkProbe", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: "存在多个测试配置"])
                }
                let manager = existing.first ?? NEAppProxyProviderManager.forPerAppVPN()
                let configuration = NETunnelProviderProtocol()
                configuration.providerBundleIdentifier = providerIdentifier
                configuration.serverAddress = "127.0.0.1"
                configuration.providerConfiguration = ["probeMode": "deny"]
                if CommandLine.arguments.count == 3 {
                    let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
                    guard let settings = try JSONSerialization.jsonObject(with: data) as? [String: String],
                          let mode = settings["probeMode"], ["deny", "proxy"].contains(mode) else {
                        throw NSError(domain: "NetworkProbe", code: 15,
                                      userInfo: [NSLocalizedDescriptionKey: "测试配置无效"])
                    }
                    configuration.providerConfiguration = settings
                }
                manager.protocolConfiguration = configuration
                manager.appRules = try ApplicationPolicy(configuration: configuration.providerConfiguration).appRules()
                manager.localizedDescription = "CC Switch 网络隔离验证"
                manager.isEnabled = true
                let rule = NEOnDemandRuleConnect()
                rule.interfaceTypeMatch = .any
                manager.onDemandRules = [rule]
                manager.isOnDemandEnabled = true
                try await manager.saveToPreferences()
                try await manager.loadFromPreferences()
                guard !manager.appRules.isEmpty else {
                    throw NSError(domain: "AppEgress", code: 42,
                                  userInfo: [NSLocalizedDescriptionKey: "系统没有保存测试应用规则"])
                }
                try manager.connection.startVPNTunnel()
                emit(["status": "configured", "target": "com.ccswitch.egress-client-probe"])
            case "provider-status", "terminate-test-provider":
                let managers = try await NEAppProxyProviderManager.loadAllFromPreferences()
                guard managers.count == 1, let session = managers[0].connection as? NETunnelProviderSession else {
                    throw NSError(domain: "NetworkProbe", code: 16,
                                  userInfo: [NSLocalizedDescriptionKey: "测试扩展没有连接"])
                }
                let command = Data(CommandLine.arguments[1].utf8)
                let response: Data? = try await withCheckedThrowingContinuation { continuation in
                    do {
                        try session.sendProviderMessage(command) { data in continuation.resume(returning: data) }
                    } catch { continuation.resume(throwing: error) }
                }
                guard let response else {
                    throw NSError(domain: "NetworkProbe", code: 17,
                                  userInfo: [NSLocalizedDescriptionKey: "测试扩展没有响应"])
                }
                FileHandle.standardOutput.write(response)
                FileHandle.standardOutput.write(Data([10]))
            case "crash-test":
                let managers = try await transparentManagers()
                guard managers.count == 1,
                      let configuration = managers[0].protocolConfiguration as? NETunnelProviderProtocol,
                      (configuration.providerConfiguration?["applicationPaths"] as? [String] ?? [])
                        .allSatisfy({ ["/Applications/CCSwitchPathProbe.app", "/Applications/CCSwitchEgressProbe.app"].contains($0) }) else {
                    throw NSError(domain: "NetworkProbe", code: 18,
                                  userInfo: [NSLocalizedDescriptionKey: "缺少唯一测试配置"])
                }
                let manager = managers[0]
                manager.isOnDemandEnabled = false
                try await manager.saveToPreferences()
                manager.connection.stopVPNTunnel()
                for _ in 0..<100 {
                    if manager.connection.status == .disconnected { break }
                    try await Task.sleep(for: .milliseconds(50))
                }
                guard manager.connection.status == .disconnected else {
                    throw NSError(domain: "NetworkProbe", code: 19,
                                  userInfo: [NSLocalizedDescriptionKey: "测试扩展未停止"])
                }
                try manager.connection.startVPNTunnel(options: ["terminateTestProvider": NSNumber(value: true)])
                emit(["status": "termination_scheduled", "seconds_after_start": 4])
            case "stop", "remove":
                let managers = try await NEAppProxyProviderManager.loadAllFromPreferences()
                for manager in managers {
                    if CommandLine.arguments[1] == "remove" {
                        try await manager.removeFromPreferences()
                    } else {
                        manager.appRules = manager.copyAppRules() ?? []
                        manager.isOnDemandEnabled = false
                        try await manager.saveToPreferences()
                        manager.connection.stopVPNTunnel()
                    }
                }
                emit(["status": "completed", "operation": CommandLine.arguments[1]])
            default:
                throw NSError(domain: "NetworkProbe", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: "未知测试操作"])
            }
        } catch {
            let detail = error as NSError
            emit(["status": "failed", "domain": detail.domain, "code": detail.code,
                  "message": detail.localizedDescription])
            exit(1)
        }
    }

    static func transparentManagers() async throws -> [NETransparentProxyManager] {
        let managers = try await NETransparentProxyManager.loadAllFromPreferences()
        return managers.filter {
            guard let configuration = $0.protocolConfiguration as? NETunnelProviderProtocol else { return false }
            return configuration.providerBundleIdentifier == providerIdentifier
                && configuration.providerConfiguration?["transparentMode"] as? Bool == true
        }
    }

    static func waitForDisconnection(_ manager: NEVPNManager) async throws {
        for _ in 0..<200 {
            if [.invalid, .disconnected].contains(manager.connection.status) { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw NSError(domain: "NetworkProbe", code: 53,
                      userInfo: [NSLocalizedDescriptionKey: "透明代理测试连接未停止"])
    }
}
