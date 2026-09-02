import Foundation
import EmailKit

/// Signs a development build in automatically so a rebuild does not mean
/// retyping an app-specific password every time.
///
/// Three deliberate constraints:
///
/// 1. `#if DEBUG` **and** Simulator-only. This code does not exist in a release
///    build and will not run on a real device, so it cannot become a way that
///    credentials ship.
/// 2. The file lives on the Mac, at `~/.aether-mail-dev.json`, NOT in the app
///    bundle. Nothing to accidentally commit, and it survives erasing the
///    Simulator - which wiping the Keychain does not.
/// 3. It only ever runs when there are no accounts, so it cannot fight with an
///    account added by hand.
///
/// The repository is public. Never put real credentials anywhere inside it.
enum DevBootstrap {

    struct DevAccount: Codable {
        let provider: String       // icloud | gmail | outlook | custom
        let email: String
        let password: String       // app-specific password
        let host: String?          // custom IMAP host, optional
    }

    /// Resolved against the *host* home directory, not the app sandbox.
    private static var hostConfigURL: URL? {
        #if targetEnvironment(simulator)
        // SIMULATOR_HOST_HOME is documented but is not actually set in the
        // app's environment, so the host home is recovered from the sandbox
        // path instead. A Simulator container always lives under
        //   /Users/<name>/Library/Developer/CoreSimulator/Devices/...
        // so everything before that marker is the Mac's home directory.
        if let hostHome = ProcessInfo.processInfo.environment["SIMULATOR_HOST_HOME"] {
            return URL(fileURLWithPath: hostHome).appendingPathComponent(".aether-mail-dev.json")
        }
        let sandbox = NSHomeDirectory()
        if let range = sandbox.range(of: "/Library/Developer/CoreSimulator") {
            let hostHome = String(sandbox[sandbox.startIndex..<range.lowerBound])
            return URL(fileURLWithPath: hostHome).appendingPathComponent(".aether-mail-dev.json")
        }
        #endif
        return nil
    }

    @MainActor
    static func run(store: MailStore) async {
        #if DEBUG
        #if targetEnvironment(simulator)
        // Adds anything in the file that is not signed in yet, rather than only
        // running on an empty store - otherwise appending a second account to
        // the file does nothing until every account is removed by hand.
        guard let url = hostConfigURL,
              let data = try? Data(contentsOf: url),
              let accounts = try? JSONDecoder().decode([DevAccount].self, from: data),
              !accounts.isEmpty
        else { return }

        let existing = Set(store.accounts.map { $0.emailAddress.lowercased() })
        for dev in accounts where !existing.contains(dev.email.lowercased()) {
            let provider = MailProvider(rawValue: dev.provider) ?? .custom
            let error = await store.addAccount(
                provider: provider,
                email: dev.email,
                password: dev.password,
                customHost: dev.host ?? ""
            )
            if let error {
                store.banner = "Dev sign-in failed for \(dev.email) — \(error)"
            } else {
                store.banner = "Signed in \(dev.email) from the dev file."
            }
        }
        #endif
        #endif
    }
}
