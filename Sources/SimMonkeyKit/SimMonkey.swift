//
//  SimMonkey.swift
//  SimMonkeyKit
//
//  Created by Milan Djordjevic on 6. 9. 2026..
//  https://miff.me

import Foundation
import ObjectiveC.runtime

/// Debug-only network stubbing client.
///
/// Add the package, then in your `App` init:
/// ```swift
/// #if DEBUG
/// SimMonkey.start()
/// #endif
/// ```
public enum SimMonkey {
    
    /// Set before `start()` if the panel is listening somewhere else.
    public static var port: UInt16 = 8377

    /// Printed in the attach line. When a copy of this package drifts behind
    /// the panel, this is how you find out — see CHANGELOG.md.
    public static let version = "1.0.0"
    
    private static var started = false
    
    /// Installs the interceptor. Safe to call more than once.
    public static func start(port: UInt16 = 8377) {
        guard !started else { return }
        started = true
        Self.port = port
        
        // Built BEFORE the swizzle, so its configuration snapshot can never
        // contain our protocol. Forwarded requests cannot re-enter.
        Bridge.buildPassthroughSession()
        
        swizzleProtocolClasses()
        URLProtocol.registerClass(SimMonkeyURLProtocol.self)
        
        NSLog("[simmonkey] \(version) attached — panel at 127.0.0.1:\(port)")
    }
    
    /// `URLProtocol.registerClass` alone does nothing for URLSession: a session
    /// reads its protocol list off the configuration, so the getter on the
    /// configuration is what has to change.
    private static func swizzleProtocolClasses() {
        let target: AnyClass? = NSClassFromString("__NSCFURLSessionConfiguration")
        ?? NSClassFromString("NSURLSessionConfiguration")
        guard let cls = target,
              let method = class_getInstanceMethod(cls, #selector(getter: URLSessionConfiguration.protocolClasses))
        else {
            NSLog("[simmonkey] could not swizzle protocolClasses — URLSession traffic will not be intercepted")
            return
        }
        
        typealias Getter = @convention(c) (AnyObject, Selector) -> [AnyClass]?
        let original = unsafeBitCast(method_getImplementation(method), to: Getter.self)
        let selector = #selector(getter: URLSessionConfiguration.protocolClasses)
        
        let replacement: @convention(block) (AnyObject) -> [AnyClass] = { receiver in
            let existing = original(receiver, selector) ?? []
            var classes: [AnyClass] = [SimMonkeyURLProtocol.self]
            classes.append(contentsOf: existing.filter { $0 != SimMonkeyURLProtocol.self })
            return classes
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
    }
}

// MARK: - Interceptor

final class SimMonkeyURLProtocol: URLProtocol {
    private static let handledKey = "SimMonkeyHandled"
    private static let queue = DispatchQueue(label: "simmonkey.protocol", attributes: .concurrent)
    
    private var forwardTask: URLSessionDataTask?
    private var traceID: String?
    
    // Streamed passthrough bookkeeping. Touched on the session's serial
    // delegate queue, plus `startedAt` before the task is resumed.
    private var startedAt = Date()
    private var responseStatus = 0
    private var receivedBytes = 0
    private var responseHeaders: [String: String] = [:]
    /// Reports are posted on a concurrent queue, so a streamed response's two
    /// reports can arrive in either order. This lets the panel drop a stale one
    /// instead of letting it overwrite the finished figures.
    private var reportSeq = 0
    private var capturedBody = Data()
    private var bodyTruncated = false
    
    /// Enough of a body to read in the panel, bounded so an endless response
    /// can't grow this forever — playing a radio station would otherwise buffer
    /// the whole broadcast just to fill a detail pane.
    ///
    /// Sized to swallow a real payload whole rather than to be frugal: a
    /// truncated JSON body is a body the tree view cannot parse at all, which
    /// makes the inspector useless on exactly the responses worth inspecting.
    /// The panel drops bodies from older entries to keep the total bounded.
    private static let bodyCaptureLimit = 512 * 1024
    
    /// Written by `stopLoading` on URLSession's thread and read on the resolve
    /// queue after the injected delay, so it cannot be a plain Bool — a stale
    /// read there would deliver a response to an already-cancelled request.
    private let stateLock = NSLock()
    private var _stopped = false
    private var stopped: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _stopped }
        set { stateLock.lock(); _stopped = newValue; stateLock.unlock() }
    }
    
    override class func canInit(with request: URLRequest) -> Bool {
        if URLProtocol.property(forKey: handledKey, in: request) != nil { return false }
        guard let scheme = request.url?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }
    
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    
    override class func requestIsCacheEquivalent(_ a: URLRequest, to b: URLRequest) -> Bool { false }
    
    override func startLoading() {
        let request = self.request
        Self.queue.async { [weak self] in self?.resolve(request) }
    }
    
    override func stopLoading() {
        stopped = true
        forwardTask?.cancel()
    }
    
    private func resolve(_ request: URLRequest) {
        let body = Self.requestBody(request)
        
        let payload: [String: Any] = [
            "method": request.httpMethod ?? "GET",
            "url": request.url?.absoluteString ?? "",
            "headers": Self.reportableHeaders(request),
            "body": body?.base64EncodedString() ?? ""
        ]
        
        var plan: [String: Any]?
        if let encoded = try? JSONSerialization.data(withJSONObject: payload),
           let reply = Bridge.post(path: "/resolve", body: encoded, timeout: 2),
           let parsed = try? JSONSerialization.jsonObject(with: reply) as? [String: Any] {
            plan = parsed
        }
        
        // Panel closed, socket refused, garbage reply: never break the app.
        guard let plan else { return forward(request, body: body) }
        
        traceID = plan["traceId"] as? String
        
        if let delay = plan["delayMs"] as? Int, delay > 0 {
            Thread.sleep(forTimeInterval: Double(delay) / 1000)
        }
        guard !stopped else { return }
        
        switch plan["action"] as? String {
        case "stub":
            let status = plan["status"] as? Int ?? 200
            let data = (plan["body"] as? String).flatMap { Data(base64Encoded: $0) } ?? Data()
            var headers = plan["headers"] as? [String: String] ?? [:]
            headers["Content-Length"] = headers["Content-Length"] ?? "\(data.count)"
            
            guard let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: status,
                                                 httpVersion: "HTTP/1.1", headerFields: headers) else {
                return forward(request, body: body)
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !data.isEmpty { client?.urlProtocol(self, didLoad: data) }
            client?.urlProtocolDidFinishLoading(self)
            
        case "fail":
            let code = plan["failCode"] as? Int ?? NSURLErrorNotConnectedToInternet
            let error = NSError(domain: NSURLErrorDomain, code: code, userInfo: [
                NSLocalizedDescriptionKey: "simmonkey simulated a network failure",
                NSURLErrorFailingURLErrorKey: request.url as Any
            ])
            client?.urlProtocol(self, didFailWithError: error)
            
        case "forward":
            // The rule wants the real server to answer, but with the request
            // changed on the way out. Anything not supplied keeps the original.
            var rewritten = request
            if let raw = plan["url"] as? String, let url = URL(string: raw) {
                rewritten.url = url
            }
            if let headers = plan["headers"] as? [String: String] {
                for (name, value) in headers {
                    rewritten.setValue(value, forHTTPHeaderField: name)
                }
            }
            forward(rewritten, body: body)
            
        default:
            forward(request, body: body)
        }
    }
    
    private func forward(_ request: URLRequest, body: Data?) {
        guard let mutable = (request as NSURLRequest).mutableCopy() as? NSMutableURLRequest else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        URLProtocol.setProperty(true, forKey: Self.handledKey, in: mutable)
        if let body {
            mutable.httpBodyStream = nil    // already drained
            mutable.httpBody = body
        }
        
        startedAt = Date()
        // No completion handler: bytes are relayed as they arrive, so endless
        // responses (radio streams, SSE, long-poll) play instead of hanging.
        let task = Bridge.passthroughSession.dataTask(with: mutable as URLRequest)
        forwardTask = task
        PassthroughDelegate.shared.register(self, for: task)
        task.resume()
    }
    
    // MARK: streamed passthrough
    
    func passthroughReceived(_ response: URLResponse) {
        guard !stopped else { return }
        if let http = response as? HTTPURLResponse {
            responseStatus = http.statusCode
            responseHeaders = http.allHeaderFields.reduce(into: [:]) { out, field in
                guard let name = field.key as? String else { return }
                out[name] = String(describing: field.value)
            }
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        // Report as soon as the headers land. A stream never finishes, and a row
        // stuck on "—" for the whole session is worse than a slightly early one.
        report(status: responseStatus,
               ms: Int(Date().timeIntervalSince(startedAt) * 1000),
               bytes: 0, error: nil, includeBody: false)
    }
    
    func passthroughReceived(_ data: Data) {
        guard !stopped else { return }
        receivedBytes += data.count
        if capturedBody.count < Self.bodyCaptureLimit {
            capturedBody.append(data.prefix(Self.bodyCaptureLimit - capturedBody.count))
            if receivedBytes > capturedBody.count { bodyTruncated = true }
        } else {
            bodyTruncated = true
        }
        client?.urlProtocol(self, didLoad: data)
    }
    
    func passthroughFinished(_ error: Error?) {
        report(status: responseStatus,
               ms: Int(Date().timeIntervalSince(startedAt) * 1000),
               bytes: receivedBytes, error: error, includeBody: true)
        guard !stopped else { return }
        if let error {
            client?.urlProtocol(self, didFailWithError: error)
        } else {
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    
    private func report(status: Int, ms: Int, bytes: Int, error: Error?, includeBody: Bool) {
        guard let traceID else { return }
        reportSeq += 1
        var payload: [String: Any] = [
            "traceId": traceID, "status": status, "ms": ms, "bytes": bytes,
            "error": error.map { ($0 as NSError).localizedDescription } ?? "",
            "responseHeaders": responseHeaders,
            "seq": reportSeq
        ]
        if includeBody {
            payload["responseBody"] = capturedBody.base64EncodedString()
            payload["responseBodyTruncated"] = bodyTruncated
        }
        guard let encoded = try? JSONSerialization.data(withJSONObject: payload) else { return }
        Self.queue.async { _ = Bridge.post(path: "/report", body: encoded, timeout: 1) }
    }
    
    /// The headers as they will actually go out.
    ///
    /// `allHTTPHeaderFields` only holds what the app set by hand — the URL
    /// loading system injects Cookie (and User-Agent, Accept-Encoding and
    /// friends) further down, well after a URLProtocol gets to look. Cookies
    /// are the one omission that matters when reading a capture, so they get
    /// reconstructed from the same storage the request will draw on.
    private static func reportableHeaders(_ request: URLRequest) -> [String: String] {
        var headers = request.allHTTPHeaderFields ?? [:]
        let hasCookie = headers.contains { $0.key.caseInsensitiveCompare("Cookie") == .orderedSame }
        guard request.httpShouldHandleCookies, !hasCookie, let url = request.url,
              let cookies = HTTPCookieStorage.shared.cookies(for: url), !cookies.isEmpty
        else { return headers }
        
        for (name, value) in HTTPCookie.requestHeaderFields(with: cookies) {
            headers[name] = value
        }
        return headers
    }
    
    /// URLSession normally hands you a stream rather than `httpBody`. Draining it
    /// consumes it, so the bytes are put back on the forwarded copy.
    private static func requestBody(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        
        var data = Data()
        stream.open()
        defer { stream.close() }
        let size = 8192
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: size)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data.isEmpty ? nil : data
    }
}
