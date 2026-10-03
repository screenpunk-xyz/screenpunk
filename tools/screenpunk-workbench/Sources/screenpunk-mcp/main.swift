import WorkbenchCommand
import Darwin

exit(WorkbenchCommand.run(arguments: ["mcp", "serve"] + Array(CommandLine.arguments.dropFirst())))
