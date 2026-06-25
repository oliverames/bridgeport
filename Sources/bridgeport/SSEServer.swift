import Foundation
import FlyingFox
import FlyingSocks

// Conform an AsyncStream to AsyncBufferedSequence so that FlyingFox can stream the HTTP body response.
public struct StreamSequence: AsyncBufferedSequence, Sendable {
    public typealias Element = UInt8
    public typealias AsyncIterator = Iterator
    
    private let stream: AsyncStream<UInt8>
    
    public init(stream: AsyncStream<UInt8>) {
        self.stream = stream
    }
    
    public func makeAsyncIterator() -> Iterator {
        Iterator(iterator: stream.makeAsyncIterator())
    }
    
    public struct Iterator: AsyncBufferedIteratorProtocol, @unchecked Sendable {
        public typealias Element = UInt8
        public typealias Buffer = [UInt8]
        
        private var iterator: AsyncStream<UInt8>.Iterator
        
        public init(iterator: AsyncStream<UInt8>.Iterator) {
            self.iterator = iterator
        }
        
        public mutating func next() async -> UInt8? {
            await iterator.next()
        }
        
        public mutating func nextBuffer(suggested count: Int) async throws -> [UInt8]? {
            guard count > 0 else { return [] }
            guard let first = await iterator.next() else { return nil }
            return [first]
        }
    }
}

public actor Session {
    public nonisolated let id: String
    public nonisolated let connectorName: String
    private let bridge: ProcessBridge
    private let continuation: AsyncStream<UInt8>.Continuation
    
    public init(id: String, connectorName: String, bridge: ProcessBridge, continuation: AsyncStream<UInt8>.Continuation) {
        self.id = id
        self.connectorName = connectorName
        self.bridge = bridge
        self.continuation = continuation
    }
    
    public func writeToSSE(_ event: String) {
        guard let data = event.data(using: .utf8) else { return }
        for byte in data {
            continuation.yield(byte)
        }
    }
    
    public func writeToSubprocess(_ message: String) async {
        logMessage("Session.writeToSubprocess: entering, calling bridge.write")
        await bridge.write(message)
        logMessage("Session.writeToSubprocess: bridge.write returned")
    }
    
    public func close() async {
        continuation.finish()
        await bridge.stop()
    }
}

public actor SSEServer {
    private let port: UInt16
    private let token: String
    private let manager: ConnectorManager
    private let disabledConnectors: [String]
    private var server: HTTPServer?
    private var sessions: [String: Session] = [:] // Session ID -> Session
    private var connectorBridges: [String: ProcessBridge] = [:] // Connector Name -> active ProcessBridge
    
    public init(port: UInt16, token: String, manager: ConnectorManager, disabledConnectors: [String] = []) {
        self.port = port
        self.token = token
        self.manager = manager
        self.disabledConnectors = disabledConnectors
    }
    
    public func start() async throws {
        let server = HTTPServer(port: port)
        self.server = server
        
        var handler = RoutedHTTPHandler()
        
        // SSE route: GET /:connector/sse
        handler.appendRoute("GET /:connector/sse") { [weak self] request in
            logMessage("GET /:connector/sse requested")
            guard let self = self else {
                return HTTPResponse(statusCode: .internalServerError)
            }
            
            // 1. Auth check
            guard await self.isAuthorized(request) else {
                logMessage("GET /:connector/sse unauthorized request")
                return HTTPResponse(statusCode: .unauthorized, body: "Unauthorized\n".data(using: .utf8)!)
            }
            logMessage("GET /:connector/sse auth passed")
            
            guard let connectorName = request.routeParameters["connector"] else {
                logMessage("GET /:connector/sse missing connector parameter")
                return HTTPResponse(statusCode: .badRequest, body: "Missing connector parameter\n".data(using: .utf8)!)
            }
            
            // 2. Discover connector
            let connectors = await self.manager.discoverConnectors()
            guard let connector = connectors.first(where: { $0.name == connectorName }) else {
                logMessage("GET /:connector/sse connector '\(connectorName)' not found")
                return HTTPResponse(statusCode: .notFound, body: "Connector '\(connectorName)' not found\n".data(using: .utf8)!)
            }
            
            if self.disabledConnectors.contains(connectorName) {
                logMessage("GET /:connector/sse connector '\(connectorName)' is disabled")
                return HTTPResponse(statusCode: .notFound, body: "Connector '\(connectorName)' is disabled\n".data(using: .utf8)!)
            }
            
            print("Client connecting to SSE for '\(connectorName)'")
            logMessage("GET /:connector/sse starting connection for \(connectorName)")
            
            // 3. Set up SSE stream
            let sessionId = UUID().uuidString.lowercased()
            logMessage("GET /:connector/sse session ID generated: \(sessionId)")
            
            let (stream, continuation) = AsyncStream<UInt8>.makeStream()
            
            // Yield connection endpoints immediately (standard MCP SSE handshake)
            let endpointEvent = "event: endpoint\ndata: /\(connectorName)/message?sessionId=\(sessionId)\n\n"
            guard let endpointData = endpointEvent.data(using: .utf8) else {
                return HTTPResponse(statusCode: .internalServerError)
            }
            for byte in endpointData {
                continuation.yield(byte)
            }
            
            // 4. Resolve environment and spawn subprocess bridge
            let resolvedEnv = await self.manager.resolveEnvironment(for: connector)
            let bridge = ProcessBridge(connector: connector, env: resolvedEnv)
            
            let session = Session(id: sessionId, connectorName: connectorName, bridge: bridge, continuation: continuation)
            await self.registerSession(id: sessionId, session: session)
            
            do {
                try await bridge.start(
                    onMessage: { @Sendable msg in
                        let sseEvent = "event: message\ndata: \(msg)\n\n"
                        Task {
                            logMessage("SSEServer onMessage: sending message \(msg)")
                            await session.writeToSSE(sseEvent)
                        }
                    },
                    onExit: { @Sendable in
                        print("Subprocess for '\(connectorName)' exited")
                        Task {
                            await session.close()
                            await self.removeSession(id: sessionId)
                        }
                    }
                )
            } catch {
                print("Failed to start process bridge: \(error)")
                continuation.finish()
                return HTTPResponse(statusCode: .internalServerError, body: "Failed to start process bridge\n".data(using: .utf8)!)
            }
            
            // Clean up when client disconnects
            continuation.onTermination = { @Sendable termination in
                print("SSE stream for '\(connectorName)' (session: \(sessionId)) closed")
                Task {
                    await session.close()
                    await self.removeSession(id: sessionId)
                }
            }
            
            let streamSequence = StreamSequence(stream: stream)
            let bodySequence = HTTPBodySequence(from: streamSequence)
            
            return HTTPResponse(
                statusCode: .ok,
                headers: [
                    .contentType: "text/event-stream",
                    HTTPHeader("Cache-Control"): "no-cache",
                    HTTPHeader("Connection"): "keep-alive"
                ],
                body: bodySequence
            )
        }
        
        // POST message route: POST /:connector/message
        handler.appendRoute("POST /:connector/message") { [weak self] request in
            logMessage("POST /:connector/message requested")
            guard let self = self else {
                return HTTPResponse(statusCode: .internalServerError)
            }
            
            // 1. Auth check
            guard await self.isAuthorized(request) else {
                logMessage("POST /:connector/message unauthorized request")
                return HTTPResponse(statusCode: .unauthorized, body: "Unauthorized\n".data(using: .utf8)!)
            }
            logMessage("POST /:connector/message auth passed")
            
            // Extract sessionId from query params
            let sessionId = request.query.first(where: { $0.name == "sessionId" })?.value
            guard let sessionVal = sessionId, !sessionVal.isEmpty else {
                logMessage("POST /:connector/message missing sessionId parameter")
                return HTTPResponse(statusCode: .badRequest, body: "Missing sessionId parameter\n".data(using: .utf8)!)
            }
            
            guard let session = await self.getSession(id: sessionVal) else {
                logMessage("POST /:connector/message session '\(sessionVal)' not found")
                return HTTPResponse(statusCode: .notFound, body: "Session '\(sessionVal)' not found\n".data(using: .utf8)!)
            }
            logMessage("POST /:connector/message session found: \(sessionVal)")
            
            do {
                logMessage("POST /:connector/message reading bodyData...")
                let bodyData = try await request.bodyData
                logMessage("POST /:connector/message read bodyData size: \(bodyData.count) bytes")
                if let bodyString = String(data: bodyData, encoding: .utf8) {
                    logMessage("POST /:connector/message writing to subprocess...")
                    await session.writeToSubprocess(bodyString)
                    logMessage("POST /:connector/message wrote to subprocess successfully")
                }
                logMessage("POST /:connector/message returning 200 OK")
                return HTTPResponse(statusCode: .ok)
            } catch {
                logMessage("POST /:connector/message error: \(error)")
                return HTTPResponse(statusCode: .internalServerError, body: "Failed to read request body\n".data(using: .utf8)!)
            }
        }
        
        // POST webhook route: POST /:connector/webhook
        handler.appendRoute("POST /:connector/webhook") { [weak self] request in
            logMessage("POST /:connector/webhook requested")
            guard let self = self else {
                return HTTPResponse(statusCode: .internalServerError)
            }
            
            // 1. Auth check
            guard await self.isAuthorized(request) else {
                logMessage("POST /:connector/webhook unauthorized request")
                return HTTPResponse(statusCode: .unauthorized, body: "Unauthorized\n".data(using: .utf8)!)
            }
            logMessage("POST /:connector/webhook auth passed")
            
            guard let connectorName = request.routeParameters["connector"] else {
                logMessage("POST /:connector/webhook missing connector parameter")
                return HTTPResponse(statusCode: .badRequest, body: "Missing connector parameter\n".data(using: .utf8)!)
            }
            
            do {
                let bodyData = try await request.bodyData
                let bodyString = String(data: bodyData, encoding: .utf8) ?? ""
                logMessage("POST /:connector/webhook body size: \(bodyData.count) bytes")
                
                await self.broadcastWebhook(connectorName: connectorName, payload: bodyString)
                
                return HTTPResponse(statusCode: .ok, body: "Webhook broadcasted\n".data(using: .utf8)!)
            } catch {
                logMessage("POST /:connector/webhook error: \(error)")
                return HTTPResponse(statusCode: .internalServerError, body: "Failed to read request body\n".data(using: .utf8)!)
            }
        }
        
        // Catch-all route to prevent crashing/unmatched requests
        handler.appendRoute("*") { _ in
            return HTTPResponse(statusCode: .notFound, body: "Not Found\n".data(using: .utf8)!)
        }
        
        await server.appendRoute("*", to: handler)
        print("Bridgeport Server starting on port \(port)...")
        try await server.run()
    }
    
    private func isAuthorized(_ request: HTTPRequest) -> Bool {
        // Check Authorization header
        if let authHeader = request.headers[.authorization] {
            if authHeader == "Bearer \(token)" {
                return true
            }
        }
        
        // Check token query parameter
        if let queryToken = request.query.first(where: { $0.name == "token" })?.value {
            if queryToken == token {
                return true
            }
        }
        
        return false
    }
    
    private func registerSession(id: String, session: Session) {
        sessions[id] = session
    }
    
    private func removeSession(id: String) {
        sessions.removeValue(forKey: id)
    }
    
    private func getSession(id: String) -> Session? {
        sessions[id]
    }
    
    public func broadcastWebhook(connectorName: String, payload: String) async {
        logMessage("SSEServer.broadcastWebhook: Broadcasting webhook for '\(connectorName)'")
        
        let payloadObj: Any
        if let data = payload.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data, options: []) {
            payloadObj = json
        } else {
            payloadObj = payload
        }
        
        let notification: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "notifications/webhook",
            "params": [
                "connector": connectorName,
                "payload": payloadObj
            ]
        ]
        
        guard let data = try? JSONSerialization.data(withJSONObject: notification, options: []),
              let jsonStr = String(data: data, encoding: .utf8) else {
            logMessage("SSEServer.broadcastWebhook: Failed to serialize JSON-RPC notification")
            return
        }
        
        let sseEvent = "event: message\ndata: \(jsonStr)\n\n"
        
        var count = 0
        for session in sessions.values {
            if session.connectorName == connectorName {
                await session.writeToSSE(sseEvent)
                count += 1
            }
        }
        logMessage("SSEServer.broadcastWebhook: Sent to \(count) sessions")
    }
}
