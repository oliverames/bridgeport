import Foundation
import FlyingFox
import FlyingSocks

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

public struct RuntimeStatus: Codable, Sendable {
    public struct ConnectorRuntimeStatus: Codable, Sendable {
        public let name: String
        public let enabled: Bool
        public let activeSessions: Int
        public let publicURL: String
        public let localURL: String
        public let sourceKind: String
        public let sourcePath: String
    }

    public let activeSessions: Int
    public let sessionsByConnector: [String: Int]
    public let connectors: [ConnectorRuntimeStatus]
}

public actor BridgeSession {
    public nonisolated let id: String
    public nonisolated let connectorName: String

    private let bridge: ProcessBridge
    private var streams: [String: AsyncStream<UInt8>.Continuation] = [:]
    private var responseStreams: [String: AsyncStream<UInt8>.Continuation] = [:]
    private var onClose: (@Sendable () -> Void)?
    private var isClosed = false

    public init(id: String, connectorName: String, bridge: ProcessBridge) {
        self.id = id
        self.connectorName = connectorName
        self.bridge = bridge
    }

    public func start(onClose: @escaping @Sendable () -> Void) async throws {
        self.onClose = onClose
        try await bridge.start(
            onMessage: { @Sendable [weak self] message in
                Task {
                    await self?.routeMessage(message)
                }
            },
            onExit: { @Sendable [weak self] in
                Task {
                    await self?.close(callOnClose: true)
                }
            }
        )
    }

    public func addPersistentStream(initialEvents: [String] = []) -> (String, AsyncStream<UInt8>) {
        let streamId = UUID().uuidString.lowercased()
        let (stream, continuation) = AsyncStream<UInt8>.makeStream()
        streams[streamId] = continuation
        continuation.onTermination = { @Sendable [weak self] _ in
            Task {
                await self?.removePersistentStream(id: streamId)
            }
        }
        for event in initialEvents {
            write(event, to: continuation)
        }
        return (streamId, stream)
    }

    public func removePersistentStream(id: String) {
        if let continuation = streams.removeValue(forKey: id) {
            continuation.finish()
        }
    }

    public func responseStream(for requestId: String) -> AsyncStream<UInt8> {
        let (stream, continuation) = AsyncStream<UInt8>.makeStream()
        responseStreams[requestId] = continuation
        continuation.onTermination = { @Sendable [weak self] _ in
            Task {
                await self?.removeResponseStream(id: requestId)
            }
        }
        return stream
    }

    public func sendNotification(_ message: String) {
        let event = Self.sseMessageEvent(message)
        for continuation in streams.values {
            write(event, to: continuation)
        }
    }

    public func writeToSubprocess(_ message: String) async {
        await bridge.write(message)
    }

    public func close(callOnClose: Bool = true) async {
        guard !isClosed else { return }
        isClosed = true

        for continuation in streams.values {
            continuation.finish()
        }
        streams.removeAll()

        for continuation in responseStreams.values {
            continuation.finish()
        }
        responseStreams.removeAll()

        await bridge.stop()
        if callOnClose {
            onClose?()
        }
    }

    private func removeResponseStream(id: String) {
        responseStreams.removeValue(forKey: id)
    }

    private func routeMessage(_ message: String) {
        let event = Self.sseMessageEvent(message)
        if let requestId = Self.jsonRPCID(from: message),
           let continuation = responseStreams.removeValue(forKey: requestId) {
            write(event, to: continuation)
            continuation.finish()
            return
        }

        for continuation in streams.values {
            write(event, to: continuation)
        }
    }

    private func write(_ event: String, to continuation: AsyncStream<UInt8>.Continuation) {
        guard let data = event.data(using: .utf8) else { return }
        for byte in data {
            continuation.yield(byte)
        }
    }

    public static func sseMessageEvent(_ message: String) -> String {
        "event: message\ndata: \(message)\n\n"
    }

    public static func jsonRPCID(from message: String) -> String? {
        guard let data = message.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"] else {
            return nil
        }
        return String(describing: id)
    }
}

public actor SSEServer {
    private let config: BridgeportConfig
    private let manager: ConnectorManager
    private var server: HTTPServer?
    private var sessions: [String: BridgeSession] = [:]

    public init(config: BridgeportConfig, manager: ConnectorManager) {
        self.config = config
        self.manager = manager
    }

    public init(port: UInt16, token: String, manager: ConnectorManager, disabledConnectors: [String] = []) {
        self.config = BridgeportConfig(
            token: token,
            port: port,
            bindHost: "127.0.0.1",
            allowedOrigins: ConfigManager.defaultAllowedOrigins(port: port, publicBaseURL: nil),
            allowQueryTokenAuth: false,
            connectorSettings: ConfigManager.settingsFromLegacyDisabled(disabledConnectors),
            disabledConnectors: disabledConnectors
        )
        self.manager = manager
    }

    public func start() async throws {
        let port = config.port ?? 8080
        let bindHost = config.bindHost ?? "127.0.0.1"
        let server = try makeHTTPServer(bindHost: bindHost, port: port)
        self.server = server

        var handler = RoutedHTTPHandler()

        handler.appendRoute("GET /status") { [weak self] request in
            guard let self else { return HTTPResponse(statusCode: .internalServerError) }
            guard await self.isAuthorized(request) else { return Self.unauthorizedResponse() }
            return await self.statusResponse()
        }

        handler.appendRoute("GET /:connector/sse") { [weak self] request in
            guard let self else { return HTTPResponse(statusCode: .internalServerError) }
            guard await self.isRequestAllowed(request) else { return Self.textResponse(.forbidden, "Forbidden\n") }
            guard await self.isAuthorized(request) else { return Self.unauthorizedResponse() }
            return await self.openLegacySSE(request)
        }

        handler.appendRoute("POST /:connector/message") { [weak self] request in
            guard let self else { return HTTPResponse(statusCode: .internalServerError) }
            guard await self.isRequestAllowed(request) else { return Self.textResponse(.forbidden, "Forbidden\n") }
            guard await self.isAuthorized(request) else { return Self.unauthorizedResponse() }
            return await self.postLegacyMessage(request)
        }

        handler.appendRoute("GET /:connector/mcp") { [weak self] request in
            guard let self else { return HTTPResponse(statusCode: .internalServerError) }
            guard await self.isRequestAllowed(request) else { return Self.textResponse(.forbidden, "Forbidden\n") }
            guard await self.isAuthorized(request) else { return Self.unauthorizedResponse() }
            return await self.openStreamableHTTP(request)
        }

        handler.appendRoute("GET /mcp/:connector") { [weak self] request in
            guard let self else { return HTTPResponse(statusCode: .internalServerError) }
            guard await self.isRequestAllowed(request) else { return Self.textResponse(.forbidden, "Forbidden\n") }
            guard await self.isAuthorized(request) else { return Self.unauthorizedResponse() }
            return await self.openStreamableHTTP(request)
        }

        handler.appendRoute("POST /:connector/mcp") { [weak self] request in
            guard let self else { return HTTPResponse(statusCode: .internalServerError) }
            guard await self.isRequestAllowed(request) else { return Self.textResponse(.forbidden, "Forbidden\n") }
            guard await self.isAuthorized(request) else { return Self.unauthorizedResponse() }
            return await self.postStreamableHTTP(request)
        }

        handler.appendRoute("POST /mcp/:connector") { [weak self] request in
            guard let self else { return HTTPResponse(statusCode: .internalServerError) }
            guard await self.isRequestAllowed(request) else { return Self.textResponse(.forbidden, "Forbidden\n") }
            guard await self.isAuthorized(request) else { return Self.unauthorizedResponse() }
            return await self.postStreamableHTTP(request)
        }

        handler.appendRoute("DELETE /:connector/mcp") { [weak self] request in
            guard let self else { return HTTPResponse(statusCode: .internalServerError) }
            guard await self.isRequestAllowed(request) else { return Self.textResponse(.forbidden, "Forbidden\n") }
            guard await self.isAuthorized(request) else { return Self.unauthorizedResponse() }
            return await self.deleteStreamableHTTPSession(request)
        }

        handler.appendRoute("DELETE /mcp/:connector") { [weak self] request in
            guard let self else { return HTTPResponse(statusCode: .internalServerError) }
            guard await self.isRequestAllowed(request) else { return Self.textResponse(.forbidden, "Forbidden\n") }
            guard await self.isAuthorized(request) else { return Self.unauthorizedResponse() }
            return await self.deleteStreamableHTTPSession(request)
        }

        handler.appendRoute("POST /:connector/webhook") { [weak self] request in
            guard let self else { return HTTPResponse(statusCode: .internalServerError) }
            guard await self.isRequestAllowed(request) else { return Self.textResponse(.forbidden, "Forbidden\n") }
            guard await self.isAuthorized(request) else { return Self.unauthorizedResponse() }
            return await self.postWebhook(request)
        }

        handler.appendRoute("*") { _ in
            Self.textResponse(.notFound, "Not Found\n")
        }

        await server.appendRoute("*", to: handler)
        logMessage("Bridgeport Server starting on \(bindHost):\(port)")
        try await server.run()
    }

    private func makeHTTPServer(bindHost: String, port: UInt16) throws -> HTTPServer {
        if bindHost == "127.0.0.1" || bindHost == "localhost" {
            return HTTPServer(address: try sockaddr_in.inet(ip4: "127.0.0.1", port: port))
        }
        if bindHost == "::1" {
            return HTTPServer(address: sockaddr_in6.loopback(port: port))
        }
        if bindHost == "0.0.0.0" {
            return HTTPServer(address: sockaddr_in.inet(port: port))
        }
        if bindHost.contains(":") {
            return HTTPServer(address: try sockaddr_in6.inet6(ip6: bindHost, port: port))
        }
        return HTTPServer(address: try sockaddr_in.inet(ip4: bindHost, port: port))
    }

    private func openLegacySSE(_ request: HTTPRequest) async -> HTTPResponse {
        guard let connector = await connector(for: request) else {
            return Self.textResponse(.notFound, "Connector not found\n")
        }

        do {
            let session = try await makeSession(for: connector)
            let endpointEvent = "event: endpoint\ndata: /\(config.publicRoutePath(for: connector))/message?sessionId=\(session.id)\n\n"
            let (_, stream) = await session.addPersistentStream(initialEvents: [endpointEvent])
            registerSession(session)

            return sseResponse(stream: stream, sessionId: session.id)
        } catch {
            logMessage("SSEServer: Failed to open legacy SSE for \(connector.name): \(error)")
            return Self.textResponse(.internalServerError, "Failed to start connector\n")
        }
    }

    private func postLegacyMessage(_ request: HTTPRequest) async -> HTTPResponse {
        guard let sessionId = request.query.first(where: { $0.name == "sessionId" })?.value,
              !sessionId.isEmpty else {
            return Self.textResponse(.badRequest, "Missing sessionId parameter\n")
        }

        guard let session = sessions[sessionId] else {
            return Self.textResponse(.notFound, "Session not found\n")
        }

        do {
            let bodyData = try await request.bodyData
            guard let bodyString = String(data: bodyData, encoding: .utf8) else {
                return Self.textResponse(.badRequest, "Invalid UTF-8 body\n")
            }
            await session.writeToSubprocess(bodyString)
            return HTTPResponse(statusCode: .accepted)
        } catch {
            return Self.textResponse(.internalServerError, "Failed to read request body\n")
        }
    }

    private func openStreamableHTTP(_ request: HTTPRequest) async -> HTTPResponse {
        guard let connector = await connector(for: request) else {
            return Self.textResponse(.notFound, "Connector not found\n")
        }

        do {
            let session: BridgeSession
            if let existingSession = sessionFromHeader(request) {
                session = existingSession
            } else {
                session = try await makeSession(for: connector)
            }
            registerSession(session)
            let (_, stream) = await session.addPersistentStream()
            return sseResponse(stream: stream, sessionId: session.id)
        } catch {
            logMessage("SSEServer: Failed to open streamable HTTP for \(connector.name): \(error)")
            return Self.textResponse(.internalServerError, "Failed to start connector\n")
        }
    }

    private func postStreamableHTTP(_ request: HTTPRequest) async -> HTTPResponse {
        guard let connector = await connector(for: request) else {
            return Self.textResponse(.notFound, "Connector not found\n")
        }

        do {
            let bodyData = try await request.bodyData
            guard let bodyString = String(data: bodyData, encoding: .utf8) else {
                return Self.textResponse(.badRequest, "Invalid UTF-8 body\n")
            }

            let session: BridgeSession
            if let existingSession = sessionFromHeader(request) {
                session = existingSession
            } else {
                session = try await makeSession(for: connector)
            }
            registerSession(session)

            guard let requestId = Self.jsonRPCID(from: bodyString) else {
                await session.writeToSubprocess(bodyString)
                var headers = HTTPHeaders()
                headers[Self.sessionHeader] = session.id
                return HTTPResponse(statusCode: .accepted, headers: headers)
            }

            let responseStream = await session.responseStream(for: requestId)
            await session.writeToSubprocess(bodyString)
            return sseResponse(stream: responseStream, sessionId: session.id)
        } catch {
            logMessage("SSEServer: Streamable HTTP POST failed: \(error)")
            return Self.textResponse(.internalServerError, "Failed to process message\n")
        }
    }

    private func deleteStreamableHTTPSession(_ request: HTTPRequest) async -> HTTPResponse {
        guard let sessionId = request.headers[Self.sessionHeader],
              let session = sessions[sessionId] else {
            return Self.textResponse(.notFound, "Session not found\n")
        }
        await session.close()
        sessions.removeValue(forKey: sessionId)
        return HTTPResponse(statusCode: .accepted)
    }

    private func postWebhook(_ request: HTTPRequest) async -> HTTPResponse {
        guard let connector = await connector(for: request) else {
            return Self.textResponse(.notFound, "Connector not found\n")
        }

        do {
            let bodyData = try await request.bodyData
            let bodyString = String(data: bodyData, encoding: .utf8) ?? ""
            await broadcastWebhook(connectorName: connector.name, payload: bodyString)
            return Self.textResponse(.accepted, "Webhook broadcasted\n")
        } catch {
            return Self.textResponse(.internalServerError, "Failed to read request body\n")
        }
    }

    private func statusResponse() async -> HTTPResponse {
        let connectors = await manager.discoverConnectors()
        let grouped = Dictionary(grouping: sessions.values, by: { $0.connectorName })
        let sessionsByConnector = grouped.mapValues(\.count)
        let port = config.port ?? 8080
        let baseURL = ConfigManager.clientEndpointBaseURL(port: port, publicBaseURL: config.publicBaseURL)
        let hasPublicBaseURL = config.publicBaseURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false

        let connectorStatuses = connectors.map { connector in
            let settings = config.settings(for: connector.name)
            let publicURL = settings.exposePublicly && hasPublicBaseURL
                ? ConfigManager.mcpEndpointURL(baseURL: baseURL, routePath: config.publicRoutePath(for: connector))
                : ""

            return RuntimeStatus.ConnectorRuntimeStatus(
                name: connector.name,
                enabled: settings.enabled,
                activeSessions: sessionsByConnector[connector.name] ?? 0,
                publicURL: publicURL,
                localURL: ConfigManager.mcpEndpointURL(baseURL: "http://localhost:\(port)", routePath: config.publicRoutePath(for: connector)),
                sourceKind: connector.sourceKind.rawValue,
                sourcePath: connector.configPath
            )
        }

        let status = RuntimeStatus(
            activeSessions: sessions.count,
            sessionsByConnector: sessionsByConnector,
            connectors: connectorStatuses
        )

        do {
            let data = try JSONEncoder().encode(status)
            return HTTPResponse(statusCode: .ok, headers: [.contentType: "application/json"], body: data)
        } catch {
            return Self.textResponse(.internalServerError, "Failed to encode status\n")
        }
    }

    private func registerSession(_ session: BridgeSession) {
        sessions[session.id] = session
    }

    private func removeSession(id: String) {
        sessions.removeValue(forKey: id)
    }

    private func makeSession(for connector: Connector) async throws -> BridgeSession {
        let resolvedEnv = await manager.resolveEnvironment(for: connector)
        let bridge = ProcessBridge(connector: connector, env: resolvedEnv)
        let session = BridgeSession(id: UUID().uuidString.lowercased(), connectorName: connector.name, bridge: bridge)
        try await session.start(onClose: { [weak self, id = session.id] in
            Task {
                await self?.removeSession(id: id)
            }
        })
        return session
    }

    private func sessionFromHeader(_ request: HTTPRequest) -> BridgeSession? {
        guard let sessionId = request.headers[Self.sessionHeader], !sessionId.isEmpty else {
            return nil
        }
        return sessions[sessionId]
    }

    private func connector(for request: HTTPRequest) async -> Connector? {
        guard let routeName = request.routeParameters["connector"] else { return nil }
        let connectors = await manager.discoverConnectors()
        return connectors.first { connector in
            connector.name == routeName || config.publicRoutePath(for: connector) == routeName
        }.flatMap { connector in
            config.settings(for: connector.name).enabled ? connector : nil
        }
    }

    private func sseResponse(stream: AsyncStream<UInt8>, sessionId: String) -> HTTPResponse {
        HTTPResponse(
            statusCode: .ok,
            headers: [
                .contentType: "text/event-stream",
                HTTPHeader("Cache-Control"): "no-cache",
                HTTPHeader("Connection"): "keep-alive",
                Self.sessionHeader: sessionId
            ],
            body: HTTPBodySequence(from: StreamSequence(stream: stream))
        )
    }

    private func isRequestAllowed(_ request: HTTPRequest) -> Bool {
        guard let origin = request.headers[Self.originHeader], !origin.isEmpty else {
            return true
        }
        let allowedOrigins = Set(config.allowedOrigins ?? [])
        return allowedOrigins.contains(origin)
    }

    private func isAuthorized(_ request: HTTPRequest) -> Bool {
        let token = config.token ?? ""
        guard !token.isEmpty else { return false }

        if let authHeader = request.headers[.authorization],
           authHeader == "Bearer \(token)" {
            return true
        }

        if config.allowQueryTokenAuth == true,
           let queryToken = request.query.first(where: { $0.name == "token" })?.value,
           queryToken == token {
            return true
        }

        return false
    }

    public func broadcastWebhook(connectorName: String, payload: String) async {
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

        var count = 0
        for session in sessions.values where session.connectorName == connectorName {
            await session.sendNotification(jsonStr)
            count += 1
        }
        logMessage("SSEServer.broadcastWebhook: Sent to \(count) sessions")
    }

    public static func jsonRPCID(from message: String) -> String? {
        BridgeSession.jsonRPCID(from: message)
    }

    private static func textResponse(_ statusCode: HTTPStatusCode, _ text: String) -> HTTPResponse {
        HTTPResponse(statusCode: statusCode, headers: [.contentType: "text/plain"], body: Data(text.utf8))
    }

    private static func unauthorizedResponse() -> HTTPResponse {
        var headers = HTTPHeaders()
        headers[.contentType] = "text/plain"
        headers[HTTPHeader("WWW-Authenticate")] = "Bearer realm=\"Bridgeport\""
        return HTTPResponse(statusCode: .unauthorized, headers: headers, body: Data("Unauthorized\n".utf8))
    }

    private static let sessionHeader = HTTPHeader("Mcp-Session-Id")
    private static let originHeader = HTTPHeader("Origin")
}
