import Link from "next/link";
import { headers } from "next/headers";
import { notFound } from "next/navigation";
import { ChevronLeft, Download } from "lucide-react";
import { prisma } from "@/lib/prisma";
import { audit, clientIp, requireUser } from "@/lib/security";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/basic";
import { Button } from "@/components/ui/button";
import { EditScanForm } from "@/components/forms";
import { MeshViewer } from "@/components/mesh-viewer";
import { QualityBadge } from "@/components/quality-badge";
import { patientDisplayName, scanTypeLabel } from "@/lib/scan-types";
import { formatBytes, formatDateTime } from "@/lib/utils";

const FILE_HELP: Record<string, string> = {
  STL: "Géométrie seule — planification, CFAO",
  PLY: "Géométrie + couleur — exocad, Blue Sky Plan, MeshLab",
  OBJ: "Géométrie + couleur par sommet",
};

export default async function ScanPage({ params }: { params: Promise<{ id: string }> }) {
  const user = await requireUser();
  const { id } = await params;
  const scan = await prisma.scan.findUnique({
    where: { id },
    include: { patient: true, files: { orderBy: { kind: "asc" } } },
  });
  if (!scan) notFound();

  await audit({
    action: "scan.view",
    userId: user.id,
    targetType: "scan",
    targetId: scan.id,
    detail: scan.patient.ref,
    ip: clientIp(await headers()),
  });

  const ply = scan.files.find((f) => f.kind === "PLY");
  const stl = scan.files.find((f) => f.kind === "STL");
  const viewFile = ply ?? stl;

  const rows: [string, React.ReactNode][] = [
    ["Capturé le", formatDateTime(scan.capturedAt)],
    ["Reçu le", formatDateTime(scan.uploadedAt)],
    ["Appareil", scan.deviceName ?? "—"],
    ["Images fusionnées", scan.framesIntegrated ?? "—"],
    ["Écart suivi / profondeur", <QualityBadge key="q" mm={scan.medianAlignmentMm} />],
    ["Résolution", scan.voxelSizeMm != null ? `${scan.voxelSizeMm.toFixed(2)} mm` : "—"],
    [
      "Dimensions (L × H × P)",
      scan.widthMm != null && scan.heightMm != null && scan.depthMm != null
        ? `${scan.widthMm.toFixed(0)} × ${scan.heightMm.toFixed(0)} × ${scan.depthMm.toFixed(0)} mm`
        : "—",
    ],
    [
      "Maillage",
      scan.vertexCount != null && scan.triangleCount != null
        ? `${scan.vertexCount.toLocaleString("fr-FR")} sommets · ${scan.triangleCount.toLocaleString("fr-FR")} triangles`
        : "—",
    ],
  ];

  return (
    <div className="flex flex-col gap-6">
      <Link
        href={`/patients/${scan.patientId}`}
        className="flex items-center gap-1 text-sm text-muted-foreground hover:text-foreground"
      >
        <ChevronLeft className="size-4" /> {patientDisplayName(scan.patient)}
      </Link>
      <h1 className="text-2xl font-semibold tracking-tight">
        {scanTypeLabel(scan.type)} <span className="font-normal text-muted-foreground">· {formatDateTime(scan.capturedAt)}</span>
      </h1>

      <div className="grid gap-6 lg:grid-cols-[1fr_340px]">
        <div className="min-w-0">
          {viewFile ? (
            <MeshViewer url={`/api/files/${viewFile.id}?view=1`} format={viewFile.kind === "PLY" ? "PLY" : "STL"} />
          ) : (
            <p className="text-sm text-muted-foreground">Aucun fichier affichable.</p>
          )}
        </div>

        <div className="flex flex-col gap-6">
          <Card>
            <CardHeader>
              <CardTitle>Fichiers</CardTitle>
            </CardHeader>
            <CardContent className="flex flex-col gap-3">
              {scan.files.map((f) => (
                <div key={f.id} className="flex items-center justify-between gap-3">
                  <div className="min-w-0">
                    <div className="font-medium">
                      {f.kind} <span className="text-xs font-normal text-muted-foreground">{formatBytes(f.sizeBytes)}</span>
                    </div>
                    <div className="text-xs text-muted-foreground">{FILE_HELP[f.kind]}</div>
                  </div>
                  <Button asChild variant="outline" size="sm">
                    <a href={`/api/files/${f.id}`} download>
                      <Download /> Télécharger
                    </a>
                  </Button>
                </div>
              ))}
              <p className="text-xs text-muted-foreground">Unités : mm. Repère : x = gauche du patient, y = haut, z = antérieur.</p>
            </CardContent>
          </Card>

          <Card>
            <CardHeader>
              <CardTitle>Contrôle qualité</CardTitle>
            </CardHeader>
            <CardContent>
              <dl className="grid gap-2 text-sm">
                {rows.map(([k, v]) => (
                  <div key={k} className="flex justify-between gap-4">
                    <dt className="text-muted-foreground">{k}</dt>
                    <dd className="text-right">{v}</dd>
                  </div>
                ))}
              </dl>
            </CardContent>
          </Card>

          <Card>
            <CardHeader>
              <CardTitle>Classement</CardTitle>
            </CardHeader>
            <CardContent>
              <EditScanForm id={scan.id} type={scan.type} notes={scan.notes} patientRef={scan.patient.ref} />
            </CardContent>
          </Card>
        </div>
      </div>
    </div>
  );
}
