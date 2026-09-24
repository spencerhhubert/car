import AppKit

// One binary: with a subcommand it is the `owl` command and exits; with none
// it is the menu bar app.
let args = Array(CommandLine.arguments.dropFirst())
if let first = args.first, CLI.commands.contains(first) {
    exit(await CLI.run(args))
}
let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
