import Foundation
import NetworkExtension
import Network
import OSLog

final class ProxyReadiness: @unchecked Sendable {
    static let shared = ProxyReadiness()
    private let lock = NSLock()
    private var value = false

    var isReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func update(_ ready: Bool) {
        lock.lock()
        value = ready
        lock.unlock()
    }
}

@objc(AppEgressTransparentProbeProvider)
final class AppEgressTransparentProbeProvider: NETransparentProxyProvider {
    private let queue = DispatchQueue(label: "com.ccswitch.network-probe.flows")
    private let logger = Logger(subsystem: "com.ccswitch.network-probe", category: "flows")
    private var upstream: Upstream?
    private var proxyEndpoint: Network.NWEndpoint?
    private var gateway: ChainGateway?
    private var flows: [UUID: ManagedFlow] = [:]
    private var denied = 0
    private var tcp = 0
    private var udp = 0
    private var dnsQueries = 0
    private var policy = try! ApplicationPolicy(configuration: nil)
    private var loopbackPorts: Set<UInt16> = []
    override func startProxy(options: [String: Any]? = nil,
                             completionHandler: @escaping (Error?) -> Void) {
        ProxyReadiness.shared.update(false)
        guard let configuration = protocolConfiguration as? NETunnelProviderProtocol,
              configuration.providerConfiguration?["transparentMode"] as? Bool == true,
              let mode = configuration.providerConfiguration?["probeMode"] as? String,
              ["deny", "proxy"].contains(mode) else {
            completionHandler(NSError(domain: "NetworkProbe", code: 4,
                userInfo: [NSLocalizedDescriptionKey: "缺少测试配置，禁止启动"])); return
        }
        do {
            policy = try ApplicationPolicy(configuration: configuration.providerConfiguration)
            loopbackPorts = Set((configuration.providerConfiguration?["loopbackPorts"] as? [UInt16]) ?? [])
            if mode == "proxy" {
                guard let url = configuration.providerConfiguration?["upstream"] as? String else {
                    throw NSError(domain: "NetworkProbe", code: 14,
                                  userInfo: [NSLocalizedDescriptionKey: "缺少代理地址"])
                }
                proxyEndpoint = try Upstream(url: url).endpoint
                let gateway = try ChainGateway(configuration: configuration.providerConfiguration!)
                upstream = try Upstream(url: "http://127.0.0.1:\(gateway.port)")
                self.gateway = gateway
            }
            let settings = NETransparentProxyNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
            settings.includedNetworkRules = [NENetworkRule(
                remoteNetworkEndpoint: nil, remotePrefix: 0, localNetworkEndpoint: nil, localPrefix: 0,
                protocol: .any, direction: .outbound)]
            if options?["terminateTestProvider"] as? Bool == true {
                queue.asyncAfter(deadline: .now() + 4) {
                    self.logger.notice("验证扩展异常终止后的连接限制")
                    exit(86)
                }
            }
            setTunnelNetworkSettings(settings) { error in
                ProxyReadiness.shared.update(error == nil)
                completionHandler(error)
            }
        } catch { completionHandler(error) }
    }

    override func stopProxy(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        ProxyReadiness.shared.update(false)
        queue.async {
            for flow in Array(self.flows.values) { flow.cancel(URLError(.cancelled)) }
            self.upstream = nil
            self.gateway = nil
            completionHandler()
        }
    }

    override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
        guard policy.includes(token: flow.metaData.sourceAppAuditToken,
                              signingIdentifier: flow.metaData.sourceAppSigningIdentifier) else {
            return false
        }
        let signingIdentifier = flow.metaData.sourceAppSigningIdentifier
        let hostname = flow.remoteHostname ?? ""
        let filterIdentifier = flow.metaData.filterFlowIdentifier?.uuidString ?? ""
        logger.debug("接管应用 flow，type=\(String(describing: type(of: flow)), privacy: .public)，signingIdentifier=\(signingIdentifier, privacy: .public)，remoteHostname=\(hostname, privacy: .private)，filterFlowIdentifier=\(filterIdentifier, privacy: .public)")
        var localModelConnection = false
        if let tcpFlow = flow as? NEAppProxyTCPFlow,
           case .hostPort(let host, let port) = tcpFlow.remoteFlowEndpoint,
           ["127.0.0.1", "::1"].contains(String(describing: host)),
           loopbackPorts.contains(port.rawValue) { localModelConnection = true }
        guard let upstream else {
            queue.async { self.denied += 1 }
            flow.closeReadWithError(URLError(.notConnectedToInternet))
            flow.closeWriteWithError(URLError(.notConnectedToInternet))
            return true
        }
        let identifier = UUID()
        let completed = { self.flows.removeValue(forKey: identifier); () }
        let relay: ManagedFlow
        if let flow = flow as? NEAppProxyTCPFlow {
            relay = TCPRelay(flow: flow, upstream: localModelConnection ? nil : upstream,
                             proxyEndpoint: proxyEndpoint,
                             queue: queue, completed: completed)
            queue.async { self.tcp += 1 }
        } else if let flow = flow as? NEAppProxyUDPFlow {
            relay = DNSRelay(flow: flow, upstream: upstream, queue: queue, completed: completed,
                             onQuery: {
                self.dnsQueries += 1
                self.logger.debug("转发应用 DNS 查询，count=\(self.dnsQueries, privacy: .public)，remoteHostname=\(hostname, privacy: .private)，filterFlowIdentifier=\(filterIdentifier, privacy: .public)")
            })
            queue.async { self.udp += 1 }
        } else {
            queue.async { self.denied += 1 }
            flow.closeReadWithError(URLError(.unsupportedURL))
            flow.closeWriteWithError(URLError(.unsupportedURL))
            return true
        }
        queue.async {
            self.flows[identifier] = relay
            relay.start()
        }
        return true
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        guard let command = String(data: messageData, encoding: .utf8) else {
            completionHandler?(nil); return
        }
        queue.async {
            let status: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier,
                "active": self.flows.count, "denied": self.denied, "tcp": self.tcp, "udp": self.udp,
                "dnsQueries": self.dnsQueries, "transparentMode": true]
            completionHandler?(try! JSONSerialization.data(withJSONObject: status, options: [.sortedKeys]))
            if command == "terminate-test-provider" {
                self.logger.notice("验证扩展异常终止后的连接限制")
                self.queue.asyncAfter(deadline: .now() + 0.3) { exit(86) }
            }
        }
    }
}

@main
struct ProviderMain {
    static func main() {
        NEProvider.startSystemExtensionMode()
        dispatchMain()
    }
}
