import Foundation
import Network
import NetworkExtension

protocol ManagedFlow: AnyObject {
    func start()
    func cancel(_ error: Error?)
}

final class TCPRelay: ManagedFlow {
    private let flow: NEAppProxyTCPFlow
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let completed: () -> Void
    private var closed = false
    private var readingEnded = false
    private var writingEnded = false
    private var opened = false

    init(flow: NEAppProxyTCPFlow, upstream: Upstream?, proxyEndpoint: Network.NWEndpoint? = nil, queue: DispatchQueue,
         completed: @escaping () -> Void) {
        self.flow = flow
        self.queue = queue
        self.completed = completed
        var endpoint = flow.remoteFlowEndpoint
        if upstream != nil, endpoint != proxyEndpoint, let hostname = flow.remoteHostname, !hostname.isEmpty,
           case .hostPort(_, let port) = endpoint, port.rawValue != 53 {
            endpoint = .hostPort(host: .name(hostname, nil), port: port)
        }
        connection = NWConnection(to: endpoint, using: upstream?.parameters() ?? .tcp)
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, !closed else { return }
            switch state {
            case .ready:
                guard !opened else { return }
                opened = true
                flow.open(withLocalFlowEndpoint: nil) { error in
                    self.queue.async {
                        if let error { self.cancel(error); return }
                        self.readApplication()
                        self.readUpstream()
                    }
                }
            case .failed(let error), .waiting(let error): cancel(error)
            case .cancelled: cancel(nil)
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, !opened else { return }
            cancel(URLError(.timedOut))
        }
    }

    private func readApplication() {
        guard !closed else { return }
        flow.readData { data, error in
            self.queue.async {
                guard !self.closed else { return }
                if let error { self.cancel(error); return }
                guard let data else { self.cancel(URLError(.networkConnectionLost)); return }
                if data.isEmpty {
                    self.readingEnded = true
                    self.connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { error in
                            if let error { self.cancel(error) }
                            else if self.writingEnded { self.cancel(nil) }
                        })
                    return
                }
                self.connection.send(content: data, completion: .contentProcessed { error in
                    if let error { self.cancel(error) } else { self.readApplication() }
                })
            }
        }
    }

    private func readUpstream() {
        guard !closed else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, ended, error in
            if let error { self.cancel(error); return }
            let continueReading: (Error?) -> Void = { error in
                self.queue.async {
                    guard !self.closed else { return }
                    if let error { self.cancel(error); return }
                    if ended {
                        self.writingEnded = true
                        self.flow.closeWriteWithError(nil)
                        if self.readingEnded { self.cancel(nil) }
                    } else { self.readUpstream() }
                }
            }
            if let data, !data.isEmpty { self.flow.write(data, withCompletionHandler: continueReading) }
            else { continueReading(nil) }
        }
    }

    func cancel(_ error: Error?) {
        guard !closed else { return }
        closed = true
        connection.stateUpdateHandler = nil
        connection.cancel()
        flow.closeReadWithError(error)
        flow.closeWriteWithError(error)
        completed()
    }
}

final class DNSRelay: ManagedFlow {
    private let flow: NEAppProxyUDPFlow
    private let session: URLSession
    private let queue: DispatchQueue
    private let completed: () -> Void
    private let onQuery: () -> Void
    private var closed = false

    init(flow: NEAppProxyUDPFlow, upstream: Upstream, queue: DispatchQueue,
         completed: @escaping () -> Void, onQuery: @escaping () -> Void = {}) {
        self.flow = flow
        self.queue = queue
        self.completed = completed
        self.onQuery = onQuery
        let configuration = URLSessionConfiguration.ephemeral
        configuration.proxyConfigurations = [upstream.proxy]
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }

    func start() {
        flow.open(withLocalFlowEndpoint: nil) { error in
            self.queue.async {
                if let error { self.cancel(error) } else { self.read() }
            }
        }
    }

    private func read() {
        guard !closed else { return }
        flow.readDatagrams { datagrams, error in
            self.queue.async {
                if let error { self.cancel(error); return }
                guard let datagrams, !datagrams.isEmpty else { self.cancel(nil); return }
                for (data, endpoint) in datagrams {
                    guard case .hostPort(_, let port) = endpoint, port.rawValue == 53 else {
                        self.cancel(URLError(.unsupportedURL)); return
                    }
                    self.onQuery()
                    var request = URLRequest(url: URL(string: "https://1.1.1.1/dns-query")!)
                    request.httpMethod = "POST"
                    request.setValue("application/dns-message", forHTTPHeaderField: "Content-Type")
                    request.setValue("application/dns-message", forHTTPHeaderField: "Accept")
                    request.httpBody = data
                    self.session.dataTask(with: request) { responseData, response, error in
                        self.queue.async {
                            guard !self.closed else { return }
                            if let error { self.cancel(error); return }
                            guard let responseData, let response = response as? HTTPURLResponse,
                                  response.statusCode == 200,
                                  response.mimeType == "application/dns-message" else {
                                self.cancel(URLError(.badServerResponse)); return
                            }
                            self.flow.writeDatagrams([(responseData, endpoint)]) { error in
                                self.queue.async { if let error { self.cancel(error) } }
                            }
                        }
                    }.resume()
                }
                self.read()
            }
        }
    }

    func cancel(_ error: Error?) {
        guard !closed else { return }
        closed = true
        session.invalidateAndCancel()
        flow.closeReadWithError(error)
        flow.closeWriteWithError(error)
        completed()
    }
}
