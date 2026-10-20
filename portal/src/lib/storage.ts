import "server-only";
import { createCipheriv, createDecipheriv, createHash, randomBytes } from "node:crypto";
import { mkdir, readFile, rm, writeFile } from "node:fs/promises";
import path from "node:path";

/**
 * Stockage des fichiers 3D sur disque (volume persistant Coolify monté sur /data).
 * Si STORAGE_ENCRYPTION_KEY est défini (32 octets en base64), chaque fichier est chiffré
 * en AES-256-GCM : [12 octets IV][16 octets tag][données chiffrées].
 */

const ROOT = process.env.STORAGE_DIR ?? path.join(process.cwd(), "data", "scans");

function key(): Buffer | null {
  const raw = process.env.STORAGE_ENCRYPTION_KEY;
  if (!raw) return null;
  const k = Buffer.from(raw, "base64");
  if (k.length !== 32) throw new Error("STORAGE_ENCRYPTION_KEY doit faire 32 octets encodés en base64 (openssl rand -base64 32).");
  return k;
}

export const encryptionEnabled = () => key() !== null;

function resolve(storageKey: string): string {
  if (!/^[a-zA-Z0-9/_.-]+$/.test(storageKey) || storageKey.includes("..")) {
    throw new Error("Clé de stockage invalide");
  }
  return path.join(ROOT, storageKey);
}

export function sha256(data: Buffer): string {
  return createHash("sha256").update(data).digest("hex");
}

export async function saveFile(storageKey: string, data: Buffer): Promise<{ encrypted: boolean }> {
  const p = resolve(storageKey);
  await mkdir(path.dirname(p), { recursive: true });
  const k = key();
  if (!k) {
    await writeFile(p, data);
    return { encrypted: false };
  }
  const iv = randomBytes(12);
  const cipher = createCipheriv("aes-256-gcm", k, iv);
  const body = Buffer.concat([cipher.update(data), cipher.final()]);
  await writeFile(p, Buffer.concat([iv, cipher.getAuthTag(), body]));
  return { encrypted: true };
}

export async function loadFile(storageKey: string, encrypted: boolean): Promise<Buffer> {
  const raw = await readFile(resolve(storageKey));
  if (!encrypted) return raw;
  const k = key();
  if (!k) throw new Error("Fichier chiffré mais STORAGE_ENCRYPTION_KEY absent.");
  const decipher = createDecipheriv("aes-256-gcm", k, raw.subarray(0, 12));
  decipher.setAuthTag(raw.subarray(12, 28));
  return Buffer.concat([decipher.update(raw.subarray(28)), decipher.final()]);
}

export async function deleteScanFolder(scanId: string): Promise<void> {
  await rm(resolve(scanId), { recursive: true, force: true });
}
