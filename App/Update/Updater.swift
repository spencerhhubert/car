import AppKit
import CryptoKit
import OwlKit
import Security

// Keeping owl up to date from the GitHub releases of the repository named in
// Info.plist (OwlReleases). A few times a day it asks for the latest release;
// when that is newer than this copy, it downloads the zip beside it and
// checks it three ways before it is offered: the checksum published with it,
// a valid signature, and the same signing team as the owl running now. The
// menu then offers the update; it is put in place only while nothing is
// recording or transcribing (a session in progress is worth more than any
// update), and owl restarts into it.
//
// The development copy never updates itself: it is whatever `./build.sh` made.
@MainActor
final class Updater {
    enum State: Equatable {
        case idle
        case checking
        case current
        case downloading(String)
        /// Downloaded and checked, waiting to be put in place.
        case ready(String)
        case failed(String)
    }

    private(set) var state: State = .idle
    /// Put the update in place as soon as owl is idle.
    private(set) var installWhenIdle = false
    private var staged: URL?
    private var timer: Timer?
    private let isBusy: () -> Bool

    static var version: String { Config.bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?" }
    private static var repository: String? { Config.bundle.infoDictionary?["OwlReleases"] as? String }
    static var enabled: Bool { !Config.isDev && repository != nil }

    init(isBusy: @escaping () -> Bool) { self.isBusy = isBusy }

    func start() {
        guard Self.enabled else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(30))
            await check()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.check() }
        }
    }

    /// Ask for the latest release, and fetch it when it is newer.
    func check() async {
        guard Self.enabled, let repo = Self.repository else { return }
        switch state {
        case .checking, .downloading, .ready: return
        default: break
        }
        state = .checking
        do {
            var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            req.timeoutInterval = 30
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                // No release yet is not a failure.
                state = (resp as? HTTPURLResponse)?.statusCode == 404 ? .current : .failed("no answer from GitHub")
                return
            }
            let release = try JSONDecoder().decode(Release.self, from: data)
            let latest = release.tag.hasPrefix("v") ? String(release.tag.dropFirst()) : release.tag
            guard Versions.newer(latest, than: Self.version) else {
                state = .current
                return
            }
            guard let zip = release.assets.first(where: { $0.name == "owl-\(latest).zip" }),
                  let sum = release.assets.first(where: { $0.name == "owl-\(latest).zip.sha256" }) else {
                state = .failed("release \(latest) has no owl-\(latest).zip and its .sha256")
                return
            }
            state = .downloading(latest)
            staged = try await fetch(latest, zip: zip.url, sum: sum.url)
            state = .ready(latest)
            Log.line("owl \(latest) is downloaded and checked; ready to install")
            if installWhenIdle { installIfIdle() }
        } catch {
            state = .failed(error.localizedDescription)
            Log.line("update check failed: \(error.localizedDescription)")
        }
    }

    /// The menu's "Update to …": now if idle, else as soon as it is.
    func install() {
        installWhenIdle = true
        installIfIdle()
    }

    /// Called when a session stops or finishes: the moment an update waiting
    /// for idle can go in.
    func installIfIdle() {
        guard installWhenIdle, case .ready(let version) = state, let staged, !isBusy() else { return }
        let here = Config.bundle.bundleURL
        do {
            _ = try FileManager.default.replaceItemAt(here, withItemAt: staged)
        } catch {
            state = .failed("could not put \(version) in place: \(error.localizedDescription)")
            return
        }
        Log.line("updated to owl \(version); restarting")
        // Reopen once this process is gone.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", here.path]
        try? p.run()
        NSApp.terminate(nil)
    }

    // MARK: - fetching and checking

    private func fetch(_ version: String, zip: URL, sum: URL) async throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "owl-update-\(version)")
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let (zipFile, _) = try await URLSession.shared.download(from: zip)
        let (sumData, _) = try await URLSession.shared.data(from: sum)
        let expected = String(decoding: sumData, as: UTF8.self).split(separator: " ").first.map(String.init) ?? ""
        let actual = SHA256.hash(data: try Data(contentsOf: zipFile)).map { String(format: "%02x", $0) }.joined()
        guard !expected.isEmpty, expected == actual else { throw Failure("the download does not match its checksum") }
        try run("/usr/bin/ditto", ["-x", "-k", zipFile.path, dir.path])
        let app = dir.appending(path: "owl.app")
        guard FileManager.default.fileExists(atPath: app.path) else { throw Failure("the zip holds no owl.app") }
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        guard let theirs = Self.team(of: app), let ours = Self.team(of: Config.bundle.bundleURL), theirs == ours else {
            throw Failure("the download is not signed by the team this owl is")
        }
        return app
    }

    private func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw Failure("\((tool as NSString).lastPathComponent) refused the download") }
    }

    /// The signing team of a bundle.
    private static func team(of url: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess
        else { return nil }
        return (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }

    private struct Release: Decodable {
        let tag: String
        let assets: [Asset]
        enum CodingKeys: String, CodingKey { case tag = "tag_name", assets }
        struct Asset: Decodable {
            let name: String
            let url: URL
            enum CodingKeys: String, CodingKey { case name, url = "browser_download_url" }
        }
    }
}
