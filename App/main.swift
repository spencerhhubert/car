import AppKit

// One binary: run with anything on its command line (`owl session last`,
// `owl --help`) it is the command and exits, with its usage for anything it
// does not know; run with nothing, or with only the options macOS and Xcode
// hand an app (-psn_…, -NS…, -Apple…), it is the menu bar app. A typo never
// starts a second owl.
let args = Array(CommandLine.arguments.dropFirst())
if let first = args.first, !["-psn", "-NS", "-Apple"].contains(where: { first.hasPrefix($0) }) {
    exit(await CLI.run(args))
}
let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
