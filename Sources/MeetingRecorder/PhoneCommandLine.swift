import Foundation

enum PhoneCommandLine {
    /// The value after `flag`, if there is one.
    static func value(_ flag: String, in arguments: [String]) -> String? {
        arguments.firstIndex(of: flag).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
    }

    /// `--serve [--port N] --data-dir X [--keychain]`: runs only the server against a data folder and reads commands from
    /// stdin (`pair [seconds]`, `revoke <id>`, `devices`, `quit`), so a scratch copy of the data can be tested end to end.
    /// The device keys go to a file in the folder, or with `--keychain` to a test service in the Keychain.
    static func serve(_ arguments: [String]) -> Never {
        guard AppPaths.dataDirectory != nil else { fail("--serve needs --data-dir, so the real data is never served by accident") }
        let store = MeetingStore.openDefault()
        if let error = store.openError { fail(error.localizedDescription) }
        let port = value("--port", in: arguments).flatMap(UInt16.init) ?? UInt16(PhoneAPI.defaultPort)
        let secrets: PhoneSecretStore = arguments.contains("--keychain") ? KeychainSecretStore(service: KeychainSecretStore.service + ".dev")
            : FileSecretStore(folder: AppPaths.dataDirectory!)
        var endpoints = PhoneEndpoints(store: store, appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")
        endpoints.features = { PhoneFeatures(githubEnabled: true, activityEnabled: true, chatAvailable: PhoneEndpoints.chatAvailable) }
        endpoints.refreshGitHub = { [store] in
            let fetch = await Task.detached { GitHubClient.fetchAll(cli: GitHubLogic.findCLI()) }.value
            if !fetch.prs.isEmpty { try? store.saveGitHubPRs(fetch.prs) }
            return fetch.error?.message
        }
        let server = PhoneServer(store: store, secrets: secrets, endpoints: endpoints)
        setvbuf(stdout, nil, _IOLBF, 0)
        Task {
            await server.start(port: port)
            switch server.status {
            case .listening(let host, let port): print("listening \(host):\(port)")
            case .failed(let message): fail(message)
            default: break
            }
            for await line in standardInputLines() {
                let words = line.split(separator: " ").map(String.init)
                switch words.first {
                case "pair":
                    do {
                        let pairing = try await server.beginPairing(lifetime: words.count > 1 ? TimeInterval(words[1]) ?? 300 : 300)
                        print("pair \(pairing.url.absoluteString)")
                        print("code \(pairing.manualCode)")
                    } catch { print("error \(error.localizedDescription)") }
                case "revoke" where words.count > 1:
                    await server.revoke(words[1])
                    print("revoked \(words[1])")
                case "devices":
                    for device in server.pairedDevices { print("device \(device.id) \(device.name) seen \(device.lastSeen.map(ActivityLogic.dateText) ?? "never")") }
                    print("devices \(server.pairedDevices.count)")
                case "quit":
                    await server.stop()
                    exit(0)
                default:
                    print("error unknown command")
                }
            }
            await server.stop()
            exit(0)
        }
        dispatchMain()
    }

    private static func standardInputLines() -> AsyncStream<String> {
        AsyncStream { continuation in
            let thread = Thread {
                while let line = readLine() { continuation.yield(line) }
                continuation.finish()
            }
            thread.start()
        }
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("Failed: \(message)\n".utf8))
        exit(1)
    }
}
