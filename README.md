# FaceScan · ALTIORE

Scanner facial 3D low-cost pour la réhabilitation implantaire. Il remplace un MetiSmile ou un RayFace par :

- **`ios/`** : une application iPhone qui scanne le visage avec la caméra Face ID (TrueDepth) et produit un STL, un PLY couleur et un OBJ couleur, en millimètres ;
- **`portal/`** : un portail web (Next.js 15, Prisma/PostgreSQL, BetterAuth, shadcn/ui) qui reçoit les scans, les range par patient, les affiche en 3D et permet de les télécharger pour la CFAO.

```
iPhone (FaceScan) ──HTTPS + jeton──▶ Portail (Coolify) ──▶ PostgreSQL + fichiers chiffrés (/data)
                                            │
                                            └──▶ navigateur des PC du cabinet : visionneuse 3D, STL/PLY/OBJ pour exocad
```

Aucun Mac n'est nécessaire : GitHub compile l'application iPhone, et on l'installe depuis un PC Windows.

---

## 1. Installer l'application sur l'iPhone (depuis un PC)

**Prérequis :** un iPhone avec Face ID, un PC Windows et un câble USB.

1. **Récupérer l'application compilée.** Sur GitHub, ouvrir le dépôt `facescan` › **Releases** › **FaceScan (dernière version)** › télécharger `FaceScan.ipa`.
   Chaque modification du dossier `ios/` relance automatiquement la compilation (onglet **Actions**, environ 5 minutes).
2. **Installer iTunes pour Windows,** dans sa version du site d'Apple et non celle du Microsoft Store. Il fournit les pilotes USB de l'iPhone.
3. **Installer Sideloadly** (gratuit) depuis sideloadly.io.
4. Brancher l'iPhone et le **déverrouiller**. Répondre « Faire confiance » sur l'iPhone.
5. Dans Sideloadly :
   - glisser `FaceScan.ipa` ;
   - saisir votre **identifiant Apple** (un compte gratuit suffit) ;
   - cliquer sur **Start**, puis saisir le code de double authentification si Apple le demande.
6. Sur l'iPhone :
   - *Réglages › Confidentialité et sécurité › Mode développeur* : activer, puis redémarrer ;
   - *Réglages › Général › VPN et gestion de l'appareil* : faire confiance à votre identifiant Apple.
7. Ouvrir **FaceScan**.

> **Compte Apple gratuit :** l'application expire au bout de **7 jours**. Il suffit alors de rebrancher l'iPhone et de cliquer à nouveau sur *Start* dans Sideloadly, ce qui conserve les scans.
> **Compte Apple Developer (99 €/an) :** validité d'un an, et distribution possible par TestFlight sur tous les iPhone du cabinet, sans câble.

## 2. Déployer le portail sur Coolify (VPS Hostinger)

1. **DNS.** Chez Hostinger, créer un enregistrement **A** `facescan` → `72.62.90.243`, pour obtenir `facescan.altioresante.cloud`.
2. **Base de données.** Dans Coolify : *+ New › Database › PostgreSQL 16*. La démarrer et copier l'**URL interne** (« Postgres URL (internal) »).
3. **Application.** Dans Coolify : *+ New › Application › GitHub (private repository)*, puis choisir `Moldok1/facescan`, branche `main` :
   - **Build Pack** : `Dockerfile`
   - **Base Directory** : `/portal`
   - **Port** : `3000`
   - **Domaine** : `https://facescan.altioresante.cloud`. Coolify obtient le certificat HTTPS tout seul.
4. **Stockage persistant.** Dans l'application, onglet *Storages* : ajouter un volume monté sur **`/data`**. Il contient les fichiers 3D ; sans ce volume, ils seraient perdus à chaque redéploiement.
5. **Variables d'environnement** (modèle dans `portal/.env.example`) :

   | Variable | Valeur |
   |---|---|
   | `DATABASE_URL` | URL interne de la base de l'étape 2 |
   | `BETTER_AUTH_SECRET` | `openssl rand -base64 32` (ou une longue chaîne aléatoire) |
   | `BETTER_AUTH_URL` | `https://facescan.altioresante.cloud` |
   | `ALLOW_SIGNUP` | `true` au départ, puis `false` |
   | `STORAGE_ENCRYPTION_KEY` | `openssl rand -base64 32`. **À conserver précieusement** : sans elle, les fichiers sont illisibles |
   | `N8N_WEBHOOK_URL` | Optionnel : webhook n8n appelé à chaque nouveau scan |

6. **Déployer.** Au démarrage, le conteneur applique lui-même les migrations de la base.
7. Ouvrir le portail, *Créer un compte* pour vous et l'équipe, puis passer `ALLOW_SIGNUP` à `false` et **redéployer**.

**Sauvegardes :** activer les sauvegardes planifiées de la base dans Coolify, et sauvegarder le volume `/data` ainsi que la clé `STORAGE_ENCRYPTION_KEY`.

## 3. Appairer l'iPhone au portail

1. Sur un PC : portail › **Réglages** › nom de l'appareil (ex. « iPhone salle 3 ») › **Créer un jeton**. Un QR code s'affiche.
2. Sur l'iPhone : viser le QR code avec l'**appareil photo**, puis toucher la bannière « Ouvrir dans FaceScan ». L'application confirme l'appairage.
3. Dans FaceScan › **Portail** : *Tester la connexion*, puis activer si besoin l'**envoi automatique** après chaque scan.

Si le QR code ne fonctionne pas, on peut saisir l'adresse et le jeton à la main dans FaceScan › Portail › Saisie manuelle. Un jeton se révoque à tout moment dans les réglages du portail, par exemple en cas de perte de l'iPhone.

## 4. Utilisation au quotidien

1. Dans FaceScan, saisir ou rechercher l'identifiant du patient (🔍 interroge le portail), puis choisir le type de scan.
2. Scanner. Le protocole et les contrôles qualité sont décrits dans `ios/FaceScan.swiftpm/README.md`.
3. Le scan part vers le portail, automatiquement ou avec **Envoyer au portail**.
4. Sur un PC du cabinet : portail › patient › scan. La page affiche la visionneuse 3D (vues, mesure en mm) et propose le téléchargement des fichiers **STL / PLY / OBJ** pour exocad.

## 5. Sécurité et données

- Le portail est accessible uniquement après connexion, avec des sessions de 12 h et des inscriptions fermées après la création des comptes.
- L'iPhone s'authentifie par un jeton propre à chaque appareil. Le portail ne stocke que l'empreinte SHA-256 du jeton.
- Les fichiers 3D sont chiffrés au repos en AES-256-GCM, à condition que `STORAGE_ENCRYPTION_KEY` soit défini.
- Un **journal d'audit** trace chaque scan reçu, consulté, téléchargé, modifié ou supprimé.
- Hébergement : le VPS Hostinger n'est **pas certifié HDS**. Ce choix a été fait en connaissance de cause. Pour un usage en production, migrer vers un hébergeur HDS ne demande que de changer la cible Coolify.

## 6. Développement

```bash
cd portal
cp .env.example .env        # renseigner une base PostgreSQL locale
npm install
npx prisma migrate deploy
npm run dev
```

Les workflows GitHub Actions :

- `.github/workflows/ios.yml` : compile l'application iPhone sur un Mac de GitHub et publie le `.ipa` ;
- `.github/workflows/portal.yml` : applique les migrations, vérifie qu'elles correspondent au schéma, puis construit le portail et son image Docker.
