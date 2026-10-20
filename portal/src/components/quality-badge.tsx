import { Badge } from "@/components/ui/basic";

/** Écart médian suivi/profondeur mesuré par l'iPhone pendant le scan. */
export function QualityBadge({ mm }: { mm: number | null }) {
  if (mm == null) return <span className="text-muted-foreground">—</span>;
  const variant = mm < 4 ? "success" : mm < 8 ? "warning" : "outline";
  return <Badge variant={variant}>écart {mm.toFixed(1)} mm</Badge>;
}
