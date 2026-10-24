import type { Metadata } from "next";
import { PairingRedirect } from "./pairing-redirect";

export const metadata: Metadata = { title: "Appairer l'iPhone · FaceScan", robots: { index: false } };

export default function Page() {
  return <PairingRedirect />;
}
