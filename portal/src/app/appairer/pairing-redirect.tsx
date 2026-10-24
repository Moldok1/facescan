"use client";

import { useEffect, useState } from "react";
import { ScanFace } from "lucide-react";
import { Button } from "@/components/ui/button";

/**
 * Page ouverte en scannant le QR code avec l'appareil photo de l'iPhone.
 * Les paramètres sont dans le fragment (#…), jamais transmis au serveur.
 * Elle ouvre l'application FaceScan via facescan://pair?… et explique quoi faire sinon.
 */
export function PairingRedirect() {
  const [appUrl, setAppUrl] = useState<string | null>(null);
  const [invalid, setInvalid] = useState(false);

  useEffect(() => {
    const params = new URLSearchParams(window.location.hash.slice(1));
    const token = params.get("token");
    const url = params.get("url");
    if (!token?.startsWith("fsk_") || !url) {
      setInvalid(true);
      return;
    }
    const target = `facescan://pair?url=${encodeURIComponent(url)}&token=${encodeURIComponent(token)}&name=${encodeURIComponent(params.get("name") ?? "")}`;
    setAppUrl(target);
    // Retire le jeton de la barre d'adresse et de l'historique
    history.replaceState(null, "", window.location.pathname);
    window.location.href = target;
  }, []);

  return (
    <main className="flex min-h-svh items-center justify-center px-6">
      <div className="flex max-w-sm flex-col items-center gap-5 text-center">
        <ScanFace className="size-12 text-primary" />
        <h1 className="text-xl font-semibold">Appairage de l&apos;iPhone</h1>
        {invalid ? (
          <p className="text-sm text-muted-foreground">
            Lien d&apos;appairage incomplet. Créez un nouveau jeton dans les réglages du portail et scannez le nouveau QR code.
          </p>
        ) : (
          <>
            <p className="text-sm text-muted-foreground">
              Touchez le bouton ci-dessous pour enregistrer ce portail dans l&apos;application FaceScan.
            </p>
            {appUrl && (
              <Button asChild size="lg" className="w-full">
                <a href={appUrl}>Ouvrir dans FaceScan</a>
              </Button>
            )}
            <p className="text-xs text-muted-foreground">
              Rien ne se passe ? L&apos;application FaceScan n&apos;est pas installée sur cet iPhone, ou son autorisation a expiré
              (compte Apple gratuit : 7 jours). Réinstallez-la avec Sideloadly depuis le PC, puis scannez à nouveau le QR code.
              Vous pouvez aussi saisir l&apos;adresse et le jeton dans FaceScan › Portail › Saisie manuelle.
            </p>
          </>
        )}
      </div>
    </main>
  );
}
