import { NextResponse } from "next/server";
import { prisma } from "@/lib/prisma";
import { authenticateDevice } from "@/lib/security";

export const dynamic = "force-dynamic";

/** Recherche de patients depuis l'iPhone (?q=…), 30 résultats max. */
export async function GET(request: Request) {
  const device = await authenticateDevice(request);
  if (!device) return NextResponse.json({ error: "Jeton invalide ou révoqué" }, { status: 401 });

  const q = new URL(request.url).searchParams.get("q")?.trim() ?? "";
  const patients = await prisma.patient.findMany({
    where: q
      ? {
          OR: [
            { ref: { contains: q, mode: "insensitive" } },
            { lastName: { contains: q, mode: "insensitive" } },
            { firstName: { contains: q, mode: "insensitive" } },
          ],
        }
      : undefined,
    orderBy: { updatedAt: "desc" },
    take: 30,
    select: { ref: true, lastName: true, firstName: true, _count: { select: { scans: true } } },
  });

  return NextResponse.json({
    patients: patients.map((p) => ({
      ref: p.ref,
      lastName: p.lastName,
      firstName: p.firstName,
      scanCount: p._count.scans,
    })),
  });
}
