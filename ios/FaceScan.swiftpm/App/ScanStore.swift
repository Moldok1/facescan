import Foundation

/// Liste des scans enregistrés dans Documents/Scans (un dossier par scan).
/// Les données restent sur l'appareil ; rien n'est envoyé sur Internet.
@MainActor
final class ScanStore: ObservableObject {
    @Published private(set) var records: [ScanRecord] = []

    let root: URL

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        root = docs.appendingPathComponent("Scans", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        reload()
    }

    func reload() {
        let fm = FileManager.default
        let folders = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        records = folders.compactMap { folder -> ScanRecord? in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("scan.json")) else { return nil }
            return try? decoder.decode(ScanRecord.self, from: data)
        }
        .sorted { $0.date > $1.date }
    }

    func folderURL(for record: ScanRecord) -> URL {
        root.appendingPathComponent(record.folderName, isDirectory: true)
    }

    /// Fichiers 3D du scan (STL, PLY, OBJ), sans la fiche JSON.
    func fileURLs(for record: ScanRecord) -> [URL] {
        record.files.map { folderURL(for: record).appendingPathComponent($0) }
    }

    func delete(_ record: ScanRecord) {
        try? FileManager.default.removeItem(at: folderURL(for: record))
        reload()
    }
}
