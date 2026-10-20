import Link from "next/link";
import { notFound } from "next/navigation";
import { ChevronLeft, ScanFace } from "lucide-react";
import { prisma } from "@/lib/prisma";
import { Badge, Card, CardContent, CardHeader, CardTitle } from "@/components/ui/basic";
import { EditPatientForm } from "@/components/forms";
import { QualityBadge } from "@/components/quality-badge";
import { patientDisplayName, scanTypeLabel } from "@/lib/scan-types";
import { formatDateTime } from "@/lib/utils";

export default async function PatientPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const patient = await prisma.patient.findUnique({
    where: { id },
    include: { scans: { orderBy: { capturedAt: "desc" }, include: { files: { select: { kind: true } } } } },
  });
  if (!patient) notFound();

  return (
    <div className="flex flex-col gap-6">
      <Link href="/patients" className="flex items-center gap-1 text-sm text-muted-foreground hover:text-foreground">
        <ChevronLeft className="size-4" /> Patients
      </Link>
      <h1 className="text-2xl font-semibold tracking-tight">{patientDisplayName(patient)}</h1>

      <div className="grid gap-6 lg:grid-cols-[1fr_380px]">
        <Card>
          <CardHeader>
            <CardTitle>Scans ({patient.scans.length})</CardTitle>
          </CardHeader>
          <CardContent>
            {patient.scans.length === 0 ? (
              <p className="py-6 text-center text-sm text-muted-foreground">
                Aucun scan. Saisissez l&apos;identifiant <span className="font-mono">{patient.ref}</span> sur l&apos;iPhone.
              </p>
            ) : (
              <ul className="grid gap-3 sm:grid-cols-2">
                {patient.scans.map((s) => (
                  <li key={s.id}>
                    <Link
                      href={`/scans/${s.id}`}
                      className="flex flex-col gap-2 rounded-lg border p-4 transition-colors hover:bg-accent/50"
                    >
                      <div className="flex items-center justify-between">
                        <span className="flex items-center gap-2 font-medium">
                          <ScanFace className="size-4 text-primary" /> {scanTypeLabel(s.type)}
                        </span>
                        <QualityBadge mm={s.medianAlignmentMm} />
                      </div>
                      <span className="text-sm text-muted-foreground">{formatDateTime(s.capturedAt)}</span>
                      <div className="flex gap-1">
                        {s.files.map((f) => (
                          <Badge key={f.kind} variant="outline">
                            {f.kind}
                          </Badge>
                        ))}
                      </div>
                    </Link>
                  </li>
                ))}
              </ul>
            )}
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>Fiche patient</CardTitle>
          </CardHeader>
          <CardContent>
            <EditPatientForm
              id={patient.id}
              values={{
                ref: patient.ref,
                lastName: patient.lastName,
                firstName: patient.firstName,
                birthDate: patient.birthDate ? patient.birthDate.toISOString().slice(0, 10) : null,
                notes: patient.notes,
              }}
            />
          </CardContent>
        </Card>
      </div>
    </div>
  );
}
