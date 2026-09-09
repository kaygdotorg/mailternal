import Foundation
#if canImport(Darwin)
import Darwin
#elseif os(Linux)
import Glibc
#endif
import MailternalInterfaces
import MailternalWorkspace

public enum CLIEngineAction: String, Equatable, Sendable {
    case start
    case stop
    case status
}

public enum CLIPairingAction: Equatable, Sendable {
    case show(grant: AutomationGrant?)
    case code(String)
    case revoke(UUID)
    case remoteStatus
    case remoteDisable
    case remoteEnable(host: String, port: UInt16)
}

public enum CLIInvocation: Equatable, Sendable {
    case command(Command)
    case attachment(Command, output: String?, stream: Bool)
    case draftAttachment(draftID: UUID, path: String, mimeType: String?, filename: String)
    case state
    case uiState
    case observe(afterRevision: UInt64?)
    case uiObserve(afterRevision: UInt64?)
    case searchFollow(query: String, afterRevision: UInt64?)
    case schema
    case setup
    case help
    case engine(CLIEngineAction)
    case pairing(CLIPairingAction)
}

public enum CLIParseError: LocalizedError, Equatable, Sendable {
    case usage(String)
    public var errorDescription: String? {
        if case .usage(let message) = self { return message }
        return nil
    }
}

/// The command-line grammar is kept beside the Codable command definition.
/// Parsing never performs a mail operation; execution routes every operation
/// through the authenticated app automation socket.
public enum AutomationCLI {
    private struct Options: Sendable {
        var container: String?
        var token: String?
        var host: String?
        var sshPort: String?
        var app: String?
        var pairedHost: String?
        var pairedPort: UInt16?
        var bearerToken: String?
        var clientID: UUID?
        var fingerprint: String?
        var clientName: String?
        var noStart = false
        var passwordFromStdin = false
    }

    private struct ParsedArguments: Sendable {
        var options: Options
        var commandArguments: [String]
    }

    public static func parse(_ arguments: [String]) throws -> CLIInvocation {
        let parsed = try splitOptions(arguments)
        var commandArguments = parsed.commandArguments
        if commandArguments.first == "--" {
            commandArguments.removeFirst()
        }
        guard let verb = commandArguments.first else { throw CLIParseError.usage(usage) }
        let args = Array(commandArguments.dropFirst())
        switch verb {
        case "schema":
            try requireNoArguments(args, command: "schema")
            return .schema
        case "help", "--help", "-h":
            try requireNoArguments(args, command: "help")
            return .help
        case "setup":
            try requireNoArguments(args, command: "setup")
            return .setup
        case "observe":
            let parsed = try commandOptions(args, values: ["--after"], flags: [])
            guard parsed.positionals.isEmpty else {
                throw CLIParseError.usage("observe accepts only --after REV")
            }
            return .observe(afterRevision: try uint64Option(parsed.values["--after"], name: "--after"))
        case "state":
            try requireNoArguments(args, command: "state")
            return .state
        case "ui":
            return try parseUI(args)
        case "list":
            let parsed = try commandOptions(args, values: ["--folder", "--after", "--limit", "--sort"], flags: [])
            guard parsed.positionals.isEmpty else {
                throw CLIParseError.usage("list accepts only --folder, --limit, --after, or --sort")
            }
            return .command(.list(
                try optionalID(parsed.values["--folder"]),
                try pageCursor(parsed.values["--after"]),
                try limit(parsed.values["--limit"]),
                try listSort(parsed.values["--sort"])
            ))
        case "read":
            let parsed = try commandOptions(args, values: [], flags: [])
            guard parsed.positionals.count == 1 else {
                throw CLIParseError.usage("read requires <id-or-link>")
            }
            return .command(.read(try messageReference(parsed.positionals[0])))
        case "raw":
            let parsed = try commandOptions(args, values: [], flags: [])
            guard parsed.positionals.count == 1 else {
                throw CLIParseError.usage("raw requires <id-or-link>")
            }
            return .command(.raw(try messageReference(parsed.positionals[0])))
        case "search":
            let parsed = try commandOptions(args, values: ["--limit", "--after"], flags: ["--follow"])
            let query = parsed.positionals.joined(separator: " ")
            guard !query.isEmpty else {
                throw CLIParseError.usage("search requires <query>")
            }
            let follows = parsed.flags.contains("--follow")
            guard !parsed.values.keys.contains("--after") || follows else {
                throw CLIParseError.usage("--after is valid only with search --follow")
            }
            if follows {
                return .searchFollow(
                    query: query,
                    afterRevision: try uint64Option(parsed.values["--after"], name: "--after")
                )
            }
            return .command(.search(query, try limit(parsed.values["--limit"])))
        case "fetch-attachment":
            let parsed = try commandOptions(args, values: ["--output"], flags: ["--stream"])
            guard parsed.positionals.count == 2 else {
                throw CLIParseError.usage("fetch-attachment requires <id-or-link> <part>")
            }
            let stream = parsed.flags.contains("--stream")
            guard (parsed.values["--output"] != nil) != stream else {
                throw CLIParseError.usage("fetch-attachment requires exactly one of --output PATH or --stream")
            }
            return .attachment(
                .fetchAttachment(
                    try messageReference(parsed.positionals[0]),
                    parsed.positionals[1]
                ),
                output: parsed.values["--output"],
                stream: stream
            )
        case "mark":
            let parsed = try commandOptions(args, values: selectionOptionNames, flags: [])
            let target: MessageTarget
            let action: String
            if parsed.values.isEmpty {
                guard parsed.positionals.count == 2 else {
                    throw CLIParseError.usage("mark requires <id-or-link> read|unread")
                }
                target = try messageTarget(parsed.positionals[0])
                action = parsed.positionals[1]
            } else {
                guard parsed.positionals.count == 1 else {
                    throw CLIParseError.usage("mark selection target requires read or unread")
                }
                target = try selectionTarget(parsed.values)
                action = parsed.positionals[0]
            }
            switch action {
            case "read": return .command(.markRead(target))
            case "unread": return .command(.markUnread(target))
            default: throw CLIParseError.usage("mark requires read or unread")
            }
        case "flag":
            let parsed = try commandOptions(args, values: selectionOptionNames, flags: ["--off"])
            let target: MessageTarget
            if parsed.values.isEmpty {
                guard parsed.positionals.count == 1 else {
                    throw CLIParseError.usage("flag requires <id-or-link>")
                }
                target = try messageTarget(parsed.positionals[0])
            } else {
                guard parsed.positionals.isEmpty else {
                    throw CLIParseError.usage("flag selection target accepts no message id")
                }
                target = try selectionTarget(parsed.values)
            }
            return .command(.setFlagged(target, !parsed.flags.contains("--off")))
        case "archive", "trash":
            let parsed = try commandOptions(args, values: selectionOptionNames, flags: [])
            let target: MessageTarget
            if parsed.values.isEmpty {
                guard parsed.positionals.count == 1 else {
                    throw CLIParseError.usage("\(verb) requires <id-or-link>")
                }
                target = try messageTarget(parsed.positionals[0])
            } else {
                guard parsed.positionals.isEmpty else {
                    throw CLIParseError.usage("\(verb) selection target accepts no message id")
                }
                target = try selectionTarget(parsed.values)
            }
            if verb == "archive" {
                return .command(.archive(target))
            }
            return .command(.trash(target))
        case "move":
            let parsed = try commandOptions(args, values: ["--folder"] + selectionOptionNames, flags: [])
            guard let rawFolder = parsed.values["--folder"] else {
                throw CLIParseError.usage("move requires --folder ID")
            }
            let target: MessageTarget
            if parsed.values.keys.contains(where: { selectionOptionNames.contains($0) }) {
                guard parsed.positionals.isEmpty else {
                    throw CLIParseError.usage("move selection target accepts no message id")
                }
                target = try selectionTarget(parsed.values)
            } else {
                guard parsed.positionals.count == 1 else {
                    throw CLIParseError.usage("move requires <id-or-link> --folder ID")
                }
                target = try messageTarget(parsed.positionals[0])
            }
            return .command(.move(target, try folderID(rawFolder)))
        case "undo":
            try requireNoArguments(args, command: "undo")
            return .command(.undo)
        case "refresh":
            try requireNoArguments(args, command: "refresh")
            return .command(.refresh)
        case "draft": return try parseDraft(args)
        case "outbox": return try parseOutbox(args)
        case "account": return try parseAccount(args)
        case "settings": return try parseSettings(args)
        case "engine":
            guard args.count == 1, let action = CLIEngineAction(rawValue: args[0]) else {
                throw CLIParseError.usage("engine requires start, stop, or status")
            }
            return .engine(action)
        case "pair":
            if args.first == "--revoke" {
                guard args.count == 2, let id = UUID(uuidString: args[1]) else {
                    throw CLIParseError.usage("pair --revoke requires a client UUID")
                }
                return .pairing(.revoke(id))
            }
            if args.first == "--code" {
                guard args.count == 2, !args[1].isEmpty else {
                    throw CLIParseError.usage("pair --code requires an offer code")
                }
                return .pairing(.code(args[1]))
            }
            if args.isEmpty || args == ["show"] || args == ["--show"] {
                return .pairing(.show(grant: nil))
            }
            if args.first == "--show" || args.first == "show" {
                guard args.count == 3, args[1] == "--grant" else {
                    throw CLIParseError.usage("pair --show accepts optional --grant FILE")
                }
                return .pairing(.show(grant: try pairingGrant(path: args[2])))
            }
            throw CLIParseError.usage("pair accepts --show [--grant FILE], --code WORDS, or --revoke UUID")
        case "remote":
            guard let action = args.first else { return .pairing(.remoteStatus) }
            if action == "status" {
                guard args.count == 1 else {
                    throw CLIParseError.usage("remote status accepts no additional arguments")
                }
                return .pairing(.remoteStatus)
            }
            if action == "disable" {
                guard args.count == 1 else {
                    throw CLIParseError.usage("remote disable accepts no additional arguments")
                }
                return .pairing(.remoteDisable)
            }
            guard (action == "enable" || action == "bind"),
                  args.count == 3,
                  let port = UInt16(args[2]),
                  port != 0 else {
                throw CLIParseError.usage("remote enable|bind requires <host> <port>")
            }
            return .pairing(.remoteEnable(host: args[1], port: port))
        case "folder": return try parseFolder(args)
        default: throw CLIParseError.usage("Unknown command \(verb).\n\n\(usage)")
        }
    }

    public static var usage: String {
        """
        mailternal [global options] <command>
        mailternal --container PATH <command>
        mailternal --host USER@HOST <command>
        mailternal --host https://HOST[:PORT] <command>

        Global options:
          --container PATH                  --app APP-OR-EXECUTABLE
          --no-start                        --password-stdin

          list [--folder ID] [--limit N (1...\(AutomationProtocol.maximumQueryLimit))] [--after CURSOR] [--sort FIELD:DIRECTION]
          read|raw <id-or-mailternal-link>
          search "<query>" [--limit N (1...\(AutomationProtocol.maximumQueryLimit))] [--follow [--after REV]]
          fetch-attachment <id-or-link> <part> --output PATH
          mark <target-list> read|unread     flag <target-list> [--off]
          archive|trash <target-list>        move <target-list> --folder ID
          mark --selection-revision REV [--selection-folder ID|none] [--selection-ids ID[,ID...]] read|unread
          flag --selection-revision REV [--selection-folder ID|none] [--selection-ids ID[,ID...]] [--off]
          archive|trash --selection-revision REV [--selection-folder ID|none] [--selection-ids ID[,ID...]]
          move --selection-revision REV [--selection-folder ID|none] [--selection-ids ID[,ID...]] --folder ID
          undo                               refresh

        Accounts, folders, and settings:
          account list
          account add JSON-FILE
          account enable|disable|remove ID   account rename ID NAME
          account export [ID...] [--settings]
          account import FILE [ID...] [--replace] [--settings]
          folder rename ID NAME             folder retention ID true|false
          settings list|get KEY|set KEY [VALUE]

        Drafts and sending:
          account smtp configure ID --file JSON [--use-imap-password|--keep-password]
          account smtp disable ID
          draft create --account ID --file JSON
          draft reply <id-or-link> [--all]    draft forward <id-or-link>
          draft list [--account ID] [--limit N]   draft get UUID
          draft save UUID --revision N --file JSON
          draft delete UUID --revision N     draft send UUID --revision N
          draft attach UUID --file PATH [--filename NAME] [--mime TYPE]
          draft attach UUID --file - --filename NAME [--mime TYPE]
          draft attachment UUID --account ID (--output PATH|--stream)
          outbox list [--account ID] [--limit N]   outbox get UUID
          outbox retry UUID [--acknowledge-duplicate-risk]   outbox cancel UUID
          SMTP configuration without a credential-reuse flag requires a transient
          password via --password-stdin or MAILTERNAL_PASSWORD. Draft JSON contains
          editable content, not credentials. Send queues durably; it is not a
          delivery receipt. Unknown delivery is never retried automatically.
          A locally auto-started owner remains running after a send or outbox retry
          request so queued delivery can finish. Use engine stop to stop it.

        Engine and local pairing:
          engine start|stop|status
          pair --show [--grant JSON-FILE] | pair --code WORDS | pair --revoke UUID
          remote status|disable|enable HOST PORT
          `pair --show` reuses a reachable owner or starts a headless owner on
          macOS; a newly started owner remains running for the offer's lifetime.
          `--no-start` makes an absent owner an exit-3 unavailable result.
          `remote status` never starts an owner and reports persisted enabled
          intent plus actual listener running/host/port state.

        GUI (explicit; never implied by ordinary mail commands):
          ui state|observe [--after REV]
          ui folder [ID]                    ui select <target-list> [--anchor REF]
          ui select --selection-revision REV [--selection-folder ID|none] [--selection-ids ID[,ID...]]
          ui select-all|clear-selection     ui open|open-window <id-or-link>
          ui search-open <id-or-link>        ui activate-tab|close-tab|close-others|keep-tab <TAB>
          ui move-tab <TAB> <INDEX>          ui next-tab|previous-tab
          ui find-present true|false
          ui workspace-category workspace|appearance|actions true|false
          ui workspace-resolve workspace|appearance|actions local|cloud
          ui search|find|sidebar|settings|raw
          ui find-query|search-query <TEXT>  ui search-select [REF]
          ui search-focus|pairing-present true|false
          ui pairing-action <JSON-FILE>
          ui reading-mode original|dark      ui remote-images true|false
          ui list-target currentFolder|global
          ui pane-layout sideBySide|listAboveReader
          ui presentation cards|columns       ui list-column-order <COLUMN,...>
          ui list-column-visible <COLUMN> true|false
          ui list-column-width <COLUMN> <WIDTH>
          ui list-sort FIELD:DIRECTION        ui reset-list [currentFolder|global]
          ui workspace-sync true|false

        A target-list is a comma-separated homogeneous list of local message IDs
        or canonical mailternal message links; an empty, mixed, or malformed list
        is usage error. Selection targets carry the current GUI's revision and,
        when needed to identify that context, its folder and message IDs.
        `--` ends option parsing for a command.

        Exit status: 0 success, 1 domain failure, 2 usage, 3 unavailable, 4 authentication/authorization.
        """
    }

    public static func schemaJSON() throws -> Data {
        try AutomationSchemaGenerator.makeJSON()
    }
    /// Converts a single JSON result into readable lines for an interactive
    /// terminal. Piped callers continue to receive the original bytes; every
    /// field remains represented here, including schema tags and nested data.
    public static func terminalOutput(_ data: Data) -> Data {
        guard let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return data
        }
        if let object = value as? [String: Any],
           object["schema"] as? String == "mailternal.setup.v1",
           let command = object["command"] as? String {
            return Data((command + "\n").utf8)
        }
        let lines = humanLines(value, indent: 0, label: nil)
        guard !lines.isEmpty else { return Data("\n".utf8) }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    private static func humanLines(_ value: Any, indent: Int, label: String?) -> [String] {
        let prefix = String(repeating: "  ", count: indent)
        switch value {
        case let object as [String: Any]:
            var lines: [String] = []
            if let schema = object["schema"] as? String {
                lines.append("\(prefix)\(label.map { "\($0): " } ?? "")[\(schema)]")
            } else if let label {
                lines.append("\(prefix)\(label):")
            }
            let entries = object.keys.sorted()
            for key in entries where key != "schema" {
                guard let child = object[key] else { continue }
                if let scalar = humanScalar(child) {
                    lines.append("\(prefix)  \(key)=\(scalar)")
                } else {
                    lines.append(contentsOf: humanLines(child, indent: indent + 1, label: key))
                }
            }
            if lines.isEmpty, let label { lines.append("\(prefix)\(label): {}") }
            return lines
        case let array as [Any]:
            var lines: [String] = []
            if let label { lines.append("\(prefix)\(label) [\(array.count)]") }
            for (index, child) in array.enumerated() {
                if let scalar = humanScalar(child) {
                    lines.append("\(prefix)  [\(index)]=\(scalar)")
                } else {
                    lines.append(contentsOf: humanLines(child, indent: indent + 1, label: "[\(index)]"))
                }
            }
            return lines
        default:
            return [prefix + (label.map { "\($0)=" } ?? "") + (humanScalar(value) ?? String(describing: value))]
        }
    }

    private static func humanScalar(_ value: Any) -> String? {
        if value is NSNull { return "null" }
        if let string = value as? String {
            return terminalSafe(string)
        }
        if let number = value as? NSNumber {
            if String(cString: number.objCType) == "c" {
                return number.boolValue ? "true" : "false"
            }
            return number.stringValue
        }
        return nil
    }

    private static func terminalSafe(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(value.utf8.count)
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x09:
                result.append("\t")
            case 0x0A:
                result.append("\\n")
            case 0x00...0x1F, 0x7F...0x9F:
                let hex = String(scalar.value, radix: 16, uppercase: true)
                result.append("\\u")
                result.append(String(repeating: "0", count: max(0, 4 - hex.count)))
                result.append(hex)
            default:
                result.append(String(scalar))
            }
        }
        return result
    }

    /// Executes one request and emits output incrementally. Ordinary non-GUI
    /// requests start a temporary headless owner when needed; pairing offers
    /// use a persistent headless owner so they remain claimable.
    /// Large JSON and binary chunks are opaque; only complete small responses
    /// should be human-formatted. Failures after output begins go to stderr.
    public static func execute(
        _ arguments: [String],
        endpoint suppliedEndpoint: AutomationEndpoint? = nil,
        token suppliedToken: String? = nil,
        emit: @escaping (Data) -> Void
    ) -> Int32 {
        var didEmit = false
        let deliver: (Data) -> Void = { data in
            didEmit = true
            emit(data)
        }
        let reportFailure: (Data) -> Void = { data in
            if didEmit { FileHandle.standardError.write(data) }
            else { emit(data) }
        }
        let deliverResult: ((Int32, Data)) -> Int32 = { result in
            if !result.1.isEmpty { deliver(result.1) }
            return result.0
        }
        do {
            let parsed = try splitOptions(arguments)
            let invocation = try parse(parsed.commandArguments)
            if let pairedHost = parsed.options.pairedHost {
                if case .pairing(.code(let code)) = invocation {
                    return deliverResult(try pairOverTLS(code: code, parsed: parsed, host: pairedHost))
                }
                return deliverResult(try executeOverTLS(
                    invocation: invocation,
                    parsed: parsed,
                    host: pairedHost,
                    emit: deliver
                ))
            }
            if let host = parsed.options.host {
                #if os(macOS) || os(Linux)
                return deliverResult(try executeOverSSH(parsed: parsed, host: host, emit: deliver))
                #else
                return deliverResult((3, errorOutput("SSH transport is unavailable on this platform.", failure: .unavailable)))
                #endif
            }
            switch invocation {
            case .schema:
                return deliverResult((0, try schemaJSON()))
            case .help:
                return deliverResult((0, jsonOutput([
                    "schema": "mailternal.help.v1",
                    "version": 1,
                    "usage": usage
                ])))
            case .setup:
                return deliverResult((0, setupOutput(endpoint: suppliedEndpoint, options: parsed.options)))
            case .pairing(let action):
                return deliverResult(pairing(action: action, endpoint: suppliedEndpoint, options: parsed.options, emit: deliver))
            case .engine(let action):
                return deliverResult(engine(
                    action: action, suppliedEndpoint: suppliedEndpoint,
                    suppliedToken: suppliedToken, options: parsed.options
                ))
            case .searchFollow:
                return deliverResult((2, errorOutput("search --follow must be streamed", failure: .usage)))
            case .state, .uiState, .observe, .uiObserve, .command, .attachment, .draftAttachment:
                let result = try executeRequest(
                    invocation: invocation,
                    parsed: parsed,
                    suppliedEndpoint: suppliedEndpoint,
                    suppliedToken: suppliedToken,
                    emit: deliver
                )
                if !result.output.isEmpty {
                    deliver(result.output)
                }
                return result.status
            }
        } catch let error as CLIParseError {
            reportFailure(errorOutput(error.localizedDescription, failure: .usage))
            return 2
        } catch let error as AutomationCommandError {
            reportFailure(errorOutput(error.localizedDescription, failure: error.failure))
            return error.failure.exitCode
        } catch let error as AutomationSecurityError {
            let failure = automationFailure(for: error)
            reportFailure(errorOutput(error.localizedDescription, failure: failure))
            return failure.exitCode
        } catch {
            reportFailure(errorOutput(error.localizedDescription, failure: .unavailable))
            return 3
        }
    }
    /// Streams one ordered state observation as JSONL. The callback is invoked
    /// once per wire response, so callers can forward each line immediately.
    public static func stream(
        _ arguments: [String],
        endpoint suppliedEndpoint: AutomationEndpoint? = nil,
        token suppliedToken: String? = nil,
        emit: @escaping @Sendable (Data) -> Void
    ) -> Int32 {
        do {
            let parsed = try splitOptions(arguments)
            let invocation = try parse(parsed.commandArguments)
            switch invocation {
            case .observe, .uiObserve, .searchFollow:
                break
            default:
                throw CLIParseError.usage("streaming output is available only for observe or search --follow")
            }
            if let host = parsed.options.host {
                #if os(macOS) || os(Linux)
                return try streamOverSSH(parsed: parsed, host: host, emit: emit)
                #else
                emit(errorOutput("SSH transport is unavailable on this platform.", failure: .unavailable))
                return 3
                #endif
            }
            if let host = parsed.options.pairedHost {
                return streamOverTLS(invocation: invocation, parsed: parsed, host: host, emit: emit)
            }
            let after: UInt64?
            let uiObserve: Bool
            let followQuery: String?
            switch invocation {
            case .observe(let revision):
                after = revision; uiObserve = false; followQuery = nil
            case .uiObserve(let revision):
                after = revision; uiObserve = true; followQuery = nil
            case .searchFollow(let query, let revision):
                after = revision; uiObserve = false; followQuery = query
            default:
                throw CLIParseError.usage("streaming output is available only for observe or search --follow")
            }
            let endpoint = try resolveEndpoint(suppliedEndpoint, options: parsed.options)
            var resolvedToken = try resolveToken(suppliedToken, endpoint: endpoint, options: parsed.options)
            var startedHeadless = false
            if uiObserve {
                guard let token = resolvedToken,
                      let response = requestEngineStatus(endpoint: endpoint, token: token)
                else {
                    emit(errorOutput("A GUI runtime is not available for this command.", failure: .unavailable))
                    return 3
                }
                guard response.ok else {
                    emit(errorOutput(
                        response.error ?? "A GUI runtime is not available for this command.",
                        failure: response.failure ?? .unavailable
                    ))
                    return responseStatus(response, fallback: 3)
                }
                guard let result = response.result,
                      let runtime = try? AutomationLineCodec.decode(AutomationRuntimeStatus.self, from: result),
                      runtime.kind == .app
                else {
                    emit(errorOutput("A GUI runtime is not available for this command.", failure: .unavailable))
                    return 3
                }
            }
            if !socketResponds(endpoint: endpoint, token: resolvedToken) {
                guard !parsed.options.noStart, !uiObserve else {
                    emit(errorOutput(AutomationCommandError.appUnavailable.localizedDescription, failure: .unavailable))
                    return 3
                }
                #if os(macOS)
                startedHeadless = true
                try launchHeadlessRuntime(endpoint: endpoint, options: parsed.options)
                resolvedToken = try waitForRuntime(endpoint: endpoint, timeout: 15)
                #else
                emit(errorOutput(AutomationCommandError.appUnavailable.localizedDescription, failure: .unavailable))
                return 3
                #endif
            }
            guard let token = resolvedToken else {
                emit(errorOutput(AutomationCommandError.appUnavailable.localizedDescription, failure: .unavailable))
                return 3
            }
            let client = AutomationSocketClient(endpoint: endpoint)
            if let followQuery {
                defer {
                    if startedHeadless, let token = resolvedToken {
                        _ = requestEngineShutdown(endpoint: endpoint, token: token)
                    }
                }
                var previous: Data?
                while true {
                    let response = try client.request(AutomationRequest(
                        token: token,
                        origin: .localCLI,
                        command: .search(followQuery, 50)
                    ))
                    guard response.ok else {
                        emit(responseOutput(response))
                        return responseStatus(response, fallback: 1)
                    }
                    let output = responseOutput(response)
                    if output != previous {
                        emit(output)
                        previous = output
                    }
                    Thread.sleep(forTimeInterval: 1)
                }
            }
            let request = AutomationRequest(
                token: token,
                origin: .localCLI,
                command: nil,
                control: nil,
                wantsState: true,
                wantsGUIState: uiObserve,
                observesState: true,
                afterRevision: after,
                secret: nil
            )
            let completion = DispatchSemaphore(value: 0)
            let outcome = LockedStatus()
            let shouldStopHeadless = startedHeadless
            let shutdownToken = resolvedToken
            Task {
                defer {
                    if shouldStopHeadless, let shutdownToken {
                        _ = requestEngineShutdown(endpoint: endpoint, token: shutdownToken)
                    }
                    completion.signal()
                }
                do {
                    try await client.observe(request) { response in
                        emit(responseOutput(response))
                    }
                    outcome.set(3)
                    emit(errorOutput("Observation stream ended; reconnect to resynchronize.", failure: .unavailable))
                } catch let error as AutomationCommandError {
                    outcome.set(error.failure.exitCode)
                    emit(errorOutput(error.localizedDescription, failure: error.failure))
                } catch let error as AutomationSecurityError {
                    let failure = automationFailure(for: error)
                    outcome.set(failure.exitCode)
                    emit(errorOutput(error.localizedDescription, failure: failure))
                } catch {
                    outcome.set(3)
                    emit(errorOutput(error.localizedDescription, failure: .unavailable))
                }
            }
            completion.wait()
            return outcome.get()
        } catch let error as CLIParseError {
            emit(errorOutput(error.localizedDescription, failure: .usage)); return 2
        } catch let error as AutomationCommandError {
            emit(errorOutput(error.localizedDescription, failure: error.failure)); return error.failure.exitCode
        } catch let error as AutomationSecurityError {
            let failure = automationFailure(for: error)
            emit(errorOutput(error.localizedDescription, failure: failure)); return failure.exitCode
        } catch {
            emit(errorOutput(error.localizedDescription, failure: .unavailable)); return 3
        }
    }

    private static func executeRequest(
        invocation: CLIInvocation,
        parsed: ParsedArguments,
        suppliedEndpoint: AutomationEndpoint?,
        suppliedToken: String?,
        emit: @escaping (Data) -> Void
    ) throws -> (status: Int32, output: Data) {
        let endpoint = try resolveEndpoint(suppliedEndpoint, options: parsed.options)
        let token = try resolveToken(suppliedToken, endpoint: endpoint, options: parsed.options)
        let command: Command?
        let draftAttachment: (draftID: UUID, path: String, mimeType: String?, filename: String)?
        let wantsState: Bool
        let wantsGUIState: Bool
        let observes: Bool
        let after: UInt64?
        let attachmentOutput: String?
        let attachmentStream: Bool
        switch invocation {
        case .state:
            command = nil; draftAttachment = nil
            wantsState = true; wantsGUIState = false; observes = false; after = nil
            attachmentOutput = nil; attachmentStream = false
        case .uiState:
            command = nil; draftAttachment = nil
            wantsState = true; wantsGUIState = true; observes = false; after = nil
            attachmentOutput = nil; attachmentStream = false
        case .observe(let revision):
            command = nil; draftAttachment = nil
            wantsState = true; wantsGUIState = false; observes = true; after = revision
            attachmentOutput = nil; attachmentStream = false
        case .uiObserve(let revision):
            command = nil; draftAttachment = nil
            wantsState = true; wantsGUIState = true; observes = true; after = revision
            attachmentOutput = nil; attachmentStream = false
        case .command(let value):
            command = value; draftAttachment = nil
            wantsState = false; wantsGUIState = false; observes = false; after = nil
            attachmentOutput = nil; attachmentStream = false
        case .attachment(let value, let output, let stream):
            command = value; draftAttachment = nil
            wantsState = false; wantsGUIState = false; observes = false; after = nil
            attachmentOutput = output; attachmentStream = stream
        case .draftAttachment(let draftID, let path, let mimeType, let filename):
            command = nil; draftAttachment = (draftID, path, mimeType, filename)
            wantsState = false; wantsGUIState = false; observes = false; after = nil
            attachmentOutput = nil; attachmentStream = false
        default:
            throw AutomationCommandError.unsupported("not a request")
        }
        let writer: (any AutomationTransferSink)? = try attachmentOutput.map { try ExclusiveOutputWriter(path: $0) }

        let requiresGUI: Bool = {
            if command?.requiresGUI == true { return true }
            switch invocation {
            case .uiState, .uiObserve: return true
            default: return false
            }
        }()
        if requiresGUI {
            guard let token,
                  let response = requestEngineStatus(endpoint: endpoint, token: token)
            else {
                return (3, errorOutput("A GUI runtime is not available for this command.", failure: .unavailable))
            }
            guard response.ok else {
                let status = responseStatus(response, fallback: 3)
                return (status, errorOutput(response.error ?? "A GUI runtime is not available for this command.", failure: response.failure ?? .unavailable))
            }
            guard let result = response.result,
                  let runtime = try? AutomationLineCodec.decode(AutomationRuntimeStatus.self, from: result),
                  runtime.kind == .app
            else {
                return (3, errorOutput("A GUI runtime is not available for this command.", failure: .unavailable))
            }
        }
        var startedHeadless = false
        var resolvedToken = token
        if !socketResponds(endpoint: endpoint, token: token) {
            guard !parsed.options.noStart, !requiresGUI else {
            return (3, errorOutput(AutomationCommandError.appUnavailable.localizedDescription, failure: .unavailable))
            }
            #if os(macOS)
            try launchHeadlessRuntime(endpoint: endpoint, options: parsed.options)
            resolvedToken = try waitForRuntime(endpoint: endpoint, timeout: 15)
            startedHeadless = true
            #else
            return (3, errorOutput(AutomationCommandError.appUnavailable.localizedDescription, failure: .unavailable))
            #endif
        }
        guard let resolvedToken else {
            return (3, errorOutput(AutomationCommandError.appUnavailable.localizedDescription, failure: .unavailable))
        }
        var retainsOutgoingOwner = false
        defer {
            if startedHeadless, !retainsOutgoingOwner {
                _ = requestEngineShutdown(endpoint: endpoint, token: resolvedToken)
            }
        }

        if let draftAttachment {
            let uploadClient = AutomationSocketClient(endpoint: endpoint)
            return try executeDraftAttachment(
                draftID: draftAttachment.draftID,
                path: draftAttachment.path,
                mimeType: draftAttachment.mimeType,
                filename: draftAttachment.filename,
                token: resolvedToken,
                origin: .localCLI,
                clientID: nil,
                emit: emit,
                request: { request in try uploadClient.request(request) }
            )
        }
        let secret = try readSecret(options: parsed.options)
        let request = AutomationRequest(
            token: resolvedToken,
            origin: .localCLI,
            command: command,
            control: nil,
            wantsState: wantsState,
            wantsGUIState: wantsGUIState,
            observesState: observes,
            afterRevision: after,
            secret: secret
        )
        // A lost acknowledgement may still mean durable admission. Keep the
        // worker alive once a delivery request can have reached the runtime.
        retainsOutgoingOwner = command?.name == .sendDraft || command?.name == .retrySubmission
        let response = try AutomationSocketClient(endpoint: endpoint).request(request)
        guard response.ok else {
            return (responseStatus(response, fallback: 1), responseOutput(response))
        }
        if let command, command.name == .fetchAttachment || command.name == .getDraftAttachment {
            if !attachmentStream, attachmentOutput == nil {
                throw CLIParseError.usage("attachment download requires a local output destination")
            }
            guard let descriptor = try commandTransferDescriptor(from: response),
                  descriptor.kind == .attachment else {
                throw AutomationCommandError.unsupported("attachment transfer was unavailable")
            }
            _ = try drainUnixTransfer(
                endpoint: endpoint,
                token: resolvedToken,
                descriptor: descriptor,
                writer: writer,
                rawEmit: attachmentStream ? emit : nil
            )
            if attachmentStream {
                return (0, Data())
            }
            return (0, cliResultOutput([
                "output": attachmentOutput ?? "",
                "bytes": descriptor.size
            ]))
        }
        if let descriptor = try commandTransferDescriptor(from: response) {
            guard descriptor.kind == .commandResult else {
                throw AutomationCommandError.unsupported("unexpected transfer kind")
            }
            let spool = try BoundedTransferSpool(maximumBytes: descriptor.size)
            _ = try drainUnixTransfer(
                endpoint: endpoint,
                token: resolvedToken,
                descriptor: descriptor,
                writer: spool
            )
            defer { spool.abort() }
            try streamCommandTransfer(response, spool: spool, emit: emit)
            return (0, Data())
        }
        return (responseStatus(response, fallback: 1), responseOutput(response))
    }

    private static func executeDraftAttachment(
        draftID: UUID,
        path: String,
        mimeType: String?,
        filename: String,
        token: String,
        origin: CommandOrigin,
        clientID: String?,
        emit: (Data) -> Void,
        request: (AutomationRequest) throws -> AutomationResponse
    ) throws -> (status: Int32, output: Data) {
        let input = try DraftAttachmentInput(path: path)
        func commandValue<Value: Decodable>(
            _ response: AutomationResponse, as type: Value.Type
        ) throws -> Value {
            guard response.ok, let result = response.result,
                  let commandResult = try? AutomationLineCodec.decode(CommandResult.self, from: result),
                  let data = commandResult.data else {
                throw AutomationCommandError.unsupported("malformed command result")
            }
            if let descriptor = try commandTransferDescriptor(from: response) {
                guard descriptor.kind == .commandResult else {
                    throw AutomationCommandError.unsupported("unexpected transfer kind")
                }
                var payload = Data()
                payload.reserveCapacity(Int(descriptor.size))
                try drainTransfer(descriptor: descriptor, writer: nil, rawEmit: { payload.append($0) }) {
                    control, offset, length in
                    try request(AutomationRequest(
                        token: token, origin: origin, clientID: clientID, control: control,
                        transferID: descriptor.transferID, transferOffset: offset, transferLength: length
                    ))
                }
                return try AutomationLineCodec.decode(Value.self, from: payload)
            }
            return try AutomationLineCodec.decode(Value.self, from: data)
        }
        let draftResponse = try request(AutomationRequest(
            token: token, origin: origin, clientID: clientID, command: .getDraft(draftID)
        ))
        guard draftResponse.ok else {
            return (responseStatus(draftResponse, fallback: 1), responseOutput(draftResponse))
        }
        let optionalDraft: MailDraft? = try commandValue(draftResponse, as: MailDraft?.self)
        guard let loadedDraft = optionalDraft else {
            throw AutomationCommandError.unsupported("draft is unavailable")
        }
        let draft = loadedDraft
        let source = input.handle
        let contentType = mimeType ?? "application/octet-stream"
        let createResponse = try request(AutomationRequest(
            token: token, origin: origin, clientID: clientID, control: .transferCreate,
            transferTotalBytes: input.size,
            transferFilename: filename, transferContentType: contentType
        ))
        guard createResponse.ok else {
            return (responseStatus(createResponse, fallback: 1), responseOutput(createResponse))
        }
        let descriptor: AutomationTransferDescriptor = try {
            guard createResponse.ok, let result = createResponse.result,
                  let value = try? AutomationLineCodec.decode(AutomationTransferDescriptor.self, from: result),
                  value.kind == .attachment,
                  value.schema == AutomationProtocol.transferSchema,
                  value.version == AutomationProtocol.version,
                  value.chunkBytes == AutomationTransferPolicy.chunkBytes,
                  value.size == input.size
            else { throw AutomationCommandError.unsupported("attachment upload was unavailable") }
            return value
        }()
        var uploadConsumed = false
        defer {
            if !uploadConsumed {
                _ = try? request(AutomationRequest(
                    token: token, origin: origin, clientID: clientID, control: .transferCancel,
                    transferID: descriptor.transferID
                ))
            }
        }
        var offset: UInt64 = 0
        var sequence: UInt64 = 0
            while offset < descriptor.size || descriptor.size == 0 && sequence == 0 {
                let length = Int(min(UInt64(descriptor.chunkBytes), descriptor.size - offset))
                let data = length == 0 ? Data() : (try source.read(upToCount: length) ?? Data())
                guard data.count == length else {
                    throw AutomationCommandError.unsupported("attachment file changed during upload")
                }
                let final = offset + UInt64(data.count) == descriptor.size
                let response = try request(AutomationRequest(
                    token: token, origin: origin, clientID: clientID, control: .transferWrite,
                    transferID: descriptor.transferID, transferOffset: offset,
                    transferLength: data.count, transferSequence: sequence,
                    transferTotalBytes: descriptor.size, transferData: data,
                    transferFinal: final
                ))
                guard response.ok else {
                    return (responseStatus(response, fallback: 1), responseOutput(response))
                }
                offset += UInt64(data.count)
                sequence += 1
                if final { break }
            }
            let imported = try request(AutomationRequest(
                token: token, origin: origin, clientID: clientID,
                command: .importDraftAttachment(
                    id: descriptor.transferID,
                    account: draft.accountID,
                    source: .transfer(descriptor.transferID),
                    filename: filename,
                    mimeType: contentType
                )
            ))
            guard imported.ok else {
                return (responseStatus(imported, fallback: 1), responseOutput(imported))
            }
            uploadConsumed = true
            let attachment: DraftAttachment = try commandValue(imported, as: DraftAttachment.self)
            var content = draft.content
            content.attachments.append(attachment)
            let saved = try request(AutomationRequest(
                token: token, origin: origin, clientID: clientID,
                command: .saveDraft(
                    id: draft.id, expectedRevision: draft.revision, content: content
                )
            ))
            guard saved.ok else { return (responseStatus(saved, fallback: 1), responseOutput(saved)) }
            if let descriptor = try commandTransferDescriptor(from: saved) {
                guard descriptor.kind == .commandResult else {
                    throw AutomationCommandError.unsupported("unexpected transfer kind")
                }
                let spool = try BoundedTransferSpool(maximumBytes: descriptor.size)
                defer { spool.abort() }
                try drainTransfer(descriptor: descriptor, writer: spool, rawEmit: nil) {
                    control, offset, length in
                    try request(AutomationRequest(
                        token: token, origin: origin, clientID: clientID, control: control,
                        transferID: descriptor.transferID, transferOffset: offset, transferLength: length
                    ))
                }
                try streamCommandTransfer(saved, spool: spool, emit: emit)
                return (0, Data())
            }
            return (responseStatus(saved, fallback: 0), responseOutput(saved))
    }
    private static func streamCommandTransfer(
        _ response: AutomationResponse,
        spool: BoundedTransferSpool,
        emit: (Data) -> Void
    ) throws {
        guard let result = response.result,
              let commandResult = try? AutomationLineCodec.decode(CommandResult.self, from: result)
        else {
            throw AutomationCommandError.unsupported("malformed command result")
        }
        var metadata: [String: Any] = [
            "schema": "mailternal.cli.result.v1",
            "version": 1,
            "ok": true,
            "command": commandResult.command.rawValue
        ]
        if let revision = commandResult.stateRevision {
            metadata["stateRevision"] = revision
        }
        let encoded = jsonOutput(metadata)
        guard encoded.count >= 2 else {
            throw AutomationCommandError.unsupported("malformed command envelope")
        }
        emit(Data(encoded.dropLast(2)) + Data(",\"result\":".utf8))
        try spool.streamContents(emit)
        emit(Data("}\n".utf8))
    }

    private static func commandTransferDescriptor(
        from response: AutomationResponse
    ) throws -> AutomationTransferDescriptor? {
        guard let result = response.result,
              let commandResult = try? AutomationLineCodec.decode(CommandResult.self, from: result),
              let data = commandResult.data
        else {
            return nil
        }
        guard let descriptor = try? AutomationLineCodec.decode(
            AutomationTransferDescriptor.self,
            from: data
        ) else {
            return nil
        }
        guard descriptor.schema == AutomationProtocol.transferSchema,
              descriptor.version == AutomationProtocol.version,
              descriptor.chunkBytes == AutomationTransferPolicy.chunkBytes,
              descriptor.size <= AutomationTransferPolicy.maximumBytes
        else {
            throw AutomationCommandError.unsupported("malformed transfer descriptor")
        }
        return descriptor
    }


    private static func drainUnixTransfer(
        endpoint: AutomationEndpoint,
        token: String,
        descriptor: AutomationTransferDescriptor,
        writer: (any AutomationTransferSink)?,
        rawEmit: ((Data) -> Void)? = nil
    ) throws {
        let client = AutomationSocketClient(endpoint: endpoint)
        try drainTransfer(descriptor: descriptor, writer: writer, rawEmit: rawEmit) { control, offset, length in
            try client.request(AutomationRequest(
                token: token, origin: .localCLI, control: control,
                transferID: descriptor.transferID, transferOffset: offset, transferLength: length
            ))
        }
    }

    private static func drainTransfer(
        descriptor: AutomationTransferDescriptor,
        writer: (any AutomationTransferSink)?,
        rawEmit: ((Data) -> Void)?,
        request: (AutomationControl, UInt64?, Int?) throws -> AutomationResponse
    ) throws {
        guard (writer != nil) != (rawEmit != nil) else {
            throw AutomationCommandError.unsupported("transfer output is unavailable")
        }
        var offset: UInt64 = 0
        var sequence: UInt64 = 0
        var completed = false
        defer {
            if !completed {
                writer?.abort()
                _ = try? request(.transferCancel, nil, nil)
            }
        }
        while true {
            let length = Int(min(UInt64(descriptor.chunkBytes), descriptor.size - offset))
            let response = try request(.transferRead, offset, length)
            guard response.ok,
                  let data = response.result,
                  let chunk = try? AutomationLineCodec.decode(AutomationTransferChunk.self, from: data),
                  chunk.schema == AutomationProtocol.transferSchema,
                  chunk.version == AutomationProtocol.version,
                  chunk.transferID == descriptor.transferID,
                  chunk.sequence == sequence,
                  chunk.offset == offset,
                  chunk.totalBytes == descriptor.size,
                  chunk.data.count == length,
                  chunk.final == (offset + UInt64(length) == descriptor.size) else {
                throw AutomationCommandError.unsupported("malformed transfer chunk")
            }
            if let rawEmit {
                rawEmit(chunk.data)
            } else if let writer {
                try writer.append(chunk.data)
            }
            offset += UInt64(length)
            sequence += 1
            if chunk.final {
                try writer?.finish()
                completed = true
                return
            }
        }
    }

    private static func parseAccount(_ args: [String]) throws -> CLIInvocation {
        guard let action = args.first else {
            throw CLIParseError.usage("account requires add, remove, list, export, or import")
        }
        if action == "smtp" {
            let rest = Array(args.dropFirst())
            guard let mode = rest.first else {
                throw CLIParseError.usage("account smtp requires configure or disable")
            }
            let parsed = try commandOptions(
                Array(rest.dropFirst()), values: ["--file"], flags: ["--use-imap-password", "--keep-password"]
            )
            guard parsed.positionals.count == 1 else {
                throw CLIParseError.usage("account smtp requires <account-id>")
            }
            let id = try accountID(parsed.positionals[0])
            switch mode {
            case "disable":
                guard parsed.values["--file"] == nil, parsed.flags.isEmpty else {
                    throw CLIParseError.usage("account smtp disable accepts no file")
                }
                return .command(.configureSMTP(id, nil, hasPassword: false))
            case "configure":
                guard let path = parsed.values["--file"],
                      let data = try? boundedFileData(path: path, maximumBytes: 1 * 1_024 * 1_024),
                      var config = try? JSONDecoder().decode(SMTPConfiguration.self, from: data)
                else { throw CLIParseError.usage("account smtp configure requires --file JSON") }
                guard parsed.flags.count <= 1 else {
                    throw CLIParseError.usage("choose either --use-imap-password or --keep-password")
                }
                if parsed.flags.contains("--use-imap-password") {
                    config.credentialReference = nil
                } else if parsed.flags.contains("--keep-password"), config.credentialReference?.isEmpty != false {
                    throw CLIParseError.usage("--keep-password requires the current SMTP credentialReference in the JSON file; use --use-imap-password for IMAP credentials")
                }
                return .command(.configureSMTP(id, config, hasPassword: parsed.flags.isEmpty))
            default:
                throw CLIParseError.usage("account smtp requires configure or disable")
            }
        }
        let parsed: ParsedCommandOptions
        switch action {
        case "export":
            parsed = try commandOptions(Array(args.dropFirst()), values: [], flags: ["--settings"])
            let ids = try parsed.positionals.map { try accountID($0) }
            return .command(.exportAccounts(ids, includeSettings: parsed.flags.contains("--settings")))
        case "import":
            parsed = try commandOptions(Array(args.dropFirst()), values: [], flags: ["--replace", "--settings"])
            guard let path = parsed.positionals.first,
                  let data = try? boundedFileData(path: path, maximumBytes: 262_197) else {
                throw CLIParseError.usage("account import requires an encrypted pairing file")
            }
            let ids = try parsed.positionals.dropFirst().map { try accountID($0) }
            return .command(.importAccounts(
                data,
                selectedIDs: ids,
                replaceExisting: parsed.flags.contains("--replace"),
                importSettings: parsed.flags.contains("--settings")
            ))
        default:
            parsed = try commandOptions(Array(args.dropFirst()), values: [], flags: [])
        }
        switch action {
        case "list":
            guard parsed.positionals.isEmpty else {
                throw CLIParseError.usage("account list accepts no arguments")
            }
            return .state
        case "enable":
            guard parsed.positionals.count == 1 else {
                throw CLIParseError.usage("account enable requires <account-id>")
            }
            return .command(.setAccountEnabled(try accountID(parsed.positionals[0]), true))
        case "disable":
            guard parsed.positionals.count == 1 else {
                throw CLIParseError.usage("account disable requires <account-id>")
            }
            return .command(.setAccountEnabled(try accountID(parsed.positionals[0]), false))
        case "rename":
            guard parsed.positionals.count >= 2 else {
                throw CLIParseError.usage("account rename requires <id> <name>")
            }
            return .command(.renameAccount(
                try accountID(parsed.positionals[0]),
                parsed.positionals.dropFirst().joined(separator: " ")
            ))
        case "remove":
            guard parsed.positionals.count == 1 else {
                throw CLIParseError.usage("account remove requires <account-id>")
            }
            return .command(.removeAccount(try accountID(parsed.positionals[0])))
        case "add":
            guard parsed.positionals.count == 1,
                  let data = try? boundedFileData(path: parsed.positionals[0], maximumBytes: 1 * 1_024 * 1_024),
                  let config = try? JSONDecoder().decode(AccountConfig.self, from: data) else {
                throw CLIParseError.usage("account add requires a JSON AccountConfig file")
            }
            return .command(.saveAccount(config, hasPassword: true))
        case "export", "import":
            throw CLIParseError.usage("account export/import parser branch was not selected")
        default:
            throw CLIParseError.usage("account requires add, remove, list, export, or import")
        }
    }

    private static func parseDraft(_ args: [String]) throws -> CLIInvocation {
        guard let action = args.first else {
            throw CLIParseError.usage("draft requires create, reply, forward, save, delete, get, list, attach, or send")
        }
        let rest = Array(args.dropFirst())
        switch action {
        case "create":
            let parsed = try commandOptions(rest, values: ["--account", "--file"], flags: [])
            guard parsed.positionals.isEmpty,
                  let account = parsed.values["--account"],
                  let path = parsed.values["--file"],
                  let data = try? boundedFileData(path: path, maximumBytes: 1 * 1_024 * 1_024),
                  let content = try? JSONDecoder().decode(DraftContent.self, from: data)
            else { throw CLIParseError.usage("draft create requires --account ID --file JSON") }
            return .command(.createDraft(id: UUID(), accountID: try accountID(account), content: content))
        case "reply":
            let parsed = try commandOptions(rest, values: [], flags: ["--all"])
            guard parsed.positionals.count == 1 else {
                throw CLIParseError.usage("draft reply requires <message-id-or-link>")
            }
            return .command(.createReplyDraft(
                id: UUID(), try messageReference(parsed.positionals[0]),
                replyAll: parsed.flags.contains("--all")
            ))
        case "forward":
            let parsed = try commandOptions(rest, values: [], flags: [])
            guard parsed.positionals.count == 1 else {
                throw CLIParseError.usage("draft forward requires <message-id-or-link>")
            }
            return .command(.createForwardDraft(id: UUID(), try messageReference(parsed.positionals[0])))
        case "save":
            let parsed = try commandOptions(rest, values: ["--revision", "--file"], flags: [])
            guard parsed.positionals.count == 1,
                  let revision = parsed.values["--revision"].flatMap(Int64.init),
                  let path = parsed.values["--file"],
                  let data = try? boundedFileData(path: path, maximumBytes: 1 * 1_024 * 1_024),
                  let content = try? JSONDecoder().decode(DraftContent.self, from: data)
            else { throw CLIParseError.usage("draft save requires UUID --revision N --file JSON") }
            return .command(.saveDraft(
                id: try uuid(parsed.positionals[0]), expectedRevision: revision, content: content
            ))
        case "delete":
            let parsed = try commandOptions(rest, values: ["--revision"], flags: [])
            guard parsed.positionals.count == 1,
                  let revision = parsed.values["--revision"].flatMap(Int64.init)
            else { throw CLIParseError.usage("draft delete requires UUID --revision N") }
            return .command(.deleteDraft(id: try uuid(parsed.positionals[0]), expectedRevision: revision))
        case "get":
            let parsed = try commandOptions(rest, values: [], flags: [])
            guard parsed.positionals.count == 1 else { throw CLIParseError.usage("draft get requires UUID") }
            return .command(.getDraft(try uuid(parsed.positionals[0])))
        case "list":
            let parsed = try commandOptions(rest, values: ["--account", "--limit"], flags: [])
            guard parsed.positionals.isEmpty else { throw CLIParseError.usage("draft list accepts options only") }
            return .command(.listDrafts(
                try parsed.values["--account"].map(accountID),
                try limit(parsed.values["--limit"])
            ))
        case "attachment":
            let parsed = try commandOptions(rest, values: ["--account", "--output"], flags: ["--stream"])
            let stream = parsed.flags.contains("--stream")
            guard parsed.positionals.count == 1, let account = parsed.values["--account"],
                  (parsed.values["--output"] != nil) != stream else {
                throw CLIParseError.usage("draft attachment requires UUID --account ID and exactly one of --output PATH or --stream")
            }
            return .attachment(
                .getDraftAttachment(account: try accountID(account), id: try uuid(parsed.positionals[0])),
                output: parsed.values["--output"], stream: stream
            )
        case "attach":
            let parsed = try commandOptions(rest, values: ["--file", "--mime", "--filename"], flags: [])
            guard parsed.positionals.count == 1, let path = parsed.values["--file"] else {
                throw CLIParseError.usage("draft attach requires UUID --file PATH")
            }
            guard path != "-" || parsed.values["--filename"] != nil else {
                throw CLIParseError.usage("draft attach --file - requires --filename NAME")
            }
            let filename = parsed.values["--filename"] ?? URL(fileURLWithPath: path).lastPathComponent
            guard !filename.isEmpty, filename != ".", filename != "..",
                  !filename.contains("/"), !filename.contains("\\"),
                  !filename.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
            else { throw CLIParseError.usage("attachment filename must be a single valid name") }
            return .draftAttachment(
                draftID: try uuid(parsed.positionals[0]), path: path,
                mimeType: parsed.values["--mime"], filename: filename
            )
        case "send":
            let parsed = try commandOptions(rest, values: ["--revision"], flags: [])
            guard parsed.positionals.count == 1,
                  let revision = parsed.values["--revision"].flatMap(Int64.init)
            else { throw CLIParseError.usage("draft send requires UUID --revision N") }
            return .command(.sendDraft(
                id: UUID(), draftID: try uuid(parsed.positionals[0]), expectedRevision: revision
            ))
        default:
            throw CLIParseError.usage("draft requires create, reply, forward, save, delete, get, list, attach, or send")
        }
    }

    private static func parseOutbox(_ args: [String]) throws -> CLIInvocation {
        guard let action = args.first else {
            throw CLIParseError.usage("outbox requires list, get, retry, or cancel")
        }
        let parsed = try commandOptions(
            Array(args.dropFirst()), values: ["--account", "--limit"],
            flags: ["--acknowledge-duplicate-risk"]
        )
        switch action {
        case "list":
            guard parsed.positionals.isEmpty else { throw CLIParseError.usage("outbox list accepts options only") }
            return .command(.listOutbox(
                try parsed.values["--account"].map(accountID),
                try limit(parsed.values["--limit"])
            ))
        case "get":
            guard parsed.positionals.count == 1 else { throw CLIParseError.usage("outbox get requires UUID") }
            return .command(.getSubmission(try uuid(parsed.positionals[0])))
        case "retry":
            guard parsed.positionals.count == 1 else { throw CLIParseError.usage("outbox retry requires UUID") }
            return .command(.retrySubmission(
                try uuid(parsed.positionals[0]),
                acknowledgeDuplicateRisk: parsed.flags.contains("--acknowledge-duplicate-risk")
            ))
        case "cancel":
            guard parsed.positionals.count == 1 else { throw CLIParseError.usage("outbox cancel requires UUID") }
            return .command(.cancelSubmission(try uuid(parsed.positionals[0])))
        default: throw CLIParseError.usage("outbox requires list, get, retry, or cancel")
        }
    }

    private static func parseFolder(_ args: [String]) throws -> CLIInvocation {
        guard let action = args.first else {
            throw CLIParseError.usage("folder requires rename or retention")
        }
        let parsed = try commandOptions(Array(args.dropFirst()), values: [], flags: [])
        switch action {
        case "rename":
            guard parsed.positionals.count >= 2 else {
                throw CLIParseError.usage("folder rename requires <id> <name>")
            }
            return .command(.renameFolder(
                try folderID(parsed.positionals[0]),
                parsed.positionals.dropFirst().joined(separator: " ")
            ))
        case "retention":
            guard parsed.positionals.count == 2,
                  let keep = Bool(parsed.positionals[1]) else {
                throw CLIParseError.usage("folder retention requires <id> true|false")
            }
            return .command(.setRetention(try folderID(parsed.positionals[0]), keep))
        default:
            throw CLIParseError.usage("folder requires rename or retention")
        }
    }

    private static func parseSettings(_ args: [String]) throws -> CLIInvocation {
        guard let action = args.first else {
            throw CLIParseError.usage("settings requires list, get, or set")
        }
        let parsed = try commandOptions(Array(args.dropFirst()), values: [], flags: [])
        switch action {
        case "list":
            guard parsed.positionals.isEmpty else {
                throw CLIParseError.usage("settings list accepts no arguments")
            }
            return .command(.getSettings)
        case "get":
            guard parsed.positionals.count == 1 else {
                throw CLIParseError.usage("settings get requires <key>")
            }
            return .command(.getSetting(parsed.positionals[0]))
        case "set":
            guard (1...2).contains(parsed.positionals.count) else {
                throw CLIParseError.usage("settings set requires <key> [value]")
            }
            return .command(.setSetting(parsed.positionals[0], parsed.positionals.dropFirst().first))
        default:
            throw CLIParseError.usage("settings requires list, get, or set")
        }
    }

    private static func parseUI(_ args: [String]) throws -> CLIInvocation {
        guard let action = args.first else {
            throw CLIParseError.usage("ui requires state, observe, or an explicit action")
        }
        let rest = Array(args.dropFirst())
        switch action {
        case "state":
            try requireNoArguments(rest, command: "ui state")
            return .uiState
        case "observe":
            let parsed = try commandOptions(rest, values: ["--after"], flags: [])
            guard parsed.positionals.isEmpty else {
                throw CLIParseError.usage("ui observe accepts only --after REV")
            }
            return .uiObserve(afterRevision: try uint64Option(parsed.values["--after"], name: "--after"))
        case "folder":
            let parsed = try commandOptions(rest, values: [], flags: [])
            guard parsed.positionals.count <= 1 else {
                throw CLIParseError.usage("ui folder accepts an optional folder id")
            }
            return .command(.selectFolder(try optionalID(parsed.positionals.first)))
        case "select":
            let parsed = try commandOptions(
                rest,
                values: ["--anchor"] + selectionOptionNames,
                flags: []
            )
            let hasSelection = parsed.values.keys.contains(where: { selectionOptionNames.contains($0) })
            let target: MessageTarget
            if hasSelection {
                guard parsed.positionals.isEmpty else {
                    throw CLIParseError.usage("ui select selection target accepts no message id")
                }
                target = try selectionTarget(parsed.values)
            } else {
                guard parsed.positionals.count == 1 else {
                    throw CLIParseError.usage("ui select requires comma-separated ids or links")
                }
                target = try messageTarget(parsed.positionals[0])
            }
            let anchor = try parsed.values["--anchor"].map { try messageReference($0) }
            return .command(.selectMessages(target, anchor: anchor))
        case "select-all":
            try requireNoArguments(rest, command: "ui select-all")
            return .command(.selectAll)
        case "clear-selection":
            try requireNoArguments(rest, command: "ui clear-selection")
            return .command(.clearSelection)
        case "find-query":
            let parsed = try commandOptions(rest, values: [], flags: [])
            return .command(.setFindQuery(parsed.positionals.joined(separator: " ")))
        case "workspace-sync":
            let parsed = try commandOptions(rest, values: [], flags: [])
            guard parsed.positionals.count == 1, let value = Bool(parsed.positionals[0]) else {
                throw CLIParseError.usage("workspace-sync requires true or false")
            }
            return .command(.setWorkspaceSync(value))
        case "workspace-category":
            let parsed = try commandOptions(rest, values: [], flags: [])
            guard parsed.positionals.count == 2,
                  let category = WorkspaceSyncCategory(rawValue: parsed.positionals[0]),
                  let enabled = Bool(parsed.positionals[1]) else {
                throw CLIParseError.usage("workspace-category requires <workspace|appearance|actions> true|false")
            }
            return .command(.setWorkspaceSyncCategory(category, enabled))
        case "workspace-resolve":
            let parsed = try commandOptions(rest, values: [], flags: [])
            guard parsed.positionals.count == 2,
                  let category = WorkspaceSyncCategory(rawValue: parsed.positionals[0]),
                  let choice = WorkspaceSyncChoice(rawValue: parsed.positionals[1]) else {
                throw CLIParseError.usage("workspace-resolve requires <workspace|appearance|actions> local|cloud")
            }
            return .command(.resolveWorkspaceSyncConflict(category, choice))
        case "list-target":
            let parsed = try commandOptions(rest, values: [], flags: [])
            guard parsed.positionals.count == 1,
                  let value = MailListCustomizationTargetValue(rawValue: parsed.positionals[0]) else {
                throw CLIParseError.usage("list-target requires currentFolder or global")
            }
            return .command(.setListCustomizationTarget(value))
        case "search-query":
            let parsed = try commandOptions(rest, values: [], flags: [])
            return .command(.setSearchQuery(parsed.positionals.joined(separator: " ")))
        case "search-select":
            let parsed = try commandOptions(rest, values: [], flags: [])
            guard parsed.positionals.count <= 1 else {
                throw CLIParseError.usage("search-select accepts an optional message id or canonical link")
            }
            return .command(.selectSearchResult(try parsed.positionals.first.map { try messageReference($0) }))
        case "search-focus":
            let parsed = try commandOptions(rest, values: [], flags: [])
            guard parsed.positionals.count == 1, let value = Bool(parsed.positionals[0]) else {
                throw CLIParseError.usage("search-focus requires true or false")
            }
            return .command(.setSearchFieldFocused(value))
        case "find-present":
            let parsed = try commandOptions(rest, values: [], flags: [])
            guard parsed.positionals.count == 1, let value = Bool(parsed.positionals[0]) else {
                throw CLIParseError.usage("find-present requires true or false")
            }
            return .command(.setFindPresented(value))
        case "cancel-search":
            try requireNoArguments(rest, command: "ui cancel-search")
            return .command(.cancelSearch)
        case "pairing-present":
            let parsed = try commandOptions(rest, values: [], flags: [])
            guard parsed.positionals.count == 1, let value = Bool(parsed.positionals[0]) else {
                throw CLIParseError.usage("pairing-present requires true or false")
            }
            return .command(.setPairingPresented(value))
        case "pairing-action":
            let parsed = try commandOptions(rest, values: [], flags: [])
            guard parsed.positionals.count == 1,
                  let data = try? boundedFileData(path: parsed.positionals[0], maximumBytes: 256 * 1_024),
                  let pairingAction = try? JSONDecoder().decode(PairingUIAction.self, from: data) else {
                throw CLIParseError.usage("pairing-action requires a JSON PairingUIAction file")
            }
            return .command(.pairingUI(pairingAction))
        case "pane-layout":
            let parsed = try commandOptions(rest, values: [], flags: [])
            guard parsed.positionals.count == 1,
                  let value = MailPaneLayout(rawValue: parsed.positionals[0]) else {
                throw CLIParseError.usage("pane-layout requires a valid layout")
            }
            return .command(.setListPaneLayout(value))
        case "presentation":
            let parsed = try commandOptions(rest, values: [], flags: [])
            guard parsed.positionals.count == 1,
                  let value = MailListPresentation(rawValue: parsed.positionals[0]) else {
                throw CLIParseError.usage("presentation requires cards or columns")
            }
            return .command(.setListPresentation(value))
        case "list-column-order":
            let parsed = try commandOptions(rest, values: [], flags: [])
            guard parsed.positionals.count == 1 else {
                throw CLIParseError.usage("list-column-order requires comma-separated columns")
            }
            return .command(.setListColumnOrder(try listColumnOrder(parsed.positionals[0])))
        case "list-column-visible":
            let parsed = try commandOptions(rest, values: [], flags: [])
            guard parsed.positionals.count == 2,
                  let visible = Bool(parsed.positionals[1]) else {
                throw CLIParseError.usage("list-column-visible requires <column> true|false")
            }
            return .command(.setListColumnVisible(try listColumn(parsed.positionals[0]), visible))
        case "list-column-width":
            let parsed = try commandOptions(rest, values: [], flags: [])
            guard parsed.positionals.count == 2,
                  let width = Double(parsed.positionals[1]),
                  width.isFinite,
                  width >= 0 else {
                throw CLIParseError.usage("list-column-width requires <column> a non-negative number")
            }
            return .command(.setListColumnWidth(try listColumn(parsed.positionals[0]), width))
        case "list-sort":
            let parsed = try commandOptions(rest, values: [], flags: [])
            guard parsed.positionals.count == 1 else {
                throw CLIParseError.usage("list-sort requires FIELD:DIRECTION")
            }
            return .command(.setListSort(try listSort(parsed.positionals[0])))
        case "reset-list":
            let parsed = try commandOptions(rest, values: [], flags: [])
            guard parsed.positionals.count <= 1 else {
                throw CLIParseError.usage("reset-list accepts optional currentFolder or global")
            }
            switch parsed.positionals.first ?? "currentFolder" {
            case "currentFolder": return .command(.resetListSettings)
            case "global": return .command(.resetGlobalListSettings)
            default: throw CLIParseError.usage("reset-list accepts currentFolder or global")
            }
        case "open":
            let parsed = try commandOptions(rest, values: [], flags: [])
            guard parsed.positionals.count == 1 else {
                throw CLIParseError.usage("ui open requires <id-or-link>")
            }
            return .command(.openMessage(try messageReference(parsed.positionals[0]), permanent: false))
        case "search-open":
            let parsed = try commandOptions(rest, values: [], flags: [])
            guard parsed.positionals.count == 1 else {
                throw CLIParseError.usage("ui search-open requires <id-or-link>")
            }
            return .command(.openSearchResult(try messageReference(parsed.positionals[0])))
        case "open-window":
            let parsed = try commandOptions(rest, values: [], flags: [])
            guard parsed.positionals.count == 1 else {
                throw CLIParseError.usage("ui open-window requires <id-or-link>")
            }
            return .command(.openWindow(try messageReference(parsed.positionals[0])))
        case "move-tab":
            let parsed = try commandOptions(rest, values: [], flags: [])
            guard parsed.positionals.count == 2, let index = Int(parsed.positionals[1]) else {
                throw CLIParseError.usage("move-tab requires <tab-uuid> <index>")
            }
            return .command(.moveTab(try uuid(parsed.positionals[0]), index))
        case "activate-tab":
            let parsed = try commandOptions(rest, values: [], flags: [])
            guard parsed.positionals.count == 1 else {
                throw CLIParseError.usage("activate-tab requires <tab-uuid>")
            }
            return .command(.activateTab(try uuid(parsed.positionals[0])))
        case "close-tab":
            let parsed = try commandOptions(rest, values: [], flags: [])
            guard parsed.positionals.count == 1 else {
                throw CLIParseError.usage("close-tab requires <tab-uuid>")
            }
            return .command(.closeTab(try uuid(parsed.positionals[0])))
        case "close-others":
            let parsed = try commandOptions(rest, values: [], flags: [])
            guard parsed.positionals.count == 1 else {
                throw CLIParseError.usage("close-others requires <tab-uuid>")
            }
            return .command(.closeOthers(try uuid(parsed.positionals[0])))
        case "close-to-right":
            let parsed = try commandOptions(rest, values: [], flags: [])
            guard parsed.positionals.count == 1 else {
                throw CLIParseError.usage("close-to-right requires <tab-uuid>")
            }
            return .command(.closeToRight(try uuid(parsed.positionals[0])))
        case "keep-tab":
            let parsed = try commandOptions(rest, values: [], flags: [])
            guard parsed.positionals.count == 1 else {
                throw CLIParseError.usage("keep-tab requires <tab-uuid>")
            }
            return .command(.keepTab(try uuid(parsed.positionals[0])))
        case "next-tab":
            try requireNoArguments(rest, command: "ui next-tab")
            return .command(.nextTab)
        case "previous-tab":
            try requireNoArguments(rest, command: "ui previous-tab")
            return .command(.previousTab)
        case "reading-mode":
            let parsed = try commandOptions(rest, values: [], flags: [])
            guard parsed.positionals.count == 1 else {
                throw CLIParseError.usage("reading-mode requires original or dark")
            }
            return .command(.setReadingMode(try readingMode(parsed.positionals[0])))
        case "remote-images":
            let parsed = try commandOptions(rest, values: [], flags: [])
            guard parsed.positionals.count == 1, let value = Bool(parsed.positionals[0]) else {
                throw CLIParseError.usage("remote-images requires true or false")
            }
            return .command(.setRemoteImages(value))
        case "search":
            try requireNoArguments(rest, command: "ui search")
            return .command(.toggleSearch)
        case "find":
            try requireNoArguments(rest, command: "ui find")
            return .command(.toggleFind)
        case "sidebar":
            try requireNoArguments(rest, command: "ui sidebar")
            return .command(.toggleSidebar)
        case "settings":
            try requireNoArguments(rest, command: "ui settings")
            return .command(.showSettings)
        case "raw":
            try requireNoArguments(rest, command: "ui raw")
            return .command(.toggleRawSource)
        default:
            throw CLIParseError.usage("Unknown ui action \(action)")
        }
    }
    private struct ParsedCommandOptions: Sendable {
        var positionals: [String]
        var values: [String: String]
        var flags: Set<String>
    }

    private static let selectionOptionNames = [
        "--selection-revision",
        "--selection-folder",
        "--selection-ids"
    ]

    private static func commandOptions(
        _ args: [String],
        values allowedValues: [String],
        flags allowedFlags: [String]
    ) throws -> ParsedCommandOptions {
        let valueNames = Set(allowedValues)
        let flagNames = Set(allowedFlags)
        var positionals: [String] = []
        var values: [String: String] = [:]
        var flags: Set<String> = []
        var optionsEnded = false
        var index = 0
        while index < args.count {
            let argument = args[index]
            if optionsEnded {
                positionals.append(argument)
                index += 1
                continue
            }
            if argument == "--" {
                optionsEnded = true
                index += 1
                continue
            }
            if argument.hasPrefix("--") {
                if flagNames.contains(argument) {
                    guard flags.insert(argument).inserted else {
                        throw CLIParseError.usage("\(argument) may be supplied only once")
                    }
                    index += 1
                    continue
                }
                guard valueNames.contains(argument) else {
                    throw CLIParseError.usage("Unknown option \(argument)")
                }
                guard values[argument] == nil,
                      args.indices.contains(index + 1),
                      !args[index + 1].isEmpty else {
                    throw CLIParseError.usage("\(argument) requires a value")
                }
                values[argument] = args[index + 1]
                index += 2
                continue
            }
            positionals.append(argument)
            index += 1
        }
        return ParsedCommandOptions(positionals: positionals, values: values, flags: flags)
    }

    private static func requireNoArguments(_ args: [String], command: String) throws {
        guard args.isEmpty || args == ["--"] else {
            throw CLIParseError.usage("\(command) accepts no additional arguments")
        }
    }

    private static func uint64Option(_ raw: String?, name: String) throws -> UInt64? {
        guard let raw else { return nil }
        guard let value = UInt64(raw) else {
            throw CLIParseError.usage("\(name) must be an unsigned integer")
        }
        return value
    }

    private static func selectionTarget(_ values: [String: String]) throws -> MessageTarget {
        guard let rawRevision = values["--selection-revision"],
              let revision = UInt64(rawRevision) else {
            throw CLIParseError.usage("--selection-revision requires an unsigned integer")
        }
        let selectedFolderID: FolderID?
        if let rawFolder = values["--selection-folder"] {
            if rawFolder == "none" {
                selectedFolderID = nil
            } else {
                selectedFolderID = try folderID(rawFolder)
            }
        } else {
            selectedFolderID = nil
        }
        let messageIDs: [MessageID]
        if let rawIDs = values["--selection-ids"] {
            messageIDs = try messageIDList(rawIDs)
        } else {
            messageIDs = []
        }
        return .selection(SelectionContext(
            revision: revision,
            folderID: selectedFolderID,
            messageIDs: messageIDs
        ))
    }

    private static func splitOptions(_ arguments: [String]) throws -> ParsedArguments {
        var options = Options()
        var commandArguments: [String] = []
        var index = 0
        var optionsEnded = false
        while index < arguments.count {
            let argument = arguments[index]
            if optionsEnded {
                commandArguments.append(argument)
                index += 1
                continue
            }
            if argument == "--" {
                commandArguments.append(argument)
                optionsEnded = true
                index += 1
                continue
            }
            switch argument {
            case "--container": options.container = try optionValue(arguments, &index, name: argument)
            case "--token": options.token = try optionValue(arguments, &index, name: argument)
            case "--host":
                try configureHost(try optionValue(arguments, &index, name: argument), options: &options)
            case "--ssh-port": options.sshPort = try optionValue(arguments, &index, name: argument)
            case "--app": options.app = try optionValue(arguments, &index, name: argument)
            case "--port":
                let value = try optionValue(arguments, &index, name: argument)
                guard let port = UInt16(value), port != 0 else {
                    throw CLIParseError.usage("--port must be a non-zero integer")
                }
                options.pairedPort = port
            case "--bearer": options.bearerToken = try optionValue(arguments, &index, name: argument)
            case "--client-id":
                let value = try optionValue(arguments, &index, name: argument)
                guard let id = UUID(uuidString: value) else {
                    throw CLIParseError.usage("--client-id must be a UUID")
                }
                options.clientID = id
            case "--fingerprint": options.fingerprint = try optionValue(arguments, &index, name: argument)
            case "--client-name": options.clientName = try optionValue(arguments, &index, name: argument)
            case "--no-start": options.noStart = true
            case "--password-stdin": options.passwordFromStdin = true
            default: commandArguments.append(argument)
            }
            index += 1
        }
        if options.host == nil, options.pairedHost == nil,
           let raw = ProcessInfo.processInfo.environment["MAILTERNAL_HOST"],
           !raw.isEmpty {
            try configureHost(raw, options: &options)
        }
        return ParsedArguments(options: options, commandArguments: commandArguments)
    }

    private static func configureHost(_ raw: String, options: inout Options) throws {
        if let url = URL(string: raw), url.scheme?.lowercased() == "https",
           let host = url.host, !host.isEmpty,
           url.user == nil, url.password == nil,
           (url.path.isEmpty || url.path == "/"),
           url.query == nil, url.fragment == nil {
            options.pairedHost = host
            if let port = url.port {
                guard let value = UInt16(exactly: port), value != 0 else {
                    throw CLIParseError.usage("HTTPS --host port must be a non-zero 16-bit integer")
                }
                options.pairedPort = value
            }
            return
        }
        guard !raw.contains("://"), !raw.isEmpty else {
            throw CLIParseError.usage("--host must be USER@HOST or https://HOST[:PORT]")
        }
        options.host = raw
    }

    private static func optionValue(_ arguments: [String], _ index: inout Int, name: String) throws -> String {
        let next = index + 1
        guard arguments.indices.contains(next), !arguments[next].isEmpty else { throw CLIParseError.usage("\(name) requires a value") }
        index = next
        return arguments[next]
    }

    private static func resolveEndpoint(_ supplied: AutomationEndpoint?, options: Options) throws -> AutomationEndpoint {
        if let container = options.container {
            return AutomationEndpoint(containerURL: URL(fileURLWithPath: container, isDirectory: true).standardizedFileURL)
        }
        if let supplied { return supplied }
        let root = ProcessInfo.processInfo.environment["MAILTERNAL_CONTAINER"]
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("Mailternal", isDirectory: true).path
        return AutomationEndpoint(containerURL: URL(fileURLWithPath: root, isDirectory: true))
    }

    private static func resolveToken(_ supplied: String?, endpoint: AutomationEndpoint, options: Options) throws -> String? {
        if let token = options.token ?? supplied, !token.isEmpty {
            return token
        }
        if options.container == nil,
           let token = ProcessInfo.processInfo.environment["MAILTERNAL_TOKEN"],
           !token.isEmpty {
            return token
        }
        guard FileManager.default.fileExists(atPath: endpoint.tokenURL.path) else {
            return nil
        }
        do {
            return try AutomationTokenStore(endpoint: endpoint).read()
        } catch let error as AutomationSecurityError {
            if case .socketUnavailable = error { return nil }
            throw error
        } catch {
            return nil
        }
    }

    private static func socketResponds(endpoint: AutomationEndpoint, token: String?) -> Bool {
        guard let token else { return false }
        let request = AutomationRequest(token: token, origin: .localCLI, wantsState: true)
        return (try? AutomationSocketClient(endpoint: endpoint).request(request)) != nil
    }

    #if os(macOS)
    private static func launchHeadlessRuntime(endpoint: AutomationEndpoint, options: Options) throws {
        guard let executable = discoverAppExecutable(override: options.app) else {
            throw AutomationCommandError.appUnavailable
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--mailternal-engine", "--mailternal-container", endpoint.containerURL.path]
        var environment = ProcessInfo.processInfo.environment
        for key in ["MAILTERNAL_PASSWORD", "MAILTERNAL_TOKEN", "MAILTERNAL_BEARER_TOKEN", "MAILTERNAL_TLS_FINGERPRINT"] {
            environment[key] = nil
        }
        environment["MAILTERNAL_CONTAINER"] = endpoint.containerURL.path
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        // A persistent owner must not keep a piped CLI caller waiting for EOF.
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    private static func discoverAppExecutable(override: String?) -> URL? {
        var candidates: [URL] = []
        if let override {
            let url = URL(fileURLWithPath: override, isDirectory: urlLooksLikeBundle(override))
            if let executable = bundleExecutable(at: url) {
                candidates.append(executable)
            } else {
                candidates.append(url)
                candidates.append(url.resolvingSymlinksInPath())
            }
        }
        if let env = ProcessInfo.processInfo.environment["MAILTERNAL_APP_EXECUTABLE"] {
            let url = URL(fileURLWithPath: env)
            candidates.append(url)
            candidates.append(url.resolvingSymlinksInPath())
        }
        if let env = ProcessInfo.processInfo.environment["MAILTERNAL_APP"],
           let executable = bundleExecutable(at: URL(fileURLWithPath: env, isDirectory: true)) {
            candidates.append(executable)
        }

        let invocation = URL(fileURLWithPath: CommandLine.arguments.first ?? "")
        if let executable = bundleExecutable(containing: invocation) {
            candidates.append(executable)
        }
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        for bundle in [
            home.appendingPathComponent("Applications/Mailternal.app", isDirectory: true),
            URL(fileURLWithPath: "/Applications/Mailternal.app", isDirectory: true)
        ] {
            if let executable = bundleExecutable(at: bundle) {
                candidates.append(executable)
            }
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static func urlLooksLikeBundle(_ path: String) -> Bool {
        path.lowercased().hasSuffix(".app")
    }

    private static func bundleExecutable(at url: URL) -> URL? {
        guard url.pathExtension.lowercased() == "app" else { return nil }
        // This process may be the embedded CLI. Resolve the declared app entry
        // point directly instead of using process-bundle executable discovery.
        let infoURL = url.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
              let info = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let name = info["CFBundleExecutable"] as? String,
              !name.isEmpty, !name.contains("/"), name != ".", name != ".."
        else { return nil }
        return url.appendingPathComponent("Contents/MacOS", isDirectory: true).appendingPathComponent(name)
    }

    private static func bundleExecutable(containing executable: URL) -> URL? {
        let contents = executable.deletingLastPathComponent().deletingLastPathComponent()
        guard contents.lastPathComponent == "Contents" else { return nil }
        return bundleExecutable(at: contents.deletingLastPathComponent())
    }

    private static func waitForRuntime(endpoint: AutomationEndpoint, timeout: TimeInterval) throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let token = try? AutomationTokenStore(endpoint: endpoint).read(),
               runtimeReady(endpoint: endpoint, token: token) {
                return token
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw AutomationCommandError.appUnavailable
    }

    private static func runtimeReady(endpoint: AutomationEndpoint, token: String) -> Bool {
        guard let response = requestEngineStatus(endpoint: endpoint, token: token),
              response.ok,
              let result = response.result,
              let runtime = try? AutomationLineCodec.decode(AutomationRuntimeStatus.self, from: result)
        else {
            return false
        }
        return runtime.ready
    }
    #endif

    private static func requestEngineShutdown(endpoint: AutomationEndpoint, token: String) -> AutomationResponse? {
        let request = AutomationRequest(
            token: token,
            origin: .localCLI,
            command: nil,
            control: .engineShutdown
        )
        return try? AutomationSocketClient(endpoint: endpoint).request(request)
    }
    private static func requestEngineStatus(endpoint: AutomationEndpoint, token: String) -> AutomationResponse? {
        let request = AutomationRequest(
            token: token,
            origin: .localCLI,
            command: nil,
            control: .engineStatus
        )
        return try? AutomationSocketClient(endpoint: endpoint).request(request)
    }

    /// Returns a ready local owner, starting the bundled headless runtime only
    /// when no owner answers. Unlike ordinary one-shot requests, pairing keeps
    /// a newly started owner alive so the short-lived offer remains claimable.
    private static func ensurePairingRuntime(
        endpoint: AutomationEndpoint,
        options: Options
    ) throws -> (token: String, started: Bool) {
        let token = try resolveToken(nil, endpoint: endpoint, options: options)
        if let token, socketResponds(endpoint: endpoint, token: token) {
            return (token: token, started: false)
        }
        guard !options.noStart else {
            throw AutomationCommandError.appUnavailable
        }
        #if os(macOS)
        try launchHeadlessRuntime(endpoint: endpoint, options: options)
        return (token: try waitForRuntime(endpoint: endpoint, timeout: 15), started: true)
        #else
        throw AutomationCommandError.appUnavailable
        #endif
    }

    private static func requestRemoteStatus(endpoint: AutomationEndpoint, token: String) -> AutomationResponse? {
        let request = AutomationRequest(
            token: token,
            origin: .localCLI,
            command: nil,
            control: .remoteStatus
        )
        return try? AutomationSocketClient(endpoint: endpoint).request(request)
    }

    private static func engine(action: CLIEngineAction, suppliedEndpoint: AutomationEndpoint?, suppliedToken: String?, options: Options) -> (Int32, Data) {
        do {
            let endpoint = try resolveEndpoint(suppliedEndpoint, options: options)
            switch action {
            case .status:
                guard let token = try resolveToken(suppliedToken, endpoint: endpoint, options: options),
                      let response = requestEngineStatus(endpoint: endpoint, token: token)
                else {
                    return (0, cliResultOutput([
                        "state": "not-running",
                        "endpoint": endpoint.socketURL.path
                    ]))
                }
                return (responseStatus(response, fallback: 3), responseOutput(response))
            case .start:
                let token = try resolveToken(suppliedToken, endpoint: endpoint, options: options)
                if socketResponds(endpoint: endpoint, token: token) {
                    return (0, cliResultOutput(["state": "running", "owner": "existing"]))
                }
                guard !options.noStart else { return (3, errorOutput(AutomationCommandError.appUnavailable.localizedDescription, failure: .unavailable)) }
                #if os(macOS)
                try launchHeadlessRuntime(endpoint: endpoint, options: options)
                let ready = try waitForRuntime(endpoint: endpoint, timeout: 15)
                return (0, cliResultOutput([
                    "state": "running",
                    "owner": "headless",
                    "tokenAvailable": !ready.isEmpty
                ]))
                #else
                return (3, errorOutput(AutomationCommandError.appUnavailable.localizedDescription, failure: .unavailable))
                #endif
            case .stop:
                guard let token = try resolveToken(suppliedToken, endpoint: endpoint, options: options),
                      socketResponds(endpoint: endpoint, token: token) else {
                    return (0, cliResultOutput(["state": "not-running"]))
                }
                guard let statusResponse = requestEngineStatus(endpoint: endpoint, token: token) else {
                    return (3, errorOutput("Engine status control is unavailable.", failure: .unavailable))
                }
                guard statusResponse.ok else {
                    let status = responseStatus(statusResponse, fallback: 3)
                    return (status, errorOutput(statusResponse.error ?? "Engine status control failed.", failure: statusResponse.failure ?? .unavailable))
                }
                if let result = statusResponse.result,
                   let runtime = try? AutomationLineCodec.decode(AutomationRuntimeStatus.self, from: result),
                   runtime.kind == .app {
                    return (0, cliResultOutput(["state": "running", "owner": "app", "stopped": false]))
                }
                guard let response = requestEngineShutdown(endpoint: endpoint, token: token) else {
                    return (3, errorOutput("Engine shutdown control is unavailable.", failure: .unavailable))
                }
                return (
                    responseStatus(response, fallback: 1),
                    responseOutput(response)
                )
            }
        } catch let error as AutomationSecurityError {
            let failure = automationFailure(for: error)
            return (failure.exitCode, errorOutput(error.localizedDescription, failure: failure))
        } catch {
            return (3, errorOutput(error.localizedDescription, failure: .unavailable))
        }
    }
    private static func createPairingOffer(
        endpoint: AutomationEndpoint,
        options: Options,
        grant: AutomationGrant?
    ) throws -> (Int32, Data) {
        let runtime = try ensurePairingRuntime(endpoint: endpoint, options: options)
        let token = runtime.token
        // Deliberately do not shut down a successful pairing owner: the offer
        // is persisted by that owner and must remain claimable after this CLI exits.
        let response: AutomationResponse
        do {
            response = try AutomationSocketClient(endpoint: endpoint).request(AutomationRequest(
                token: token,
                origin: .localCLI,
                control: .pairingCreate,
                pairingGrant: grant
            ))
        } catch {
            if runtime.started {
                _ = requestEngineShutdown(endpoint: endpoint, token: token)
            }
            throw error
        }
        guard response.ok, let data = response.result else {
            if runtime.started {
                _ = requestEngineShutdown(endpoint: endpoint, token: token)
            }
            return (responseStatus(response, fallback: 1), responseOutput(response))
        }
        guard let offer = try? AutomationLineCodec.decode(AutomationPairingOfferResult.self, from: data) else {
            return (3, errorOutput("Pairing offer response was malformed.", failure: .unavailable))
        }
        return (0, cliResultOutput([
            "code": offer.code,
            "offerID": offer.offerID.uuidString,
            "expiresAt": ISO8601DateFormatter().string(from: offer.expiresAt),
            "host": offer.host,
            "port": offer.port,
            "fingerprint": offer.fingerprint
        ]))
    }

    private static func pairing(
        action: CLIPairingAction,
        endpoint: AutomationEndpoint?,
        options: Options,
        emit: @escaping (Data) -> Void
    ) -> (Int32, Data) {
        do {
            let resolved = try resolveEndpoint(endpoint, options: options)
            switch action {
            case .remoteStatus:
                guard let token = try resolveToken(nil, endpoint: resolved, options: options),
                      let response = requestRemoteStatus(endpoint: resolved, token: token)
                else {
                    return (3, errorOutput(
                        AutomationCommandError.appUnavailable.localizedDescription,
                        failure: .unavailable
                    ))
                }
                return (responseStatus(response, fallback: 3), responseOutput(response))
            case .remoteDisable:
                let previous = try AutomationRemoteConfigurationStore(endpoint: resolved).load()
                let config = try AutomationRemoteConfiguration(
                    enabled: false,
                    bindHost: previous.bindHost,
                    port: previous.port,
                    allowWildcard: previous.allowWildcard
                )
                return try executeRuntimeCommand(.configureRemote(config), endpoint: resolved, options: options, emit: emit)
            case .remoteEnable(let host, let port):
                let config = try AutomationRemoteConfiguration(enabled: true, bindHost: host, port: port)
                return try executeRuntimeCommand(.configureRemote(config), endpoint: resolved, options: options, emit: emit)
            case .show(let grant):
                return try createPairingOffer(endpoint: resolved, options: options, grant: grant)
            case .revoke(let clientID):
                return try executeRuntimeCommand(.revokeAutomationClient(clientID), endpoint: resolved, options: options, emit: emit)
            case .code:
                return (3, errorOutput("Pairing enrollment requires the authenticated device exchange; it cannot be emulated by the CLI.", failure: .unavailable))
            }
        } catch let error as AutomationSecurityError {
            let failure = automationFailure(for: error)
            return (failure.exitCode, errorOutput(error.localizedDescription, failure: failure))
        } catch {
            return (3, errorOutput(error.localizedDescription, failure: .unavailable))
        }
    }

    private static func executeRuntimeCommand(
        _ command: Command,
        endpoint: AutomationEndpoint,
        options: Options,
        emit: @escaping (Data) -> Void
    ) throws -> (Int32, Data) {
        let parsed = ParsedArguments(options: options, commandArguments: [])
        return try executeRequest(
            invocation: .command(command),
            parsed: parsed,
            suppliedEndpoint: endpoint,
            suppliedToken: nil,
            emit: emit
        )
    }


    /// Shared by Settings and `setup`; installing remains an explicit shell action.
    public static func installationCommand(executable: URL, target: String = "/usr/local/bin/mailternal") -> String {
        "ln -sf -- \(shellQuote(executable.resolvingSymlinksInPath().standardizedFileURL.path)) \(shellQuote(target))"
    }

    private static func setupOutput(endpoint: AutomationEndpoint?, options: Options) -> Data {
        let target = ProcessInfo.processInfo.environment["MAILTERNAL_CLI_TARGET"] ?? "/usr/local/bin/mailternal"
        let invocation = Bundle.main.executableURL
            ?? URL(fileURLWithPath: CommandLine.arguments.first ?? "mailternal")
        let resolved = invocation.resolvingSymlinksInPath().standardizedFileURL
        let executable = resolved.path
        let command = installationCommand(executable: resolved, target: target)
        return jsonOutput([
            "schema": "mailternal.setup.v1",
            "version": 1,
            "command": command,
            "target": target,
            "executable": executable,
            "endpoint": (try? resolveEndpoint(endpoint, options: options).socketURL.path) ?? ""
        ])
    }
#if os(macOS) || os(Linux)

    private static func sshCommandArguments(
        parsed: ParsedArguments,
        attachmentStream: Bool = false
    ) -> [String] {
        var arguments: [String] = []
        if let container = parsed.options.container {
            arguments += ["--container", container]
        }
        if let app = parsed.options.app {
            arguments += ["--app", app]
        }
        if parsed.options.noStart {
            arguments.append("--no-start")
        }
        if parsed.options.passwordFromStdin {
            arguments.append("--password-stdin")
        }
        var commandArguments = parsed.commandArguments
        if attachmentStream,
           let outputIndex = commandArguments.firstIndex(of: "--output"),
           commandArguments.indices.contains(outputIndex + 1) {
            commandArguments.removeSubrange(outputIndex...(outputIndex + 1))
            commandArguments.append("--stream")
        }
        arguments.append(contentsOf: commandArguments)
        return arguments
    }

    private static func executeOverSSH(
        parsed: ParsedArguments,
        host: String,
        emit: (Data) -> Void
    ) throws -> (Int32, Data) {
        let invocation = try parse(parsed.commandArguments)
        if case .attachment(_, let output, false) = invocation,
           let output {
            return try executeAttachmentOverSSH(parsed: parsed, host: host, output: output)
        }
        if case .draftAttachment(let draftID, let path, let mimeType, let filename) = invocation {
            return try executeDraftAttachmentOverSSH(
                parsed: parsed, host: host, draftID: draftID,
                path: path, mimeType: mimeType, filename: filename
            )
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        var args = ["-T"]
        if let port = parsed.options.sshPort { args += ["-p", port] }
        args += ["--", host, "mailternal"]
        args += sshCommandArguments(parsed: parsed).map(shellQuote)
        process.arguments = args
        var environment = ProcessInfo.processInfo.environment
        for key in ["MAILTERNAL_PASSWORD", "MAILTERNAL_TOKEN", "MAILTERNAL_BEARER_TOKEN", "MAILTERNAL_TLS_FINGERPRINT"] {
            environment[key] = nil
        }
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.standardError
        process.standardInput = FileHandle.standardInput
        try process.run()
        var count: UInt64 = 0
        var exceeded = false
        let maximumBytes: UInt64
        if case .attachment = invocation {
            maximumBytes = AutomationTransferPolicy.maximumBytes
        } else {
            maximumBytes = AutomationTransferPolicy.maximumBytes + UInt64(AutomationLineCodec.maximumFrameBytes)
        }
        while true {
            let chunk = output.fileHandleForReading.readData(ofLength: 64 * 1024)
            guard !chunk.isEmpty else { break }
            guard count + UInt64(chunk.count) <= maximumBytes else {
                exceeded = true
                process.terminate()
                continue
            }
            count += UInt64(chunk.count)
            emit(chunk)
        }
        process.waitUntilExit()
        if exceeded {
            return (3, Data())
        }
        return (sshExitStatus(process.terminationStatus), Data())
    }

    private static func executeDraftAttachmentOverSSH(
        parsed: ParsedArguments,
        host: String,
        draftID: UUID,
        path: String,
        mimeType: String?,
        filename: String
    ) throws -> (Int32, Data) {
        let input = try DraftAttachmentInput(path: path)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        var args = ["-T"]
        if let port = parsed.options.sshPort { args += ["-p", port] }
        args += ["--", host, "mailternal"]
        var remote = sshCommandArguments(parsed: parsed)
        if let fileIndex = remote.firstIndex(of: "--file"), remote.indices.contains(fileIndex + 1) {
            remote[fileIndex + 1] = "-"
        } else {
            throw CLIParseError.usage("draft attach requires --file PATH")
        }
        if let nameIndex = remote.firstIndex(of: "--filename") {
            remote[nameIndex + 1] = filename
        } else {
            remote += ["--filename", filename]
        }
        args += remote.map(shellQuote)
        process.arguments = args
        var environment = ProcessInfo.processInfo.environment
        for key in ["MAILTERNAL_PASSWORD", "MAILTERNAL_TOKEN", "MAILTERNAL_BEARER_TOKEN", "MAILTERNAL_TLS_FINGERPRINT"] {
            environment[key] = nil
        }
        process.environment = environment
        let output = Pipe()
        let stdin = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.standardError
        process.standardInput = stdin
        try process.run()
        defer {
            try? stdin.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }
        var remaining = input.size
        while remaining > 0 {
            guard let chunk = try input.handle.read(upToCount: Int(min(remaining, 64 * 1024))),
                  !chunk.isEmpty else {
                throw AutomationCommandError.unsupported("attachment file changed during upload")
            }
            try stdin.fileHandleForWriting.write(contentsOf: chunk)
            remaining -= UInt64(chunk.count)
        }
        try stdin.fileHandleForWriting.close()
        var result = Data()
        while true {
            let chunk = output.fileHandleForReading.readData(ofLength: 64 * 1024)
            if chunk.isEmpty { break }
            guard UInt64(result.count) + UInt64(chunk.count)
                    <= AutomationTransferPolicy.maximumBytes + UInt64(AutomationLineCodec.maximumFrameBytes) else {
                process.terminate()
                process.waitUntilExit()
                return (3, errorOutput("Remote attachment result exceeded the permitted size.", failure: .unavailable))
            }
            result.append(chunk)
        }
        process.waitUntilExit()
        return (sshExitStatus(process.terminationStatus), result)
    }

    private static func executeAttachmentOverSSH(
        parsed: ParsedArguments,
        host: String,
        output path: String
    ) throws -> (Int32, Data) {
        let writer = try ExclusiveOutputWriter(path: path)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        var args = ["-T"]
        if let port = parsed.options.sshPort { args += ["-p", port] }
        args += ["--", host, "mailternal"]
        args += sshCommandArguments(parsed: parsed, attachmentStream: true).map(shellQuote)
        process.arguments = args
        var environment = ProcessInfo.processInfo.environment
        for key in ["MAILTERNAL_PASSWORD", "MAILTERNAL_TOKEN", "MAILTERNAL_BEARER_TOKEN", "MAILTERNAL_TLS_FINGERPRINT"] {
            environment[key] = nil
        }
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.standardError
        process.standardInput = FileHandle.standardInput
        do {
            try process.run()
            var count: UInt64 = 0
            while true {
                let chunk = pipe.fileHandleForReading.readData(ofLength: 64 * 1024)
                guard !chunk.isEmpty else { break }
                guard count + UInt64(chunk.count) <= AutomationTransferPolicy.maximumBytes else {
                    process.terminate()
                    writer.abort()
                    process.waitUntilExit()
                    return (3, errorOutput("Remote attachment exceeded the permitted transfer size.", failure: .unavailable))
                }
                try writer.append(chunk)
                count += UInt64(chunk.count)
            }
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                writer.abort()
                return (sshExitStatus(process.terminationStatus), errorOutput("Remote attachment transfer failed.", failure: .domain))
            }
            _ = try writer.finish()
            return (0, cliResultOutput(["output": path, "bytes": count]))
        } catch {
            process.terminate()
            writer.abort()
            process.waitUntilExit()
            throw error
        }
    }

    private static func streamOverSSH(
        parsed: ParsedArguments,
        host: String,
        emit: @escaping @Sendable (Data) -> Void
    ) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        var args = ["-T"]
        if let port = parsed.options.sshPort { args += ["-p", port] }
        args += ["--", host, "mailternal"]
        args += sshCommandArguments(parsed: parsed).map(shellQuote)
        process.arguments = args
        var environment = ProcessInfo.processInfo.environment
        for key in ["MAILTERNAL_PASSWORD", "MAILTERNAL_TOKEN", "MAILTERNAL_BEARER_TOKEN", "MAILTERNAL_TLS_FINGERPRINT"] {
            environment[key] = nil
        }
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.standardError
        process.standardInput = FileHandle.standardInput
        try process.run()

        let maximumLine = 4 * 1024 * 1024
        var pending = Data()
        var exceeded = false
        while true {
            let chunk = output.fileHandleForReading.readData(ofLength: 64 * 1024)
            guard !chunk.isEmpty else { break }
            pending.append(chunk)
            guard pending.count <= maximumLine else {
                process.terminate()
                exceeded = true
                break
            }
            while let newline = pending.firstIndex(of: 0x0A) {
                let end = pending.index(after: newline)
                emit(Data(pending[..<end]))
                pending.removeSubrange(..<end)
            }
        }
        if !exceeded, !pending.isEmpty {
            emit(pending)
        }
        process.waitUntilExit()
        return exceeded ? 3 : sshExitStatus(process.terminationStatus)
    }

    private static func sshExitStatus(_ status: Int32) -> Int32 {
        (0...5).contains(status) ? status : 3
    }
#endif
    private static func remoteDetails(host: String, options: Options) throws -> (port: UInt16, bearer: String, clientID: UUID?, fingerprint: String) {
        let stored = try? AutomationPairedEndpointStore(
            endpoint: resolveEndpoint(nil, options: options)
        ).load()
        let storedForHost = stored?.host == host ? stored : nil
        guard let port = options.pairedPort ?? storedForHost?.port,
              let bearer = options.bearerToken
                    ?? ProcessInfo.processInfo.environment["MAILTERNAL_BEARER_TOKEN"]
                    ?? storedForHost?.bearerToken,
              let fingerprint = options.fingerprint
                    ?? ProcessInfo.processInfo.environment["MAILTERNAL_TLS_FINGERPRINT"]
                    ?? storedForHost?.pinnedFingerprint
        else {
            throw CLIParseError.usage("--host https://HOST[:PORT] requires a paired endpoint or --bearer and --fingerprint")
        }
        return (port, bearer, options.clientID ?? storedForHost?.clientID, fingerprint)
    }
    private static func pairOverTLS(
        code: String,
        parsed: ParsedArguments,
        host: String
    ) throws -> (Int32, Data) {
        guard let port = parsed.options.pairedPort,
              let fingerprint = parsed.options.fingerprint
                    ?? ProcessInfo.processInfo.environment["MAILTERNAL_TLS_FINGERPRINT"],
              fingerprint.count == 64 else {
            throw CLIParseError.usage("pair --code requires --port and --fingerprint")
        }
        let client = try AutomationTLSSocketClient(
            host: host,
            port: port,
            bearerToken: "",
            pinnedFingerprint: fingerprint
        )
        let paired = try synchronousRemoteClaim(
            client: client,
            code: code,
            clientName: parsed.options.clientName
        )
        try AutomationPairedEndpointStore(
            endpoint: resolveEndpoint(nil, options: parsed.options)
        ).save(paired)
        return (0, cliResultOutput([
            "paired": true,
            "clientID": paired.clientID.uuidString,
            "host": paired.host,
            "port": paired.port,
            "fingerprint": paired.pinnedFingerprint
        ]))
    }
    private static func executeOverTLS(
        invocation: CLIInvocation,
        parsed: ParsedArguments,
        host: String,
        emit: @escaping (Data) -> Void
    ) throws -> (Int32, Data) {
        let details = try remoteDetails(host: host, options: parsed.options)
        let client = try AutomationTLSSocketClient(
            host: host,
            port: details.port,
            bearerToken: details.bearer,
            clientID: details.clientID,
            pinnedFingerprint: details.fingerprint
        )
        let command: Command?
        let wantsState: Bool
        let wantsGUIState: Bool
        let attachmentOutput: String?
        let attachmentStream: Bool
        if case .draftAttachment(let draftID, let path, let mimeType, let filename) = invocation {
            return try executeDraftAttachment(
                draftID: draftID, path: path, mimeType: mimeType, filename: filename,
                token: details.bearer, origin: .pairedRemote,
                clientID: details.clientID?.uuidString,
                emit: emit,
                request: { request in
                    try synchronousRemoteRequest(client: client, request: request)
                }
            )
        }
        switch invocation {
        case .state:
            command = nil; wantsState = true; wantsGUIState = false
            attachmentOutput = nil; attachmentStream = false
        case .uiState:
            command = nil; wantsState = true; wantsGUIState = true
            attachmentOutput = nil; attachmentStream = false
        case .command(let value):
            command = value; wantsState = false; wantsGUIState = false
            attachmentOutput = nil; attachmentStream = false
        case .attachment(let value, let output, let stream):
            command = value; wantsState = false; wantsGUIState = false
            attachmentOutput = output; attachmentStream = stream
        case .observe, .uiObserve:
            throw CLIParseError.usage("Use observe through the streaming CLI path")
        default:
            throw CLIParseError.usage("The selected command is not available over paired transport")
        }
        let writer: (any AutomationTransferSink)? = try attachmentOutput.map { try ExclusiveOutputWriter(path: $0) }
        let request = AutomationRequest(
            token: details.bearer,
            origin: .pairedRemote,
            clientID: details.clientID?.uuidString,
            command: command,
            wantsState: wantsState,
            wantsGUIState: wantsGUIState,
            observesState: false,
            secret: try readSecret(options: parsed.options)
        )
        let response = try synchronousRemoteRequest(client: client, request: request)
        guard response.ok else {
            return (responseStatus(response, fallback: 1), responseOutput(response))
        }
        if let command, command.name == .fetchAttachment || command.name == .getDraftAttachment {
            if !attachmentStream, attachmentOutput == nil {
                throw CLIParseError.usage("attachment download requires a local output destination")
            }
            guard let descriptor = try commandTransferDescriptor(from: response),
                  descriptor.kind == .attachment else {
                throw AutomationCommandError.unsupported("attachment transfer was unavailable")
            }
            _ = try drainTLSTransfer(
                client: client,
                token: details.bearer,
                clientID: details.clientID,
                descriptor: descriptor,
                writer: writer,
                rawEmit: attachmentStream ? emit : nil
            )
            if attachmentStream {
                return (0, Data())
            }
            return (0, cliResultOutput(["output": attachmentOutput ?? "", "bytes": descriptor.size]))
        }
        if let descriptor = try commandTransferDescriptor(from: response) {
            guard descriptor.kind == .commandResult else {
                throw AutomationCommandError.unsupported("unexpected transfer kind")
            }
            let spool = try BoundedTransferSpool(maximumBytes: descriptor.size)
            _ = try drainTLSTransfer(
                client: client,
                token: details.bearer,
                clientID: details.clientID,
                descriptor: descriptor,
                writer: spool
            )
            defer { spool.abort() }
            try streamCommandTransfer(response, spool: spool, emit: emit)
            return (0, Data())
        }
        return (responseStatus(response, fallback: 1), responseOutput(response))
    }


    private static func drainTLSTransfer(
        client: AutomationTLSSocketClient,
        token: String,
        clientID: UUID?,
        descriptor: AutomationTransferDescriptor,
        writer: (any AutomationTransferSink)?,
        rawEmit: ((Data) -> Void)? = nil
    ) throws {
        try drainTransfer(descriptor: descriptor, writer: writer, rawEmit: rawEmit) { control, offset, length in
            try synchronousRemoteRequest(client: client, request: AutomationRequest(
                token: token, origin: .pairedRemote, clientID: clientID?.uuidString,
                control: control, transferID: descriptor.transferID,
                transferOffset: offset, transferLength: length
            ))
        }
    }

    private static func streamOverTLS(
        invocation: CLIInvocation,
        parsed: ParsedArguments,
        host: String,
        emit: @escaping @Sendable (Data) -> Void
    ) -> Int32 {
        let after: UInt64?
        let wantsGUIState: Bool
        let followQuery: String?
        switch invocation {
        case .observe(let revision):
            after = revision; wantsGUIState = false; followQuery = nil
        case .uiObserve(let revision):
            after = revision; wantsGUIState = true; followQuery = nil
        case .searchFollow(let query, let revision):
            after = revision; wantsGUIState = false; followQuery = query
        default:
            emit(errorOutput("Paired observe requires an observe command", failure: .usage))
            return 2
        }
        do {
            let details = try remoteDetails(host: host, options: parsed.options)
            let client = try AutomationTLSSocketClient(
                host: host,
                port: details.port,
                bearerToken: details.bearer,
                clientID: details.clientID,
                pinnedFingerprint: details.fingerprint
            )
            if let followQuery {
                var previous: Data?
                while true {
                    let response = try synchronousRemoteRequest(
                        client: client,
                        request: AutomationRequest(
                            token: details.bearer,
                            origin: .pairedRemote,
                            clientID: details.clientID?.uuidString,
                            command: .search(followQuery, 50)
                        )
                    )
                    guard response.ok else {
                        emit(responseOutput(response))
                        return responseStatus(response, fallback: 1)
                    }
                    let output = responseOutput(response)
                    if output != previous {
                        emit(output)
                        previous = output
                    }
                    Thread.sleep(forTimeInterval: 1)
                }
            }
            let request = AutomationRequest(
                token: details.bearer,
                origin: .pairedRemote,
                clientID: details.clientID?.uuidString,
                command: nil,
                control: nil,
                wantsState: true,
                wantsGUIState: wantsGUIState,
                observesState: true,
                afterRevision: after,
                secret: nil
            )
            let completion = DispatchSemaphore(value: 0)
            let outcome = LockedStatus()
            Task {
                do {
                    try await client.observe(request) { response in
                        emit(responseOutput(response))
                    }
                    outcome.set(3)
                    emit(errorOutput("Observation stream ended; reconnect to resynchronize.", failure: .unavailable))
                } catch let error as AutomationCommandError {
                    outcome.set(error.failure.exitCode)
                    emit(errorOutput(error.localizedDescription, failure: error.failure))
                } catch let error as AutomationSecurityError {
                    let failure = automationFailure(for: error)
                    outcome.set(failure.exitCode)
                    emit(errorOutput(error.localizedDescription, failure: failure))
                } catch {
                    outcome.set(3)
                    emit(errorOutput(error.localizedDescription, failure: .unavailable))
                }
                completion.signal()
            }
            completion.wait()
            return outcome.get()
        } catch let error as CLIParseError {
            emit(errorOutput(error.localizedDescription, failure: .usage)); return 2
        } catch let error as AutomationCommandError {
            emit(errorOutput(error.localizedDescription, failure: error.failure)); return error.failure.exitCode
        } catch let error as AutomationSecurityError {
            let failure = automationFailure(for: error)
            emit(errorOutput(error.localizedDescription, failure: failure)); return failure.exitCode
        } catch {
            emit(errorOutput(error.localizedDescription, failure: .unavailable)); return 3
        }
    }

    private static func synchronousRemoteRequest(
        client: AutomationTLSSocketClient,
        request: AutomationRequest
    ) throws -> AutomationResponse {
        let completion = DispatchSemaphore(value: 0)
        let result = LockedRemoteResult()
        Task {
            do {
                result.set(.success(try await client.request(request)))
            } catch {
                result.set(.failure(error))
            }
            completion.signal()
        }
        completion.wait()
        return try result.get()
    }
    private static func synchronousRemoteClaim(
        client: AutomationTLSSocketClient,
        code: String,
        clientName: String?
    ) throws -> AutomationPairedEndpoint {
        let completion = DispatchSemaphore(value: 0)
        let result = LockedRemoteEndpoint()
        Task {
            do {
                result.set(.success(try await client.claim(code: code, clientName: clientName)))
            } catch {
                result.set(.failure(error))
            }
            completion.signal()
        }
        completion.wait()
        return try result.get()
    }
    private static func readSecret(options: Options) throws -> String? {
        if let secret = ProcessInfo.processInfo.environment["MAILTERNAL_PASSWORD"], !secret.isEmpty {
            guard secret.utf8.count <= 4_096 else { throw CLIParseError.usage("Password exceeds the permitted size") }
            return secret
        }
        guard options.passwordFromStdin else { return nil }
        let data = FileHandle.standardInput.readData(ofLength: 4_097)
        guard data.count <= 4_096,
              let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .newlines),
              !value.isEmpty else { return nil }
        return value
    }

    private static func pairingGrant(path: String) throws -> AutomationGrant {
        guard let data = try? boundedFileData(path: path, maximumBytes: 64 * 1_024),
              let object = try? JSONSerialization.jsonObject(with: data, options: []),
              let dictionary = object as? [String: Any],
              Set(dictionary.keys).isSubset(of: [
                "accountLinkIDs", "canRead", "canMutate", "canSend", "canControlGUI"
              ]),
              let grant = try? JSONDecoder().decode(AutomationGrant.self, from: data)
        else {
            throw CLIParseError.usage("pair --show --grant requires a JSON AutomationGrant file")
        }
        return grant
    }
    private static func boundedFileData(path: String, maximumBytes: Int) throws -> Data {
        let descriptor = path.withCString { open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) }
        guard descriptor >= 0 else { throw CLIParseError.usage("Unable to open input file") }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size >= 0,
              info.st_size <= off_t(maximumBytes) else {
            throw CLIParseError.usage("Input file is not a permitted regular file")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let data = handle.readData(ofLength: maximumBytes + 1)
        guard data.count <= maximumBytes else {
            throw CLIParseError.usage("Input file exceeds the permitted size")
        }
        return data
    }


    private static func cliResultOutput(_ result: [String: Any]) -> Data {
        jsonOutput([
            "schema": "mailternal.cli.result.v1",
            "version": 1,
            "ok": true,
            "result": result
        ])
    }
    private static func responseStatus(_ response: AutomationResponse, fallback: Int32) -> Int32 {
        response.ok ? 0 : (response.failure?.exitCode ?? fallback)
    }

    private static func responseOutput(_ response: AutomationResponse) -> Data {
        guard response.ok else {
            return errorOutput(
                response.error ?? "The automation request failed.",
                failure: response.failure ?? .domain
            )
        }
        guard let result = response.result else {
            return jsonOutput([
                "schema": "mailternal.cli.result.v1",
                "version": 1,
                "ok": true,
                "result": NSNull()
            ])
        }
        if let commandResult = try? AutomationLineCodec.decode(CommandResult.self, from: result) {
            var output: [String: Any] = [
                "schema": "mailternal.cli.result.v1",
                "version": 1,
                "ok": true,
                "command": commandResult.command.rawValue
            ]
            if let revision = commandResult.stateRevision {
                output["stateRevision"] = revision
            }
            if let data = commandResult.data,
               let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
                output["result"] = value
            } else {
                output["result"] = NSNull()
            }
            return jsonOutput(output)
        }
        if let value = try? JSONSerialization.jsonObject(with: result, options: [.fragmentsAllowed]) {
            if let object = value as? [String: Any],
               let schema = object["schema"] as? String,
               schema == AutomationProtocol.eventSchema || schema == AutomationProtocol.stateSchema {
                return result.last == 0x0A ? result : result + Data([0x0A])
            }
            return jsonOutput([
                "schema": "mailternal.cli.result.v1",
                "version": 1,
                "ok": true,
                "result": value
            ])
        }
        return jsonOutput([
            "schema": "mailternal.cli.result.v1",
            "version": 1,
            "ok": true,
            "result": String(data: result, encoding: .utf8) ?? ""
        ])
    }

    private static func jsonOutput(_ object: [String: Any]) -> Data {
        var tagged = object
        if tagged["schema"] == nil {
            tagged["schema"] = "mailternal.cli.v1"
            tagged["version"] = 1
        }
        return (try? JSONSerialization.data(withJSONObject: tagged, options: [.sortedKeys])).map {
            $0 + Data([0x0A])
        } ?? Data("{}\n".utf8)
    }

    private static func errorOutput(_ message: String, failure: AutomationFailure = .domain) -> Data {
        jsonOutput([
            "schema": AutomationProtocol.responseSchema,
            "version": AutomationProtocol.version,
            "ok": false,
            "error": message,
            "failure": failure.rawValue
        ])
    }

    private static func automationFailure(for error: AutomationSecurityError) -> AutomationFailure {
        switch error {
        case .invalidToken, .insecurePermissions, .notPaired:
            return .authorization
        default:
            return .unavailable
        }
    }


    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }



    private static func limit(_ raw: String?) throws -> Int {
        guard let raw else { return 50 }
        let maximum = AutomationProtocol.maximumQueryLimit
        guard let result = Int(raw), (1...maximum).contains(result) else {
            throw CLIParseError.usage("--limit must be between 1 and \(maximum)")
        }
        return result
    }
    private static func messageID(_ raw: String) throws -> MessageID {
        guard let value = Int64(raw) else {
            throw CLIParseError.usage("Message ids must be integers")
        }
        return MessageID(rawValue: value)
    }
    private static func pageCursor(_ raw: String?) throws -> MessagePageCursor? {
        guard let raw, !raw.isEmpty else { return nil }
        let data = Data(base64Encoded: raw) ?? Data(raw.utf8)
        guard let cursor = try? AutomationLineCodec.decode(MessagePageCursor.self, from: data) else {
            throw CLIParseError.usage("--after must be a base64 or JSON page cursor")
        }
        return cursor
    }
    private static func accountID(_ raw: String?) throws -> AccountID {
        guard let raw, !raw.isEmpty else { throw CLIParseError.usage("Missing account id") }

        return AccountID(rawValue: raw)
    }
    private static func listSort(_ raw: String?) throws -> MailListSort {
        guard let raw, !raw.isEmpty else { return .newest }
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2,
              let field = MailListSort.Field(rawValue: parts[0]),
              let direction = MailListSort.Direction(rawValue: parts[1])
        else {
            throw CLIParseError.usage("--sort must be field:direction")
        }
        return MailListSort(field: field, direction: direction)
    }
    private static func folderID(_ raw: String?) throws -> FolderID {
        guard let raw, let value = Int64(raw) else {
            throw CLIParseError.usage("Folder id must be an integer")
        }
        return FolderID(rawValue: value)
    }

    private static func listColumn(_ raw: String?) throws -> MailListColumn {
        guard let raw, let column = MailListColumn(rawValue: raw) else {
            throw CLIParseError.usage("Unknown list column; use \(MailListColumn.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        return column
    }

    private static func listColumnOrder(_ raw: String?) throws -> [MailListColumn] {
        guard let raw, !raw.isEmpty else {
            throw CLIParseError.usage("list-column-order requires comma-separated columns")
        }
        let values = try raw.split(separator: ",").map { try listColumn(String($0)) }
        guard Set(values).count == values.count else {
            throw CLIParseError.usage("list-column-order cannot contain duplicate columns")
        }
        return values
    }
    private static func optionalID(_ raw: String?) throws -> FolderID? {
        guard let raw else { return nil }
        guard let value = Int64(raw) else { throw CLIParseError.usage("Folder id must be an integer") }
        return FolderID(rawValue: value)
    }
    private static func messageReference(_ raw: String?) throws -> MessageReference {
        guard let raw, !raw.isEmpty else { throw CLIParseError.usage("Missing message id or mailternal deep link") }
        if let value = Int64(raw) { return .local(MessageID(rawValue: value)) }
        guard let link = MailternalDeepLink(string: raw), case .message = link else {
            throw CLIParseError.usage("Expected a local message id or canonical mailternal message link")
        }
        return .link(link)
    }
    private static func readingMode(_ raw: String?) throws -> AutomationReadingMode {
        guard let raw, let mode = AutomationReadingMode(rawValue: raw) else { throw CLIParseError.usage("reading-mode requires original or dark") }
        return mode
    }
    private static func messageTarget(_ raw: String?) throws -> MessageTarget {
        guard let raw, !raw.isEmpty else {
            throw CLIParseError.usage("Missing message id or mailternal deep link")
        }
        return try messageTargetList(raw)
    }
    private static func uuid(_ raw: String?) throws -> UUID {
        guard let raw, let value = UUID(uuidString: raw) else {
            throw CLIParseError.usage("Missing or invalid tab id")
        }
        return value
    }
    private static func messageIDList(_ raw: String) throws -> [MessageID] {
        let values = raw.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard !values.isEmpty, values.allSatisfy({ !$0.isEmpty }) else {
            throw CLIParseError.usage("Message target cannot be empty")
        }
        return try values.map(messageID)
    }
    private static func messageTargetList(_ raw: String) throws -> MessageTarget {
        let values = raw.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard !values.isEmpty, values.allSatisfy({ !$0.isEmpty }) else {
            throw CLIParseError.usage("Message target cannot be empty")
        }
        let isLocal = values.allSatisfy { Int64($0) != nil }
        let isLink = values.allSatisfy {
            guard let link = MailternalDeepLink(string: $0) else { return false }
            if case .message = link { return true }
            return false
        }
        guard isLocal || isLink else {
            throw CLIParseError.usage("Message targets cannot mix local ids and canonical links")
        }
        if isLocal {
            return .explicit(try values.map(messageID))
        }
        return .links(try values.map { raw in
            guard let link = MailternalDeepLink(string: raw), case .message = link else {
                throw CLIParseError.usage("Expected a canonical mailternal message link")
            }
            return link
        })
    }
}

private protocol AutomationTransferSink: AnyObject {
    func append(_ data: Data) throws
    func finish() throws
    func abort()
}

private final class ExclusiveOutputWriter: AutomationTransferSink {
    private let path: String
    private let temporaryPath: String
    private var handle: FileHandle?
    private var finished = false

    init(path: String) throws {
        guard !path.isEmpty, !path.utf8.contains(0) else {
            throw CLIParseError.usage("--output requires a path")
        }
        var existing = stat()
        guard path.withCString({ lstat($0, &existing) }) != 0, errno == ENOENT else {
            throw CLIParseError.usage("Output file already exists or cannot be inspected")
        }
        self.path = path
        let destination = URL(fileURLWithPath: path)
        temporaryPath = destination
            .deletingLastPathComponent()
            .appendingPathComponent(".mailternal-\(UUID().uuidString).part")
            .path
#if os(macOS)
        let descriptor = temporaryPath.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        }
#elseif os(Linux)
        let descriptor = temporaryPath.withCString {
            Glibc.open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        }
#else
        let descriptor: Int32 = -1
#endif
        guard descriptor >= 0 else {
            throw CLIParseError.usage("Output file cannot be prepared")
        }
        handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    func append(_ data: Data) throws {
        guard let handle else {
            throw AutomationCommandError.unsupported("output is unavailable")
        }
        try handle.write(contentsOf: data)
    }

    func finish() throws {
        guard let handle else {
            throw AutomationCommandError.unsupported("output is unavailable")
        }
        try handle.close()
        self.handle = nil
#if os(macOS)
        let result = temporaryPath.withCString { temp in
            path.withCString { destination in Darwin.link(temp, destination) }
        }
#elseif os(Linux)
        let result = temporaryPath.withCString { temp in
            path.withCString { destination in Glibc.link(temp, destination) }
        }
#else
        let result: Int32 = -1
#endif
        guard result == 0 else {
            try? FileManager.default.removeItem(atPath: temporaryPath)
            finished = true
            throw CLIParseError.usage("Output file already exists or cannot be published")
        }
        try? FileManager.default.removeItem(atPath: temporaryPath)
        finished = true
    }

    func abort() {
        try? handle?.close()
        handle = nil
        guard !finished else { return }
        try? FileManager.default.removeItem(atPath: temporaryPath)
        finished = true
    }


    deinit { abort() }
}

/// Owns an opened regular file, or a private bounded stdin spool. Keeping the
/// descriptor open avoids path replacement between validation and streaming.
private final class DraftAttachmentInput {
    let handle: FileHandle
    let size: UInt64
    private let temporaryURL: URL?

    init(path: String) throws {
        if path == "-" {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("mailternal-cli-upload-\(UUID().uuidString)")
            let descriptor = url.path.withCString {
                open($0, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
            }
            guard descriptor >= 0 else {
                throw AutomationCommandError.unsupported("attachment spool is unavailable")
            }
            let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            do {
                var count: UInt64 = 0
                while let chunk = try FileHandle.standardInput.read(upToCount: 64 * 1024),
                      !chunk.isEmpty {
                    guard UInt64(chunk.count) <= AutomationTransferPolicy.maximumBytes - count else {
                        throw CLIParseError.usage("draft attach exceeds the permitted size")
                    }
                    try file.write(contentsOf: chunk)
                    count += UInt64(chunk.count)
                }
                try file.seek(toOffset: 0)
                handle = file
                size = count
                temporaryURL = url
            } catch {
                try? file.close()
                try? FileManager.default.removeItem(at: url)
                throw error
            }
        } else {
            let descriptor = path.withCString {
                open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            }
            guard descriptor >= 0 else {
                throw CLIParseError.usage("attachment file could not be opened")
            }
            var info = stat()
            guard fstat(descriptor, &info) == 0,
                  info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                  info.st_size >= 0,
                  UInt64(info.st_size) <= AutomationTransferPolicy.maximumBytes else {
                close(descriptor)
                throw CLIParseError.usage("draft attach requires a regular file no larger than 256 MiB")
            }
            handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            size = UInt64(info.st_size)
            temporaryURL = nil
        }
    }

    deinit {
        try? handle.close()
        if let temporaryURL { try? FileManager.default.removeItem(at: temporaryURL) }
    }
}

private final class BoundedTransferSpool: AutomationTransferSink {
    private let path: URL
    private let maximumBytes: UInt64
    private var handle: FileHandle?
    private var count: UInt64 = 0
    private var finished = false

    init(maximumBytes: UInt64) throws {
        self.maximumBytes = maximumBytes
        path = FileManager.default.temporaryDirectory
            .appendingPathComponent("mailternal-cli-transfer-\(UUID().uuidString)")
        let descriptor = path.path.withCString {
            open($0, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        }
        guard descriptor >= 0 else {
            throw AutomationCommandError.unsupported("transfer spool is unavailable")
        }
        handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    func append(_ data: Data) throws {
        guard !finished, let handle, UInt64(data.count) <= maximumBytes - count else {
            throw AutomationCommandError.unsupported("transfer exceeds the permitted size")
        }
        try handle.write(contentsOf: data)
        count += UInt64(data.count)
    }

    func finish() throws {
        guard !finished, let handle, count == maximumBytes else {
            throw AutomationCommandError.unsupported("transfer spool is incomplete")
        }
        try handle.seek(toOffset: 0)
        finished = true
    }

    func streamContents(_ emit: (Data) throws -> Void) throws {
        guard finished, let handle else {
            throw AutomationCommandError.unsupported("transfer spool is unavailable")
        }
        defer { abort() }
        var remaining = count
        while remaining > 0 {
            guard let chunk = try handle.read(upToCount: Int(min(remaining, 64 * 1024))), !chunk.isEmpty else {
                throw AutomationCommandError.unsupported("transfer spool is truncated")
            }
            try emit(chunk)
            remaining -= UInt64(chunk.count)
        }
    }

    func abort() {
        try? handle?.close()
        handle = nil
        try? FileManager.default.removeItem(at: path)
        finished = true
    }

    deinit { abort() }
}

private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Data()

    func set(_ value: Data) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func get() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
private final class LockedStatus: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int32 = 0

    func set(_ value: Int32) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func get() -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
private final class LockedRemoteEndpoint: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<AutomationPairedEndpoint, Error>?

    func set(_ result: Result<AutomationPairedEndpoint, Error>) {
        lock.lock()
        self.result = result
        lock.unlock()
    }

    func get() throws -> AutomationPairedEndpoint {
        lock.lock()
        defer { lock.unlock() }
        guard let result else { throw AutomationSecurityError.socketUnavailable }
        return try result.get()
    }
}
private final class LockedRemoteResult: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<AutomationResponse, Error>?

    func set(_ result: Result<AutomationResponse, Error>) {
        lock.lock()
        self.result = result
        lock.unlock()
    }

    func get() throws -> AutomationResponse {
        lock.lock()
        defer { lock.unlock() }
        guard let result else { throw AutomationSecurityError.socketUnavailable }
        return try result.get()
    }
}
