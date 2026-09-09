import Foundation

/// Reports that a command's effect may already be durable even though its
/// queue/audit completion or response handling failed. Callers must not retry
/// this error as an ordinary pre-effect failure without first reviewing state.
public struct CommandEffectAppliedError: Error, Sendable, LocalizedError {
    public let commandID: UUID
    public let message: String

    public init(commandID: UUID, message: String) {
        self.commandID = commandID
        self.message = message
    }

    public var errorDescription: String? { message }
}
