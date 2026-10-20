import SwiftUI
import UIKit

/// État observable du portail, partagé par toute l'application.
@MainActor
final class PortalModel: ObservableObject {
    @Published private(set) var isConfigured = PortalSettings.isConfigured
    @Published private(set) var host: String? = PortalSettings.baseURL?.host
    @Published var autoUpload = PortalSettings.autoUpload {
        didSet { PortalSettings.autoUpload = autoUpload }
    }
    @Published var pairingMessage: String?

    func refresh() {
        isConfigured = PortalSettings.isConfigured
        host = PortalSettings.baseURL?.host
    }

    func handle(url: URL) {
        if let host = PortalSettings.handlePairingURL(url) {
            refresh()
            pairingMessage = "iPhone appairé au portail \(host)."
        } else {
            pairingMessage = "Lien d'appairage invalide."
        }
    }

    func configure(urlString: String, token: String) -> Bool {
        guard let url = PortalSettings.normalize(urlString),
              token.trimmingCharacters(in: .whitespaces).hasPrefix("fsk_") else { return false }
        PortalSettings.baseURL = url
        PortalSettings.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        refresh()
        return true
    }

    func disconnect() {
        PortalSettings.disconnect()
        autoUpload = false
        refresh()
    }

    var deviceName: String { PortalSettings.deviceName ?? UIDevice.current.name }
}

/// Réglages du portail : état, test de connexion, saisie manuelle, déconnexion.
struct PortalSettingsView: View {
    @EnvironmentObject private var portal: PortalModel
    @State private var urlText = PortalSettings.baseURL?.absoluteString ?? ""
    @State private var tokenText = ""
    @State private var testResult: String?
    @State private var testing = false

    var body: some View {
        Form {
            Section {
                if portal.isConfigured {
                    LabeledContent("Portail", value: portal.host ?? "—")
                    LabeledContent("Appareil", value: portal.deviceName)
                    Button {
                        Task { await test() }
                    } label: {
                        HStack {
                            Text("Tester la connexion")
                            if testing { Spacer(); ProgressView() }
                        }
                    }
                    if let testResult { Text(testResult).font(.footnote) }
                    Toggle("Envoi automatique après chaque scan", isOn: $portal.autoUpload)
                } else {
                    Text("Non appairé").foregroundStyle(.secondary)
                }
            } header: {
                Text("Portail du cabinet")
            } footer: {
                Text("Pour appairer : sur un ordinateur, ouvrez le portail › Réglages › Créer un jeton, puis scannez le QR code avec l'appareil photo de cet iPhone.")
            }

            Section("Saisie manuelle") {
                TextField("Adresse (ex. facescan.altioresante.cloud)", text: $urlText)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Jeton (fsk_…)", text: $tokenText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Enregistrer") {
                    if portal.configure(urlString: urlText, token: tokenText) {
                        tokenText = ""
                        Task { await test() }
                    } else {
                        testResult = "Adresse ou jeton invalide (le jeton commence par fsk_)."
                    }
                }
                .disabled(urlText.isEmpty || tokenText.isEmpty)
            }

            if portal.isConfigured {
                Section {
                    Button("Déconnecter cet iPhone", role: .destructive) {
                        portal.disconnect()
                        testResult = nil
                    }
                }
            }
        }
        .navigationTitle("Portail")
    }

    private func test() async {
        testing = true
        defer { testing = false }
        do {
            let name = try await PortalClient.ping()
            testResult = "✅ Connexion réussie (appareil « \(name) »)."
        } catch {
            testResult = "❌ \(error.localizedDescription)"
        }
    }
}

/// Recherche d'un patient sur le portail pour remplir l'identifiant.
struct PatientPickerView: View {
    @Environment(\.dismiss) private var dismiss
    let onPick: (PortalPatient) -> Void
    @State private var query = ""
    @State private var results: [PortalPatient] = []
    @State private var error: String?
    @State private var loading = false

    var body: some View {
        NavigationStack {
            List {
                if let error { Text(error).foregroundStyle(.red).font(.footnote) }
                ForEach(results) { p in
                    Button {
                        onPick(p)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading) {
                            Text(p.displayName).font(.headline).foregroundStyle(.primary)
                            Text("\(p.ref) · \(p.scanCount) scan(s)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if !loading && results.isEmpty && error == nil {
                    Text("Aucun patient trouvé").foregroundStyle(.secondary)
                }
            }
            .overlay { if loading { ProgressView() } }
            .searchable(text: $query, prompt: "Nom ou identifiant")
            .navigationTitle("Patients du portail")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Fermer") { dismiss() } }
            }
            .task(id: query) {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { return }
                loading = true
                defer { loading = false }
                do {
                    results = try await PortalClient.searchPatients(query)
                    error = nil
                } catch {
                    self.error = error.localizedDescription
                }
            }
        }
    }
}

/// Bouton « Envoyer au portail » avec état (affiché sur l'écran de résultat et la fiche d'un scan).
struct UploadSection: View {
    @EnvironmentObject private var portal: PortalModel
    let record: ScanRecord
    let folder: URL
    var autoStart = false

    @State private var marker: UploadMarker?
    @State private var uploading = false
    @State private var error: String?
    @State private var started = false

    var body: some View {
        Section {
            if !portal.isConfigured {
                Text("Portail non appairé — voir Réglages › Portail.").foregroundStyle(.secondary)
            } else if let marker {
                Label("Envoyé au portail le \(marker.uploadedAt.formatted(date: .abbreviated, time: .shortened))",
                      systemImage: "checkmark.icloud.fill")
                    .foregroundStyle(.green)
                if let url = PortalClient.webURL(scanId: marker.scanId) {
                    Link("Ouvrir sur le portail", destination: url)
                }
            } else {
                Button {
                    Task { await send() }
                } label: {
                    HStack {
                        Label(uploading ? "Envoi en cours…" : "Envoyer au portail", systemImage: "icloud.and.arrow.up")
                            .font(.headline)
                        if uploading { Spacer(); ProgressView() }
                    }
                }
                .disabled(uploading)
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            }
        } header: {
            Text("Portail")
        }
        .task {
            marker = PortalClient.uploadMarker(folder: folder)
            if autoStart, portal.autoUpload, portal.isConfigured, marker == nil, !started {
                started = true
                await send()
            }
        }
    }

    private func send() async {
        uploading = true
        error = nil
        defer { uploading = false }
        do {
            marker = try await PortalClient.upload(record: record, folder: folder, deviceName: portal.deviceName)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
