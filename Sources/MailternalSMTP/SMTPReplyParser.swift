import Foundation
import NIO

// SMTP replies are intentionally bounded independently from the socket read
// allocator. A server cannot make a submission retain an unbounded diagnostic.
enum SMTPReplyLimits {
    static let maximumLineBytes = 16 * 1024
    static let maximumReplyBytes = 128 * 1024
    static let maximumReplyLines = 128
    static let maximumQueuedReplies = 16
}

struct SMTPReply: Sendable {
    let code: Int
    /// Text is used only for EHLO capability parsing. It is never included in
    /// a user-visible error, because even a server reply is untrusted input.
    let lines: [String]
}

enum SMTPWireError: Error, Sendable {
    case connectionClosed
    case cancelled
    case timeout
    case malformedReply
    case replyQueueOverflow
    case writeFailed
    case tlsFailure
}

struct SMTPReplyParser {
    private var line: [UInt8] = []
    private var sawCR = false
    private var replyCode: Int?
    private var replyLines: [String] = []
    private var replyBytes = 0

    mutating func feed(_ byte: UInt8) throws -> SMTPReply? {
        guard replyBytes < SMTPReplyLimits.maximumReplyBytes else {
            throw SMTPWireError.malformedReply
        }
        replyBytes += 1

        if sawCR {
            guard byte == 0x0A else { throw SMTPWireError.malformedReply }
            sawCR = false
            return try completeLine()
        }
        if byte == 0x0D {
            sawCR = true
            return nil
        }
        guard byte != 0x0A else { throw SMTPWireError.malformedReply }
        guard line.count < SMTPReplyLimits.maximumLineBytes else {
            throw SMTPWireError.malformedReply
        }
        line.append(byte)
        return nil
    }

    mutating func finish() throws {
        guard !sawCR, line.isEmpty, replyCode == nil else {
            throw SMTPWireError.malformedReply
        }
    }

    private mutating func completeLine() throws -> SMTPReply? {
        defer { line.removeAll(keepingCapacity: true) }
        guard line.count >= 3,
              line[0] >= 48, line[0] <= 57,
              line[1] >= 48, line[1] <= 57,
              line[2] >= 48, line[2] <= 57 else {
            throw SMTPWireError.malformedReply
        }
        let code = Int(line[0] - 48) * 100 + Int(line[1] - 48) * 10 + Int(line[2] - 48)
        guard (100...599).contains(code) else { throw SMTPWireError.malformedReply }
        let separator: UInt8
        if line.count == 3 {
            separator = 0x20
        } else {
            guard line[3] == 0x20 || line[3] == 0x2D else {
                throw SMTPWireError.malformedReply
            }
            separator = line[3]
        }
        let text = line.count == 3
            ? ""
            : String(decoding: line.dropFirst(4), as: UTF8.self)

        if let existingCode = replyCode {
            guard existingCode == code else { throw SMTPWireError.malformedReply }
        } else {
            replyCode = code
        }
        guard replyLines.count < SMTPReplyLimits.maximumReplyLines else {
            throw SMTPWireError.malformedReply
        }
        replyLines.append(text)
        if separator == 0x2D {
            return nil
        }
        let result = SMTPReply(code: code, lines: replyLines)
        replyCode = nil
        replyLines.removeAll(keepingCapacity: true)
        replyBytes = 0
        return result
    }
}

final class SMTPReplyInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [SMTPReply] = []
    private var waiters: [CheckedContinuation<SMTPReply, Error>] = []
    private var terminalError: Error?

    func next() async throws -> SMTPReply {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if !values.isEmpty {
                    let value = values.removeFirst()
                    lock.unlock()
                    continuation.resume(returning: value)
                } else if let terminalError {
                    lock.unlock()
                    continuation.resume(throwing: terminalError)
                } else {
                    waiters.append(continuation)
                    lock.unlock()
                }
            }
        }, onCancel: {
            self.fail(SMTPWireError.cancelled)
        })
    }

    func push(_ value: SMTPReply) {
        lock.lock()
        if let waiter = waiters.first {
            waiters.removeFirst()
            lock.unlock()
            waiter.resume(returning: value)
            return
        }
        guard terminalError == nil else {
            lock.unlock()
            return
        }
        guard values.count < SMTPReplyLimits.maximumQueuedReplies else {
            let continuations = waiters
            waiters.removeAll(keepingCapacity: false)
            terminalError = SMTPWireError.replyQueueOverflow
            lock.unlock()
            continuations.forEach { $0.resume(throwing: SMTPWireError.replyQueueOverflow) }
            return
        }
        values.append(value)
        lock.unlock()
    }

    func fail(_ error: Error) {
        lock.lock()
        guard terminalError == nil else {
            lock.unlock()
            return
        }
        terminalError = error
        let continuations = waiters
        waiters.removeAll(keepingCapacity: false)
        lock.unlock()
        continuations.forEach { $0.resume(throwing: error) }
    }
}

final class SMTPReplyHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    let inbox: SMTPReplyInbox
    private var parser = SMTPReplyParser()
    private var removed = false

    init(inbox: SMTPReplyInbox) {
        self.inbox = inbox
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        do {
            while let byte: UInt8 = buffer.readInteger() {
                if let reply = try parser.feed(byte) {
                    inbox.push(reply)
                }
            }
        } catch {
            inbox.fail(error)
            context.close(promise: nil)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        do {
            try parser.finish()
            inbox.fail(SMTPWireError.connectionClosed)
        } catch {
            inbox.fail(error)
        }
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        inbox.fail(SMTPWireError.connectionClosed)
        context.close(promise: nil)
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        removed = true
        inbox.fail(SMTPWireError.connectionClosed)
    }

    deinit {
        if !removed {
            inbox.fail(SMTPWireError.connectionClosed)
        }
    }
}
