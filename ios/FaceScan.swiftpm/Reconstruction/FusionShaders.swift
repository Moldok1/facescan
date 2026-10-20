// Shaders Metal compilés à l'exécution (évite toute configuration de build Metal).
//
// Principe : fusion volumétrique TSDF (Truncated Signed Distance Function).
// Le volume est exprimé dans le repère du VISAGE (ARFaceAnchor) : quand le patient
// tourne la tête devant l'iPhone fixe, chaque carte de profondeur est replacée dans
// ce repère et moyennée avec les précédentes. La couleur est moyennée de la même façon.

enum FusionShaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct FusionUniforms {
        float4x4 cameraFromFace;   // repère visage -> caméra « sténopé » (x droite, y bas, z avant), mètres
        float4   depthIntrinsics;  // fx, fy, cx, cy de la carte de profondeur (pixels)
        float4   colorIntrinsics;  // fx, fy, cx, cy de l'image couleur (pixels)
        float4   originVoxel;      // origine du volume (xyz, mètres) + taille de voxel (w, mètres)
        uint4    dims;             // nx, ny, nz, 0
        uint4    imageDims;        // largeur/hauteur profondeur, largeur/hauteur couleur
        float4   params;           // troncature, poids max, profondeur min, profondeur max
        float4   params2;          // seuil de discontinuité, bande couleur, 0, 0
    };

    kernel void resetVolume(device half   *tsdf   [[buffer(0)]],
                            device half   *weight [[buffer(1)]],
                            device uchar4 *color  [[buffer(2)]],
                            constant uint &count  [[buffer(3)]],
                            uint gid [[thread_position_in_grid]])
    {
        if (gid >= count) { return; }
        tsdf[gid]   = half(1.0h);
        weight[gid] = half(0.0h);
        color[gid]  = uchar4(0, 0, 0, 0);
    }

    static inline bool validDepth(float d, float minD, float maxD) {
        return isfinite(d) && d > minD && d < maxD;
    }

    kernel void integrateDepth(device half   *tsdf   [[buffer(0)]],
                               device half   *weight [[buffer(1)]],
                               device uchar4 *color  [[buffer(2)]],
                               constant FusionUniforms &u [[buffer(3)]],
                               texture2d<float, access::read>   depthTex  [[texture(0)]],
                               texture2d<float, access::sample> lumaTex   [[texture(1)]],
                               texture2d<float, access::sample> chromaTex [[texture(2)]],
                               uint3 gid [[thread_position_in_grid]])
    {
        if (gid.x >= u.dims.x || gid.y >= u.dims.y || gid.z >= u.dims.z) { return; }

        const float voxel = u.originVoxel.w;
        const float3 p = u.originVoxel.xyz + (float3(gid) + 0.5f) * voxel;
        const float4 pc = u.cameraFromFace * float4(p, 1.0f);

        const float minD = u.params.z;
        const float maxD = u.params.w;
        if (pc.z < minD || pc.z > maxD) { return; }

        const float invZ = 1.0f / pc.z;
        const float px = u.depthIntrinsics.x * pc.x * invZ + u.depthIntrinsics.z;
        const float py = u.depthIntrinsics.y * pc.y * invZ + u.depthIntrinsics.w;
        const int ix = int(floor(px + 0.5f));
        const int iy = int(floor(py + 0.5f));
        const int w = int(u.imageDims.x);
        const int h = int(u.imageDims.y);
        if (ix < 1 || iy < 1 || ix >= w - 1 || iy >= h - 1) { return; }

        const float d = depthTex.read(uint2(ix, iy)).r;
        if (!validDepth(d, minD, maxD)) { return; }

        // Rejet des « pixels volants » sur les bords (discontinuités de profondeur).
        const float d1 = depthTex.read(uint2(ix - 1, iy)).r;
        const float d2 = depthTex.read(uint2(ix + 1, iy)).r;
        const float d3 = depthTex.read(uint2(ix, iy - 1)).r;
        const float d4 = depthTex.read(uint2(ix, iy + 1)).r;
        if (!validDepth(d1, minD, maxD) || !validDepth(d2, minD, maxD) ||
            !validDepth(d3, minD, maxD) || !validDepth(d4, minD, maxD)) { return; }
        const float edge = u.params2.x;
        if (fabs(d1 - d) > edge || fabs(d2 - d) > edge ||
            fabs(d3 - d) > edge || fabs(d4 - d) > edge) { return; }

        const float trunc = u.params.x;
        const float sdf = d - pc.z;            // > 0 : voxel devant la surface (vide)
        if (sdf < -trunc) { return; }          // voxel caché derrière la surface : inconnu

        const float tNew = min(1.0f, sdf / trunc);
        const uint idx = gid.x + u.dims.x * (gid.y + u.dims.y * gid.z);
        const float wOld = float(weight[idx]);
        const float tOld = float(tsdf[idx]);
        const float tOut = (tOld * wOld + tNew) / (wOld + 1.0f);
        tsdf[idx]   = half(tOut);
        weight[idx] = half(min(wOld + 1.0f, u.params.y));

        // Couleur : uniquement pour les voxels proches de la surface.
        if (fabs(sdf) <= u.params2.y) {
            const float cu = (u.colorIntrinsics.x * pc.x * invZ + u.colorIntrinsics.z) / float(u.imageDims.z);
            const float cv = (u.colorIntrinsics.y * pc.y * invZ + u.colorIntrinsics.w) / float(u.imageDims.w);
            if (cu < 0.0f || cv < 0.0f || cu > 1.0f || cv > 1.0f) { return; }
            constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
            const float y = lumaTex.sample(s, float2(cu, cv)).r;
            const float2 cbcr = chromaTex.sample(s, float2(cu, cv)).rg - float2(0.5f, 0.5f);
            // YCbCr pleine échelle (format natif ARKit) -> RVB
            float3 rgb = float3(y + 1.402f * cbcr.y,
                                y - 0.344136f * cbcr.x - 0.714136f * cbcr.y,
                                y + 1.772f * cbcr.x);
            rgb = saturate(rgb);
            const uchar4 old = color[idx];
            const float cw = float(old.a);     // alpha = nombre d'échantillons couleur (plafonné)
            const float3 outRgb = (float3(old.rgb) / 255.0f * cw + rgb) / (cw + 1.0f);
            color[idx] = uchar4(uchar3(round(outRgb * 255.0f)), uchar(min(cw + 1.0f, 24.0f)));
        }
    }
    """
}
