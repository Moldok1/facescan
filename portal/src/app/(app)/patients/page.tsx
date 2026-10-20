import Link from "next/link";
import { Search } from "lucide-react";
import { prisma } from "@/lib/prisma";
import { Card, CardContent, Input, Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/basic";
import { NewPatientDialog } from "@/components/forms";
import { formatDate, formatDateTime } from "@/lib/utils";

export default async function PatientsPage({ searchParams }: { searchParams: Promise<{ q?: string }> }) {
  const { q = "" } = await searchParams;
  const query = q.trim();
  const patients = await prisma.patient.findMany({
    where: query
      ? {
          OR: [
            { ref: { contains: query, mode: "insensitive" } },
            { lastName: { contains: query, mode: "insensitive" } },
            { firstName: { contains: query, mode: "insensitive" } },
          ],
        }
      : undefined,
    orderBy: { updatedAt: "desc" },
    take: 200,
    include: {
      _count: { select: { scans: true } },
      scans: { orderBy: { capturedAt: "desc" }, take: 1, select: { capturedAt: true } },
    },
  });

  return (
    <div className="flex flex-col gap-6">
      <div className="flex flex-wrap items-center justify-between gap-4">
        <div>
          <h1 className="text-2xl font-semibold tracking-tight">Patients</h1>
          <p className="text-sm text-muted-foreground">{patients.length} patient(s)</p>
        </div>
        <NewPatientDialog />
      </div>

      <form className="relative max-w-sm">
        <Search className="absolute top-2.5 left-3 size-4 text-muted-foreground" />
        <Input name="q" defaultValue={query} placeholder="Rechercher (identifiant, nom, prénom)" className="pl-9" />
      </form>

      <Card className="py-2">
        <CardContent className="px-2">
          {patients.length === 0 ? (
            <p className="py-10 text-center text-sm text-muted-foreground">
              {query ? "Aucun résultat." : "Aucun patient. Ils sont créés automatiquement à la réception du premier scan."}
            </p>
          ) : (
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Identifiant</TableHead>
                  <TableHead>Nom</TableHead>
                  <TableHead>Naissance</TableHead>
                  <TableHead className="text-right">Scans</TableHead>
                  <TableHead>Dernier scan</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {patients.map((p) => (
                  <TableRow key={p.id}>
                    <TableCell>
                      <Link href={`/patients/${p.id}`} className="font-mono font-medium hover:underline">
                        {p.ref}
                      </Link>
                    </TableCell>
                    <TableCell>
                      {[p.lastName?.toUpperCase(), p.firstName].filter(Boolean).join(" ") || (
                        <span className="text-muted-foreground">—</span>
                      )}
                    </TableCell>
                    <TableCell className="text-muted-foreground">{p.birthDate ? formatDate(p.birthDate) : "—"}</TableCell>
                    <TableCell className="text-right tabular-nums">{p._count.scans}</TableCell>
                    <TableCell className="text-muted-foreground">
                      {p.scans[0] ? formatDateTime(p.scans[0].capturedAt) : "—"}
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
