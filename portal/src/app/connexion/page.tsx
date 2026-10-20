import { redirect } from "next/navigation";
import { SignInForm } from "@/components/auth-forms";
import { signupAllowed } from "@/lib/auth";
import { getSession } from "@/lib/security";

export const dynamic = "force-dynamic";

export default async function Page() {
  if (await getSession()) redirect("/");
  return <SignInForm signupAllowed={signupAllowed} />;
}
