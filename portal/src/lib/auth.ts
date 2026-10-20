import { betterAuth } from "better-auth";
import { prismaAdapter } from "better-auth/adapters/prisma";
import { nextCookies } from "better-auth/next-js";
import { prisma } from "@/lib/prisma";

/**
 * Authentification par e-mail + mot de passe.
 * Les inscriptions sont fermées par défaut : ALLOW_SIGNUP=true le temps de créer
 * les comptes de l'équipe, puis repasser à false et redéployer.
 */
export const signupAllowed = process.env.ALLOW_SIGNUP === "true";

export const auth = betterAuth({
  appName: "FaceScan ALTIORE",
  database: prismaAdapter(prisma, { provider: "postgresql" }),
  emailAndPassword: {
    enabled: true,
    disableSignUp: !signupAllowed,
    minPasswordLength: 10,
  },
  session: {
    expiresIn: 60 * 60 * 12, // 12 h
    updateAge: 60 * 60,
  },
  rateLimit: { enabled: true, window: 60, max: 30 },
  plugins: [nextCookies()],
});
