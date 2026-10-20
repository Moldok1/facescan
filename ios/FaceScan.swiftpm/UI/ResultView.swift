import SwiftUI
import SceneKit

/// Résultat juste après le scan : aperçu 3D, contrôles qualité, partage des fichiers.
struct ResultView: View {
    let record: ScanRecord
    let mesh: ColoredMesh
    let fileURLs: [URL]
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                MeshPreview(mesh: mesh)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                ScanInfoList(record: record, fileURLs: fileURLs, autoUpload: true)
                    .frame(height: 380)
            }
            .navigationTitle("Résultat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Terminé", action: onDone)
                }
            }
        }
    }
}

/// Fiche d'un scan déjà enregistré (depuis la liste de l'écran d'accueil).
struct ScanDetailView: View {
    @EnvironmentObject private var store: ScanStore
    @Environment(\.dismiss) private var dismiss
    let record: ScanRecord
    @State private var mesh: ColoredMesh?
    @State private var confirmDelete = false

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if let mesh {
                    MeshPreview(mesh: mesh)
                } else {
                    ProgressView("Chargement de l'aperçu…")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)

            ScanInfoList(record: record, fileURLs: store.fileURLs(for: record))
                .frame(height: 380)
        }
        .navigationTitle(record.patientID.isEmpty ? record.scanType : "\(record.patientID) — \(record.scanType)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .destructiveAction) {
                Button(role: .destructive) { confirmDelete = true } label: {
                    Image(systemName: "trash")
                }
            }
        }
        .confirmationDialog("Supprimer ce scan ?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Supprimer", role: .destructive) {
                store.delete(record)
                dismiss()
            }
        }
        .task {
            guard mesh == nil,
                  let plyName = record.files.first(where: { $0.hasSuffix(".ply") }) else { return }
            let url = store.folderURL(for: record).appendingPathComponent(plyName)
            mesh = await Task.detached(priority: .userInitiated) {
                try? MeshExporters.readPLY(url)
            }.value
        }
    }
}

private struct ScanInfoList: View {
    let record: ScanRecord
    let fileURLs: [URL]
    var autoUpload = false

    var body: some View {
        List {
            if let folder = fileURLs.first?.deletingLastPathComponent() {
                UploadSection(record: record, folder: folder, autoStart: autoUpload)
            }
            Section {
                ShareLink(items: fileURLs) {
                    Label("Partager / enregistrer STL, PLY, OBJ", systemImage: "square.and.arrow.up")
                        .font(.headline)
                }
            } footer: {
                Text("AirDrop vers le poste de CFAO, ou « Enregistrer dans Fichiers ». Unités : millimètres.")
            }
            Section("Contrôle qualité") {
                InfoRow("Images fusionnées", "\(record.framesIntegrated)")
                if let a = record.medianAlignmentMM {
                    InfoRow("Écart médian suivi / profondeur", String(format: "%.1f mm", a))
                }
                if record.sizeMM.count == 3 {
                    InfoRow("Dimensions (L × H × P)",
                            String(format: "%.0f × %.0f × %.0f mm", record.sizeMM[0], record.sizeMM[1], record.sizeMM[2]))
                }
                InfoRow("Résolution", String(format: "%.2f mm", record.voxelSizeMM))
                InfoRow("Maillage", "\(record.vertexCount) sommets · \(record.triangleCount) triangles")
            }
            Section("Fichiers") {
                ForEach(record.files, id: \.self) { name in
                    Text(name).font(.footnote.monospaced())
                }
            }
        }
    }
}

private struct InfoRow: View {
    let label: String
    let value: String
    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }
    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
    }
}

/// Aperçu 3D (SceneKit) : rotation au doigt, pincer pour zoomer.
struct MeshPreview: UIViewRepresentable {
    let mesh: ColoredMesh

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .black
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        view.antialiasingMode = .multisampling4X
        let (scene, cameraNode) = Self.makeScene(mesh)
        view.scene = scene
        view.pointOfView = cameraNode
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {}

    static func makeScene(_ mesh: ColoredMesh) -> (SCNScene, SCNNode) {
        let scene = SCNScene()
        let n = mesh.vertexCount
        let stride = MemoryLayout<SIMD3<Float>>.stride

        let normals = mesh.normals.count == n ? mesh.normals : [SIMD3<Float>](repeating: SIMD3<Float>(0, 0, 1), count: n)
        let colors = mesh.colors.map { SIMD3<Float>(Float($0.x) / 255, Float($0.y) / 255, Float($0.z) / 255) }

        func source(_ values: [SIMD3<Float>], _ semantic: SCNGeometrySource.Semantic) -> SCNGeometrySource {
            let data = values.withUnsafeBufferPointer { Data(buffer: $0) }
            return SCNGeometrySource(data: data, semantic: semantic, vectorCount: values.count,
                                     usesFloatComponents: true, componentsPerVector: 3,
                                     bytesPerComponent: MemoryLayout<Float>.size,
                                     dataOffset: 0, dataStride: stride)
        }

        let indexData = mesh.indices.withUnsafeBufferPointer { Data(buffer: $0) }
        let element = SCNGeometryElement(data: indexData, primitiveType: .triangles,
                                         primitiveCount: mesh.triangleCount,
                                         bytesPerIndex: MemoryLayout<UInt32>.size)
        let geometry = SCNGeometry(sources: [source(mesh.positions, .vertex),
                                             source(normals, .normal),
                                             source(colors, .color)],
                                   elements: [element])
        let material = SCNMaterial()
        material.diffuse.contents = UIColor.white
        material.lightingModel = .lambert
        material.isDoubleSided = true
        geometry.materials = [material]

        let node = SCNNode(geometry: geometry)
        let box = MeshTools.boundingBox(mesh)
        let center = (box.min + box.max) / 2
        node.position = SCNVector3(-center.x, -center.y, -center.z)
        scene.rootNode.addChildNode(node)

        let cameraNode = SCNNode()
        let camera = SCNCamera()
        camera.zNear = 0.01
        camera.zFar = 10
        camera.fieldOfView = 40
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, 0, 0.45)
        scene.rootNode.addChildNode(cameraNode)
        return (scene, cameraNode)
    }
}
