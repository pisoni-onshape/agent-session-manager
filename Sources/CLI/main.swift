import Foundation
import AgentSessionManagerCore

let result = SessionSearchCLI.execute(arguments: CommandLine.arguments)
if !result.standardOutput.isEmpty {
    FileHandle.standardOutput.write(Data(result.standardOutput.utf8))
}
if !result.standardError.isEmpty {
    FileHandle.standardError.write(Data(result.standardError.utf8))
}
exit(result.exitCode)
