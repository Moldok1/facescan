import SwiftUI
import ARKit

struct ContentView: View {
    @EnvironmentObject private var store: ScanStore
    @EnvironmentObject private var portal: PortalModel
    @State private var showPatientPicker = false

    @State private var patientID = ""
    @State private var scanType: ScanType = .repos
    @AppStorage("resolution") private var resolution: ScanResolution = .standard
    @AppStorage("smoothing") private var smoothing = true
    @AppStorage("expressionLock") private var expressionLock = true
    @AppStorage("voiceGuidance") private var voiceGuidance = true
    @State private var activeScan: ScanSettings?

    private let supported = ARFaceTrackingConfiguration.isSupported

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        TextField("Identifiant (ex. P-2026-0142)", text: $patientID)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                        if portal.isConfigured {
                            Button {
                                showPatientPicker = true
                            } label: {
                                Image(systemName: "magnifyingglass")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Rechercher un patient sur le portail")
                        }
                    }
                    Picker("Type de scan", selection: $scanType) {
                        ForEach(ScanType.allCases) { Text($0.rawValue).tag($0) }
                    }
                } header: {
                    Text("Patient")
                } footer: {
                    Text("Utilisez un identifiant pseudonymisé plutôt que le nom du patient.")
                }

                Section("Portail") {
                    NavigationLink {
                        PortalSettingsView()
                    } label: {
                        HStack {
                            Label("Portail du cabinet", systemImage: "icloud")
                            Spacer()
                            Text(portal.isConfigured ? (portal.host ?? "Appairé") : "Non appairé")
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }

                Section("Réglages") {
                    Picker("Résolution", selection: $resolution) {
                        ForEach(ScanResolution.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Toggle("Lissage léger", isOn: $smoothing)
                    Toggle("Verrou d'expression", isOn: $expressionLock)
                    Toggle("Guidage vocal", isOn: $voiceGuidance)
                }

                Section {
                    Button {
                        activeScan = ScanSettings(patientID: patientID,
                                                  scanType: scanType,
                                                  resolution: resolution,
                                                  smoothing: smoothing,
                                                  expressionLock: expressionLock,
                                                  voiceGuidance: voiceGuidance)
                    } label: {
                        Label("Démarrer le scan", systemImage: "faceid")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(!supported)
                } footer: {
                    if !supported {
                        Text("Cet appareil n'a pas de caméra TrueDepth (Face ID) : le scan est impossible.")
                    }
                }

                Section("Protocole") {
                    DisclosureGroup("Conseils de capture") {
                        VStack(alignment: .leading, spacing: 8) {
                            Tip("iPhone fixé sur un trépied, écran face au patient, à hauteur des yeux.")
                            Tip("Distance 25 à 40 cm. Lumière diffuse, pas de contre-jour ni de soleil direct.")
                            Tip("Cheveux dégagés du front et des oreilles, lunettes retirées.")
                            Tip("Le patient tourne la tête lentement en suivant la voix et les flèches ; il garde la même expression.")
                            Tip("Faites 2 à 3 scans : repos, sourire, puis écarteurs pour le recalage avec l'empreinte optique.")
                        }
                        .font(.footnote)
                        .padding(.vertical, 4)
                    }
                }

                Section("Scans enregistrés") {
                    if store.records.isEmpty {
                        Text("Aucun scan pour le moment").foregroundStyle(.secondary)
                    }
                    ForEach(store.records) { record in
                        NavigationLink(value: record) { ScanRow(record: record) }
                    }
                    .onDelete { offsets in
                        let toDelete = offsets.map { store.records[$0] }
                        toDelete.forEach { store.delete($0) }
                    }
                }
            }
            .navigationTitle("FaceScan")
            .navigationDestination(for: ScanRecord.self) { record in
                ScanDetailView(record: record)
            }
            .fullScreenCover(item: $activeScan, onDismiss: { store.reload() }) { settings in
                ScanView(settings: settings, scansRoot: store.root)
                    .environmentObject(portal)
            }
            .sheet(isPresented: $showPatientPicker) {
                PatientPickerView { patient in patientID = patient.ref }
            }
        }
    }
}

private struct Tip: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "checkmark.circle").foregroundStyle(.tint)
            Text(text)
        }
    }
}

struct ScanRow: View {
    let record: ScanRecord
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(record.patientID.isEmpty ? "Sans identifiant" : record.patientID) — \(record.scanType)")
                .font(.headline)
            Text(record.date.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
