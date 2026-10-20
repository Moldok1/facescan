import { NextResponse } from "next/server";
import { authenticateDevice } from "@/lib/security";

export const dynamic = "force-dynamic";

/** Test de connexion depuis l'iPhone. */
export async function GET(request: Request) {
  const device = await authenticateDevice(request);
  if (!device) return NextResponse.json({ error: "Jeton invalide ou révoqué" }, { status: 401 });
  return NextResponse.json({ ok: true, device: device.name, server: "FaceScan ALTIORE" });
}
