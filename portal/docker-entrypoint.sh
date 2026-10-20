#!/bin/sh
set -e
echo "→ Migrations de la base de données"
(cd /app/migrator && node node_modules/prisma/build/index.js migrate deploy)
echo "→ Démarrage du portail"
exec node server.js
