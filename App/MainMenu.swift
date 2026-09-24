import AppKit
import CarKit

// The menu bar while one of car's windows is open and car is the app in
// front: the standard menus, with standard items, so ⌘W, ⌘C, ⌘, and the
// rest do what they do everywhere.
@MainActor
enum MainMenu {
    static func build(for app: App) -> NSMenu {
        let name = Config.name
        let main = NSMenu()

        let car = menu(name, in: main)
        car.addItem(withTitle: "About \(name)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                    keyEquivalent: "")
        car.addItem(.separator())
        car.addItem(item("Settings…", #selector(App.showSettings), ",", target: app))
        car.addItem(.separator())
        car.addItem(withTitle: "Hide \(name)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let others = car.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)),
                                 keyEquivalent: "h")
        others.keyEquivalentModifierMask = [.command, .option]
        car.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        car.addItem(.separator())
        car.addItem(item("Quit \(name)", #selector(App.quit), "q", target: app))

        let file = menu("File", in: main)
        file.addItem(item("Sessions", #selector(App.showSessions), "0", target: app))
        file.addItem(.separator())
        file.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        let edit = menu("Edit", in: main)
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let view = menu("View", in: main)
        let sidebar = view.addItem(withTitle: "Show Sidebar", action: #selector(NSSplitViewController.toggleSidebar(_:)),
                                   keyEquivalent: "s")
        sidebar.keyEquivalentModifierMask = [.command, .control]
        let full = view.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)),
                                keyEquivalent: "f")
        full.keyEquivalentModifierMask = [.command, .control]

        let window = menu("Window", in: main)
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        window.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)),
                       keyEquivalent: "")
        NSApp.windowsMenu = window
        return main
    }

    private static func menu(_ title: String, in main: NSMenu) -> NSMenu {
        let m = NSMenu(title: title)
        main.addItem(withTitle: title, action: nil, keyEquivalent: "").submenu = m
        return m
    }

    private static func item(_ title: String, _ action: Selector, _ key: String, target: AnyObject) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = target
        return i
    }
}
