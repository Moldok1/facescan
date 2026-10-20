import { NextResponse } from "next/server";
import { headers } from "next/headers";
import { auth } from "@/lib/auth";
import { prisma } from "@/lib/prisma";
import { audit, clientIp } from "@/lib/security";
import { loadFile } from "@/lib/storage";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

const MIME: Record<string, string> = {
  STL: "model/stl",
  PLY: "application/octet-stream",
  OBJ: "model/obj",
};

/** Téléchargement d'un fichier de scan (session obligatoire). ?view=1 : chargement par la visionneuse. */
export async function GET(request: Request, { params }: { params: Promise<{ fileId: string }> }) {
  const h = await headers();
  const session = await auth.api.getSession({ headers: h });
  if (!session) return NextResponse.json({ error: "Non connecté" }, { status: 401 });

  const { fileId } = await params;
  const file = await prisma.scanFile.findUnique({
    where: { id: fileId },
    include: { scan: { include: { patient: true } } },
  });
  if (!file) return NextResponse.json({ error: "Fichier introuvable" }, { status: 404 });

  const data = await loadFile(file.storageKey, file.encrypted);
  const view = new URL(request.url).searchParams.get("view") === "1";
  if (!view) {
    await audit({
      action: "file.download",
      userId: session.user.id,
      targetType: "scan",
      targetId: file.scanId,
      detail: `${file.scan.patient.ref} · ${file.kind}`,
      ip: clientIp(h),
    });
  }

  const name = `${file.scan.patient.ref}_${file.scan.type.toLowerCase()}_${file.scan.capturedAt.toISOString().slice(0, 10)}.${file.kind.toLowerCase()}`
    .replace(/[^a-zA-Z0-9._-]/g, "_");

  return new NextResponse(new Uint8Array(data), {
    headers: {
      "content-type": MIME[file.kind] ?? "application/octet-stream",
      "content-length": String(data.length),
      "content-disposition": view ? "inline" : `attachment; filename="${name}"`,
      "cache-control": "private, no-store",
      "x-content-type-options": "nosniff",
    },
  });
}
