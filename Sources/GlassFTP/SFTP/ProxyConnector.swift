import Foundation
import NIOCore
import NIOPosix

/// Opens a TCP stream to `host:port` through a SOCKS5 or HTTP CONNECT proxy and
/// hands back the channel, ready for the SSH handshake.
///
/// Citadel cannot do this itself: it accepts extra channel handlers, but its
/// bootstrap always dials the SSH host directly, and NIOSOCKS lives in
/// swift-nio-extras, which is not in the dependency graph. The handshakes are
/// small enough to carry here.
enum ProxyConnector {
    static func connect(
        through proxy: ProxyEndpoint,
        to host: String,
        port: Int,
        timeout: TimeAmount
    ) async throws -> Channel {
        let channel: Channel
        do {
            channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                .connectTimeout(timeout)
                .connect(host: proxy.host, port: proxy.port)
                .get()
        } catch {
            throw ProviderError.proxyFailed("could not reach \(proxy.host):\(proxy.port) — \(error.localizedDescription)")
        }

        let promise = channel.eventLoop.makePromise(of: Void.self)
        let handler = ProxyHandshakeHandler(proxy: proxy, targetHost: host, targetPort: port, promise: promise)

        // The proxy may accept the TCP connection and then never answer.
        let deadline = channel.eventLoop.scheduleTask(in: timeout) {
            promise.fail(ProviderError.proxyFailed("the proxy did not answer in time"))
        }

        do {
            try await channel.pipeline.addHandler(handler).get()
            try await promise.futureResult.get()
            deadline.cancel()
            return channel
        } catch {
            deadline.cancel()
            try? await channel.close()
            if let providerError = error as? ProviderError { throw providerError }
            throw ProviderError.proxyFailed(error.localizedDescription)
        }
    }
}

// MARK: - Wire format

/// The proxy protocols' messages, kept pure so they can be tested without a
/// network.
enum ProxyHandshake {
    // MARK: SOCKS5 (RFC 1928, RFC 1929)

    static func socksGreeting(withCredentials: Bool) -> [UInt8] {
        // Version 5, then the methods offered: 0x00 no auth, 0x02 user/pass.
        withCredentials ? [0x05, 0x02, 0x00, 0x02] : [0x05, 0x01, 0x00]
    }

    static func socksCredentials(username: String, password: String) -> [UInt8] {
        let user = Array(username.utf8.prefix(255))
        let pass = Array(password.utf8.prefix(255))
        return [0x01, UInt8(user.count)] + user + [UInt8(pass.count)] + pass
    }

    /// CONNECT by domain name, so the proxy does the DNS lookup — the host
    /// may only resolve on the proxy's side of the network.
    static func socksConnect(host: String, port: Int) -> [UInt8] {
        let name = Array(host.utf8.prefix(255))
        return [0x05, 0x01, 0x00, 0x03, UInt8(name.count)] + name
            + [UInt8((port >> 8) & 0xFF), UInt8(port & 0xFF)]
    }

    enum Step: Equatable {
        /// Not enough bytes yet.
        case needMore
        /// Consumed this many bytes; carry on.
        case done(consumed: Int)
        case failed(String)
    }

    enum Method: Equatable {
        case noAuth
        case credentials
    }

    static func parseSocksMethod(_ bytes: [UInt8]) -> (Step, Method?) {
        guard bytes.count >= 2 else { return (.needMore, nil) }
        guard bytes[0] == 0x05 else { return (.failed("not a SOCKS5 proxy"), nil) }
        switch bytes[1] {
        case 0x00: return (.done(consumed: 2), .noAuth)
        case 0x02: return (.done(consumed: 2), .credentials)
        default: return (.failed("the proxy accepts none of the offered authentication methods — does it need a username?"), nil)
        }
    }

    static func parseSocksCredentialsReply(_ bytes: [UInt8]) -> Step {
        guard bytes.count >= 2 else { return .needMore }
        return bytes[1] == 0x00 ? .done(consumed: 2) : .failed("the proxy rejected the username or password")
    }

    static func parseSocksConnectReply(_ bytes: [UInt8]) -> Step {
        guard bytes.count >= 5 else { return .needMore }
        guard bytes[0] == 0x05 else { return .failed("malformed SOCKS reply") }
        guard bytes[1] == 0x00 else { return .failed(socksReason(bytes[1])) }

        let addressLength: Int
        switch bytes[3] {
        case 0x01: addressLength = 4
        case 0x04: addressLength = 16
        case 0x03: addressLength = 1 + Int(bytes[4])
        default: return .failed("malformed SOCKS reply")
        }
        let total = 4 + addressLength + 2
        return bytes.count >= total ? .done(consumed: total) : .needMore
    }

    static func socksReason(_ code: UInt8) -> String {
        switch code {
        case 0x01: return "general SOCKS server failure"
        case 0x02: return "connection not allowed by the proxy's rules"
        case 0x03: return "network unreachable from the proxy"
        case 0x04: return "host unreachable from the proxy"
        case 0x05: return "connection refused by the destination"
        case 0x06: return "TTL expired"
        case 0x07: return "command not supported by the proxy"
        case 0x08: return "address type not supported by the proxy"
        default: return "SOCKS error \(code)"
        }
    }

    // MARK: HTTP CONNECT

    static func httpConnectRequest(host: String, port: Int, username: String, password: String) -> [UInt8] {
        // IPv6 literals need brackets in the authority.
        let authority = host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
        var request = "CONNECT \(authority) HTTP/1.1\r\nHost: \(authority)\r\n"
        if !username.isEmpty {
            let token = Data("\(username):\(password)".utf8).base64EncodedString()
            request += "Proxy-Authorization: Basic \(token)\r\n"
        }
        request += "\r\n"
        return Array(request.utf8)
    }

    /// Waits for the end of the response head and accepts any 2xx.
    static func parseHTTPConnectReply(_ bytes: [UInt8]) -> Step {
        let terminator: [UInt8] = [13, 10, 13, 10]
        guard let end = bytes.firstRange(of: terminator)?.upperBound else {
            // A proxy answering with a megabyte of headers is not a proxy.
            return bytes.count > 16_384 ? .failed("malformed HTTP proxy reply") : .needMore
        }

        let head = String(decoding: bytes[..<end], as: UTF8.self)
        let statusLine = head.split(separator: "\r\n", maxSplits: 1).first ?? ""
        let parts = statusLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/"), let code = Int(parts[1]) else {
            return .failed("malformed HTTP proxy reply")
        }
        switch code {
        case 200..<300:
            return .done(consumed: end)
        case 407:
            return .failed("the proxy requires authentication, or rejected the credentials (407)")
        default:
            let reason = parts.count > 2 ? " \(parts[2])" : ""
            return .failed("the proxy refused the tunnel (\(code)\(reason))")
        }
    }
}

// MARK: - Handler

/// Drives one proxy handshake on a freshly connected channel.
///
/// After success it stays in the pipeline as a pass-through. Whatever arrived
/// in the same read as the proxy's final reply — typically the SSH server's
/// banner — belongs to the SSH handler, which does not exist yet. It is held
/// back and delivered right after the SSH handler sends its first bytes,
/// which proves it is in the pipeline.
///
/// `@unchecked Sendable` only so it can be handed to `addHandler` from async
/// code: every member is touched on the channel's event loop and nowhere else.
private final class ProxyHandshakeHandler: ChannelDuplexHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private enum State {
        case awaitingMethod
        case awaitingCredentials
        case awaitingSocksConnect
        case awaitingHTTPConnect
        case established
        case failed
    }

    private let proxy: ProxyEndpoint
    private let targetHost: String
    private let targetPort: Int
    private let promise: EventLoopPromise<Void>

    private var state: State
    private var received: [UInt8] = []
    private var leftover: ByteBuffer?

    init(proxy: ProxyEndpoint, targetHost: String, targetPort: Int, promise: EventLoopPromise<Void>) {
        self.proxy = proxy
        self.targetHost = targetHost
        self.targetPort = targetPort
        self.promise = promise
        self.state = proxy.kind == .socks5 ? .awaitingMethod : .awaitingHTTPConnect
    }

    func handlerAdded(context: ChannelHandlerContext) {
        switch proxy.kind {
        case .socks5:
            send(ProxyHandshake.socksGreeting(withCredentials: proxy.hasCredentials), context: context)
        case .httpConnect:
            send(
                ProxyHandshake.httpConnectRequest(
                    host: targetHost,
                    port: targetPort,
                    username: proxy.username,
                    password: proxy.password
                ),
                context: context
            )
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard state != .established else {
            context.fireChannelRead(data)
            return
        }
        guard state != .failed else { return }

        var buffer = unwrapInboundIn(data)
        received += buffer.readBytes(length: buffer.readableBytes) ?? []
        advance(context: context)
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        context.write(data, promise: promise)

        // The SSH handler has started talking, so it is in the pipeline and can
        // receive what was held back.
        if state == .established, let held = leftover {
            leftover = nil
            context.eventLoop.execute {
                context.fireChannelRead(self.wrapInboundOut(held))
                context.fireChannelReadComplete()
            }
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        if state != .established, state != .failed {
            fail(.proxyFailed("the proxy closed the connection"), context: context)
        }
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        guard state != .established else {
            context.fireErrorCaught(error)
            return
        }
        fail(.proxyFailed(error.localizedDescription), context: context)
    }

    // MARK: - State machine

    private func advance(context: ChannelHandlerContext) {
        // Loops because one read can complete several steps.
        while true {
            switch state {
            case .awaitingMethod:
                let (step, method) = ProxyHandshake.parseSocksMethod(received)
                guard consume(step, context: context) else { return }
                if method == .credentials {
                    guard proxy.hasCredentials else {
                        fail(.proxyFailed("the proxy requires a username and password"), context: context)
                        return
                    }
                    state = .awaitingCredentials
                    send(ProxyHandshake.socksCredentials(username: proxy.username, password: proxy.password), context: context)
                } else {
                    state = .awaitingSocksConnect
                    send(ProxyHandshake.socksConnect(host: targetHost, port: targetPort), context: context)
                }

            case .awaitingCredentials:
                guard consume(ProxyHandshake.parseSocksCredentialsReply(received), context: context) else { return }
                state = .awaitingSocksConnect
                send(ProxyHandshake.socksConnect(host: targetHost, port: targetPort), context: context)

            case .awaitingSocksConnect:
                guard consume(ProxyHandshake.parseSocksConnectReply(received), context: context) else { return }
                establish(context: context)
                return

            case .awaitingHTTPConnect:
                guard consume(ProxyHandshake.parseHTTPConnectReply(received), context: context) else { return }
                establish(context: context)
                return

            case .established, .failed:
                return
            }
        }
    }

    /// Applies one parse step. Returns `true` when the state machine may move on.
    private func consume(_ step: ProxyHandshake.Step, context: ChannelHandlerContext) -> Bool {
        switch step {
        case .needMore:
            return false
        case .failed(let reason):
            fail(.proxyFailed(reason), context: context)
            return false
        case .done(let consumed):
            received.removeFirst(consumed)
            return true
        }
    }

    private func establish(context: ChannelHandlerContext) {
        state = .established
        if !received.isEmpty {
            var buffer = context.channel.allocator.buffer(capacity: received.count)
            buffer.writeBytes(received)
            leftover = buffer
            received = []
        }
        promise.succeed(())
    }

    private func fail(_ error: ProviderError, context: ChannelHandlerContext) {
        state = .failed
        promise.fail(error)
        context.close(promise: nil)
    }

    private func send(_ bytes: [UInt8], context: ChannelHandlerContext) {
        var buffer = context.channel.allocator.buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        context.writeAndFlush(wrapOutboundOut(buffer), promise: nil)
    }
}
