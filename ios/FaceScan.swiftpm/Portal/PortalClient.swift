import Foundation
import Security

// MARK: - Réglages du portail (adresse dans UserDefaults, jeton dans le trousseau iOS)

enum PortalSettings {
    private static let urlKey = "portalURL"
    private static let nameKey = "portalDeviceName"
    private static let autoKey = "portalAutoUpload"
    private static let keychainAccount = "fr.altiore.facescan.portal-token"

    static var baseURL: URL? {
        get {
            guard let s = UserDefaults.standard.string(forKey: urlKey), !s.isEmpty else { return nil }
            return URL(string: s)
        }
        set { UserDefaults.standard.set(newValue?.absoluteString, forKey: urlKey) }
    }

    static var deviceName: String? {
        get { UserDefaults.standard.string(forKey: nameKey) }
        set { UserDefaults.standard.set(newValue, forKey: nameKey) }
    }

    static var autoUpload: Bool {
        get { UserDefaults.standard.bool(forKey: autoKey) }
        set { UserDefaults.standard.set(newValue, forKey: autoKey) }
    }

    static var token: String? {
        get { Keychain.read(account: keychainAccount) }
        set {
            if let newValue, !newValue.isEmpty {
                Keychain.write(newValue, account: keychainAccount)
            } else {
                Keychain.delete(account: keychainAccount)
            }
        }
    }

    static var isConfigured: Bool { baseURL != nil && token != nil }

    /// Normalise l'adresse saisie : https par défaut, sans « / » final.
    static func normalize(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        if !s.lowercased().hasPrefix("http://") && !s.lowercased().hasPrefix("https://") { s = "https://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        return URL(string: s)
    }

    /// Lien d'appairage du QR code : facescan://pair?url=…&token=…&name=…
    static func handlePairingURL(_ url: URL) -> String? {
        guard url.scheme?.lowercased() == "facescan", url.host?.lowercased() == "pair",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let rawURL = items.first(where: { $0.name == "url" })?.value,
              let token = items.first(where: { $0.name == "token" })?.value,
              token.hasPrefix("fsk_"),
              let base = normalize(rawURL) else { return nil }
        baseURL = base
        self.token = token
        deviceName = items.first(where: { $0.name == "name" })?.value
        return base.host ?? base.absoluteString
    }

    static func disconnect() {
        baseURL = nil
        token = nil
        deviceName = nil
    }
}

enum Keychain {
    static func write(_ value: String, account: String) {
        delete(account: account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Client HTTP

struct PortalPatient: Decodable, Identifiable, Hashable {
    var id: String { ref }
    let ref: String
    let lastName: String?
    let firstName: String?
    let scanCount: Int

    var displayName: String {
        let name = [lastName?.uppercased(), firstName].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        return name.isEmpty ? ref : name
    }
}

/// Trace d'un envoi réussi, enregistrée dans le dossier du scan (upload.json).
struct UploadMarker: Codable {
    let scanId: String
    let uploadedAt: Date
    let portal: String
}

enum PortalError: LocalizedError {
    case notConfigured
    case unauthorized
    case server(Int, String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Portail non configuré. Scannez le QR code affiché dans les réglages du portail."
        case .unauthorized: return "Jeton refusé (révoqué ?). Appairez à nouveau l'iPhone."
        case .server(let code, let msg): return "Erreur du portail (\(code)) : \(msg)"
        case .invalidResponse: return "Réponse du portail illisible."
        }
    }
}

enum PortalClient {

    private static func request(_ path: String, query: [URLQueryItem] = []) throws -> URLRequest {
        guard let base = PortalSettings.baseURL, let token = PortalSettings.token else { throw PortalError.notConfigured }
        var comps = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 20
        return req
    }

    private static func check(_ data: Data, _ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw PortalError.invalidResponse }
        if http.statusCode == 401 { throw PortalError.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw PortalError.server(http.statusCode, msg ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode))
        }
    }

    /// Test de connexion ; renvoie le nom de l'appareil connu du portail.
    static func ping() async throws -> String {
        let (data, response) = try await URLSession.shared.data(for: request("api/v1/ping"))
        try check(data, response)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return json?["device"] as? String ?? "OK"
    }

    static func searchPatients(_ q: String) async throws -> [PortalPatient] {
        struct Payload: Decodable { let patients: [PortalPatient] }
        let (data, response) = try await URLSession.shared.data(for: request("api/v1/patients", query: [URLQueryItem(name: "q", value: q)]))
        try check(data, response)
        return try JSONDecoder().decode(Payload.self, from: data).patients
    }

    /// Envoie un scan enregistré (scan.json + STL/PLY/OBJ) au portail.
    static func upload(record: ScanRecord, folder: URL, deviceName: String) async throws -> UploadMarker {
        var req = try request("api/v1/scans")
        req.httpMethod = "POST"
        req.timeoutInterval = 300
        let boundary = "FaceScan-\(UUID().uuidString)"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        // Métadonnées : scan.json + nom de l'appareil
        var meta = (try? JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("scan.json"))) as? [String: Any]) ?? [:]
        meta["deviceName"] = deviceName
        let metaData = try JSONSerialization.data(withJSONObject: meta)

        // Corps multipart écrit dans un fichier temporaire (les OBJ peuvent dépasser 20 Mo)
        let bodyURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(boundary).body")
        FileManager.default.createFile(atPath: bodyURL.path, contents: nil)
        let out = try FileHandle(forWritingTo: bodyURL)
        defer {
            try? out.close()
            try? FileManager.default.removeItem(at: bodyURL)
        }
        func write(_ s: String) { out.write(Data(s.utf8)) }

        write("--\(boundary)\r\nContent-Disposition: form-data; name=\"metadata\"\r\nContent-Type: application/json\r\n\r\n")
        out.write(metaData)
        write("\r\n")
        for name in record.files {
            let ext = (name as NSString).pathExtension.lowercased()
            guard ["stl", "ply", "obj"].contains(ext) else { continue }
            let fileURL = folder.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: fileURL.path) else { continue }
            write("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(ext)\"; filename=\"\(name)\"\r\nContent-Type: application/octet-stream\r\n\r\n")
            out.write(try Data(contentsOf: fileURL, options: .mappedIfSafe))
            write("\r\n")
        }
        write("--\(boundary)--\r\n")
        try out.close()

        let (data, response) = try await URLSession.shared.upload(for: req, fromFile: bodyURL)
        try check(data, response)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? String else { throw PortalError.invalidResponse }

        let marker = UploadMarker(scanId: id, uploadedAt: Date(), portal: PortalSettings.baseURL?.host ?? "")
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try? enc.encode(marker).write(to: folder.appendingPathComponent("upload.json"))
        return marker
    }

    static func uploadMarker(folder: URL) -> UploadMarker? {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("upload.json")) else { return nil }
        return try? dec.decode(UploadMarker.self, from: data)
    }

    /// Adresse web du scan sur le portail.
    static func webURL(scanId: String) -> URL? {
        PortalSettings.baseURL?.appendingPathComponent("scans/\(scanId)")
    }
}
