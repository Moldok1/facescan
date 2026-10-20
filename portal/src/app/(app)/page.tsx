import Link from "next/link";
import { ScanFace, Smartphone, Users } from "lucide-react";
import { prisma } from "@/lib/prisma";
import { Badge, Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/basic";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/basic";
import { Button } from "@/components/ui/button";
import { patientDisplayName, scanTypeLabel } from "@/lib/scan-types";
import { formatDateTime } from "@/lib/utils";
import { QualityBadge } from "@/components/quality-badge";

export default async function Dashboard() {
  const [patientCount, scanCount, deviceCount, recent] = await Promise.all([
    prisma.patient.count(),
    prisma.scan.count(),
    prisma.deviceToken.count({ where: { revokedAt: null } }),
    prisma.scan.findMany({ orderBy: { uploadedAt: "desc" }, take: 12, include: { patient: true } }),
  ]);

  return (
    <div className="flex flex-col gap-6">
      <div>
        <h1 className="text-2xl font-semibold tracking-tight">Tableau de bord</h1>
        <p className="text-sm text-muted-foreground">Scans faciaux reçus depuis les iPhone du cabinet.</p>
      </div>

      <div className="grid gap-4 sm:grid-cols-3">
        <Stat icon={<Users className="size-4" />} label="Patients" value={patientCount} />
        <Stat icon={<ScanFace className="size-4" />} label="Scans" value={scanCount} />
        <Stat icon={<Smartphone className="size-4" />} label="iPhone autorisés" value={deviceCount} />
      </div>

      {deviceCount === 0 && (
        <Card className="border-primary/40 bg-accent/40">
          <CardHeader>
            <CardTitle>Première étape : appairer un iPhone</CardTitle>
            <CardDescription>
              Créez un jeton dans les réglages, puis scannez le QR code avec l&apos;appareil photo de l&apos;iPhone sur lequel
              FaceScan est installé.
            </CardDescription>
          </CardHeader>
          <CardContent>
            <Button asChild>
              <Link href="/reglages">Appairer un iPhone</Link>
            </Button>
          </CardContent>
        </Card>
      )}

      <Card>
        <CardHeader>
          <CardTitle>Derniers scans</CardTitle>
        </CardHeader>
        <CardContent>
          {recent.length === 0 ? (
            <p className="py-6 text-center text-sm text-muted-foreground">Aucun scan reçu pour l&apos;instant.</p>
          ) : (
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Patient</TableHead>
                  <TableHead>Type</TableHead>
                  <TableHead>Capturé le</TableHead>
                  <TableHead>Qualité</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {recent.map((s) => (
                  <TableRow key={s.id}>
                    <TableCell>
                      <Link href={`/scans/${s.id}`} className="font-medium hover:underline">
                        {patientDisplayName(s.patient)}
                      </Link>
                    </TableCell>
                    <TableCell>
                      <Badge variant="secondary">{scanTypeLabel(s.type)}</Badge>
                    </TableCell>
                    <TableCell className="text-muted-foreground">{formatDateTime(s.capturedAt)}</TableCell>
                    <TableCell>
                      <QualityBadge mm={s.medianAlignmentMm} />
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          )}
        </CardContent>
      </Card>
    </div>
  );
}

function Stat({ icon, label, value }: { icon: React.ReactNode; label: string; value: number }) {
  return (
    <Card className="gap-1 py-4">
      <CardContent className="flex items-center justify-between">
        <span className="flex items-center gap-2 text-sm text-muted-foreground">
          {icon} {label}
        </span>
        <span className="text-2xl font-semibold tabular-nums">{value}</span>
      </CardContent>
    </Card>
  );
}
