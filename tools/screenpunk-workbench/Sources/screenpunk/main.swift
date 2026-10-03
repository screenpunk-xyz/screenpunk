import WorkbenchCommand
import Darwin

_ = signal(SIGPIPE, SIG_IGN)
exit(WorkbenchCommand.run(arguments: Array(CommandLine.arguments.dropFirst())))
