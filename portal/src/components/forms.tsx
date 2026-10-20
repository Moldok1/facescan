"use client";

import { useActionState, useEffect, useState } from "react";
import { toast } from "sonner";
import { Copy, Plus } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input, Label, NativeSelect, Textarea } from "@/components/ui/basic";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle, DialogTrigger } from "@/components/ui/dialog";
import {
  type ActionState,
  type NewTokenState,
  createDeviceToken,
  createPatient,
  deletePatient,
  deleteScan,
  revokeDeviceToken,
  updatePatient,
  updateScan,
} from "@/app/actions";
import { SCAN_TYPES } from "@/lib/scan-types";

type PatientValues = {
  ref?: string;
  lastName?: string | null;
  firstName?: string | null;
  birthDate?: string | null;
  notes?: string | null;
};

function PatientFields({ v }: { v?: PatientValues }) {
  return (
    <div className="grid gap-4 sm:grid-cols-2">
      <div className="grid gap-2 sm:col-span-2">
        <Label htmlFor="ref">Identifiant (saisi sur l&apos;iPhone)</Label>
        <Input id="ref" name="ref" defaultValue={v?.ref} placeholder="P-2026-0142" required className="font-mono uppercase" />
      </div>
      <div className="grid gap-2">
        <Label htmlFor="lastName">Nom</Label>
        <Input id="lastName" name="lastName" defaultValue={v?.lastName ?? ""} />
      </div>
      <div className="grid gap-2">
        <Label htmlFor="firstName">Prénom</Label>
        <Input id="firstName" name="firstName" defaultValue={v?.firstName ?? ""} />
      </div>
      <div className="grid gap-2">
        <Label htmlFor="birthDate">Date de naissance</Label>
        <Input id="birthDate" name="birthDate" type="date" defaultValue={v?.birthDate ?? ""} />
      </div>
      <div className="grid gap-2 sm:col-span-2">
        <Label htmlFor="notes">Notes</Label>
        <Textarea id="notes" name="notes" defaultValue={v?.notes ?? ""} rows={3} />
      </div>
    </div>
  );
}

export function NewPatientDialog() {
  const [state, action, pending] = useActionState<ActionState, FormData>(createPatient, undefined);
  return (
    <Dialog>
      <DialogTrigger asChild>
        <Button>
          <Plus /> Nouveau patient
        </Button>
      </DialogTrigger>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Nouveau patient</DialogTitle>
          <DialogDescription>
            Les scans envoyés depuis l&apos;iPhone avec le même identifiant sont rattachés automatiquement.
          </DialogDescription>
        </DialogHeader>
        <form action={action} className="flex flex-col gap-4">
          <PatientFields />
          {state?.error && <p className="text-sm text-destructive">{state.error}</p>}
          <DialogFooter>
            <Button type="submit" disabled={pending}>
              {pending ? "Création…" : "Créer"}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}

export function EditPatientForm({ id, values }: { id: string; values: PatientValues }) {
  const [state, action, pending] = useActionState<ActionState, FormData>(updatePatient.bind(null, id), undefined);
  useEffect(() => {
    if (state?.ok) toast.success("Fiche patient enregistrée");
  }, [state]);
  return (
    <form action={action} className="flex flex-col gap-4">
      <PatientFields v={values} />
      {state?.error && <p className="text-sm text-destructive">{state.error}</p>}
      <div className="flex justify-between">
        <ConfirmButton
          label="Supprimer le patient"
          title="Supprimer ce patient et tous ses scans ?"
          description="Les fichiers 3D seront définitivement effacés du serveur."
          onConfirm={() => deletePatient(id)}
        />
        <Button type="submit" disabled={pending}>
          {pending ? "Enregistrement…" : "Enregistrer"}
        </Button>
      </div>
    </form>
  );
}

export function EditScanForm({
  id,
  type,
  notes,
  patientRef,
}: {
  id: string;
  type: string;
  notes: string | null;
  patientRef: string;
}) {
  const [state, action, pending] = useActionState<ActionState, FormData>(updateScan.bind(null, id), undefined);
  useEffect(() => {
    if (state?.ok) toast.success("Scan mis à jour");
  }, [state]);
  return (
    <form action={action} className="flex flex-col gap-3">
      <div className="grid gap-2">
        <Label htmlFor="type">Type</Label>
        <NativeSelect id="type" name="type" defaultValue={type}>
          {SCAN_TYPES.map((t) => (
            <option key={t.value} value={t.value}>
              {t.label}
            </option>
          ))}
        </NativeSelect>
      </div>
      <div className="grid gap-2">
        <Label htmlFor="patientRef">Patient (identifiant)</Label>
        <Input id="patientRef" name="patientRef" defaultValue={patientRef} className="font-mono uppercase" />
      </div>
      <div className="grid gap-2">
        <Label htmlFor="notes">Notes</Label>
        <Textarea id="notes" name="notes" defaultValue={notes ?? ""} rows={3} />
      </div>
      {state?.error && <p className="text-sm text-destructive">{state.error}</p>}
      <div className="flex justify-between gap-2">
        <ConfirmButton
          label="Supprimer"
          title="Supprimer ce scan ?"
          description="Les fichiers STL, PLY et OBJ seront définitivement effacés du serveur."
          onConfirm={() => deleteScan(id)}
        />
        <Button type="submit" disabled={pending} size="sm">
          {pending ? "Enregistrement…" : "Enregistrer"}
        </Button>
      </div>
    </form>
  );
}

export function ConfirmButton({
  label,
  title,
  description,
  onConfirm,
  size = "sm",
}: {
  label: string;
  title: string;
  description: string;
  onConfirm: () => Promise<unknown>;
  size?: "sm" | "default";
}) {
  const [open, setOpen] = useState(false);
  const [pending, setPending] = useState(false);
  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogTrigger asChild>
        <Button type="button" variant="outline" size={size} className="text-destructive">
          {label}
        </Button>
      </DialogTrigger>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>{title}</DialogTitle>
          <DialogDescription>{description}</DialogDescription>
        </DialogHeader>
        <DialogFooter>
          <Button variant="outline" onClick={() => setOpen(false)}>
            Annuler
          </Button>
          <Button
            variant="destructive"
            disabled={pending}
            onClick={async () => {
              setPending(true);
              try {
                await onConfirm();
              } finally {
                setPending(false);
                setOpen(false);
              }
            }}
          >
            {pending ? "…" : "Confirmer"}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

export function NewDeviceTokenForm() {
  const [state, action, pending] = useActionState<NewTokenState, FormData>(createDeviceToken, undefined);
  return (
    <div className="flex flex-col gap-4">
      <form action={action} className="flex flex-col gap-2 sm:flex-row sm:items-end">
        <div className="grid flex-1 gap-2">
          <Label htmlFor="deviceName">Nom de l&apos;appareil</Label>
          <Input id="deviceName" name="name" placeholder="iPhone salle 3" required />
        </div>
        <Button type="submit" disabled={pending}>
          <Plus /> Créer un jeton
        </Button>
      </form>
      {state?.error && <p className="text-sm text-destructive">{state.error}</p>}
      {state?.token && state.qr && (
        <div className="flex flex-col gap-4 rounded-lg border bg-accent/30 p-4 sm:flex-row">
          {/* eslint-disable-next-line @next/next/no-img-element */}
          <img src={state.qr} alt="QR code d'appairage" className="size-56 rounded-md bg-white p-2" />
          <div className="flex flex-col gap-3 text-sm">
            <p className="font-medium">Scannez ce QR code avec l&apos;appareil photo de l&apos;iPhone.</p>
            <p className="text-muted-foreground">
              L&apos;iPhone propose d&apos;ouvrir FaceScan, qui enregistre l&apos;adresse du portail et le jeton. Le jeton
              n&apos;est affiché qu&apos;une seule fois.
            </p>
            <div className="flex items-center gap-2">
              <code className="rounded bg-muted px-2 py-1 font-mono text-xs break-all">{state.token}</code>
              <Button
                type="button"
                variant="outline"
                size="icon"
                onClick={() => {
                  navigator.clipboard.writeText(state.token!);
                  toast.success("Jeton copié");
                }}
              >
                <Copy />
              </Button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}

export function RevokeButton({ id }: { id: string }) {
  return (
    <ConfirmButton
      label="Révoquer"
      title="Révoquer ce jeton ?"
      description="L'iPhone correspondant ne pourra plus envoyer de scans. Les scans déjà reçus sont conservés."
      onConfirm={() => revokeDeviceToken(id)}
    />
  );
}
