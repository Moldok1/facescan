# FaceScan — portail (Next.js 15 standalone + Prisma 7)
FROM node:22-bookworm-slim AS deps
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends openssl ca-certificates && rm -rf /var/lib/apt/lists/*
COPY package.json package-lock.json ./
RUN npm ci

FROM deps AS build
WORKDIR /app
COPY . .
ENV NEXT_TELEMETRY_DISABLED=1
RUN npx prisma generate && npm run build

# CLI Prisma seul (pour « migrate deploy » au démarrage), sans tout node_modules
FROM deps AS migrator
WORKDIR /migrator
COPY package.json /tmp/package.json
RUN npm init -y >/dev/null \
 && npm i --no-audit --no-fund prisma@$(node -p "require('/tmp/package.json').dependencies.prisma") dotenv \
 && npx prisma --version

FROM node:22-bookworm-slim AS run
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends openssl ca-certificates && rm -rf /var/lib/apt/lists/* \
 && useradd --uid 1001 --create-home facescan && mkdir -p /data/scans && chown -R facescan /data
ENV NODE_ENV=production NEXT_TELEMETRY_DISABLED=1 PORT=3000 HOSTNAME=0.0.0.0 STORAGE_DIR=/data/scans
# Application
COPY --from=build --chown=facescan /app/.next/standalone ./
COPY --from=build --chown=facescan /app/.next/static ./.next/static
COPY --from=build --chown=facescan /app/public ./public
# Outils de migration (CLI Prisma + schéma + migrations)
COPY --from=migrator --chown=facescan /migrator ./migrator
COPY --from=build --chown=facescan /app/prisma ./migrator/prisma
COPY --from=build --chown=facescan /app/prisma.config.ts ./migrator/
COPY --chown=facescan docker-entrypoint.sh ./
RUN chmod +x docker-entrypoint.sh
USER facescan
VOLUME ["/data"]
EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=5s --start-period=40s CMD node -e "fetch('http://127.0.0.1:3000/connexion').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"
ENTRYPOINT ["./docker-entrypoint.sh"]
