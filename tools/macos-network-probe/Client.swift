import Foundation
import Network
import Darwin

@main
struct Client {
    static func main() async throws {
        guard CommandLine.arguments.count >= 3,
              let target = URL(string: CommandLine.arguments[2]) else {
            throw NSError(domain: "NetworkProbe", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "需要结果路径和测试 URL"])
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 10
        configuration.urlCache = nil
        if target.scheme != "dns", CommandLine.arguments.count == 4 {
            let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]))
            let settings = try JSONSerialization.jsonObject(with: data) as! [String: String]
            configuration.proxyConfigurations = [try Upstream(url: settings["upstream"]!).proxy]
        }
        let session = URLSession(configuration: configuration)
        let started = Date()
        var result: [String: Any] = ["url": target.absoluteString, "pid": ProcessInfo.processInfo.processIdentifier]
        result["client_build"] = "5"
        do {
            if target.scheme == "resolve" {
                guard let host = target.host else { throw URLError(.badURL) }
                var addresses: UnsafeMutablePointer<addrinfo>?
                let status = getaddrinfo(host, nil, nil, &addresses)
                guard status == 0 else {
                    throw NSError(domain: "getaddrinfo", code: Int(status),
                                  userInfo: [NSLocalizedDescriptionKey: String(cString: gai_strerror(status))])
                }
                defer { freeaddrinfo(addresses) }
                var current = addresses
                var numericAddresses: Set<String> = []
                while let address = current {
                    var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    let status = getnameinfo(address.pointee.ai_addr, address.pointee.ai_addrlen,
                                             &name, socklen_t(name.count), nil, 0, NI_NUMERICHOST)
                    guard status == 0 else { throw URLError(.cannotParseResponse) }
                    numericAddresses.insert(String(cString: name))
                    current = address.pointee.ai_next
                }
                result["addresses"] = numericAddresses.sorted()
            } else if target.scheme == "wss" {
                let socket = session.webSocketTask(with: target)
                socket.resume()
                let message = "ccswitch-live-validation-" + UUID().uuidString
                try await socket.send(.string(message))
                let response = try await socket.receive()
                guard case .string(let echo) = response, echo == message else {
                    throw URLError(.badServerResponse)
                }
                result["echo_matches"] = true
                socket.cancel(with: .normalClosure, reason: nil)
            } else if target.scheme == "dns" {
                guard CommandLine.arguments.count == 4, let host = target.host else {
                    throw URLError(.badURL)
                }
                let query = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]))
                let connection = NWConnection(host: .init(host), port: 53, using: .udp)
                let response = try await exchange(connection: connection, data: query)
                result["response_base64"] = response.base64EncodedString()
            } else {
                let (data, response) = try await session.data(from: target)
                result["http_status"] = (response as? HTTPURLResponse)?.statusCode
                result["received_bytes"] = data.count
                result["response_base64"] = data.base64EncodedString()
            }
            result["connected"] = true
        } catch {
            let detail = error as NSError
            result["connected"] = false
            result["error_domain"] = detail.domain
            result["error_code"] = detail.code
            result["error_message"] = detail.localizedDescription
        }
        result["elapsed_seconds"] = Date().timeIntervalSince(started)
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted])
        try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
        session.invalidateAndCancel()
    }

    static func exchange(connection: NWConnection, data: Data) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let queue = DispatchQueue(label: "com.ccswitch.egress-client-probe.udp")
            var finished = false
            let finish: (Result<Data, Error>) -> Void = { result in
                guard !finished else { return }
                finished = true
                connection.stateUpdateHandler = nil
                connection.cancel()
                continuation.resume(with: result)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: data, completion: .contentProcessed { error in
                        if let error { finish(.failure(error)); return }
                        connection.receiveMessage { response, _, _, error in
                            if let error { finish(.failure(error)) }
                            else if let response { finish(.success(response)) }
                            else { finish(.failure(URLError(.badServerResponse))) }
                        }
                    })
                case .failed(let error), .waiting(let error): finish(.failure(error))
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 10) { finish(.failure(URLError(.timedOut))) }
        }
    }
}
