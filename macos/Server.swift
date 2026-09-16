import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOWebSocket

// All connection ownership lives on one event loop. HID output and its watchdog
// have their own serial queue, so network stalls cannot leave controls held.
final class GamepadServer {
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private let device: HIDDevice
    private let page: ByteBuffer
    private var listener: Channel?
    private var client: Channel?
    private var connections: [ObjectIdentifier: Channel] = [:]
    private var stopping = false

    init(device: HIDDevice) throws {
        self.device = device
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let file = executable.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/index.html")
        guard let data = try? Data(contentsOf: file) else {
            throw ServerError("Missing bundled browser client. Build with ./macos/run.sh build and run the resulting app.")
        }
        page = ByteBuffer(bytes: data)
    }

    func start(host: String, port: Int) throws -> Int {
        listener = try ServerBootstrap(group: group)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(.socketOption(.tcp_nodelay), value: 1)
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 16)
            .childChannelInitializer { channel in
                guard !self.stopping, self.connections.count < 64 else {
                    return channel.close()
                }
                self.connections[ObjectIdentifier(channel)] = channel
                let lifecycle = ConnectionLifecycle(server: self)
                let http = BrowserHandler(page: self.page)
                let upgrader = NIOWebSocketServerUpgrader(
                    maxFrameSize: 4096,
                    shouldUpgrade: { channel, head in
                        channel.eventLoop.makeSucceededFuture(
                            head.uri == "/ws" && head.method == .GET ? HTTPHeaders() : nil
                        )
                    },
                    upgradePipelineHandler: { channel, _ in
                        channel.pipeline.removeHandler(http).flatMap {
                            lifecycle.upgraded()
                            return channel.eventLoop.makeCompletedFuture {
                                try channel.pipeline.syncOperations.addHandlers([
                                WebSocketValidation(),
                                NIOWebSocketFrameAggregator(minNonFinalFragmentSize: 0,
                                    maxAccumulatedFrameCount: 128, maxAccumulatedFrameSize: 4096),
                                IdleStateHandler(readTimeout: .seconds(10)),
                                GamepadSocket(server: self),
                                ])
                            }
                        }
                    }
                )
                let upgrade: NIOHTTPServerUpgradeConfiguration = (upgraders: [upgrader], completionHandler: { _ in })
                return channel.pipeline.addHandler(lifecycle).flatMap {
                    channel.pipeline.configureHTTPServerPipeline(withServerUpgrade: upgrade)
                }.flatMap { channel.pipeline.addHandler(http) }
            }
            .bind(host: host, port: port).wait()
        return listener!.localAddress!.port!
    }

    func connected(_ channel: Channel) {
        guard !stopping else { channel.close(promise: nil); return }
        let previous = client
        client = channel
        do { try device.reset() } catch { fail(error); return }
        if let previous { closeSocket(previous, code: 1000) }
        diagnostic("\(channel.remoteAddress?.description ?? "Phone") connected")
    }

    func received(_ data: Data, from channel: Channel) {
        // Buffered frames and late disconnect callbacks from a replaced phone
        // must never change the new owner's state.
        guard !stopping, client === channel else { return }
        guard let state = try? PadState(json: data) else { return }
        do { try device.apply(state) } catch { fail(error) }
    }

    func disconnected(_ channel: Channel) {
        connections.removeValue(forKey: ObjectIdentifier(channel))
        guard client === channel else { return }
        client = nil
        if !stopping {
            do { try device.reset() } catch { fail(error) }
            diagnostic("Phone disconnected; controls released")
        }
    }

    private func fail(_ error: Error) {
        diagnostic(String(describing: error))
        shutdown(status: 1)
    }

    func shutdown(status: Int32 = 0) {
        group.next().execute {
            guard !self.stopping else { return }
            self.stopping = true
            self.listener?.close(promise: nil)
            for channel in self.connections.values { channel.close(promise: nil) }
            self.device.shutdown(status)
        }
    }
}

private final class ConnectionLifecycle: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    private let server: GamepadServer
    private var deadline: Scheduled<Void>?
    init(server: GamepadServer) { self.server = server }

    func handlerAdded(context: ChannelHandlerContext) {
        let channel = context.channel
        // Also closes speculative or incomplete HTTP connections.
        deadline = context.eventLoop.scheduleTask(in: .seconds(5)) { channel.close(promise: nil) }
    }
    func upgraded() { deadline?.cancel(); deadline = nil }
    func channelInactive(context: ChannelHandlerContext) {
        deadline?.cancel()
        server.disconnected(context.channel)
        context.fireChannelInactive()
    }
}

private final class BrowserHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    private let page: ByteBuffer
    private var responded = false
    init(page: ByteBuffer) { self.page = page }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !responded, case .head(let request) = unwrapInboundIn(data) else { return }
        responded = true
        let status: HTTPResponseStatus
        let path = request.uri.split(separator: "?", maxSplits: 1).first ?? ""
        if request.method != .GET && request.method != .HEAD { status = .methodNotAllowed }
        else if path == "/" || path == "/index.html" { status = .ok }
        else if path == "/ws" { status = .upgradeRequired }
        else { status = .notFound }
        var headers = HTTPHeaders([
            ("Content-Length", status == .ok ? String(page.readableBytes) : "0"),
            ("Connection", "close"), ("Cache-Control", "no-store"),
        ])
        if status == .ok { headers.add(name: "Content-Type", value: "text/html; charset=utf-8") }
        if status == .methodNotAllowed { headers.add(name: "Allow", value: "GET, HEAD") }
        if status == .upgradeRequired { headers.add(name: "Upgrade", value: "websocket") }
        context.write(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: status, headers: headers))), promise: nil)
        if status == .ok && request.method != .HEAD {
            context.write(wrapOutboundOut(.body(.byteBuffer(page))), promise: nil)
        }
        let channel = context.channel
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in channel.close(promise: nil) }
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        // A refused upgrade is forwarded as an ordinary HTTP request by NIO.
        if error as? NIOWebSocketUpgradeError == .unsupportedWebSocketTarget { return }
        context.close(promise: nil)
    }
}

private enum SocketError: Error { case invalidFrame }

private final class WebSocketValidation: ChannelInboundHandler {
    typealias InboundIn = WebSocketFrame
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        guard frame.maskKey != nil, !frame.rsv1, !frame.rsv2, !frame.rsv3 else {
            context.fireErrorCaught(SocketError.invalidFrame)
            return
        }
        context.fireChannelRead(data)
    }
}

private func closeSocket(_ channel: Channel, code: UInt16) {
    var data = channel.allocator.buffer(capacity: 2)
    data.writeInteger(code)
    let deadline = channel.eventLoop.scheduleTask(in: .seconds(1)) { channel.close(promise: nil) }
    channel.writeAndFlush(WebSocketFrame(fin: true, opcode: .connectionClose, data: data)).whenComplete { _ in
        deadline.cancel()
        channel.close(promise: nil)
    }
}

private final class GamepadSocket: ChannelInboundHandler {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame
    private let server: GamepadServer
    private var closing = false
    init(server: GamepadServer) { self.server = server }

    func handlerAdded(context: ChannelHandlerContext) { server.connected(context.channel) }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !closing else { return }
        let frame = unwrapInboundIn(data)
        switch frame.opcode {
        case .text, .binary:
            let bytes = Data(frame.unmaskedData.readableBytesView)
            if frame.opcode == .text && String(data: bytes, encoding: .utf8) == nil {
                close(context, code: 1007); return
            }
            server.received(bytes, from: context.channel)
        case .ping:
            guard context.channel.isWritable else { close(context, code: 1008); return }
            context.writeAndFlush(wrapOutboundOut(WebSocketFrame(fin: true, opcode: .pong, data: frame.unmaskedData)), promise: nil)
        case .pong: break
        case .connectionClose:
            var bytes = frame.unmaskedData
            if bytes.readableBytes == 1 { close(context, code: 1002); return }
            let code = bytes.readInteger(as: UInt16.self) ?? 1000
            guard (1000...1014).contains(code) && ![1004, 1005, 1006].contains(code) || (3000...4999).contains(code) else {
                close(context, code: 1002); return
            }
            guard String(bytes: bytes.readableBytesView, encoding: .utf8) != nil else {
                close(context, code: 1007); return
            }
            close(context, code: code)
        default: close(context, code: 1002)
        }
    }

    private func close(_ context: ChannelHandlerContext, code: UInt16) {
        guard !closing else { return }
        closing = true
        server.disconnected(context.channel)
        closeSocket(context.channel, code: code)
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        close(context, code: error is NIOWebSocketFrameAggregator.Error ? 1009 : 1002)
    }
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is IdleStateHandler.IdleStateEvent { close(context, code: 1001) }
        else { context.fireUserInboundEventTriggered(event) }
    }
}
