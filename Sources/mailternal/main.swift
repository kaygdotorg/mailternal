#if os(macOS)
import Darwin
#else
import Glibc
#endif
import Foundation
import MailternalAutomation

let environment = ProcessInfo.processInfo.environment
let arguments = Array(CommandLine.arguments.dropFirst())

func optionValue(_ name: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: name),
          arguments.indices.contains(index + 1)
    else { return nil }
    return arguments[index + 1]
}

let containerPath = optionValue("--container", in: arguments)
    ?? environment["MAILTERNAL_CONTAINER"]
    ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        .appendingPathComponent("Mailternal", isDirectory: true).path
let endpoint = AutomationEndpoint(containerURL: URL(fileURLWithPath: containerPath, isDirectory: true))
let token = optionValue("--token", in: arguments)
    ?? (optionValue("--container", in: arguments) == nil ? environment["MAILTERNAL_TOKEN"] : nil)
    ?? (try? AutomationTokenStore(endpoint: endpoint).read())

func isObserveInvocation(_ arguments: [String]) -> Bool {
    var index = 0
    while index < arguments.count {
        switch arguments[index] {
        case "--container", "--token", "--host", "--ssh-port", "--app",
             "--port", "--bearer", "--client-id", "--fingerprint", "--client-name":
            index += 2
        case "--no-start", "--password-stdin":
            index += 1
        default:
            if index < arguments.count, arguments[index] == "observe" { return true }
            if index + 1 < arguments.count, arguments[index] == "ui", arguments[index + 1] == "observe" { return true }
            if index < arguments.count, arguments[index] == "search", arguments.contains("--follow") { return true }
            return false
        }
    }
    return false
}

func writeOutput(_ data: Data) {
    FileHandle.standardOutput.write(data)
}

func terminalOutput(_ data: Data) -> Data {
    guard isatty(STDOUT_FILENO) == 1 else { return data }
    return AutomationCLI.terminalOutput(data)
}

if isObserveInvocation(arguments) {
    let status = AutomationCLI.stream(arguments, endpoint: endpoint, token: token) { data in
        writeOutput(data)
    }
    exit(status)
}
let binaryAttachment = arguments.contains("fetch-attachment") && arguments.contains("--stream")
var passthrough = isatty(STDOUT_FILENO) != 1 || binaryAttachment
var terminalBuffer = Data()
let status = AutomationCLI.execute(arguments, endpoint: endpoint, token: token) { data in
    if passthrough {
        writeOutput(data)
    } else if data.count > AutomationTransferPolicy.inlinePayloadBytes - terminalBuffer.count {
        // Never parse individual chunks of a large JSON value as standalone
        // terminal results. Once the bounded buffer fills, preserve all bytes.
        writeOutput(terminalBuffer)
        terminalBuffer.removeAll(keepingCapacity: false)
        passthrough = true
        writeOutput(data)
    } else {
        terminalBuffer.append(data)
    }
}
if !terminalBuffer.isEmpty { writeOutput(terminalOutput(terminalBuffer)) }
exit(status)
