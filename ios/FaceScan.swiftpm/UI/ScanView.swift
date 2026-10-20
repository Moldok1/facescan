import SwiftUI
import ARKit

/// Écran plein écran : capture → reconstruction → résultat.
struct ScanView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var controller: ScanController
    private let scansRoot: URL

    init(settings: ScanSettings, scansRoot: URL) {
        self.scansRoot = scansRoot
        _controller = StateObject(wrappedValue: ScanController(settings: settings, scansRoot: scansRoot))
    }

    var body: some View {
        Group {
            switch controller.state {
            case .starting, .scanning:
                CaptureView(controller: controller, onCancel: {
                    controller.cancel()
                    dismiss()
                })
            case .processing(let message):
                VStack(spacing: 20) {
                    ProgressView().controlSize(.large)
                    Text(message).font(.headline)
                    Text("Ne quittez pas l'application.").font(.footnote).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .finished(let record, let mesh):
                ResultView(record: record,
                           mesh: mesh,
                           fileURLs: record.files.map {
                               scansRoot.appendingPathComponent(record.folderName, isDirectory: true)
                                        .appendingPathComponent($0)
                           },
                           onDone: { dismiss() })
            case .failed(let message):
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.orange)
                    Text(message).multilineTextAlignment(.center)
                    Button("Fermer") {
                        controller.cancel()
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(32)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private struct CaptureView: View {
    @ObservedObject var controller: ScanController
    let onCancel: () -> Void

    var body: some View {
        let live = controller.live
        ZStack {
            ARFaceView(controller: controller)
                .ignoresSafeArea()

            VStack(spacing: 12) {
                HStack {
                    Badge(text: live.faceDetected ? String(format: "%.0f cm", live.distanceCM) : "—",
                          systemImage: "ruler",
                          color: (25...40).contains(live.distanceCM) ? .green : .orange)
                    Spacer()
                    if let a = live.alignmentMM {
                        Badge(text: String(format: "écart %.1f mm", a),
                              systemImage: "scope",
                              color: a < 4 ? .green : (a < 8 ? .yellow : .orange))
                    }
                }

                Spacer()

                VStack(spacing: 12) {
                    Image(systemName: live.symbol)
                        .font(.system(size: 72, weight: .bold))
                    Text(live.instruction)
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)
                    if let message = live.message {
                        Text(message)
                            .font(.headline)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.orange.opacity(0.9), in: Capsule())
                    }
                }
                .foregroundStyle(.white)
                .padding(20)
                .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 20))

                Spacer()

                CoverageBar(coverage: live.coverage)
                Text("\(live.framesIntegrated) images fusionnées · \(live.framesRejected) rejetées")
                    .font(.footnote)
                    .foregroundStyle(.white)

                HStack {
                    Button("Annuler", role: .cancel, action: onCancel)
                        .buttonStyle(.bordered)
                        .tint(.white)
                    Spacer()
                    Button("Étape suivante") { controller.skipPhase() }
                        .buttonStyle(.bordered)
                        .tint(.white)
                    Spacer()
                    Button("Terminer") { controller.finish() }
                        .buttonStyle(.borderedProminent)
                        .disabled(live.framesIntegrated < ScanController.minFrames)
                }
            }
            .padding()
        }
        .background(Color.black)
    }
}

private struct Badge: View {
    let text: String
    let systemImage: String
    let color: Color
    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.subheadline.bold())
            .foregroundStyle(.black)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(color, in: Capsule())
    }
}

/// Couverture angulaire : de la tête tournée vers la gauche (à gauche) à la droite (à droite).
private struct CoverageBar: View {
    let coverage: [Int]
    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                ForEach(coverage.indices, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 4)
                        .fill(color(for: coverage[i]))
                        .frame(height: 14)
                }
            }
            HStack {
                Text("◀ gauche")
                Spacer()
                Text("face")
                Spacer()
                Text("droite ▶")
            }
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.8))
        }
        .padding(.horizontal, 8)
    }

    private func color(for count: Int) -> Color {
        switch count {
        case 0: return .gray.opacity(0.5)
        case 1..<4: return .orange
        default: return .green
        }
    }
}

/// Vue caméra ARKit (TrueDepth, image en miroir comme un selfie).
struct ARFaceView: UIViewRepresentable {
    let controller: ScanController

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.automaticallyUpdatesLighting = false
        view.rendersCameraGrain = false
        controller.start(session: view.session)
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}

    static func dismantleUIView(_ uiView: ARSCNView, coordinator: ()) {
        uiView.session.pause()
    }
}
