import Foundation
import ARKit
import AVFoundation
import simd

/// Informations affichées en direct pendant le scan.
struct LiveStatus {
    var faceDetected = false
    var distanceCM: Double = 0
    var yawDeg: Double = 0
    var pitchDeg: Double = 0
    var framesIntegrated = 0
    var framesRejected = 0
    var alignmentMM: Double?
    var message: String?
    var instruction = ScanPhase.center.instruction
    var symbol = ScanPhase.center.symbol
    var phase: ScanPhase = .center
    var coverage = [Int](repeating: 0, count: ScanController.coverageBins)
}

/// Pilote la session ARKit (caméra TrueDepth), filtre les images et les fusionne dans le volume TSDF.
///
/// Protocole : iPhone FIXE (trépied ou support) à 25–40 cm, écran tourné vers le patient.
/// Le patient suit les consignes à l'écran et à la voix : centre → un côté → l'autre côté → menton levé.
/// Chaque carte de profondeur est replacée dans le repère du visage grâce au suivi ARKit.
final class ScanController: NSObject, ObservableObject, ARSessionDelegate {

    enum State {
        case starting
        case scanning
        case processing(String)
        case finished(ScanRecord, ColoredMesh)
        case failed(String)
    }

    static let coverageBins = 7
    static let yawRange: Float = 35          // couverture affichée : ±35°
    static let sideTarget: Float = 30        // rotation à atteindre de chaque côté
    static let minFrames = 20

    @Published private(set) var state: State = .starting
    @Published private(set) var live = LiveStatus()

    let settings: ScanSettings
    let scansRoot: URL

    private let queue = DispatchQueue(label: "fr.altiore.facescan.fusion", qos: .userInitiated)
    private weak var session: ARSession?
    private let speech = AVSpeechSynthesizer()

    // Boîte de reconstruction dans le repère visage ARKit (mètres).
    // Origine ARKit ≈ centre de la tête ; z > 0 vers l'avant du visage.
    private let boxMin = SIMD3<Float>(-0.11, -0.16, -0.08)
    private let boxMax = SIMD3<Float>( 0.11,  0.10,  0.12)

    // --- État propre à la file de fusion (n'y accéder que sur `queue`) ---
    private var volume: TSDFVolume?
    private var status = LiveStatus()
    private var phaseFrames = 0
    private var firstSideSign: Float = 0
    private var residuals: [Float] = []
    private var referenceExpression: [ARFaceAnchor.BlendShapeLocation: Float]?
    private var lastRotation: simd_quatf?
    private var lastDepthTimestamp: TimeInterval = 0
    private var lastUIUpdate: TimeInterval = 0
    private var stopping = false

    private static let expressionKeys: [ARFaceAnchor.BlendShapeLocation] = [
        .jawOpen, .mouthClose, .mouthSmileLeft, .mouthSmileRight, .mouthFunnel, .mouthPucker,
        .mouthStretchLeft, .mouthStretchRight, .mouthUpperUpLeft, .mouthUpperUpRight,
        .mouthLowerDownLeft, .mouthLowerDownRight, .mouthPressLeft, .mouthPressRight,
        .mouthRollLower, .mouthRollUpper, .cheekPuff, .browInnerUp
    ]

    init(settings: ScanSettings, scansRoot: URL) {
        self.settings = settings
        self.scansRoot = scansRoot
        super.init()
    }

    // MARK: - Commandes (appelées depuis l'interface)

    func start(session: ARSession) {
        guard ARFaceTrackingConfiguration.isSupported else {
            publish(state: .failed(ScanError.unsupportedDevice.localizedDescription))
            return
        }
        self.session = session
        session.delegate = self
        session.delegateQueue = queue

        queue.async { [weak self] in
            guard let self else { return }
            do {
                self.volume = try TSDFVolume(voxelSize: self.settings.resolution.voxelSize,
                                             boxMin: self.boxMin, boxMax: self.boxMax)
            } catch {
                self.publish(state: .failed(error.localizedDescription))
                return
            }
            DispatchQueue.main.async {
                let config = ARFaceTrackingConfiguration()
                config.maximumNumberOfTrackedFaces = 1
                config.isLightEstimationEnabled = false
                if let best = ARFaceTrackingConfiguration.supportedVideoFormats.max(by: {
                    $0.imageResolution.width * $0.imageResolution.height <
                    $1.imageResolution.width * $1.imageResolution.height
                }) {
                    config.videoFormat = best
                }
                if self.settings.voiceGuidance {
                    // Catégorie par défaut (soloAmbient) : la voix serait coupée par le bouton silence.
                    try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .voicePrompt, options: [.duckOthers])
                    try? AVAudioSession.sharedInstance().setActive(true)
                }
                session.run(config, options: [.resetTracking, .removeExistingAnchors])
                self.state = .scanning
                self.speak(ScanPhase.center.instruction)
            }
        }
    }

    /// Passe manuellement à l'étape suivante du protocole.
    func skipPhase() {
        queue.async { [weak self] in
            guard let self, !self.stopping else { return }
            let next = ScanPhase(rawValue: self.status.phase.rawValue + 1) ?? .done
            if next == .secondSide && self.firstSideSign == 0 { self.firstSideSign = 1 }
            self.enter(next)
            self.pushStatus(force: true)
        }
    }

    /// Termine la capture et lance la reconstruction.
    func finish() {
        queue.async { [weak self] in self?.finishOnQueue() }
    }

    func cancel() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopping = true
            self.volume = nil
        }
        session?.pause()
        speech.stopSpeaking(at: .immediate)
    }

    // MARK: - ARSessionDelegate (exécuté sur `queue`)

    func session(_ session: ARSession, didFailWithError error: Error) {
        publish(state: .failed("Erreur ARKit : \(error.localizedDescription)"))
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard !stopping, let volume else { return }

        guard let face = frame.anchors.lazy.compactMap({ $0 as? ARFaceAnchor }).first, face.isTracked else {
            status.faceDetected = false
            status.message = "Visage non détecté"
            pushStatus(timestamp: frame.timestamp)
            return
        }

        // Position de la caméra vue depuis le visage → distance, rotation gauche/droite (yaw), haut/bas (pitch).
        // Repère visage ARKit : +x = gauche du patient, +y = haut, +z = vers l'avant.
        let faceT = face.transform
        let camT = frame.camera.transform
        let camInFace = simd_mul(simd_inverse(faceT), camT.columns.3)
        let c = SIMD3<Float>(camInFace.x, camInFace.y, camInFace.z)
        let distance = simd_length(c)
        let yaw = atan2(c.x, c.z) * 180 / .pi                    // > 0 : tête tournée vers la droite du patient
        let pitch = atan2(c.y, (c.x * c.x + c.z * c.z).squareRoot()) * 180 / .pi   // < 0 : menton levé

        status.faceDetected = true
        status.distanceCM = Double(distance * 100)
        status.yawDeg = Double(yaw)
        status.pitchDeg = Double(pitch)

        // On ne fusionne que les images accompagnées d'une carte de profondeur synchronisée (~15 par seconde).
        guard let depthData = frame.capturedDepthData,
              abs(frame.capturedDepthDataTimestamp - frame.timestamp) < 0.034 else {
            pushStatus(timestamp: frame.timestamp)
            return
        }

        // Repère visage → caméra sténopé (ARKit : y haut, z arrière ; sténopé : y bas, z avant).
        let flip = simd_float4x4(diagonal: SIMD4<Float>(1, -1, -1, 1))
        let cameraFromFace = flip * simd_inverse(camT) * faceT

        var reason: String?

        // 1. Distance de travail
        if distance < 0.22 {
            reason = "Trop près — reculez un peu"
        } else if distance > 0.45 {
            reason = "Trop loin — rapprochez-vous"
        }

        // 2. Vitesse de rotation (flou de mouvement, désynchronisation couleur/profondeur)
        let rotation = simd_quatf(Self.rotationPart(cameraFromFace))
        if reason == nil, let last = lastRotation, frame.timestamp > lastDepthTimestamp {
            var angle = (rotation * last.inverse).angle
            if angle > .pi { angle = 2 * .pi - angle }
            let speed = angle / Float(frame.timestamp - lastDepthTimestamp) * 180 / .pi
            if speed > 60 { reason = "Plus lentement" }
        }
        lastRotation = rotation
        lastDepthTimestamp = frame.timestamp

        // 3. Verrou d'expression (le visage doit rester identique pendant tout le scan)
        if reason == nil, settings.expressionLock, let ref = referenceExpression {
            let current = expression(of: face)
            let delta = Self.expressionKeys.map { abs((current[$0] ?? 0) - (ref[$0] ?? 0)) }.max() ?? 0
            if delta > 0.18 { reason = "Gardez la même expression" }
        }

        // Profondeur en mètres (Float32) et paramètres optiques
        let depth32 = depthData.depthDataType == kCVPixelFormatType_DepthFloat32
            ? depthData
            : depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
        let depthMap = depth32.depthDataMap
        let depthK = Self.depthIntrinsics(depth32,
                                          width: CVPixelBufferGetWidth(depthMap),
                                          height: CVPixelBufferGetHeight(depthMap),
                                          frame: frame)
        let K = frame.camera.intrinsics
        let colorK = SIMD4<Float>(K.columns.0.x, K.columns.1.y, K.columns.2.x, K.columns.2.y)

        // 4. Contrôle de cohérence pose / profondeur : le maillage générique ARKit, placé par
        //    le suivi, doit tomber sur la carte de profondeur. Un écart important signale une
        //    pose erronée (ou une inversion d'axes) : l'image est rejetée.
        var residual: Float?
        if reason == nil {
            residual = Self.alignmentResidual(depthMap: depthMap, intrinsics: depthK,
                                              cameraFromFace: cameraFromFace,
                                              vertices: face.geometry.vertices)
            if let r = residual {
                if r > 0.012 { reason = "Alignement incertain — restez immobile un instant" }
            } else {
                reason = "Visage mal vu par le capteur"
            }
        }

        if let reason {
            status.framesRejected += 1
            status.message = reason
            pushStatus(timestamp: frame.timestamp, force: true)
            return
        }

        if settings.expressionLock && referenceExpression == nil {
            referenceExpression = expression(of: face)
        }

        let ok = volume.integrate(depthMap: depthMap, colorImage: frame.capturedImage,
                                  frame: FusionFrame(cameraFromFace: cameraFromFace,
                                                     depthIntrinsics: depthK,
                                                     colorIntrinsics: colorK))
        guard ok else {
            status.framesRejected += 1
            status.message = "Erreur GPU sur cette image"
            pushStatus(timestamp: frame.timestamp, force: true)
            return
        }

        status.framesIntegrated += 1
        status.message = nil
        if let residual {
            residuals.append(residual)
            let recent = residuals.suffix(30).sorted()
            status.alignmentMM = Double(recent[recent.count / 2] * 1000)
        }
        if abs(yaw) <= Self.yawRange {
            let t = (yaw + Self.yawRange) / (2 * Self.yawRange)
            let bin = min(Self.coverageBins - 1, max(0, Int(t * Float(Self.coverageBins))))
            status.coverage[bin] += 1
        }

        advancePhase(yaw: yaw, pitch: pitch)
        pushStatus(timestamp: frame.timestamp, force: true)
    }

    // MARK: - Protocole de capture

    private func advancePhase(yaw: Float, pitch: Float) {
        phaseFrames += 1
        var next: ScanPhase?
        switch status.phase {
        case .center:
            if phaseFrames >= 12 { next = .firstSide }
        case .firstSide:
            // Le côté effectivement atteint détermine la consigne suivante.
            if abs(yaw) >= Self.sideTarget {
                firstSideSign = yaw > 0 ? 1 : -1
                next = .secondSide
            }
        case .secondSide:
            if yaw * firstSideSign <= -Self.sideTarget { next = .chinUp }
        case .chinUp:
            if pitch <= -10 && abs(yaw) < 15 && phaseFrames >= 5 { next = .done }
        case .done:
            break
        }
        if let next { enter(next) }
    }

    private func enter(_ phase: ScanPhase) {
        status.phase = phase
        phaseFrames = 0
        var instruction = phase.instruction
        var symbol = phase.symbol
        if phase == .secondSide {
            // yaw > 0 = tête tournée vers la droite du patient ; il faut maintenant l'autre côté.
            instruction = firstSideSign > 0 ? "Tournez lentement la tête vers votre gauche"
                                            : "Tournez lentement la tête vers votre droite"
            symbol = firstSideSign > 0 ? "arrow.left" : "arrow.right"
        }
        status.instruction = instruction
        status.symbol = symbol
        speak(instruction)
        // Asynchrone : laisse `session(_:didUpdate:)` se terminer et relâcher sa référence locale
        // au volume, pour que les tampons GPU soient libérés pendant la reconstruction.
        if phase == .done { queue.async { [weak self] in self?.finishOnQueue() } }
    }

    // MARK: - Reconstruction et export (sur `queue`)

    private func finishOnQueue() {
        guard !stopping else { return }
        stopping = true
        DispatchQueue.main.async { [weak self] in self?.session?.pause() }
        publish(state: .processing("Extraction de la surface…"))
        do {
            let (record, mesh) = try reconstructAndSave()
            publish(state: .finished(record, mesh))
            speak("Scan enregistré")
        } catch {
            publish(state: .failed(error.localizedDescription))
        }
    }

    private func reconstructAndSave() throws -> (ScanRecord, ColoredMesh) {
        let frames = status.framesIntegrated
        guard frames >= Self.minFrames else { throw ScanError.notEnoughFrames(frames) }
        guard let snapshot = volume?.snapshot() else { throw ScanError.emptyMesh }
        volume = nil                                   // libère la mémoire GPU

        var mesh = SurfaceNets.extract(snapshot, minWeight: 2)

        publish(state: .processing("Nettoyage du maillage…"))
        mesh = MeshTools.keepLargestComponent(mesh)
        guard mesh.triangleCount >= 1000 else { throw ScanError.emptyMesh }
        if settings.smoothing { MeshTools.taubinSmooth(&mesh, iterations: 2) }
        MeshTools.computeNormals(&mesh)

        publish(state: .processing("Écriture des fichiers STL, PLY et OBJ…"))
        let date = Date()
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd_HHmmss"
        let base = "\(Self.sanitize(settings.patientID))_\(settings.scanType.slug)"
        let folderName = "\(df.string(from: date))_\(base)"
        let folder = scansRoot.appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let stl = "\(base).stl"
        let ply = "\(base)_couleur.ply"
        let obj = "\(base)_couleur.obj"
        try MeshExporters.writeSTL(mesh, to: folder.appendingPathComponent(stl))
        try MeshExporters.writePLY(mesh, to: folder.appendingPathComponent(ply))
        try MeshExporters.writeOBJ(mesh, to: folder.appendingPathComponent(obj))

        let box = MeshTools.boundingBox(mesh)
        let size = (box.max - box.min) * 1000
        let sorted = residuals.sorted()
        let medianMM = sorted.isEmpty ? nil : Double(sorted[sorted.count / 2] * 1000)

        let record = ScanRecord(folderName: folderName,
                                patientID: settings.patientID,
                                scanType: settings.scanType.rawValue,
                                date: date,
                                vertexCount: mesh.vertexCount,
                                triangleCount: mesh.triangleCount,
                                framesIntegrated: frames,
                                medianAlignmentMM: medianMM,
                                voxelSizeMM: Double(settings.resolution.voxelSize * 1000),
                                sizeMM: [Double(size.x), Double(size.y), Double(size.z)],
                                files: [stl, ply, obj])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(record).write(to: folder.appendingPathComponent("scan.json"))
        return (record, mesh)
    }

    // MARK: - Calculs

    private func expression(of face: ARFaceAnchor) -> [ARFaceAnchor.BlendShapeLocation: Float] {
        var out = [ARFaceAnchor.BlendShapeLocation: Float]()
        for key in Self.expressionKeys {
            out[key] = face.blendShapes[key]?.floatValue ?? 0
        }
        return out
    }

    static func rotationPart(_ m: simd_float4x4) -> simd_float3x3 {
        simd_float3x3(columns: (SIMD3<Float>(m.columns.0.x, m.columns.0.y, m.columns.0.z),
                                SIMD3<Float>(m.columns.1.x, m.columns.1.y, m.columns.1.z),
                                SIMD3<Float>(m.columns.2.x, m.columns.2.y, m.columns.2.z)))
    }

    /// Intrinsèques de la carte de profondeur, en pixels de cette carte.
    static func depthIntrinsics(_ depth: AVDepthData, width: Int, height: Int, frame: ARFrame) -> SIMD4<Float> {
        if let calib = depth.cameraCalibrationData {
            let K = calib.intrinsicMatrix
            let ref = calib.intrinsicMatrixReferenceDimensions
            // Champ horizontal commun ; si la référence est en 16:9 et la carte en 4:3, la carte
            // déborde verticalement (cropY < 0). cropY = 0 quand les rapports sont identiques.
            let refW = Float(ref.width), refH = Float(ref.height)
            let s = Float(width) / refW
            let cropY = (refH - Float(height) / s) / 2
            return SIMD4<Float>(K.columns.0.x * s, K.columns.1.y * s,
                                K.columns.2.x * s, (K.columns.2.y - cropY) * s)
        }
        // Repli : intrinsèques couleur mises à l'échelle (hypothèse d'un recadrage centré).
        let K = frame.camera.intrinsics
        let res = frame.camera.imageResolution
        let s = Float(width) / Float(res.width)
        let cropY = (Float(res.height) - Float(height) / s) / 2
        return SIMD4<Float>(K.columns.0.x * s, K.columns.1.y * s, K.columns.2.x * s, (K.columns.2.y - cropY) * s)
    }

    /// Écart médian (mètres) entre le maillage de suivi ARKit et la carte de profondeur.
    static func alignmentResidual(depthMap: CVPixelBuffer, intrinsics k: SIMD4<Float>,
                                  cameraFromFace: simd_float4x4, vertices: [SIMD3<Float>]) -> Float? {
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(depthMap) else { return nil }
        let w = CVPixelBufferGetWidth(depthMap)
        let h = CVPixelBufferGetHeight(depthMap)
        let rowBytes = CVPixelBufferGetBytesPerRow(depthMap)

        var diffs: [Float] = []
        diffs.reserveCapacity(vertices.count / 3)
        for i in stride(from: 0, to: vertices.count, by: 3) {
            let v = vertices[i]
            let pc = cameraFromFace * SIMD4<Float>(v.x, v.y, v.z, 1)
            guard pc.z > 0.1 else { continue }
            let x = Int((k.x * pc.x / pc.z + k.z).rounded())
            let y = Int((k.y * pc.y / pc.z + k.w).rounded())
            guard x >= 0, y >= 0, x < w, y < h else { continue }
            let d = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float32.self)[x]
            guard d.isFinite, d > 0.1, d < 1.0 else { continue }
            diffs.append(abs(d - pc.z))
        }
        guard diffs.count >= 30 else { return nil }
        diffs.sort()
        return diffs[diffs.count / 2]
    }

    static func sanitize(_ id: String) -> String {
        let cleaned = String(id.map { c -> Character in
            (c.isASCII && (c.isLetter || c.isNumber)) || c == "-" || c == "_" ? c : "-"
        }).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return cleaned.isEmpty ? "patient" : String(cleaned.prefix(40))
    }

    // MARK: - Publication vers l'interface

    private func pushStatus(timestamp: TimeInterval = 0, force: Bool = false) {
        if !force && timestamp - lastUIUpdate < 1.0 / 15 { return }
        lastUIUpdate = timestamp
        let snapshot = status
        DispatchQueue.main.async { [weak self] in self?.live = snapshot }
    }

    private func publish(state: State) {
        DispatchQueue.main.async { [weak self] in self?.state = state }
    }

    private func speak(_ text: String) {
        guard settings.voiceGuidance else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.speech.stopSpeaking(at: .immediate)
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = AVSpeechSynthesisVoice(language: "fr-FR")
            self.speech.speak(utterance)
        }
    }
}
