import Foundation

/// Exports du maillage. Les coordonnées sont converties en MILLIMÈTRES (convention CFAO dentaire).
/// Repère : x = gauche du patient, y = haut, z = antérieur (vers l'observateur).
enum MeshExporters {

    static let metersToMM: Float = 1000

    // MARK: STL binaire (géométrie seule)

    static func writeSTL(_ m: ColoredMesh, to url: URL, header: String = "FaceScan ALTIORE - unites: mm") throws {
        let triCount = m.triangleCount
        var data = Data(capacity: 84 + triCount * 50)
        var head = Array(header.utf8.prefix(80))
        head += [UInt8](repeating: 0x20, count: 80 - head.count)
        data.append(contentsOf: head)
        data.appendLE(UInt32(triCount))

        let s = metersToMM
        let idx = m.indices
        for t in stride(from: 0, to: idx.count, by: 3) {
            let a = m.positions[Int(idx[t])] * s
            let b = m.positions[Int(idx[t + 1])] * s
            let c = m.positions[Int(idx[t + 2])] * s
            var n = MeshTools.cross(b - a, c - a)
            let l = MeshTools.length(n)
            n = l > 0 ? n / l : SIMD3<Float>(0, 0, 0)
            data.appendVector(n)
            data.appendVector(a)
            data.appendVector(b)
            data.appendVector(c)
            data.appendLE(UInt16(0))
        }
        try data.write(to: url, options: .atomic)
    }

    // MARK: PLY binaire (géométrie + couleur par sommet + normales)

    static func writePLY(_ m: ColoredMesh, to url: URL) throws {
        let hasNormals = m.normals.count == m.vertexCount
        var header = """
        ply
        format binary_little_endian 1.0
        comment FaceScan ALTIORE - unites: mm
        element vertex \(m.vertexCount)
        property float x
        property float y
        property float z

        """
        if hasNormals {
            header += "property float nx\nproperty float ny\nproperty float nz\n"
        }
        header += """
        property uchar red
        property uchar green
        property uchar blue
        element face \(m.triangleCount)
        property list uchar int vertex_indices
        end_header

        """
        let vertexBytes = 12 + (hasNormals ? 12 : 0) + 3
        var data = Data(capacity: header.utf8.count + m.vertexCount * vertexBytes + m.triangleCount * 13)
        data.append(contentsOf: Array(header.utf8))
        for i in 0..<m.vertexCount {
            data.appendVector(m.positions[i] * metersToMM)
            if hasNormals { data.appendVector(m.normals[i]) }
            let c = m.colors[i]
            data.append(contentsOf: [c.x, c.y, c.z])
        }
        let idx = m.indices
        for t in stride(from: 0, to: idx.count, by: 3) {
            data.append(3)
            data.appendLE(Int32(idx[t]))
            data.appendLE(Int32(idx[t + 1]))
            data.appendLE(Int32(idx[t + 2]))
        }
        try data.write(to: url, options: .atomic)
    }

    /// Relit un PLY écrit par `writePLY` (pour l'aperçu des scans enregistrés). Retourne des mètres.
    static func readPLY(_ url: URL) throws -> ColoredMesh {
        let data = try Data(contentsOf: url)
        guard let range = data.range(of: Data("end_header\n".utf8)) else { throw CocoaError(.fileReadCorruptFile) }
        let header = String(decoding: data[data.startIndex..<range.lowerBound], as: UTF8.self)
        var vertexCount = 0, faceCount = 0
        var hasNormals = false
        for line in header.split(separator: "\n") {
            let parts = line.split(separator: " ")
            if parts.count == 3, parts[0] == "element", parts[1] == "vertex" { vertexCount = Int(parts[2]) ?? 0 }
            if parts.count == 3, parts[0] == "element", parts[1] == "face" { faceCount = Int(parts[2]) ?? 0 }
            if parts.count == 3, parts[0] == "property", parts[2] == "nx" { hasNormals = true }
        }
        let vertexBytes = 12 + (hasNormals ? 12 : 0) + 3
        let start = range.upperBound - data.startIndex
        guard data.count >= start + vertexCount * vertexBytes + faceCount * 13 else {
            throw CocoaError(.fileReadCorruptFile)
        }

        var mesh = ColoredMesh()
        mesh.positions.reserveCapacity(vertexCount)
        mesh.colors.reserveCapacity(vertexCount)
        if hasNormals { mesh.normals.reserveCapacity(vertexCount) }
        mesh.indices.reserveCapacity(faceCount * 3)

        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var o = start
            func f32() -> Float {
                let v = Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: o, as: UInt32.self)))
                o += 4
                return v
            }
            func i32() -> Int32 {
                let v = Int32(littleEndian: raw.loadUnaligned(fromByteOffset: o, as: Int32.self))
                o += 4
                return v
            }
            let toM = 1 / metersToMM
            for _ in 0..<vertexCount {
                let p = SIMD3<Float>(f32(), f32(), f32()) * toM
                mesh.positions.append(p)
                if hasNormals { mesh.normals.append(SIMD3<Float>(f32(), f32(), f32())) }
                mesh.colors.append(SIMD3<UInt8>(raw[o], raw[o + 1], raw[o + 2]))
                o += 3
            }
            for _ in 0..<faceCount {
                o += 1 // toujours 3 sommets
                mesh.indices.append(UInt32(i32()))
                mesh.indices.append(UInt32(i32()))
                mesh.indices.append(UInt32(i32()))
            }
        }
        return mesh
    }

    // MARK: OBJ avec couleur par sommet (extension « v x y z r g b », lue par MeshLab, Blender, Meshmixer…)

    static func writeOBJ(_ m: ColoredMesh, to url: URL) throws {
        var text = "# FaceScan ALTIORE - unites: mm\n# couleur par sommet : v x y z r g b (0..1)\n"
        text.reserveCapacity(m.vertexCount * 60 + m.triangleCount * 30)
        for i in 0..<m.vertexCount {
            let p = m.positions[i] * metersToMM
            let c = m.colors[i]
            text += "v \(fmt(p.x, 3)) \(fmt(p.y, 3)) \(fmt(p.z, 3)) "
            text += "\(fmt(Float(c.x) / 255, 4)) \(fmt(Float(c.y) / 255, 4)) \(fmt(Float(c.z) / 255, 4))\n"
        }
        let idx = m.indices
        for t in stride(from: 0, to: idx.count, by: 3) {
            text += "f \(idx[t] + 1) \(idx[t + 1] + 1) \(idx[t + 2] + 1)\n"
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Formatage décimal rapide et indépendant de la langue (toujours un point décimal).
    static func fmt(_ v: Float, _ decimals: Int) -> String {
        var scale: Float = 1
        for _ in 0..<decimals { scale *= 10 }
        let scaled = Int64((v * scale).rounded())
        let negative = scaled < 0
        let mag = negative ? -scaled : scaled
        let intPart = mag / Int64(scale)
        var frac = String(mag % Int64(scale))
        while frac.count < decimals { frac = "0" + frac }
        return (negative ? "-" : "") + "\(intPart).\(frac)"
    }
}

extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }

    mutating func appendLE(_ value: Float) {
        appendLE(value.bitPattern)
    }

    mutating func appendVector(_ v: SIMD3<Float>) {
        appendLE(v.x)
        appendLE(v.y)
        appendLE(v.z)
    }
}
