import { prisma } from "@/lib/prisma";
import { signupAllowed } from "@/lib/auth";
import { encryptionEnabled } from "@/lib/storage";
import { Badge, Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/basic";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/basic";
import { NewDeviceTokenForm, RevokeButton } from "@/components/forms";
import { formatDateTime } from "@/lib/utils";

const ACTIONS: Record<string, string> = {
  "scan.upload": "Scan reçu",
  "scan.view": "Scan consulté",
  "scan.update": "Scan modifié",
  "scan.delete": "Scan supprimé",
  "file.download": "Fichier téléchargé",
  "patient.create": "Patient créé",
  "patient.update": "Patient modifié",
  "patient.delete": "Patient supprimé",
  "device.create": "Jeton créé",
  "device.revoke": "Jeton révoqué",
};

export default async function SettingsPage() {
  const [devices, users, logs] = await Promise.all([
    prisma.deviceToken.findMany({ orderBy: { createdAt: "desc" }, include: { createdBy: { select: { name: true } } } }),
    prisma.user.findMany({ orderBy: { createdAt: "asc" }, select: { id: true, name: true, email: true, createdAt: true } }),
    prisma.auditLog.findMany({
      orderBy: { createdAt: "desc" },
      take: 100,
      include: { user: { select: { name: true } }, deviceToken: { select: { name: true } } },
    }),
  ]);

  return (
    <div className="flex flex-col gap-6">
      <h1 className="text-2xl font-semibold tracking-tight">Réglages</h1>

      <Card>
        <CardHeader>
          <CardTitle>iPhone autorisés</CardTitle>
          <CardDescription>Chaque iPhone envoie ses scans avec son propre jeton, révocable à tout moment.</CardDescription>
        </CardHeader>
        <CardContent className="flex flex-col gap-6">
          <NewDeviceTokenForm />
          {devices.length > 0 && (
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Appareil</TableHead>
                  <TableHead>Jeton</TableHead>
                  <TableHead>Créé par</TableHead>
                  <TableHead>Dernière utilisation</TableHead>
                  <TableHead />
                </TableRow>
              </TableHeader>
              <TableBody>
                {devices.map((d) => (
                  <TableRow key={d.id}>
                    <TableCell className="font-medium">{d.name}</TableCell>
                    <TableCell className="font-mono text-xs text-muted-foreground">{d.prefix}…</TableCell>
                    <TableCell className="text-muted-foreground">{d.createdBy.name}</TableCell>
                    <TableCell className="text-muted-foreground">{d.lastUsedAt ? formatDateTime(d.lastUsedAt) : "jamais"}</TableCell>
                    <TableCell className="text-right">
                      {d.revokedAt ? <Badge variant="outline">Révoqué</Badge> : <RevokeButton id={d.id} />}
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          )}
        </CardContent>
      </Card>

      <div className="grid gap-6 lg:grid-cols-2">
        <Card>
          <CardHeader>
            <CardTitle>Utilisateurs</CardTitle>
            <CardDescription>
              Inscriptions {signupAllowed ? "ouvertes" : "fermées"} (variable ALLOW_SIGNUP).
              {signupAllowed && " Pensez à les refermer une fois les comptes de l'équipe créés."}
            </CardDescription>
          </CardHeader>
          <CardContent>
            <ul className="flex flex-col gap-2 text-sm">
              {users.map((u) => (
                <li key={u.id} className="flex justify-between gap-4">
                  <span className="font-medium">{u.name}</span>
                  <span className="text-muted-foreground">{u.email}</span>
                </li>
              ))}
            </ul>
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>Stockage</CardTitle>
          </CardHeader>
          <CardContent className="flex flex-col gap-2 text-sm">
            <div className="flex justify-between">
              <span className="text-muted-foreground">Chiffrement des fichiers (AES-256-GCM)</span>
              {encryptionEnabled() ? <Badge variant="success">Activé</Badge> : <Badge variant="warning">Désactivé</Badge>}
            </div>
            <div className="flex justify-between">
              <span className="text-muted-foreground">Notification n8n</span>
              {process.env.N8N_WEBHOOK_URL ? <Badge variant="success">Configurée</Badge> : <Badge variant="outline">Non</Badge>}
            </div>
          </CardContent>
        </Card>
      </div>

      <Card>
        <CardHeader>
          <CardTitle>Journal des accès</CardTitle>
          <CardDescription>100 dernières opérations.</CardDescription>
        </CardHeader>
        <CardContent>
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Date</TableHead>
                <TableHead>Action</TableHead>
                <TableHead>Par</TableHead>
                <TableHead>Détail</TableHead>
                <TableHead>IP</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {logs.map((l) => (
                <TableRow key={l.id}>
                  <TableCell className="whitespace-nowrap text-muted-foreground">{formatDateTime(l.createdAt)}</TableCell>
                  <TableCell>{ACTIONS[l.action] ?? l.action}</TableCell>
                  <TableCell>{l.user?.name ?? (l.deviceToken ? `📱 ${l.deviceToken.name}` : "—")}</TableCell>
                  <TableCell className="text-muted-foreground">{l.detail ?? ""}</TableCell>
                  <TableCell className="font-mono text-xs text-muted-foreground">{l.ip ?? ""}</TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </CardContent>
      </Card>
    </div>
  );
}
