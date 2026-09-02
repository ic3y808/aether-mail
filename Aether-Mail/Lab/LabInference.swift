import Foundation
import Observation

/// Finds a bigger brain on the network, and falls back to the phone's own.
///
/// The on-device model is ~3B and shows it: told to answer, it invents; told not
/// to invent, it collapses into placeholders. It cannot hold both constraints at
/// once. A 26B model on a Mac in the same house has no such trouble - and this
/// network already has one serving on 10.0.0.25.
///
/// So: on-device by default, because it always works and never leaves the phone;
/// a LAN host when one is actually reachable. Off the LAN - on cellular - the
/// scan simply finds nothing and the phone answers for itself.
@MainActor
@Observable
final class LabInference {
    static let shared = LabInference()

    struct Host: Identifiable, Hashable {
        let address: String
        let port: Int
        let engine: String        // "Ollama" | "LM Studio"
        var models: [String] = []
        var id: String { "\(address):\(port)" }
        var baseURL: String { "http://\(address):\(port)" }
        /// The model this host should be asked to use.
        var best: String? { LabInference.pickModel(from: models) }
    }

    private(set) var hosts: [Host] = []
    private(set) var isScanning = false
    /// nil means "use the phone".
    var selected: Host?

    /// Master switch for anything that touches the network. **Off by default.**
    ///
    /// This app's whole proposition is that mail talks to your providers and the
    /// AI runs on your device. Probing the local network, and then sending
    /// message bodies to another machine, is a real departure from that - even
    /// when the machine is the owner's own Mac in the next room. It should be a
    /// deliberate act, not a default, and it should be visibly reversible.
    ///
    /// The guard lives here rather than in the UI so no future caller can reach
    /// the network by forgetting to check a flag.
    var allowNetworkModels: Bool {
        get { UserDefaults.standard.bool(forKey: Self.enabledKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.enabledKey)
            if !newValue {
                // Turning it off discards what the scan learned, so nothing
                // lingers pointing at a machine on someone's network.
                hosts = []
                selected = nil
            }
        }
    }
    private static let enabledKey = "lab.allowNetworkModels"   // absent == false

    private let known = [(11434, "Ollama"), (1234, "LM Studio")]

    /// Probes the phone's own /24 for inference servers.
    ///
    /// Parallel with a short timeout because 254 sequential probes would take
    /// minutes; a server that cannot answer in a second on a LAN is not one we
    /// want to send a draft to anyway.
    func scan() async {
        guard allowNetworkModels else { hosts = []; return }
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }

        guard let prefix = Self.subnetPrefix() else { hosts = []; return }
        var found: [Host] = []

        await withTaskGroup(of: Host?.self) { group in
            for octet in 1...254 {
                let address = "\(prefix).\(octet)"
                for (port, engine) in known {
                    group.addTask { await Self.probe(address: address, port: port, engine: engine) }
                }
            }
            for await host in group {
                if let host { found.append(host) }
            }
        }
        hosts = found.sorted { $0.address < $1.address }
    }

    nonisolated private static func probe(address: String, port: Int, engine: String) async -> Host? {
        guard let url = URL(string: "http://\(address):\(port)/v1/models") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.2
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(ModelList.self, from: data),
              !decoded.data.isEmpty
        else { return nil }
        return Host(address: address, port: port, engine: engine,
                    models: decoded.data.map(\.id))
    }

    private struct ModelList: Decodable {
        struct Entry: Decodable { let id: String }
        let data: [Entry]
    }

    /// Chooses the most capable *general* model a host offers.
    ///
    /// Size wins, but only after the unusable are removed: an embedding model
    /// cannot write, and a 1.5B coder is worse at prose than the phone already
    /// is. Parameter counts come from the name because that is the only place
    /// Ollama and LM Studio agree to put them.
    nonisolated static func pickModel(from models: [String]) -> String? {
        let usable = models.filter { name in
            let n = name.lowercased()
            if n.contains("embed") || n.contains("bge") || n.contains("rerank") { return false }
            if n.contains("coder") || n.contains("code-") { return false }
            if n.contains("whisper") || n.contains("vision") { return false }
            return true
        }
        guard !usable.isEmpty else { return nil }

        func billions(_ name: String) -> Double {
            // "gemma4:26b" -> 26, "qwable-9b" -> 9, "gemma2:2b" -> 2
            guard let m = name.lowercased().range(of: #"(\d+(\.\d+)?)\s*b\b"#, options: .regularExpression)
            else { return 0 }
            return Double(name[m].lowercased()
                .replacingOccurrences(of: "b", with: "")
                .trimmingCharacters(in: .whitespaces)) ?? 0
        }

        // Anything at least as big as the phone's own model, largest first.
        let ranked = usable.sorted { billions($0) > billions($1) }
        if let best = ranked.first, billions(best) >= 4 { return best }
        return ranked.first
    }

    /// Runs a completion on the selected host. Returns nil if there is none, or
    /// it failed - the caller then falls back to the phone.
    func complete(system: String, user: String) async -> String? {
        // Checked again at the point of use: a stale selection must not survive
        // the switch being turned off mid-session.
        guard allowNetworkModels else { return nil }
        guard let host = selected, let model = host.best else { return nil }
        guard let url = URL(string: host.baseURL + "/v1/chat/completions") else { return nil }

        let payload: [String: Any] = [
            "model": model,
            "stream": false,
            "temperature": 0.2,          // a draft should not be a lottery
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user]
            ]
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        request.timeoutInterval = 90     // a 26B model on a Mac is not instant

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String
        else { return nil }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The first three octets of this device's LAN address.
    nonisolated private static func subnetPrefix() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard flags & IFF_UP == IFF_UP, flags & IFF_LOOPBACK == 0 else { continue }
            guard ptr.pointee.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            // en0 is Wi-Fi on iOS; cellular interfaces are not a LAN.
            let name = String(cString: ptr.pointee.ifa_name)
            guard name == "en0" || name == "en1" else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(ptr.pointee.ifa_addr, socklen_t(ptr.pointee.ifa_addr.pointee.sa_len),
                           &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                address = String(cString: host)
                break
            }
        }
        guard let address else { return nil }
        let parts = address.split(separator: ".")
        guard parts.count == 4 else { return nil }
        return parts.prefix(3).joined(separator: ".")
    }
}
