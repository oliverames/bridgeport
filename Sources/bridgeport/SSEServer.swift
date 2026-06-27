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

private struct OAuthAuthorizationValidation: Sendable {
    let clientID: String
    let clientName: String
    let redirectURI: String
    let codeChallenge: String
    let state: String?
    let resource: String
}

public struct BridgeportIconMetadata: Sendable {
    public let src: String
    public let mimeType: String
    public let sizes: [String]

    public init(src: String, mimeType: String, sizes: [String] = []) {
        self.src = src
        self.mimeType = mimeType
        self.sizes = sizes
    }
}

private struct ConnectorIconAsset: Sendable {
    enum Source: Sendable {
        case file(URL)
        case redirect(URL)
        case data(Data)
    }

    let source: Source
    let mimeType: String
    let sizes: [String]
    let cacheKey: String
}

public actor BridgeSession {
    public nonisolated let id: String
    public nonisolated let connectorName: String

    private let bridge: ProcessBridge
    private let icon: BridgeportIconMetadata?
    private var streams: [String: AsyncStream<UInt8>.Continuation] = [:]
    private var responseStreams: [String: AsyncStream<UInt8>.Continuation] = [:]
    private var onClose: (@Sendable () -> Void)?
    private var isClosed = false

    public init(id: String, connectorName: String, bridge: ProcessBridge, icon: BridgeportIconMetadata? = nil) {
        self.id = id
        self.connectorName = connectorName
        self.bridge = bridge
        self.icon = icon
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
        let routedMessage = Self.messageWithBridgeportIconMetadata(message, icon: icon)
        let event = Self.sseMessageEvent(routedMessage)
        if let requestId = Self.jsonRPCID(from: routedMessage),
           let continuation = responseStreams.removeValue(forKey: requestId) {
            write(event, to: continuation)
            continuation.finish()
            return
        }

        for continuation in streams.values {
            write(event, to: continuation)
        }
    }

    public static func messageWithBridgeportIconMetadata(_ message: String, iconURL: String?) -> String {
        let icon = iconURL.map { BridgeportIconMetadata(src: $0, mimeType: "image/png", sizes: ["1024x1024"]) }
        return messageWithBridgeportIconMetadata(message, icon: icon)
    }

    public static func messageWithBridgeportIconMetadata(_ message: String, icon: BridgeportIconMetadata?) -> String {
        guard let icon,
              let data = message.data(using: .utf8),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var result = object["result"] as? [String: Any],
              var serverInfo = result["serverInfo"] as? [String: Any],
              serverInfo["icons"] == nil else {
            return message
        }

        let iconObject: [String: Any] = [
            "src": icon.src,
            "mimeType": icon.mimeType,
            "sizes": icon.sizes
        ]
        serverInfo["icons"] = [iconObject]
        serverInfo["iconUrl"] = iconObject["src"]
        result["serverInfo"] = serverInfo
        result["serverCardIconUrl"] = iconObject["src"]
        object["result"] = result

        guard let encoded = try? JSONSerialization.data(withJSONObject: object, options: []),
              let encodedString = String(data: encoded, encoding: .utf8) else {
            return message
        }

        return encodedString
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
    private let oauthStore: OAuthTokenStore
    private var server: HTTPServer?
    private var sessions: [String: BridgeSession] = [:]

    public init(config: BridgeportConfig, manager: ConnectorManager, oauthStore: OAuthTokenStore = OAuthTokenStore()) {
        self.config = config
        self.manager = manager
        self.oauthStore = oauthStore
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
        self.oauthStore = OAuthTokenStore()
    }

    public func start() async throws {
        let port = config.port ?? 8080
        let bindHost = config.bindHost ?? "127.0.0.1"
        let server = try makeHTTPServer(bindHost: bindHost, port: port)
        self.server = server

        var handler = RoutedHTTPHandler()

        handler.appendRoute("GET /.well-known/oauth-protected-resource") { [weak self] request in
            guard let self else { return HTTPResponse(statusCode: .internalServerError) }
            return await self.oauthProtectedResourceMetadataResponse(for: request)
        }

        handler.appendRoute("GET /.well-known/oauth-protected-resource/mcp/:connector") { [weak self] request in
            guard let self else { return HTTPResponse(statusCode: .internalServerError) }
            return await self.oauthProtectedResourceMetadataResponse(for: request)
        }

        handler.appendRoute("GET /.well-known/oauth-protected-resource/:connector/mcp") { [weak self] request in
            guard let self else { return HTTPResponse(statusCode: .internalServerError) }
            return await self.oauthProtectedResourceMetadataResponse(for: request)
        }

        handler.appendRoute("GET /.well-known/oauth-authorization-server") { [weak self] request in
            guard let self else { return HTTPResponse(statusCode: .internalServerError) }
            return await self.oauthAuthorizationServerMetadataResponse(for: request)
        }

        handler.appendRoute("OPTIONS /oauth/register") { [weak self] request in
            guard let self else { return HTTPResponse(statusCode: .internalServerError) }
            return await self.oauthPreflightResponse(for: request)
        }

        handler.appendRoute("OPTIONS /register") { [weak self] request in
            guard let self else { return HTTPResponse(statusCode: .internalServerError) }
            return await self.oauthPreflightResponse(for: request)
        }

        handler.appendRoute("POST /oauth/register") { [weak self] request in
            guard let self else { return HTTPResponse(statusCode: .internalServerError) }
            return await self.oauthRegisterClient(request)
        }

        handler.appendRoute("POST /register") { [weak self] request in
            guard let self else { return HTTPResponse(statusCode: .internalServerError) }
            return await self.oauthRegisterClient(request)
        }

        handler.appendRoute("OPTIONS /oauth/token") { [weak self] request in
            guard let self else { return HTTPResponse(statusCode: .internalServerError) }
            return await self.oauthPreflightResponse(for: request)
        }

        handler.appendRoute("OPTIONS /token") { [weak self] request in
            guard let self else { return HTTPResponse(statusCode: .internalServerError) }
            return await self.oauthPreflightResponse(for: request)
        }

        handler.appendRoute("POST /oauth/token") { [weak self] request in
            guard let self else { return HTTPResponse(statusCode: .internalServerError) }
            return await self.oauthToken(request)
        }

        handler.appendRoute("POST /token") { [weak self] request in
            guard let self else { return HTTPResponse(statusCode: .internalServerError) }
            return await self.oauthToken(request)
        }

        handler.appendRoute("GET /oauth/authorize") { [weak self] request in
            guard let self else { return HTTPResponse(statusCode: .internalServerError) }
            return await self.oauthAuthorizeForm(request)
        }

        handler.appendRoute("GET /authorize") { [weak self] request in
            guard let self else { return HTTPResponse(statusCode: .internalServerError) }
            return await self.oauthAuthorizeForm(request)
        }

        handler.appendRoute("POST /oauth/authorize") { [weak self] request in
            guard let self else { return HTTPResponse(statusCode: .internalServerError) }
            return await self.oauthApproveAuthorization(request)
        }

        handler.appendRoute("POST /authorize") { [weak self] request in
            guard let self else { return HTTPResponse(statusCode: .internalServerError) }
            return await self.oauthApproveAuthorization(request)
        }

        handler.appendRoute("GET /icons/:connector") { [weak self] request in
            guard let self else { return HTTPResponse(statusCode: .internalServerError) }
            return await self.connectorIconResponse(for: request)
        }

        handler.appendRoute("HEAD /icons/:connector") { [weak self] request in
            guard let self else { return HTTPResponse(statusCode: .internalServerError) }
            return await self.connectorIconResponse(for: request, includeBody: false)
        }

        handler.appendRoute("GET /status") { [weak self] request in
            guard let self else { return HTTPResponse(statusCode: .internalServerError) }
            guard await self.isAuthorized(request) else { return await self.unauthorizedResponse(for: request) }
            return await self.statusResponse()
        }

        handler.appendRoute("GET /:connector/sse") { [weak self] request in
            guard let self else { return HTTPResponse(statusCode: .internalServerError) }
            guard await self.isRequestAllowed(request) else { return Self.textResponse(.forbidden, "Forbidden\n") }
            guard await self.isAuthorized(request) else { return await self.unauthorizedResponse(for: request) }
            return await self.openLegacySSE(request)
        }

        handler.appendRoute("POST /:connector/message") { [weak self] request in
            guard let self else { return HTTPResponse(statusCode: .internalServerError) }
            guard await self.isRequestAllowed(request) else { return Self.textResponse(.forbidden, "Forbidden\n") }
            guard await self.isAuthorized(request) else { return await self.unauthorizedResponse(for: request) }
            return await self.postLegacyMessage(request)
        }

        handler.appendRoute("GET /:connector/mcp") { [weak self] request in
            guard let self else { return HTTPResponse(statusCode: .internalServerError) }
            guard await self.isRequestAllowed(request) else { return Self.textResponse(.forbidden, "Forbidden\n") }
            guard await self.isAuthorized(request) else { return await self.unauthorizedResponse(for: request) }
            return await self.openStreamableHTTP(request)
        }

        handler.appendRoute("GET /mcp/:connector") { [weak self] request in
            guard let self else { return HTTPResponse(statusCode: .internalServerError) }
            guard await self.isRequestAllowed(request) else { return Self.textResponse(.forbidden, "Forbidden\n") }
            guard await self.isAuthorized(request) else { return await self.unauthorizedResponse(for: request) }
            return await self.openStreamableHTTP(request)
        }

        handler.appendRoute("POST /:connector/mcp") { [weak self] request in
            guard let self else { return HTTPResponse(statusCode: .internalServerError) }
            guard await self.isRequestAllowed(request) else { return Self.textResponse(.forbidden, "Forbidden\n") }
            guard await self.isAuthorized(request) else { return await self.unauthorizedResponse(for: request) }
            return await self.postStreamableHTTP(request)
        }

        handler.appendRoute("POST /mcp/:connector") { [weak self] request in
            guard let self else { return HTTPResponse(statusCode: .internalServerError) }
            guard await self.isRequestAllowed(request) else { return Self.textResponse(.forbidden, "Forbidden\n") }
            guard await self.isAuthorized(request) else { return await self.unauthorizedResponse(for: request) }
            return await self.postStreamableHTTP(request)
        }

        handler.appendRoute("DELETE /:connector/mcp") { [weak self] request in
            guard let self else { return HTTPResponse(statusCode: .internalServerError) }
            guard await self.isRequestAllowed(request) else { return Self.textResponse(.forbidden, "Forbidden\n") }
            guard await self.isAuthorized(request) else { return await self.unauthorizedResponse(for: request) }
            return await self.deleteStreamableHTTPSession(request)
        }

        handler.appendRoute("DELETE /mcp/:connector") { [weak self] request in
            guard let self else { return HTTPResponse(statusCode: .internalServerError) }
            guard await self.isRequestAllowed(request) else { return Self.textResponse(.forbidden, "Forbidden\n") }
            guard await self.isAuthorized(request) else { return await self.unauthorizedResponse(for: request) }
            return await self.deleteStreamableHTTPSession(request)
        }

        handler.appendRoute("POST /:connector/webhook") { [weak self] request in
            guard let self else { return HTTPResponse(statusCode: .internalServerError) }
            guard await self.isRequestAllowed(request) else { return Self.textResponse(.forbidden, "Forbidden\n") }
            guard await self.isAuthorized(request) else { return await self.unauthorizedResponse(for: request) }
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

    private func oauthProtectedResourceMetadataResponse(for request: HTTPRequest) -> HTTPResponse {
        let resource = oauthResourceURL(for: request)
        return Self.jsonResponse(
            .ok,
            [
                "resource": resource,
                "resource_name": "Bridgeport MCP",
                "authorization_servers": [oauthIssuer],
                "bearer_methods_supported": ["header"],
                "scopes_supported": ["mcp"]
            ],
            request: request
        )
    }

    private func oauthAuthorizationServerMetadataResponse(for request: HTTPRequest) -> HTTPResponse {
        Self.jsonResponse(
            .ok,
            [
                "issuer": oauthIssuer,
                "authorization_endpoint": "\(oauthIssuer)/oauth/authorize",
                "token_endpoint": "\(oauthIssuer)/oauth/token",
                "registration_endpoint": "\(oauthIssuer)/oauth/register",
                "response_types_supported": ["code"],
                "grant_types_supported": ["authorization_code"],
                "code_challenge_methods_supported": ["S256"],
                "token_endpoint_auth_methods_supported": ["none"],
                "scopes_supported": ["mcp"]
            ],
            request: request
        )
    }

    private func oauthPreflightResponse(for request: HTTPRequest) -> HTTPResponse {
        HTTPResponse(statusCode: .noContent, headers: Self.oauthCORSHeaders(for: request))
    }

    private func oauthRegisterClient(_ request: HTTPRequest) async -> HTTPResponse {
        do {
            guard Self.isContentLengthAllowed(request) else {
                return Self.oauthErrorResponse(.payloadTooLarge, "invalid_request", "Request body too large.", request: request)
            }

            let data = try await request.bodyData
            guard data.count <= Self.maxRequestBodyBytes,
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return Self.oauthErrorResponse(.badRequest, "invalid_request", "Expected a JSON dynamic client registration request.", request: request)
            }

            let redirectURIs = object["redirect_uris"] as? [String] ?? []
            guard !redirectURIs.isEmpty,
                  redirectURIs.allSatisfy(OAuthSupport.isAllowedRedirectURI) else {
                return Self.oauthErrorResponse(.badRequest, "invalid_redirect_uri", "Redirect URIs must be https URLs or localhost callback URLs.", request: request)
            }

            let clientName = (object["client_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let client = await oauthStore.registerClient(
                clientName: clientName?.isEmpty == false ? clientName! : "Claude",
                redirectURIs: redirectURIs
            )

            return Self.jsonResponse(
                .created,
                [
                    "client_id": client.clientID,
                    "client_id_issued_at": client.issuedAt,
                    "client_name": client.clientName,
                    "redirect_uris": client.redirectURIs,
                    "grant_types": ["authorization_code"],
                    "response_types": ["code"],
                    "token_endpoint_auth_method": "none"
                ],
                request: request
            )
        } catch {
            return Self.oauthErrorResponse(.badRequest, "invalid_request", "Could not read dynamic client registration request.", request: request)
        }
    }

    private func oauthAuthorizeForm(_ request: HTTPRequest) async -> HTTPResponse {
        let query = OAuthSupport.queryDictionary(request.query.map { URLQueryItem(name: $0.name, value: $0.value) })
        guard let validation = await validatedAuthorizationRequest(query) else {
            return Self.oauthErrorResponse(.badRequest, "invalid_request", "Invalid OAuth authorization request.", request: request)
        }

        return Self.htmlResponse(.ok, authorizationFormHTML(validation: validation, error: nil))
    }

    private func oauthApproveAuthorization(_ request: HTTPRequest) async -> HTTPResponse {
        do {
            guard Self.isContentLengthAllowed(request) else {
                return Self.textResponse(.payloadTooLarge, "Request body too large\n")
            }
            let data = try await request.bodyData
            guard data.count <= Self.maxRequestBodyBytes else {
                return Self.textResponse(.payloadTooLarge, "Request body too large\n")
            }

            let form = OAuthSupport.parseFormURLEncoded(data)
            guard let validation = await validatedAuthorizationRequest(form) else {
                return Self.oauthErrorResponse(.badRequest, "invalid_request", "Invalid OAuth authorization request.", request: request)
            }

            let approvalToken = form["bridgeport_token"] ?? ""
            guard Self.constantTimeEquals(approvalToken, config.token ?? "") else {
                return Self.htmlResponse(.forbidden, authorizationFormHTML(validation: validation, error: "Bridgeport token did not match."))
            }

            guard let code = await oauthStore.issueAuthorizationCode(
                clientID: validation.clientID,
                redirectURI: validation.redirectURI,
                codeChallenge: validation.codeChallenge,
                resource: validation.resource
            ) else {
                return Self.oauthErrorResponse(.badRequest, "invalid_request", "Could not issue authorization code.", request: request)
            }

            guard var components = URLComponents(string: validation.redirectURI) else {
                return Self.oauthErrorResponse(.badRequest, "invalid_redirect_uri", "Invalid redirect URI.", request: request)
            }
            var queryItems = components.queryItems ?? []
            queryItems.append(URLQueryItem(name: "code", value: code))
            if let state = validation.state, !state.isEmpty {
                queryItems.append(URLQueryItem(name: "state", value: state))
            }
            components.queryItems = queryItems

            var headers = HTTPHeaders()
            headers[HTTPHeader("Location")] = components.url?.absoluteString ?? validation.redirectURI
            return HTTPResponse(statusCode: .seeOther, headers: headers)
        } catch {
            return Self.oauthErrorResponse(.badRequest, "invalid_request", "Could not read OAuth authorization approval.", request: request)
        }
    }

    private func oauthToken(_ request: HTTPRequest) async -> HTTPResponse {
        do {
            guard Self.isContentLengthAllowed(request) else {
                return Self.oauthErrorResponse(.payloadTooLarge, "invalid_request", "Request body too large.", request: request)
            }
            let data = try await request.bodyData
            guard data.count <= Self.maxRequestBodyBytes else {
                return Self.oauthErrorResponse(.payloadTooLarge, "invalid_request", "Request body too large.", request: request)
            }

            let form = OAuthSupport.parseFormURLEncoded(data)
            guard form["grant_type"] == "authorization_code",
                  let code = form["code"],
                  let clientID = form["client_id"],
                  let redirectURI = form["redirect_uri"],
                  let verifier = form["code_verifier"] else {
                return Self.oauthErrorResponse(.badRequest, "invalid_request", "Expected authorization_code token exchange with PKCE.", request: request)
            }

            guard let accessToken = await oauthStore.redeemAuthorizationCode(
                code: code,
                clientID: clientID,
                redirectURI: redirectURI,
                codeVerifier: verifier
            ) else {
                return Self.oauthErrorResponse(.badRequest, "invalid_grant", "Authorization code could not be redeemed.", request: request)
            }

            return Self.jsonResponse(
                .ok,
                [
                    "access_token": accessToken,
                    "token_type": "Bearer",
                    "expires_in": 43_200,
                    "scope": "mcp"
                ],
                request: request
            )
        } catch {
            return Self.oauthErrorResponse(.badRequest, "invalid_request", "Could not read OAuth token request.", request: request)
        }
    }

    private func connectorIconResponse(for request: HTTPRequest, includeBody: Bool = true) async -> HTTPResponse {
        guard let connector = await publicConnector(for: request),
              let icon = connectorIconAsset(for: connector) else {
            return Self.textResponse(.notFound, "Icon not found\n")
        }

        var headers = HTTPHeaders()
        headers[.contentType] = icon.mimeType
        headers[HTTPHeader("Cache-Control")] = "public, max-age=86400"
        headers[HTTPHeader("Access-Control-Allow-Origin")] = "*"
        headers[HTTPHeader("X-Content-Type-Options")] = "nosniff"

        switch icon.source {
        case .file(let fileURL):
            guard let data = try? Data(contentsOf: fileURL) else {
                return Self.textResponse(.notFound, "Icon not found\n")
            }
            if includeBody {
                return HTTPResponse(statusCode: .ok, headers: headers, body: data)
            }
            headers[.contentLength] = "\(data.count)"
            return HTTPResponse(statusCode: .ok, headers: headers)
        case .redirect(let url):
            headers[HTTPHeader("Location")] = url.absoluteString
            return HTTPResponse(statusCode: .seeOther, headers: headers)
        case .data(let data):
            if includeBody {
                return HTTPResponse(statusCode: .ok, headers: headers, body: data)
            }
            headers[.contentLength] = "\(data.count)"
            return HTTPResponse(statusCode: .ok, headers: headers)
        }
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
            guard Self.isContentLengthAllowed(request) else {
                return Self.textResponse(.payloadTooLarge, "Request body too large\n")
            }
            let bodyData = try await request.bodyData
            guard bodyData.count <= Self.maxRequestBodyBytes else {
                return Self.textResponse(.payloadTooLarge, "Request body too large\n")
            }
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
            guard Self.isContentLengthAllowed(request) else {
                return Self.textResponse(.payloadTooLarge, "Request body too large\n")
            }
            let bodyData = try await request.bodyData
            guard bodyData.count <= Self.maxRequestBodyBytes else {
                return Self.textResponse(.payloadTooLarge, "Request body too large\n")
            }
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
            guard Self.isContentLengthAllowed(request) else {
                return Self.textResponse(.payloadTooLarge, "Request body too large\n")
            }
            let bodyData = try await request.bodyData
            guard bodyData.count <= Self.maxRequestBodyBytes else {
                return Self.textResponse(.payloadTooLarge, "Request body too large\n")
            }
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
        let session = BridgeSession(
            id: UUID().uuidString.lowercased(),
            connectorName: connector.name,
            bridge: bridge,
            icon: connectorIconPublicMetadata(for: connector)
        )
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

    private var oauthIssuer: String {
        ConfigManager.clientEndpointBaseURL(port: config.port ?? 8080, publicBaseURL: config.publicBaseURL)
    }

    private func oauthResourceURL(for request: HTTPRequest) -> String {
        let metadataPrefix = "/.well-known/oauth-protected-resource"
        if request.path.hasPrefix(metadataPrefix) {
            let suffix = String(request.path.dropFirst(metadataPrefix.count))
            return suffix.isEmpty ? oauthIssuer : "\(oauthIssuer)\(suffix)"
        }
        return "\(oauthIssuer)\(request.path)"
    }

    private func oauthProtectedResourceMetadataURL(for request: HTTPRequest) -> String {
        "\(oauthIssuer)/.well-known/oauth-protected-resource\(request.path)"
    }

    private func isAllowedOAuthResource(_ resource: String) async -> Bool {
        guard let resourceComponents = URLComponents(string: resource),
              let issuerComponents = URLComponents(string: oauthIssuer),
              resourceComponents.scheme?.lowercased() == issuerComponents.scheme?.lowercased(),
              resourceComponents.host?.lowercased() == issuerComponents.host?.lowercased(),
              resourceComponents.port == issuerComponents.port else {
            return false
        }

        let pathComponents = resourceComponents.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard pathComponents.count == 2, pathComponents[0] == "mcp" else {
            return false
        }

        return await publicConnector(routeName: pathComponents[1]) != nil
    }

    private func validatedAuthorizationRequest(_ values: [String: String]) async -> OAuthAuthorizationValidation? {
        guard values["response_type"] == "code",
              values["code_challenge_method"] == "S256",
              let clientID = values["client_id"],
              let redirectURI = values["redirect_uri"],
              let codeChallenge = values["code_challenge"],
              !codeChallenge.isEmpty,
              let resource = values["resource"],
              await isAllowedOAuthResource(resource),
              let client = await oauthStore.client(id: clientID),
              client.redirectURIs.contains(redirectURI) else {
            return nil
        }

        return OAuthAuthorizationValidation(
            clientID: clientID,
            clientName: client.clientName,
            redirectURI: redirectURI,
            codeChallenge: codeChallenge,
            state: values["state"],
            resource: resource
        )
    }

    private func authorizationFormHTML(validation: OAuthAuthorizationValidation, error: String?) -> String {
        let escapedClientName = OAuthSupport.htmlEscaped(validation.clientName)
        let escapedRedirectURI = OAuthSupport.htmlEscaped(validation.redirectURI)
        let escapedClientID = OAuthSupport.htmlEscaped(validation.clientID)
        let escapedCodeChallenge = OAuthSupport.htmlEscaped(validation.codeChallenge)
        let escapedState = OAuthSupport.htmlEscaped(validation.state ?? "")
        let escapedResource = OAuthSupport.htmlEscaped(validation.resource)
        let errorHTML = error.map { "<p class=\"error\">\(OAuthSupport.htmlEscaped($0))</p>" } ?? ""

        return """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>Authorize Bridgeport</title>
          <style>
            :root { color-scheme: light dark; font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif; }
            body { margin: 0; min-height: 100vh; display: grid; place-items: center; background: Canvas; color: CanvasText; }
            main { width: min(440px, calc(100vw - 32px)); border: 1px solid color-mix(in srgb, CanvasText 16%, transparent); border-radius: 14px; padding: 24px; box-shadow: 0 16px 48px color-mix(in srgb, black 16%, transparent); }
            h1 { font-size: 22px; margin: 0 0 10px; }
            p { color: color-mix(in srgb, CanvasText 72%, transparent); line-height: 1.4; }
            label { display: grid; gap: 8px; font-weight: 600; margin-top: 18px; }
            input { font: inherit; border-radius: 9px; border: 1px solid color-mix(in srgb, CanvasText 18%, transparent); padding: 10px 12px; background: Canvas; color: CanvasText; }
            button { font: inherit; font-weight: 700; border: 0; border-radius: 9px; margin-top: 18px; padding: 10px 14px; color: white; background: #0a84ff; }
            .meta { font-size: 13px; }
            .error { color: #b42318; font-weight: 700; }
          </style>
        </head>
        <body>
          <main>
            <h1>Authorize Bridgeport</h1>
            <p>Allow <strong>\(escapedClientName)</strong> to use Bridgeport MCP connectors from this Mac.</p>
            <p class="meta">Redirect URI: \(escapedRedirectURI)</p>
            \(errorHTML)
            <form method="post" action="/oauth/authorize">
              <input type="hidden" name="response_type" value="code">
              <input type="hidden" name="client_id" value="\(escapedClientID)">
              <input type="hidden" name="redirect_uri" value="\(escapedRedirectURI)">
              <input type="hidden" name="code_challenge" value="\(escapedCodeChallenge)">
              <input type="hidden" name="code_challenge_method" value="S256">
              <input type="hidden" name="state" value="\(escapedState)">
              <input type="hidden" name="resource" value="\(escapedResource)">
              <label>
                Bridgeport token
                <input name="bridgeport_token" type="password" autocomplete="off" required>
              </label>
              <button type="submit">Authorize</button>
            </form>
          </main>
        </body>
        </html>
        """
    }

    private func connector(for request: HTTPRequest) async -> Connector? {
        guard let routeName = request.routeParameters["connector"] else { return nil }
        let connectors = await manager.discoverConnectors()
        return connectors.first { connector in
            connector.name == routeName || config.publicRoutePath(for: connector) == routeName
        }.flatMap { connector in
            let settings = config.settings(for: connector.name)
            guard settings.enabled else { return nil }
            if isPublicHostRequest(request), !settings.exposePublicly {
                return nil
            }
            return connector
        }
    }

    private func publicConnector(for request: HTTPRequest) async -> Connector? {
        guard let routeName = request.routeParameters["connector"] else { return nil }
        return await publicConnector(routeName: routeName)
    }

    private func publicConnector(routeName: String) async -> Connector? {
        let connectors = await manager.discoverConnectors()
        return connectors.first { connector in
            connector.name == routeName || config.publicRoutePath(for: connector) == routeName
        }.flatMap { connector in
            let settings = config.settings(for: connector.name)
            return settings.enabled && settings.exposePublicly ? connector : nil
        }
    }

    private func connectorIconPublicMetadata(for connector: Connector) -> BridgeportIconMetadata? {
        guard let asset = connectorIconAsset(for: connector) else { return nil }
        var src = "\(oauthIssuer)/icons/\(config.publicRoutePath(for: connector))"
        if !asset.cacheKey.isEmpty {
            src += "?v=\(asset.cacheKey)"
        }
        return BridgeportIconMetadata(
            src: src,
            mimeType: asset.mimeType,
            sizes: asset.sizes
        )
    }

    private func connectorIconAsset(for connector: Connector) -> ConnectorIconAsset? {
        for candidate in ConfigManager.connectorIconCandidateURLs(for: connector) where FileManager.default.fileExists(atPath: candidate.path) {
            if let asset = fileIconAsset(candidate) {
                return asset
            }
        }

        let directoryURL = URL(fileURLWithPath: connector.directoryPath)
        if let declared = declaredIconAsset(for: connector, directoryURL: directoryURL) {
            return declared
        }

        return generatedIconAsset(for: connector)
    }

    private func fileIconAsset(_ fileURL: URL) -> ConnectorIconAsset? {
        let pathExtension = fileURL.pathExtension.lowercased()
        if pathExtension == "png" {
            return ConnectorIconAsset(source: .file(fileURL), mimeType: "image/png", sizes: ["1024x1024"], cacheKey: fileIconCacheKey(fileURL))
        }
        if pathExtension == "svg" {
            return ConnectorIconAsset(source: .file(fileURL), mimeType: "image/svg+xml", sizes: ["any"], cacheKey: fileIconCacheKey(fileURL))
        }
        return nil
    }

    private func fileIconCacheKey(_ fileURL: URL) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        let modified = Int((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
        return "\(max(size, 0))-\(max(modified, 0))"
    }

    private func declaredIconAsset(for connector: Connector, directoryURL: URL) -> ConnectorIconAsset? {
        let configFiles = [
            directoryURL.appendingPathComponent(".claude-plugin/plugin.json"),
            directoryURL.appendingPathComponent(".codex-plugin/plugin.json"),
            directoryURL.appendingPathComponent(".cursor-plugin/plugin.json"),
            directoryURL.appendingPathComponent(".github/plugin/plugin.json")
        ]
        let keys = ["logo", "icon", "iconURL", "iconUrl", "icon_url", "image", "imageURL", "imageUrl", "image_url"]

        for configFile in configFiles where FileManager.default.fileExists(atPath: configFile.path) {
            guard let data = try? Data(contentsOf: configFile),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            for key in keys {
                guard let rawValue = object[key] as? String else { continue }
                let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }

                if let url = normalizedRemoteIconURL(trimmed),
                   let asset = remoteIconAsset(url) {
                    return asset
                }

                let iconURL = resolveDeclaredIconPath(trimmed, configFile: configFile, directoryURL: directoryURL)
                if FileManager.default.fileExists(atPath: iconURL.path),
                   let asset = fileIconAsset(iconURL) {
                    return asset
                }
            }
        }

        _ = connector
        return nil
    }

    private func resolveDeclaredIconPath(_ value: String, configFile: URL, directoryURL: URL) -> URL {
        let expanded = NSString(string: value).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded).standardizedFileURL
        }

        let configRelative = configFile.deletingLastPathComponent().appendingPathComponent(expanded).standardizedFileURL
        if FileManager.default.fileExists(atPath: configRelative.path) {
            return configRelative
        }

        return directoryURL.appendingPathComponent(expanded).standardizedFileURL
    }

    private func normalizedRemoteIconURL(_ value: String) -> URL? {
        guard var components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              scheme == "https",
              let host = components.host?.lowercased() else {
            return nil
        }

        if host == "github.com" {
            let parts = components.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            if parts.count >= 5, parts[2] == "blob" {
                components.scheme = "https"
                components.host = "raw.githubusercontent.com"
                components.path = "/" + ([parts[0], parts[1], parts[3]] + parts.dropFirst(4)).joined(separator: "/")
                components.query = nil
                return components.url
            }
        }

        return components.url
    }

    private func remoteIconAsset(_ url: URL) -> ConnectorIconAsset? {
        switch url.pathExtension.lowercased() {
        case "png":
            return ConnectorIconAsset(source: .redirect(url), mimeType: "image/png", sizes: ["1024x1024"], cacheKey: remoteIconCacheKey(url))
        case "svg":
            return ConnectorIconAsset(source: .redirect(url), mimeType: "image/svg+xml", sizes: ["any"], cacheKey: remoteIconCacheKey(url))
        default:
            return nil
        }
    }

    private func remoteIconCacheKey(_ url: URL) -> String {
        let raw = url.absoluteString
        let scalars = raw.unicodeScalars.map { Int($0.value) }
        let checksum = scalars.reduce(0) { ($0 &* 31 &+ $1) & 0x7fffffff }
        return "\(checksum)"
    }

    private func generatedIconAsset(for connector: Connector) -> ConnectorIconAsset {
        let title = connector.name
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .prefix(2)
            .compactMap { $0.first }
            .map { String($0).uppercased() }
            .joined()
        let glyph = title.isEmpty ? "MCP" : title
        let escapedGlyph = OAuthSupport.htmlEscaped(glyph)
        let escapedTitle = OAuthSupport.htmlEscaped(connector.name)
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 128 128" role="img" aria-label="\(escapedTitle)">
          <rect width="128" height="128" rx="28" fill="#F5F5F7"/>
          <rect x="12" y="12" width="104" height="104" rx="22" fill="#FFFFFF" stroke="#D2D2D7" stroke-width="2"/>
          <text x="64" y="73" text-anchor="middle" font-family="-apple-system, BlinkMacSystemFont, 'SF Pro Display', sans-serif" font-size="34" font-weight="700" fill="#1D1D1F">\(escapedGlyph)</text>
        </svg>
        """
        return ConnectorIconAsset(source: .data(Data(svg.utf8)), mimeType: "image/svg+xml", sizes: ["any"], cacheKey: "generated-\(connector.name)")
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

    private func isPublicHostRequest(_ request: HTTPRequest) -> Bool {
        guard let publicBaseURL = config.publicBaseURL,
              let publicHost = URL(string: publicBaseURL)?.host?.lowercased(),
              !publicHost.isEmpty else {
            return false
        }

        let hostCandidates = [
            request.headers[HTTPHeader("Host")],
            request.headers[HTTPHeader("X-Forwarded-Host")]
        ]

        return hostCandidates.contains { rawValue in
            guard let rawValue, !rawValue.isEmpty else { return false }
            let host = rawValue.split(separator: ":", maxSplits: 1).first.map(String.init) ?? rawValue
            return host.lowercased() == publicHost
        }
    }

    private func isAuthorized(_ request: HTTPRequest) async -> Bool {
        let token = config.token ?? ""
        guard !token.isEmpty else { return false }

        if let authHeader = request.headers[.authorization] {
            if Self.constantTimeEquals(authHeader, "Bearer \(token)") {
                return true
            }

            if authHeader.lowercased().hasPrefix("bearer ") {
                let accessToken = String(authHeader.dropFirst("Bearer ".count))
                if await oauthStore.isValidAccessToken(accessToken, resource: oauthResourceURL(for: request)) {
                    return true
                }
            }
        }

        if config.allowQueryTokenAuth == true,
           let queryToken = request.query.first(where: { $0.name == "token" })?.value,
           Self.constantTimeEquals(queryToken, token) {
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

    private static func htmlResponse(_ statusCode: HTTPStatusCode, _ html: String) -> HTTPResponse {
        HTTPResponse(statusCode: statusCode, headers: [.contentType: "text/html; charset=utf-8"], body: Data(html.utf8))
    }

    private static func jsonResponse(_ statusCode: HTTPStatusCode, _ object: [String: Any], request: HTTPRequest) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        var headers = oauthCORSHeaders(for: request)
        headers[.contentType] = "application/json"
        return HTTPResponse(statusCode: statusCode, headers: headers, body: data)
    }

    private static func oauthErrorResponse(_ statusCode: HTTPStatusCode, _ error: String, _ description: String, request: HTTPRequest) -> HTTPResponse {
        jsonResponse(
            statusCode,
            [
                "error": error,
                "error_description": description
            ],
            request: request
        )
    }

    private static func oauthCORSHeaders(for request: HTTPRequest) -> HTTPHeaders {
        var headers = HTTPHeaders()
        headers[HTTPHeader("Access-Control-Allow-Origin")] = request.headers[originHeader] ?? "*"
        headers[HTTPHeader("Access-Control-Allow-Methods")] = "GET, POST, OPTIONS"
        headers[HTTPHeader("Access-Control-Allow-Headers")] = "authorization, content-type, mcp-session-id"
        headers[HTTPHeader("Access-Control-Max-Age")] = "86400"
        return headers
    }

    private func unauthorizedResponse(for request: HTTPRequest) -> HTTPResponse {
        var headers = HTTPHeaders()
        headers[.contentType] = "text/plain"
        let metadataURL = Self.wwwAuthenticateQuotedValue(oauthProtectedResourceMetadataURL(for: request))
        headers[HTTPHeader("WWW-Authenticate")] = "Bearer realm=\"Bridgeport\", resource_metadata=\"\(metadataURL)\""
        return HTTPResponse(statusCode: .unauthorized, headers: headers, body: Data("Unauthorized\n".utf8))
    }

    public static func wwwAuthenticateQuotedValue(_ value: String) -> String {
        var escaped = ""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"":
                escaped += "\\\""
            case "\\":
                escaped += "\\\\"
            case "\r", "\n":
                continue
            default:
                escaped.unicodeScalars.append(scalar)
            }
        }
        return escaped
    }

    public static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let lhsBytes = Array(lhs.utf8)
        let rhsBytes = Array(rhs.utf8)
        let maxCount = max(lhsBytes.count, rhsBytes.count)
        var difference = lhsBytes.count ^ rhsBytes.count

        for index in 0..<maxCount {
            let left = index < lhsBytes.count ? lhsBytes[index] : 0
            let right = index < rhsBytes.count ? rhsBytes[index] : 0
            difference |= Int(left ^ right)
        }

        return difference == 0
    }

    private static func isContentLengthAllowed(_ request: HTTPRequest) -> Bool {
        guard let rawLength = request.headers[.contentLength],
              let length = Int(rawLength.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return true
        }
        return length <= maxRequestBodyBytes
    }

    private static let sessionHeader = HTTPHeader("Mcp-Session-Id")
    private static let originHeader = HTTPHeader("Origin")
    private static let maxRequestBodyBytes = 1_048_576
}
