import Foundation

enum ScanType: String, CaseIterable, Identifiable, Codable {
    case repos = "Repos"
    case sourire = "Sourire"
    case ecarteurs = "Écarteurs"
    case autre = "Autre"

    var id: String { rawValue }

    /// Version sans accent pour les noms de fichiers.
    var slug: String {
        switch self {
        case .repos: return "repos"
        case .sourire: return "sourire"
        case .ecarteurs: return "ecarteurs"
        case .autre: return "autre"
        }
    }
}

enum ScanResolution: String, CaseIterable, Identifiable, Codable {
    case standard = "Standard (1 mm)"
    case fine = "Fine (0,75 mm)"

    var id: String { rawValue }

    var voxelSize: Float {
        switch self {
        case .standard: return 0.001
        case .fine: return 0.00075
        }
    }
}

struct ScanSettings: Identifiable {
    let id = UUID()
    var patientID: String
    var scanType: ScanType
    var resolution: ScanResolution
    var smoothing: Bool
    var expressionLock: Bool
    var voiceGuidance: Bool
}

/// Étapes du protocole de capture (téléphone fixe, le patient tourne la tête).
enum ScanPhase: Int {
    case center, firstSide, secondSide, chinUp, done

    var instruction: String {
        switch self {
        case .center: return "Regardez l'écran sans bouger"
        case .firstSide: return "Tournez lentement la tête vers votre droite"
        case .secondSide: return "Tournez lentement la tête vers votre gauche"
        case .chinUp: return "Revenez au centre et levez légèrement le menton"
        case .done: return "Scan terminé"
        }
    }

    var symbol: String {
        switch self {
        case .center: return "face.smiling"
        case .firstSide: return "arrow.right"
        case .secondSide: return "arrow.left"
        case .chinUp: return "arrow.up"
        case .done: return "checkmark.circle.fill"
        }
    }
}

/// Fiche d'un scan enregistré (scan.json dans le dossier du scan).
struct ScanRecord: Identifiable, Codable, Hashable {
    var id: String { folderName }
    let folderName: String
    let patientID: String
    let scanType: String
    let date: Date
    let vertexCount: Int
    let triangleCount: Int
    let framesIntegrated: Int
    let medianAlignmentMM: Double?
    let voxelSizeMM: Double
    let sizeMM: [Double]          // largeur, hauteur, profondeur
    let files: [String]
}

enum ScanError: LocalizedError {
    case unsupportedDevice
    case notEnoughFrames(Int)
    case emptyMesh
    case cancelled

    var errorDescription: String? {
        switch self {
        case .unsupportedDevice:
            return "Cet appareil n'a pas de caméra TrueDepth (Face ID)."
        case .notEnoughFrames(let n):
            return "Pas assez d'images exploitables (\(n)). Recommencez en tournant la tête plus lentement, à 25–40 cm."
        case .emptyMesh:
            return "La reconstruction n'a produit aucune surface exploitable."
        case .cancelled:
            return "Scan annulé."
        }
    }
}
