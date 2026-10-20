import Foundation
import Metal
import CoreVideo
import Accelerate
import simd

/// Paramètres transmis au shader. L'ordre et les types doivent correspondre exactement
/// à `FusionUniforms` dans FusionShaders.swift (176 octets, alignement 16).
struct FusionUniforms {
    var cameraFromFace: simd_float4x4
    var depthIntrinsics: SIMD4<Float>
    var colorIntrinsics: SIMD4<Float>
    var originVoxel: SIMD4<Float>
    var dims: SIMD4<UInt32>
    var imageDims: SIMD4<UInt32>
    var params: SIMD4<Float>
    var params2: SIMD4<Float>
}

/// Données d'une image à fusionner.
struct FusionFrame {
    /// Transforme un point du repère visage (mètres) vers le repère caméra sténopé
    /// (x vers la droite de l'image, y vers le bas, z vers l'avant).
    var cameraFromFace: simd_float4x4
    /// fx, fy, cx, cy de la carte de profondeur, en pixels de cette carte.
    var depthIntrinsics: SIMD4<Float>
    /// fx, fy, cx, cy de l'image couleur, en pixels de cette image.
    var colorIntrinsics: SIMD4<Float>
}

/// Copie CPU du volume, utilisée pour l'extraction du maillage.
struct VolumeSnapshot {
    let nx: Int
    let ny: Int
    let nz: Int
    let voxelSize: Float
    let origin: SIMD3<Float>
    var tsdf: [Float]
    var weight: [Float]
    var color: [SIMD4<UInt8>]
}

enum FusionError: LocalizedError {
    case noMetal
    case shaderCompilation(String)
    case allocation

    var errorDescription: String? {
        switch self {
        case .noMetal: return "Metal n'est pas disponible sur cet appareil."
        case .shaderCompilation(let m): return "Échec de compilation des shaders : \(m)"
        case .allocation: return "Mémoire insuffisante pour le volume de reconstruction. Choisissez la résolution standard."
        }
    }
}

/// Volume TSDF sur GPU (Metal). Toutes les méthodes doivent être appelées depuis la même file.
final class TSDFVolume {
    let nx: Int
    let ny: Int
    let nz: Int
    let voxelSize: Float
    let origin: SIMD3<Float>
    let truncation: Float
    let maxWeight: Float = 64
    let minDepth: Float = 0.12
    let maxDepth: Float = 0.70
    let edgeThreshold: Float = 0.008   // 8 mm entre pixels voisins = bord / pixel volant

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let integratePipeline: MTLComputePipelineState
    private let resetPipeline: MTLComputePipelineState
    private let tsdfBuffer: MTLBuffer
    private let weightBuffer: MTLBuffer
    private let colorBuffer: MTLBuffer
    private var textureCache: CVMetalTextureCache?
    private var depthTexture: MTLTexture?

    var voxelCount: Int { nx * ny * nz }

    /// - Parameters:
    ///   - voxelSize: taille de voxel en mètres (0,001 = 1 mm)
    ///   - boxMin / boxMax: boîte englobante dans le repère visage, en mètres
    init(voxelSize: Float, boxMin: SIMD3<Float>, boxMax: SIMD3<Float>) throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            throw FusionError.noMetal
        }
        self.device = device
        self.queue = queue
        self.voxelSize = voxelSize
        self.origin = boxMin
        let size = boxMax - boxMin
        self.nx = Int((size.x / voxelSize).rounded(.up))
        self.ny = Int((size.y / voxelSize).rounded(.up))
        self.nz = Int((size.z / voxelSize).rounded(.up))
        self.truncation = max(3 * voxelSize, 0.003)

        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: FusionShaders.source, options: nil)
        } catch {
            throw FusionError.shaderCompilation(error.localizedDescription)
        }
        guard let integrateFn = library.makeFunction(name: "integrateDepth"),
              let resetFn = library.makeFunction(name: "resetVolume") else {
            throw FusionError.shaderCompilation("fonctions introuvables")
        }
        self.integratePipeline = try device.makeComputePipelineState(function: integrateFn)
        self.resetPipeline = try device.makeComputePipelineState(function: resetFn)

        let count = nx * ny * nz
        guard let t = device.makeBuffer(length: count * MemoryLayout<UInt16>.stride, options: .storageModeShared),
              let w = device.makeBuffer(length: count * MemoryLayout<UInt16>.stride, options: .storageModeShared),
              let c = device.makeBuffer(length: count * 4, options: .storageModeShared) else {
            throw FusionError.allocation
        }
        self.tsdfBuffer = t
        self.weightBuffer = w
        self.colorBuffer = c

        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
        reset()
    }

    /// Mémoire GPU occupée, en Mo.
    var memoryMB: Int { voxelCount * 8 / 1_048_576 }

    func reset() {
        guard let cb = queue.makeCommandBuffer(),
              let enc = cb.makeComputeCommandEncoder() else { return }
        enc.setComputePipelineState(resetPipeline)
        enc.setBuffer(tsdfBuffer, offset: 0, index: 0)
        enc.setBuffer(weightBuffer, offset: 0, index: 1)
        enc.setBuffer(colorBuffer, offset: 0, index: 2)
        var count = UInt32(voxelCount)
        enc.setBytes(&count, length: MemoryLayout<UInt32>.stride, index: 3)
        let width = min(256, resetPipeline.maxTotalThreadsPerThreadgroup)
        enc.dispatchThreads(MTLSize(width: voxelCount, height: 1, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1))
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
    }

    /// Fusionne une carte de profondeur (Float32, mètres) et l'image couleur ARKit (YCbCr bi-planaire).
    /// - Returns: false si les textures n'ont pas pu être créées.
    @discardableResult
    func integrate(depthMap: CVPixelBuffer, colorImage: CVPixelBuffer, frame: FusionFrame) -> Bool {
        guard let depthTex = uploadDepth(depthMap),
              let lumaRef = makeTexture(colorImage, plane: 0, format: .r8Unorm),
              let chromaRef = makeTexture(colorImage, plane: 1, format: .rg8Unorm),
              let luma = CVMetalTextureGetTexture(lumaRef),
              let chroma = CVMetalTextureGetTexture(chromaRef),
              let cb = queue.makeCommandBuffer(),
              let enc = cb.makeComputeCommandEncoder() else {
            return false
        }

        var u = FusionUniforms(
            cameraFromFace: frame.cameraFromFace,
            depthIntrinsics: frame.depthIntrinsics,
            colorIntrinsics: frame.colorIntrinsics,
            originVoxel: SIMD4<Float>(origin.x, origin.y, origin.z, voxelSize),
            dims: SIMD4<UInt32>(UInt32(nx), UInt32(ny), UInt32(nz), 0),
            imageDims: SIMD4<UInt32>(UInt32(depthTex.width), UInt32(depthTex.height),
                                     UInt32(luma.width), UInt32(luma.height)),
            params: SIMD4<Float>(truncation, maxWeight, minDepth, maxDepth),
            params2: SIMD4<Float>(edgeThreshold, max(1.5 * voxelSize, 0.0015), 0, 0)
        )

        enc.setComputePipelineState(integratePipeline)
        enc.setBuffer(tsdfBuffer, offset: 0, index: 0)
        enc.setBuffer(weightBuffer, offset: 0, index: 1)
        enc.setBuffer(colorBuffer, offset: 0, index: 2)
        enc.setBytes(&u, length: MemoryLayout<FusionUniforms>.stride, index: 3)
        enc.setTexture(depthTex, index: 0)
        enc.setTexture(luma, index: 1)
        enc.setTexture(chroma, index: 2)

        let maxThreads = integratePipeline.maxTotalThreadsPerThreadgroup
        let tg = MTLSize(width: 8, height: 8, depth: max(1, min(4, maxThreads / 64)))
        enc.dispatchThreads(MTLSize(width: nx, height: ny, depth: nz), threadsPerThreadgroup: tg)
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        // lumaRef / chromaRef restent vivants jusqu'ici, après la fin du calcul GPU.
        withExtendedLifetime((lumaRef, chromaRef)) {}
        return cb.status == .completed
    }

    /// Copie le volume en mémoire CPU (Float16 -> Float32).
    func snapshot() -> VolumeSnapshot {
        let count = voxelCount
        var tsdf = [Float](repeating: 1, count: count)
        var weight = [Float](repeating: 0, count: count)
        convertHalfToFloat(source: tsdfBuffer.contents(), into: &tsdf)
        convertHalfToFloat(source: weightBuffer.contents(), into: &weight)
        let cp = colorBuffer.contents().bindMemory(to: SIMD4<UInt8>.self, capacity: count)
        let color = Array(UnsafeBufferPointer(start: cp, count: count))
        return VolumeSnapshot(nx: nx, ny: ny, nz: nz, voxelSize: voxelSize, origin: origin,
                              tsdf: tsdf, weight: weight, color: color)
    }

    // MARK: - Privé

    private func convertHalfToFloat(source: UnsafeMutableRawPointer, into dest: inout [Float]) {
        let count = dest.count
        dest.withUnsafeMutableBytes { dst in
            var src = vImage_Buffer(data: source, height: 1, width: vImagePixelCount(count), rowBytes: count * 2)
            var out = vImage_Buffer(data: dst.baseAddress, height: 1, width: vImagePixelCount(count), rowBytes: count * 4)
            _ = vImageConvert_Planar16FtoPlanarF(&src, &out, vImage_Flags(kvImageNoFlags))
        }
    }

    /// Copie la profondeur dans une texture r32Float (copie CPU : robuste quel que soit le type de tampon).
    private func uploadDepth(_ pb: CVPixelBuffer) -> MTLTexture? {
        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        if depthTexture == nil || depthTexture?.width != w || depthTexture?.height != h {
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: w, height: h, mipmapped: false)
            desc.usage = [.shaderRead]
            desc.storageMode = .shared
            depthTexture = device.makeTexture(descriptor: desc)
        }
        guard let tex = depthTexture else { return nil }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(pb)
        tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: base, bytesPerRow: rowBytes)
        return tex
    }

    private func makeTexture(_ pb: CVPixelBuffer, plane: Int, format: MTLPixelFormat) -> CVMetalTexture? {
        guard let cache = textureCache else { return nil }
        let planar = CVPixelBufferIsPlanar(pb)
        let w = planar ? CVPixelBufferGetWidthOfPlane(pb, plane) : CVPixelBufferGetWidth(pb)
        let h = planar ? CVPixelBufferGetHeightOfPlane(pb, plane) : CVPixelBufferGetHeight(pb)
        var tex: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pb, nil, format, w, h, plane, &tex)
        return status == kCVReturnSuccess ? tex : nil
    }
}
