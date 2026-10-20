import type { ScanType } from "@/generated/prisma/enums";

export const SCAN_TYPES: { value: ScanType; label: string }[] = [
  { value: "REPOS", label: "Repos" },
  { value: "SOURIRE", label: "Sourire" },
  { value: "ECARTEURS", label: "Écarteurs" },
  { value: "AUTRE", label: "Autre" },
];

export function scanTypeLabel(t: ScanType): string {
  return SCAN_TYPES.find((s) => s.value === t)?.label ?? t;
}

/** Convertit le libellé envoyé par l'iPhone (« Repos », « Écarteurs »…) en valeur d'énumération. */
export function parseScanType(input: string | null | undefined): ScanType {
  const s = (input ?? "")
    .normalize("NFD")
    .replace(/[̀-ͯ]/g, "")
    .toUpperCase()
    .trim();
  if (s === "REPOS" || s === "SOURIRE" || s === "ECARTEURS") return s;
  return "AUTRE";
}

export function patientDisplayName(p: { ref: string; lastName: string | null; firstName: string | null }): string {
  const name = [p.lastName?.toUpperCase(), p.firstName].filter(Boolean).join(" ");
  return name ? `${name} (${p.ref})` : p.ref;
}
