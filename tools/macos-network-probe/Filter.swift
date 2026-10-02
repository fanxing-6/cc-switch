import Foundation
import NetworkExtension
import OSLog

@objc(AppEgressProbeFilter)
final class AppEgressProbeFilter: NEFilterDataProvider {
    private let logger = Logger(subsystem: "com.ccswitch.network-probe", category: "filter")
    private var policy = try! ApplicationPolicy(configuration: nil)
    private let policyLock = NSLock()

    override func startFilter(completionHandler: @escaping (Error?) -> Void) {
        do { policy = try ApplicationPolicy(configuration: filterConfiguration.vendorConfiguration) }
        catch { completionHandler(error); return }
        apply(NEFilterSettings(rules: [], defaultAction: .filterData), completionHandler: completionHandler)
    }

    override func handleNewFlow(_ flow: NEFilterFlow) -> NEFilterNewFlowVerdict {
        policyLock.lock()
        let configuration = filterConfiguration.vendorConfiguration
        let paths = configuration?["applicationPaths"] as? [String] ?? []
        if paths != policy.paths {
            do {
                policy = try ApplicationPolicy(configuration: configuration)
                logger.notice("连接保护应用名单已更新，count=\(paths.count, privacy: .public)")
            } catch {
                policyLock.unlock()
                logger.fault("连接保护配置无效，拒绝连接")
                return .drop()
            }
        }
        let currentPolicy = policy
        policyLock.unlock()
        if ProxyReadiness.shared.isReady { return .allow() }
        if currentPolicy.includes(token: flow.sourceAppAuditToken) {
            logger.notice("阻断受保护应用直接连接，flow=\(flow.identifier.uuidString, privacy: .public)")
            return .drop()
        }
        return .allow()
    }
}
