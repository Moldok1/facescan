// Post-traitement du maillage. Code Swift pur, sans framework Apple.

enum MeshTools {

    /// Ne garde que la plus grande composante connexe (élimine les fragments isolés :
    /// cheveux flottants, bruit, mains, etc.).
    static func keepLargestComponent(_ m: ColoredMesh) -> ColoredMesh {
        let n = m.vertexCount
        guard n > 0, m.triangleCount > 0 else { return m }
        var parent = [Int](0..<n)

        func find(_ x: Int) -> Int {
            var x = x
            while parent[x] != x {
                parent[x] = parent[parent[x]]
                x = parent[x]
            }
            return x
        }
        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[ra] = rb }
        }

        let idx = m.indices
        for t in stride(from: 0, to: idx.count, by: 3) {
            union(Int(idx[t]), Int(idx[t + 1]))
            union(Int(idx[t + 1]), Int(idx[t + 2]))
        }

        var triCount = [Int: Int]()
        for t in stride(from: 0, to: idx.count, by: 3) {
            triCount[find(Int(idx[t])), default: 0] += 1
        }
        guard let best = triCount.max(by: { $0.value < $1.value })?.key else { return m }

        var remap = [Int32](repeating: -1, count: n)
        var out = ColoredMesh()
        for t in stride(from: 0, to: idx.count, by: 3) where find(Int(idx[t])) == best {
            for k in 0..<3 {
                let v = Int(idx[t + k])
                if remap[v] < 0 {
                    remap[v] = Int32(out.positions.count)
                    out.positions.append(m.positions[v])
                    out.colors.append(m.colors[v])
                }
                out.indices.append(UInt32(remap[v]))
            }
        }
        return out
    }

    /// Lissage de Taubin (λ/μ) : réduit le bruit du capteur sans rétrécir la surface.
    static func taubinSmooth(_ m: inout ColoredMesh, iterations: Int = 2,
                             lambda: Float = 0.5, mu: Float = -0.53) {
        let n = m.vertexCount
        guard n > 0, iterations > 0 else { return }
        let adjacency = buildAdjacency(m)

        func step(_ factor: Float) {
            let old = m.positions
            for i in 0..<n {
                let nb = adjacency[i]
                if nb.isEmpty { continue }
                var mean = SIMD3<Float>(0, 0, 0)
                for j in nb { mean += old[Int(j)] }
                mean /= Float(nb.count)
                m.positions[i] = old[i] + factor * (mean - old[i])
            }
        }
        for _ in 0..<iterations {
            step(lambda)
            step(mu)
        }
    }

    /// Normales par sommet, pondérées par l'aire des triangles.
    static func computeNormals(_ m: inout ColoredMesh) {
        var normals = [SIMD3<Float>](repeating: SIMD3<Float>(0, 0, 0), count: m.vertexCount)
        let idx = m.indices
        for t in stride(from: 0, to: idx.count, by: 3) {
            let a = Int(idx[t]), b = Int(idx[t + 1]), c = Int(idx[t + 2])
            let fn = cross(m.positions[b] - m.positions[a], m.positions[c] - m.positions[a])
            normals[a] += fn
            normals[b] += fn
            normals[c] += fn
        }
        for i in 0..<normals.count {
            let l = length(normals[i])
            normals[i] = l > 0 ? normals[i] / l : SIMD3<Float>(0, 0, 1)
        }
        m.normals = normals
    }

    /// Dimensions de la boîte englobante, en mètres.
    static func boundingBox(_ m: ColoredMesh) -> (min: SIMD3<Float>, max: SIMD3<Float>) {
        guard var lo = m.positions.first else { return (.zero, .zero) }
        var hi = lo
        for p in m.positions {
            lo = SIMD3(Swift.min(lo.x, p.x), Swift.min(lo.y, p.y), Swift.min(lo.z, p.z))
            hi = SIMD3(Swift.max(hi.x, p.x), Swift.max(hi.y, p.y), Swift.max(hi.z, p.z))
        }
        return (lo, hi)
    }

    // MARK: - Utilitaires

    static func buildAdjacency(_ m: ColoredMesh) -> [[Int32]] {
        var adj = [[Int32]](repeating: [], count: m.vertexCount)
        let idx = m.indices
        func link(_ a: UInt32, _ b: UInt32) {
            if !adj[Int(a)].contains(Int32(b)) { adj[Int(a)].append(Int32(b)) }
            if !adj[Int(b)].contains(Int32(a)) { adj[Int(b)].append(Int32(a)) }
        }
        for t in stride(from: 0, to: idx.count, by: 3) {
            link(idx[t], idx[t + 1])
            link(idx[t + 1], idx[t + 2])
            link(idx[t + 2], idx[t])
        }
        return adj
    }

    static func cross(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3<Float>(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
    }

    static func length(_ a: SIMD3<Float>) -> Float {
        (a * a).sum().squareRoot()
    }
}
