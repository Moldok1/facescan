import "server-only";
import { createHash, randomBytes } from "node:crypto";
import { headers } from "next/headers";
import { redirect } from "next/navigation";
import { auth } from "@/lib/auth";
import { prisma } from "@/lib/prisma";

// ───────── Session utilisateur (pages et actions serveur) ─────────

export async function getSession() {
  return auth.api.getSession({ headers: await headers() });
}

/** Exige un utilisateur connecté ; sinon redirige vers /connexion. */
export async function requireUser() {
  const session = await getSession();
  if (!session) redirect("/connexion");
  return session.user;
}

// ───────── Jetons d'appareil (application iPhone) ─────────

export const TOKEN_PREFIX = "fsk_";

export function generateDeviceToken(): { token: string; hash: string; prefix: string } {
  const token = TOKEN_PREFIX + randomBytes(24).toString("base64url");
  return { token, hash: hashToken(token), prefix: token.slice(0, 10) };
}

export function hashToken(token: string): string {
  return createHash("sha256").update(token).digest("hex");
}

/** Vérifie l'en-tête « Authorization: Bearer fsk_… ». */
export async function authenticateDevice(request: Request) {
  const header = request.headers.get("authorization") ?? "";
  const match = /^Bearer\s+(fsk_[A-Za-z0-9_-]{20,})$/.exec(header.trim());
  if (!match) return null;
  const device = await prisma.deviceToken.findUnique({ where: { tokenHash: hashToken(match[1]) } });
  if (!device || device.revokedAt) return null;
  await prisma.deviceToken.update({ where: { id: device.id }, data: { lastUsedAt: new Date() } });
  return device;
}

// ───────── Journal d'audit ─────────

export function clientIp(h: Headers): string | null {
  return h.get("x-forwarded-for")?.split(",")[0]?.trim() ?? h.get("x-real-ip") ?? null;
}

export async function audit(entry: {
  action: string;
  userId?: string | null;
  deviceTokenId?: string | null;
  targetType?: string;
  targetId?: string;
  detail?: string;
  ip?: string | null;
}) {
  try {
    await prisma.auditLog.create({ data: entry });
  } catch (e) {
    console.error("audit", e);
  }
}

/** Notification n8n optionnelle (N8N_WEBHOOK_URL) — n'échoue jamais la requête. */
export async function notifyN8n(event: string, payload: Record<string, unknown>) {
  const url = process.env.N8N_WEBHOOK_URL;
  if (!url) return;
  try {
    await fetch(url, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ event, ...payload }),
      signal: AbortSignal.timeout(5000),
    });
  } catch (e) {
    console.error("n8n", e);
  }
}
