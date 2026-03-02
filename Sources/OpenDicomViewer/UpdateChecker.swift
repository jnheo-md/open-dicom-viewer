import Foundation
import AppKit

@MainActor
class UpdateChecker: ObservableObject {
    enum State {
        case idle
        case checking
        case upToDate
        case updateAvailable(version: String, notes: String, downloadURL: URL)
        case error(String)
    }

    @Published var state: State = .idle
    @Published var showUpdateAlert = false

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
    }

    func checkForUpdates(userInitiated: Bool = false) async {
        if !userInitiated {
            let lastCheck = UserDefaults.standard.double(forKey: "lastUpdateCheck")
            if Date().timeIntervalSince1970 - lastCheck < 86400 {
                return
            }
        }

        state = .checking

        do {
            let url = URL(string: "https://api.github.com/repos/jnheo-md/open-dicom-viewer/releases/latest")!
            var request = URLRequest(url: url)
            request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")

            let (data, _) = try await URLSession.shared.data(for: request)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

            guard let tagName = json?["tag_name"] as? String else {
                state = .error("Invalid response from GitHub")
                return
            }

            let body = json?["body"] as? String ?? ""
            let remoteVersion = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName

            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastUpdateCheck")

            if isVersion(remoteVersion, newerThan: currentVersion) {
                if !userInitiated {
                    let skipped = UserDefaults.standard.string(forKey: "skippedVersion")
                    if skipped == remoteVersion {
                        state = .idle
                        return
                    }
                }

                let downloadURL = findDMGURL(in: json)
                    ?? URL(string: "https://github.com/jnheo-md/open-dicom-viewer/releases/latest")!

                state = .updateAvailable(version: remoteVersion, notes: body, downloadURL: downloadURL)
                showUpdateAlert = true
            } else {
                state = .upToDate
                if userInitiated {
                    showUpdateAlert = true
                }
            }
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    func skipVersion(_ version: String) {
        UserDefaults.standard.set(version, forKey: "skippedVersion")
        showUpdateAlert = false
        state = .idle
    }

    func openDownload(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    private func findDMGURL(in json: [String: Any]?) -> URL? {
        guard let assets = json?["assets"] as? [[String: Any]] else { return nil }
        for asset in assets {
            if let name = asset["name"] as? String,
               name.hasSuffix(".dmg"),
               let urlString = asset["browser_download_url"] as? String,
               let url = URL(string: urlString) {
                return url
            }
        }
        return nil
    }

    private func isVersion(_ a: String, newerThan b: String) -> Bool {
        let partsA = a.split(separator: ".").compactMap { Int($0) }
        let partsB = b.split(separator: ".").compactMap { Int($0) }
        let count = max(partsA.count, partsB.count)
        for i in 0..<count {
            let valA = i < partsA.count ? partsA[i] : 0
            let valB = i < partsB.count ? partsB[i] : 0
            if valA > valB { return true }
            if valA < valB { return false }
        }
        return false
    }
}
