import Foundation
import Network

struct Upstream {
    let proxy: ProxyConfiguration
    let endpoint: NWEndpoint
    let supportsDatagrams: Bool

    init(url: String) throws {
        guard let components = URLComponents(string: url),
              let scheme = components.scheme,
              let host = components.host,
              let port = components.port.flatMap({ UInt16(exactly: $0) }), port > 0,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/" else {
            throw NSError(domain: "NetworkProbe", code: 10,
                          userInfo: [NSLocalizedDescriptionKey: "代理地址格式无效"])
        }
        let address = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        guard IPv4Address(address) != nil || IPv6Address(address) != nil else {
            throw NSError(domain: "NetworkProbe", code: 11,
                          userInfo: [NSLocalizedDescriptionKey: "代理服务器必须使用固定 IP"])
        }
        let endpoint = NWEndpoint.hostPort(host: .init(address), port: .init(rawValue: port)!)
        self.endpoint = endpoint
        var value: ProxyConfiguration
        switch scheme {
        case "http": value = ProxyConfiguration(httpCONNECTProxy: endpoint)
        case "https": value = ProxyConfiguration(httpCONNECTProxy: endpoint, tlsOptions: .init())
        case "socks5h": value = ProxyConfiguration(socksv5Proxy: endpoint)
        default:
            throw NSError(domain: "NetworkProbe", code: 12,
                          userInfo: [NSLocalizedDescriptionKey: "支持 HTTP、HTTPS 和 SOCKS5h 代理"])
        }
        value.allowFailover = false
        if let username = components.user {
            guard let password = components.password else {
                throw NSError(domain: "NetworkProbe", code: 13,
                              userInfo: [NSLocalizedDescriptionKey: "代理认证缺少密码"])
            }
            value.applyCredential(username: username, password: password)
        }
        proxy = value
        supportsDatagrams = scheme == "socks5h"
    }

    func parameters(datagram: Bool = false) -> NWParameters {
        let parameters = datagram ? NWParameters.udp : NWParameters.tcp
        let context = NWParameters.PrivacyContext(description: "CCSwitchAppEgress")
        context.proxyConfigurations = [proxy]
        parameters.setPrivacyContext(context)
        return parameters
    }
}
