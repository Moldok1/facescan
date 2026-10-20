// Extraction de surface « Surface Nets » à partir du volume TSDF.
// Code Swift pur (sans framework Apple) : testable indépendamment.

/// Maillage coloré, positions en mètres dans le repère visage
/// (x = gauche du patient, y = haut, z = vers l'avant / antérieur).
struct ColoredMesh {
    var positions: [SIMD3<Float>] = []
    var colors: [SIMD3<UInt8>] = []
    var normals: [SIMD3<Float>] = []
    /// Indices de sommets, 3 par triangle, sens trigonométrique vu de l'extérieur.
    var indices: [UInt32] = []

    var vertexCount: Int { positions.count }
    var triangleCount: Int { indices.count / 3 }
}

enum SurfaceNets {

    /// - Parameters:
    ///   - minWeight: poids minimal pour qu'un voxel soit considéré comme observé.
    static func extract(nx: Int, ny: Int, nz: Int,
                        voxelSize: Float, origin: SIMD3<Float>,
                        tsdf: [Float], weight: [Float], color: [SIMD4<UInt8>],
                        minWeight: Float = 2) -> ColoredMesh {
        precondition(tsdf.count == nx * ny * nz && weight.count == tsdf.count && color.count == tsdf.count)
        let sy = nx
        let sz = nx * ny

        // 1. Boîte englobante des voxels observés.
        var lo = SIMD3<Int>(nx, ny, nz)
        var hi = SIMD3<Int>(-1, -1, -1)
        weight.withUnsafeBufferPointer { w in
            for k in 0..<nz {
                for j in 0..<ny {
                    let base = j * sy + k * sz
                    for i in 0..<nx where w[base + i] >= minWeight {
                        lo = SIMD3(min(lo.x, i), min(lo.y, j), min(lo.z, k))
                        hi = SIMD3(max(hi.x, i), max(hi.y, j), max(hi.z, k))
                    }
                }
            }
        }
        guard hi.x > lo.x, hi.y > lo.y, hi.z > lo.z else { return ColoredMesh() }

        // Cellules : la cellule (i,j,k) relie les voxels i..i+1, j..j+1, k..k+1.
        let cn = hi &- lo                      // nombre de cellules par axe
        let cellSY = cn.x
        let cellSZ = cn.x * cn.y
        var cellVertex = [Int32](repeating: -1, count: cn.x * cn.y * cn.z)

        var mesh = ColoredMesh()
        mesh.positions.reserveCapacity(300_000)
        mesh.colors.reserveCapacity(300_000)

        // Coins : bit0 = x, bit1 = y, bit2 = z.
        let cornerOffset: [Int] = (0..<8).map { c in (c & 1) + ((c >> 1) & 1) * sy + ((c >> 2) & 1) * sz }
        let cornerPos: [SIMD3<Float>] = (0..<8).map { c in
            SIMD3<Float>(Float(c & 1), Float((c >> 1) & 1), Float((c >> 2) & 1))
        }
        let edges: [(Int, Int)] = [(0, 1), (2, 3), (4, 5), (6, 7),
                                   (0, 2), (1, 3), (4, 6), (5, 7),
                                   (0, 4), (1, 5), (2, 6), (3, 7)]

        // 2. Un sommet par cellule traversée par la surface.
        tsdf.withUnsafeBufferPointer { t in
        weight.withUnsafeBufferPointer { w in
        color.withUnsafeBufferPointer { col in
            var f = [Float](repeating: 0, count: 8)
            for ck in 0..<cn.z {
                for cj in 0..<cn.y {
                    for ci in 0..<cn.x {
                        let gi = lo.x + ci, gj = lo.y + cj, gk = lo.z + ck
                        let base = gi + gj * sy + gk * sz
                        var mask = 0
                        var complete = true
                        for c in 0..<8 {
                            let idx = base + cornerOffset[c]
                            if w[idx] < minWeight { complete = false; break }
                            f[c] = t[idx]
                            if f[c] < 0 { mask |= (1 << c) }
                        }
                        if !complete || mask == 0 || mask == 255 { continue }

                        var sum = SIMD3<Float>(0, 0, 0)
                        var n: Float = 0
                        for (a, b) in edges {
                            let fa = f[a], fb = f[b]
                            if (fa < 0) != (fb < 0) {
                                let s = fa / (fa - fb)
                                sum += cornerPos[a] + (cornerPos[b] - cornerPos[a]) * s
                                n += 1
                            }
                        }
                        let local = sum / n
                        let grid = SIMD3<Float>(Float(gi), Float(gj), Float(gk)) + local
                        let position = origin + (grid + SIMD3<Float>(repeating: 0.5)) * voxelSize

                        var rgb = SIMD3<Float>(0, 0, 0)
                        var cw: Float = 0
                        for c in 0..<8 {
                            let px = col[base + cornerOffset[c]]
                            if px.w > 0 {
                                rgb += SIMD3<Float>(Float(px.x), Float(px.y), Float(px.z))
                                cw += 1
                            }
                        }
                        let rgb8: SIMD3<UInt8>
                        if cw > 0 {
                            let m = rgb / cw
                            rgb8 = SIMD3<UInt8>(UInt8(m.x.rounded()), UInt8(m.y.rounded()), UInt8(m.z.rounded()))
                        } else {
                            rgb8 = SIMD3<UInt8>(180, 180, 180)
                        }

                        cellVertex[ci + cj * cellSY + ck * cellSZ] = Int32(mesh.positions.count)
                        mesh.positions.append(position)
                        mesh.colors.append(rgb8)
                    }
                }
            }
        }}}

        // 3. Un quadrilatère par arête de grille traversée par la surface.
        //    Arête suivant l'axe a entre le voxel p et p + e_a ; les 4 cellules qui la
        //    partagent sont p, p - e_u, p - e_v, p - e_u - e_v avec (a, u, v) cyclique.
        mesh.indices.reserveCapacity(mesh.positions.count * 6)
        func cellIndex(_ c: SIMD3<Int>) -> Int32 {
            let l = c &- lo
            if l.x < 0 || l.y < 0 || l.z < 0 || l.x >= cn.x || l.y >= cn.y || l.z >= cn.z { return -1 }
            return cellVertex[l.x + l.y * cellSY + l.z * cellSZ]
        }
        let axisStep = [1, sy, sz]
        tsdf.withUnsafeBufferPointer { t in
        weight.withUnsafeBufferPointer { w in
            for axis in 0..<3 {
                let u = (axis + 1) % 3
                let v = (axis + 2) % 3
                var eu = SIMD3<Int>(0, 0, 0); eu[u] = 1
                var ev = SIMD3<Int>(0, 0, 0); ev[v] = 1
                for k in lo.z...hi.z {
                    for j in lo.y...hi.y {
                        for i in lo.x...hi.x {
                            let p = SIMD3<Int>(i, j, k)
                            if p[axis] + 1 > hi[axis] { continue }
                            let idx0 = i + j * sy + k * sz
                            let idx1 = idx0 + axisStep[axis]
                            if w[idx0] < minWeight || w[idx1] < minWeight { continue }
                            let inside0 = t[idx0] < 0
                            let inside1 = t[idx1] < 0
                            if inside0 == inside1 { continue }
                            let c00 = cellIndex(p &- eu &- ev)
                            let c10 = cellIndex(p &- ev)
                            let c11 = cellIndex(p)
                            let c01 = cellIndex(p &- eu)
                            if c00 < 0 || c10 < 0 || c11 < 0 || c01 < 0 { continue }
                            let a = UInt32(c00), b = UInt32(c10), c = UInt32(c11), d = UInt32(c01)
                            if inside0 {
                                // normale sortante = +axe : a -> b -> c -> d tourne dans le sens direct autour de +axe
                                mesh.indices.append(a); mesh.indices.append(b); mesh.indices.append(c)
                                mesh.indices.append(a); mesh.indices.append(c); mesh.indices.append(d)
                            } else {
                                mesh.indices.append(a); mesh.indices.append(c); mesh.indices.append(b)
                                mesh.indices.append(a); mesh.indices.append(d); mesh.indices.append(c)
                            }
                        }
                    }
                }
            }
        }}
        return mesh
    }

    static func extract(_ v: VolumeSnapshot, minWeight: Float = 2) -> ColoredMesh {
        extract(nx: v.nx, ny: v.ny, nz: v.nz, voxelSize: v.voxelSize, origin: v.origin,
                tsdf: v.tsdf, weight: v.weight, color: v.color, minWeight: minWeight)
    }
}
