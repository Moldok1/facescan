"use server";

import { headers } from "next/headers";
import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import QRCode from "qrcode";
import { z } from "zod";
import { prisma } from "@/lib/prisma";
import { audit, clientIp, generateDeviceToken, requireUser } from "@/lib/security";
import { deleteScanFolder } from "@/lib/storage";
import { SCAN_TYPES } from "@/lib/scan-types";
import type { ScanType } from "@/generated/prisma/enums";

export type ActionState = { error?: string; ok?: boolean } | undefined;

const patientSchema = z.object({
  ref: z
    .string()
    .trim()
    .min(1, "Identifiant obligatoire")
    .max(60)
    .regex(/^[A-Za-z0-9_-]+$/, "Identifiant : lettres, chiffres, - et _ uniquement"),
  lastName: z.string().trim().max(100).optional(),
  firstName: z.string().trim().max(100).optional(),
  birthDate: z.string().optional(),
  notes: z.string().max(5000).optional(),
});

function readPatient(form: FormData) {
  return patientSchema.safeParse({
    ref: form.get("ref"),
    lastName: form.get("lastName") || undefined,
    firstName: form.get("firstName") || undefined,
    birthDate: form.get("birthDate") || undefined,
    notes: form.get("notes") || undefined,
  });
}

function toDate(s?: string) {
  if (!s) return null;
  const d = new Date(`${s}T00:00:00Z`);
  return Number.isNaN(d.getTime()) ? null : d;
}

async function ip() {
  return clientIp(await headers());
}

// ───────── Patients ─────────

export async function createPatient(_: ActionState, form: FormData): Promise<ActionState> {
  const user = await requireUser();
  const parsed = readPatient(form);
  if (!parsed.success) return { error: parsed.error.issues[0].message };
  const d = parsed.data;
  const ref = d.ref.toUpperCase();
  if (await prisma.patient.findUnique({ where: { ref } })) return { error: "Cet identifiant existe déjà" };
  const p = await prisma.patient.create({
    data: { ref, lastName: d.lastName, firstName: d.firstName, birthDate: toDate(d.birthDate), notes: d.notes },
  });
  await audit({ action: "patient.create", userId: user.id, targetType: "patient", targetId: p.id, detail: ref, ip: await ip() });
  redirect(`/patients/${p.id}`);
}

export async function updatePatient(id: string, _: ActionState, form: FormData): Promise<ActionState> {
  const user = await requireUser();
  const parsed = readPatient(form);
  if (!parsed.success) return { error: parsed.error.issues[0].message };
  const d = parsed.data;
  const ref = d.ref.toUpperCase();
  const clash = await prisma.patient.findUnique({ where: { ref } });
  if (clash && clash.id !== id) return { error: "Cet identifiant est déjà utilisé par un autre patient" };
  await prisma.patient.update({
    where: { id },
    data: {
      ref,
      lastName: d.lastName ?? null,
      firstName: d.firstName ?? null,
      birthDate: toDate(d.birthDate),
      notes: d.notes ?? null,
    },
  });
  await audit({ action: "patient.update", userId: user.id, targetType: "patient", targetId: id, detail: ref, ip: await ip() });
  revalidatePath(`/patients/${id}`);
  return { ok: true };
}

export async function deletePatient(id: string) {
  const user = await requireUser();
  const p = await prisma.patient.findUnique({ where: { id }, include: { scans: { select: { id: true } } } });
  if (!p) redirect("/patients");
  for (const s of p.scans) await deleteScanFolder(s.id);
  await prisma.patient.delete({ where: { id } });
  await audit({ action: "patient.delete", userId: user.id, targetType: "patient", targetId: id, detail: p.ref, ip: await ip() });
  redirect("/patients");
}

// ───────── Scans ─────────

export async function updateScan(id: string, _: ActionState, form: FormData): Promise<ActionState> {
  const user = await requireUser();
  const type = String(form.get("type") ?? "");
  if (!SCAN_TYPES.some((t) => t.value === type)) return { error: "Type invalide" };
  const notes = String(form.get("notes") ?? "").slice(0, 5000);
  const patientRef = String(form.get("patientRef") ?? "").trim().toUpperCase();

  const scan = await prisma.scan.findUnique({ where: { id }, include: { patient: true } });
  if (!scan) return { error: "Scan introuvable" };

  let patientId = scan.patientId;
  if (patientRef && patientRef !== scan.patient.ref) {
    const target = await prisma.patient.findUnique({ where: { ref: patientRef } });
    if (!target) return { error: `Aucun patient avec l'identifiant ${patientRef}` };
    patientId = target.id;
  }

  await prisma.scan.update({ where: { id }, data: { type: type as ScanType, notes: notes || null, patientId } });
  await audit({
    action: "scan.update",
    userId: user.id,
    targetType: "scan",
    targetId: id,
    detail: patientId !== scan.patientId ? `réaffecté ${scan.patient.ref} → ${patientRef}` : undefined,
    ip: await ip(),
  });
  revalidatePath(`/scans/${id}`);
  return { ok: true };
}

export async function deleteScan(id: string) {
  const user = await requireUser();
  const scan = await prisma.scan.findUnique({ where: { id }, include: { patient: true } });
  if (!scan) redirect("/");
  await deleteScanFolder(id);
  await prisma.scan.delete({ where: { id } });
  await audit({ action: "scan.delete", userId: user.id, targetType: "scan", targetId: id, detail: scan.patient.ref, ip: await ip() });
  redirect(`/patients/${scan.patientId}`);
}

// ───────── Jetons d'appareil ─────────

export type NewTokenState = { error?: string; token?: string; qr?: string; pairUrl?: string } | undefined;

export async function createDeviceToken(_: NewTokenState, form: FormData): Promise<NewTokenState> {
  const user = await requireUser();
  const name = String(form.get("name") ?? "").trim().slice(0, 60);
  if (!name) return { error: "Donnez un nom à l'appareil (ex. iPhone salle 3)" };
  const { token, hash, prefix } = generateDeviceToken();
  const created = await prisma.deviceToken.create({ data: { name, tokenHash: hash, prefix, createdById: user.id } });
  await audit({ action: "device.create", userId: user.id, targetType: "device", targetId: created.id, detail: name, ip: await ip() });

  const h = await headers();
  const proto = h.get("x-forwarded-proto") ?? "https";
  const host = h.get("x-forwarded-host") ?? h.get("host");
  const base = process.env.BETTER_AUTH_URL ?? `${proto}://${host}`;
  const pairUrl = `facescan://pair?url=${encodeURIComponent(base)}&token=${encodeURIComponent(token)}&name=${encodeURIComponent(name)}`;
  const qr = await QRCode.toDataURL(pairUrl, { margin: 1, width: 280, errorCorrectionLevel: "M" });
  revalidatePath("/reglages");
  return { token, qr, pairUrl };
}

export async function revokeDeviceToken(id: string) {
  const user = await requireUser();
  await prisma.deviceToken.update({ where: { id }, data: { revokedAt: new Date() } });
  await audit({ action: "device.revoke", userId: user.id, targetType: "device", targetId: id, ip: await ip() });
  revalidatePath("/reglages");
}
