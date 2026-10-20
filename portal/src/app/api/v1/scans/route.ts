import { NextResponse } from "next/server";
import { z } from "zod";
import { prisma } from "@/lib/prisma";
import { audit, authenticateDevice, clientIp, notifyN8n } from "@/lib/security";
import { parseScanType } from "@/lib/scan-types";
import { deleteScanFolder, saveFile, sha256 } from "@/lib/storage";
import type { FileKind } from "@/generated/prisma/enums";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

const MAX_FILE_BYTES = 250 * 1024 * 1024;

/** Métadonnées envoyées par l'iPhone (contenu de scan.json). */
const metadataSchema = z.object({
  folderName: z.string().max(200).optional(),
  patientID: z.string().trim().max(60).optional().default(""),
  scanType: z.string().max(40).optional(),
  date: z.string().optional(),
  vertexCount: z.number().int().nonnegative().optional(),
  triangleCount: z.number().int().nonnegative().optional(),
  framesIntegrated: z.number().int().nonnegative().optional(),
  medianAlignmentMM: z.number().nullable().optional(),
  voxelSizeMM: z.number().optional(),
  sizeMM: z.array(z.number()).length(3).optional(),
  deviceName: z.string().max(100).optional(),
});

const FIELDS: { field: string; kind: FileKind; ext: string }[] = [
  { field: "stl", kind: "STL", ext: "stl" },
  { field: "ply", kind: "PLY", ext: "ply" },
  { field: "obj", kind: "OBJ", ext: "obj" },
];

function looksValid(kind: FileKind, data: Buffer): boolean {
  if (data.length < 84) return false;
  if (kind === "PLY") return data.subarray(0, 4).toString("ascii") === "ply\n" || data.subarray(0, 3).toString("ascii") === "ply";
  if (kind === "STL") {
    const ascii = data.subarray(0, 5).toString("ascii").toLowerCase() === "solid";
    const triangles = data.readUInt32LE(80);
    return ascii || data.length === 84 + triangles * 50;
  }
  const head = data.subarray(0, 2048).toString("utf8");
  return /^(#|v |vn |vt |o |g |mtllib)/m.test(head);
}

function sanitizeFilename(name: string, fallback: string): string {
  const clean = name.replace(/[^a-zA-Z0-9._-]/g, "_").slice(0, 120);
  return clean || fallback;
}

/**
 * Réception d'un scan depuis l'iPhone.
 * multipart/form-data : metadata (JSON), stl, ply, obj (fichiers ; au moins le STL ou le PLY).
 */
export async function POST(request: Request) {
  const device = await authenticateDevice(request);
  if (!device) return NextResponse.json({ error: "Jeton invalide ou révoqué" }, { status: 401 });

  let form: FormData;
  try {
    form = await request.formData();
  } catch {
    return NextResponse.json({ error: "Corps multipart invalide" }, { status: 400 });
  }

  let meta: z.infer<typeof metadataSchema>;
  try {
    meta = metadataSchema.parse(JSON.parse(String(form.get("metadata") ?? "{}")));
  } catch (e) {
    return NextResponse.json({ error: "Métadonnées invalides", detail: String(e) }, { status: 400 });
  }

  const files: { kind: FileKind; filename: string; data: Buffer }[] = [];
  for (const { field, kind, ext } of FIELDS) {
    const f = form.get(field);
    if (!f || typeof f === "string") continue;
    if (f.size > MAX_FILE_BYTES) return NextResponse.json({ error: `Fichier ${field} trop volumineux` }, { status: 413 });
    const data = Buffer.from(await f.arrayBuffer());
    if (!looksValid(kind, data)) return NextResponse.json({ error: `Fichier ${field} invalide` }, { status: 400 });
    files.push({ kind, filename: sanitizeFilename(f.name, `scan.${ext}`), data });
  }
  if (!files.some((f) => f.kind === "STL" || f.kind === "PLY")) {
    return NextResponse.json({ error: "Au moins un fichier STL ou PLY est requis" }, { status: 400 });
  }

  // Renvoi du même scan : on renvoie l'existant (idempotence).
  if (meta.folderName) {
    const existing = await prisma.scan.findUnique({ where: { clientScanId: meta.folderName } });
    if (existing) {
      return NextResponse.json({ id: existing.id, duplicate: true, url: `/scans/${existing.id}` });
    }
  }

  const ref = meta.patientID?.trim() || "SANS-ID";
  const patient = await prisma.patient.upsert({
    where: { ref },
    update: {},
    create: { ref },
  });

  const capturedAt = meta.date && !Number.isNaN(Date.parse(meta.date)) ? new Date(meta.date) : new Date();
  const scan = await prisma.scan.create({
    data: {
      patientId: patient.id,
      type: parseScanType(meta.scanType),
      capturedAt,
      deviceName: meta.deviceName ?? device.name,
      clientScanId: meta.folderName ?? null,
      vertexCount: meta.vertexCount,
      triangleCount: meta.triangleCount,
      framesIntegrated: meta.framesIntegrated,
      medianAlignmentMm: meta.medianAlignmentMM ?? null,
      voxelSizeMm: meta.voxelSizeMM,
      widthMm: meta.sizeMM?.[0],
      heightMm: meta.sizeMM?.[1],
      depthMm: meta.sizeMM?.[2],
    },
  });

  try {
    for (const f of files) {
      const storageKey = `${scan.id}/${f.kind.toLowerCase()}.bin`;
      const { encrypted } = await saveFile(storageKey, f.data);
      await prisma.scanFile.create({
        data: {
          scanId: scan.id,
          kind: f.kind,
          filename: f.filename,
          sizeBytes: f.data.length,
          sha256: sha256(f.data),
          storageKey,
          encrypted,
        },
      });
    }
  } catch (e) {
    await prisma.scan.delete({ where: { id: scan.id } }).catch(() => {});
    await deleteScanFolder(scan.id).catch(() => {});
    console.error("upload", e);
    return NextResponse.json({ error: "Échec de l'enregistrement des fichiers" }, { status: 500 });
  }

  await prisma.patient.update({ where: { id: patient.id }, data: { updatedAt: new Date() } });
  await audit({
    action: "scan.upload",
    deviceTokenId: device.id,
    targetType: "scan",
    targetId: scan.id,
    detail: `${ref} · ${scan.type} · ${files.map((f) => f.kind).join("+")}`,
    ip: clientIp(request.headers),
  });
  await notifyN8n("scan.created", {
    scanId: scan.id,
    patientRef: ref,
    type: scan.type,
    capturedAt: scan.capturedAt.toISOString(),
    url: `${process.env.BETTER_AUTH_URL ?? ""}/scans/${scan.id}`,
  });

  return NextResponse.json({ id: scan.id, url: `/scans/${scan.id}` }, { status: 201 });
}
