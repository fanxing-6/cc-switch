import Foundation

final class ChainGateway {
    let port: UInt16
    private let handle: UnsafeMutableRawPointer

    init(configuration: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: configuration)
        let text = String(data: data, encoding: .utf8)!
        var port: UInt16 = 0
        guard let handle = text.withCString({ ccs_gateway_start($0, &port) }) else {
            throw NSError(domain: "AppEgress", code: 40,
                          userInfo: [NSLocalizedDescriptionKey: "代理链启动失败，请检查代理地址"])
        }
        self.handle = handle
        self.port = port
    }

    deinit { ccs_gateway_stop(handle) }
}
