import Link from "next/link";
import { ScanFace } from "lucide-react";
import { SignOutButton } from "@/components/auth-forms";
import { requireUser } from "@/lib/security";

export const dynamic = "force-dynamic";

export default async function AppLayout({ children }: { children: React.ReactNode }) {
  const user = await requireUser();
  return (
    <div className="min-h-svh">
      <header className="sticky top-0 z-40 border-b bg-background/90 backdrop-blur">
        <div className="mx-auto flex h-14 max-w-6xl items-center gap-6 px-4">
          <Link href="/" className="flex items-center gap-2 font-semibold tracking-tight text-primary">
            <ScanFace className="size-5" />
            <span>FaceScan</span>
          </Link>
          <nav className="flex items-center gap-1 text-sm">
            <Link href="/" className="rounded-md px-3 py-1.5 hover:bg-accent">Tableau de bord</Link>
            <Link href="/patients" className="rounded-md px-3 py-1.5 hover:bg-accent">Patients</Link>
            <Link href="/reglages" className="rounded-md px-3 py-1.5 hover:bg-accent">Réglages</Link>
          </nav>
          <div className="ml-auto flex items-center gap-2 text-sm text-muted-foreground">
            <span className="hidden sm:inline">{user.name}</span>
            <SignOutButton />
          </div>
        </div>
      </header>
      <main className="mx-auto max-w-6xl px-4 py-6">{children}</main>
    </div>
  );
}
