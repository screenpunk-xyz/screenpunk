import WorkbenchCommand
import Darwin

exit(WorkbenchCommand.run(arguments: Array(CommandLine.arguments.dropFirst()), serviceExecutable: true))
