import { redirect } from "next/navigation";
import { SignUpForm } from "@/components/auth-forms";
import { signupAllowed } from "@/lib/auth";

export const dynamic = "force-dynamic";

export default function Page() {
  if (!signupAllowed) redirect("/connexion");
  return <SignUpForm />;
}
