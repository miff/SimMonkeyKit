//
//  Bridge.swift
//  SimMonkeyKit
//
//  Created by Milan Djordjevic on 6. 9. 2026..
//  https://miff.me

import Foundation
import Network

/// Talks to the panel.
///
/// Deliberately uses `Network.framework` rather than URLSession: this call
/// happens *inside* a URLProtocol, and any URLSession use here risks
/// re-entering the interceptor. NWConnection shares nothing with URLSession.
enum Bridge {
    
    /// Built before the swizzle runs, so its configuration snapshot never
    /// contains SimMonkeyURLProtocol.
    private(set) static var passthroughSession = URLSession(configuration: .default)
    
    static func buildPassthroughSession() {
        // .default, deliberately not .ephemeral. An ephemeral configuration gets
        // its own private cookie jar, so a session cookie established anywhere
        // else — at login, by another URLSession, restored from a previous
        // launch — is invisible to the forwarded request. The server then
        // answers 401 with an empty body and the app looks broken, which is
        // exactly what this tool must never do.
        let configuration = URLSessionConfiguration.default
        configuration.protocolClasses = []
        configuration.httpCookieStorage = HTTPCookieStorage.shared
        configuration.httpShouldSetCookies = true
        // A delegate, not a completion handler: a completion handler only fires
        // when the response *ends*, which for a radio stream or an SSE endpoint
        // is never. The delegate hands bytes to the app as they arrive.
        passthroughSession = URLSession(configuration: configuration,
                                        delegate: PassthroughDelegate.shared,
                                        delegateQueue: nil)
    }
    
    // MARK: panel availability
    
    private enum Reachability {
        case unknown
        case up
        case down(until: Date)
    }
    
    private static let stateLock = NSLock()
    private static var state = Reachability.unknown
    
    /// Only contended while the panel's state is unknown; once it is known to be
    /// up, requests run fully concurrently again.
    private static let probeGate = NSLock()
    
    /// How long to stop dialling after a refused connection. Long enough that a
    /// screenful of requests costs one failed connect instead of twenty, short
    /// enough that starting the panel mid-session is picked up almost at once.
    private static let retryDelay: TimeInterval = 3
    
    /// Resolves the expiry, so recovery needs no signal from anywhere.
    private static var reachability: Reachability {
        stateLock.lock()
        defer { stateLock.unlock() }
        if case .down(let until) = state, Date() >= until {
            state = .unknown
        }
        return state
    }
    
    private static func noteUnreachable() {
        stateLock.lock()
        state = .down(until: Date().addingTimeInterval(retryDelay))
        stateLock.unlock()
    }
    
    private static func noteReachable() {
        stateLock.lock()
        state = .up
        stateLock.unlock()
    }
    
    /// Blocking HTTP POST. Returns the response body, or nil on any failure —
    /// callers treat nil as "pass the request through untouched".
    static func post(path: String, body: Data, timeout: TimeInterval) -> Data? {
        switch reachability {
        case .down:
            // No socket gets created, which is the entire point: creating one is
            // what writes "Connection refused" into the app's console.
            return nil
            
        case .up:
            return attempt(path: path, body: body, timeout: timeout)
            
        case .unknown:
            // Let one request find out while the others wait. They arrive in
            // parallel, so without this a screen that fires twenty requests
            // dials a dead port twenty times before any of them learns it is
            // dead — which is exactly what the log noise was.
            probeGate.lock()
            defer { probeGate.unlock() }
            if case .down = reachability { return nil }
            return attempt(path: path, body: body, timeout: timeout)
        }
    }
    
    private static func attempt(path: String, body: Data, timeout: TimeInterval) -> Data? {
        let host = NWEndpoint.Host("127.0.0.1")
        guard let port = NWEndpoint.Port(rawValue: SimMonkey.port) else { return nil }
        
        let connection = NWConnection(host: host, port: port, using: .tcp)
        let queue = DispatchQueue(label: "simmonkey.bridge")
        let done = DispatchSemaphore(value: 0)
        
        var received = Data()
        var failed = false
        
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                var request = Data("POST \(path) HTTP/1.1\r\n".utf8)
                request.append(Data("Host: 127.0.0.1\r\n".utf8))
                request.append(Data("Content-Type: application/json\r\n".utf8))
                request.append(Data("Content-Length: \(body.count)\r\n".utf8))
                request.append(Data("Connection: close\r\n\r\n".utf8))
                request.append(body)
                
                connection.send(content: request, completion: .contentProcessed { error in
                    if error != nil { failed = true; done.signal(); return }
                    receive(connection, into: { received.append($0) }) {
                        done.signal()
                    }
                })
            case .waiting, .failed, .cancelled:
                // The panel is on loopback: if the port isn't open right now,
                // waiting for it to turn up only stalls the app under test.
                // NWConnection reports a refused connection as .waiting because
                // it intends to retry, so treat that as a miss and fail open
                // immediately — otherwise every request costs the full timeout.
                failed = true
                done.signal()
            default:
                break
            }
        }
        
        connection.start(queue: queue)
        let outcome = done.wait(timeout: .now() + timeout)
        connection.cancel()
        
        guard outcome == .success, !failed else {
            noteUnreachable()
            return nil
        }
        // Reached it — a malformed reply is the panel's problem, not the
        // socket's, so availability is judged on the connection alone.
        noteReachable()
        return httpBody(of: received)
    }
    
    private static func receive(_ connection: NWConnection,
                                into append: @escaping (Data) -> Void,
                                finished: @escaping () -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
            if let data, !data.isEmpty { append(data) }
            if isComplete || error != nil {
                finished()
            } else {
                receive(connection, into: append, finished: finished)
            }
        }
    }
    
    private static func httpBody(of response: Data) -> Data? {
        guard let separator = response.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        return response[separator.upperBound...]
    }
}


/// Routes streamed passthrough callbacks back to the URLProtocol that started
/// them. One shared delegate for the session, keyed by task identifier.
final class PassthroughDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let shared = PassthroughDelegate()
    
    private let lock = NSLock()
    private var inFlight: [Int: SimMonkeyURLProtocol] = [:]
    
    func register(_ handler: SimMonkeyURLProtocol, for task: URLSessionTask) {
        lock.lock(); inFlight[task.taskIdentifier] = handler; lock.unlock()
    }
    
    private func handler(for task: URLSessionTask) -> SimMonkeyURLProtocol? {
        lock.lock(); defer { lock.unlock() }
        return inFlight[task.taskIdentifier]
    }
    
    /// Always paired with `didCompleteWithError`, which fires for cancellation
    /// too, so nothing is left in the table.
    private func finish(_ task: URLSessionTask) -> SimMonkeyURLProtocol? {
        lock.lock(); defer { lock.unlock() }
        return inFlight.removeValue(forKey: task.taskIdentifier)
    }
    
    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        handler(for: dataTask)?.passthroughReceived(response)
        completionHandler(.allow)
    }
    
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        handler(for: dataTask)?.passthroughReceived(data)
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish(task)?.passthroughFinished(error)
    }
}
