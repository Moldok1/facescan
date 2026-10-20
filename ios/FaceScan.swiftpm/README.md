# FaceScan — scanner facial 3D sur iPhone (TrueDepth)

Application iOS qui scanne le visage d'un patient avec la caméra Face ID de l'iPhone
et produit :

- **`<id>_<type>.stl`** — géométrie seule, en millimètres (planification, CFAO) ;
- **`<id>_<type>_couleur.ply`** — géométrie + couleur par sommet + normales (exocad, Blue Sky Plan, Meshmixer, MeshLab) ;
- **`<id>_<type>_couleur.obj`** — géométrie + couleur par sommet (format « v x y z r g b »).

Repère des fichiers : **x = gauche du patient, y = haut, z = antérieur**, unités **mm**.
Les scans sont stockés dans l'application. Ils ne quittent l'iPhone que par un envoi
vers le portail du cabinet (jeton propre à l'appareil) ou un partage manuel (AirDrop, Fichiers).

> ⚠️ Prototype non marqué CE. Il ne doit pas servir à une décision thérapeutique avant
> la validation décrite plus bas.

---

## 1. Installation

Sans Mac : voir le README à la racine du dépôt. GitHub compile l'application et Sideloadly l'installe depuis un PC Windows.

Avec un Mac (variante) : ouvrir ce dossier `FaceScan.swiftpm` dans Xcode 15/16, choisir votre *Team* dans *Signing & Capabilities*, passer le schéma en **Release** et lancer sur l'iPhone. Dans cette variante, l'appairage par QR code n'est pas disponible : saisir l'adresse et le jeton dans FaceScan › Portail.

Le scan exige un **trépied ou un support** : l'iPhone reste fixe, c'est le patient qui tourne la tête.

## 2. Protocole de capture

1. iPhone sur trépied, en portrait, **écran face au patient**, à hauteur des yeux, **30 cm**.
2. Lumière diffuse et homogène (pas de fenêtre derrière le patient, pas de spot direct).
3. Cheveux dégagés (front, oreilles), lunettes et boucles d'oreille retirées.
4. Saisir un **identifiant pseudonymisé** (pas le nom), choisir le type : Repos, Sourire,
   Écarteurs…
5. Appuyer sur **Démarrer**. Le patient suit la voix et les flèches :
   - regarder l'écran (≈ 1 s) ;
   - tourner lentement la tête d'un côté (~30°) ;
   - puis de l'autre côté ;
   - revenir au centre et lever légèrement le menton.

   Le scan se termine seul (≈ 10–15 s). Le bouton *Étape suivante* force le passage à
   l'étape suivante, *Terminer* arrête la capture à tout moment.
6. **Le patient doit garder exactement la même expression** pendant tout le scan
   (le « verrou d'expression » rejette les images où la bouche ou les joues bougent).
7. Vérifier l'aperçu 3D, puis **Envoyer au portail** (ou *Partager* › AirDrop vers le poste de CFAO).

Indicateurs à l'écran :

- **Distance** (vert entre 25 et 40 cm) ;
- **Écart suivi/profondeur** : cohérence entre la position estimée de la tête et la mesure
  de profondeur. Vert < 4 mm, normal jusqu'à 6–8 mm (le modèle de suivi d'ARKit est
  générique, il n'épouse pas exactement le visage). Les images au-delà de 12 mm sont rejetées ;
- **Couverture** : barres vertes = angle suffisamment couvert.

Série conseillée pour une réhabilitation implantaire :
**Repos** → **Sourire forcé** → **Écarteurs** (dents visibles, pour le recalage avec l'empreinte optique).

## 3. Utilisation dans la CFAO

- **exocad / Smile Creator** : importer le PLY (couleur par sommet) ou l'OBJ comme scan
  facial, puis aligner sur l'empreinte intra-orale par points sur les dents du scan
  *Écarteurs*. Le scan *Sourire* s'aligne ensuite sur le scan *Écarteurs* par la partie
  haute du visage (front, nez), qui ne bouge pas.
- **Blue Sky Plan, 3Shape, Meshmixer, MeshLab** : importer le PLY.
- Si un logiciel exige un OBJ **avec texture** (fichier image + MTL), voir « Évolutions ».

## 4. Validation OBLIGATOIRE avant tout usage clinique

1. **Test du miroir (gauche/droite)** : coller une gommette épaisse (ou un petit bouchon)
   sur la **joue droite** d'un volontaire, scanner, ouvrir le fichier dans MeshLab en vue
   de face. La gommette doit apparaître du côté **droit du patient = côté x négatif**
   (à gauche de l'écran en vue de face). Si elle est inversée, ne pas utiliser l'app.
2. **Précision dimensionnelle** : scanner un objet de dimensions connues (tête imprimée en
   3D, ou une boîte rigide de 100 × 80 × 60 mm posée sur un support à hauteur de visage) et
   comparer les cotes mesurées (MeshLab : outil de mesure). Objectif : erreur < 0,5–1 mm.
3. **Reproductibilité** : 5 scans du même volontaire, alignement dans CloudCompare
   (« Fine registration ICP »), écart moyen entre scans. Objectif : < 0,5 mm sur la
   zone péri-orale.
4. Idéalement, comparaison avec un scanner de référence (MetiSmile, RayFace, Artec) chez
   un confrère.

## 5. Comment ça marche

```
TrueDepth (profondeur 640×480, ~15 i/s) + caméra couleur + suivi du visage ARKit
        │  pour chaque image : contrôles distance / vitesse / expression / cohérence
        ▼
Fusion volumétrique TSDF sur le GPU (Metal) dans le repère du visage
        │  (voxels de 1 mm ou 0,75 mm, moyenne de toutes les vues)
        ▼
Extraction de surface « Surface Nets » → plus grande composante → lissage de Taubin
        ▼
Export STL / PLY / OBJ en millimètres
```

Fichiers du projet :

| Dossier | Contenu |
|---|---|
| `Capture/` | Session ARKit, protocole guidé, filtres qualité (`ScanController.swift`) |
| `Reconstruction/` | Fusion TSDF Metal, Surface Nets, nettoyage du maillage |
| `Export/` | Écriture STL, PLY, OBJ ; relecture PLY |
| `Portal/` | Appairage, trousseau, envoi vers le portail |
| `UI/` | Écrans SwiftUI, aperçu 3D SceneKit |

## 6. Limites connues

- La précision dépend du suivi de la tête par ARKit : attendre **0,5 à 1 mm** sur le
  visage, moins bien sur les oreilles et sous le menton.
- La couleur est stockée par sommet (≈ 1 point par mm) : suffisant pour la présentation
  au patient et le repérage, moins fin qu'une vraie texture photo.
- Les zones sombres ou brillantes (barbe, cheveux, lunettes) sont mal mesurées par le capteur.

## 7. Évolutions prévues

1. Recalage fin de chaque image par ICP (sans s'appuyer uniquement sur ARKit) pour gagner en précision.
2. Export OBJ texturé (atlas photo haute résolution + MTL) pour exocad Smile Creator.
3. Alignement automatique scan *Écarteurs* ↔ empreinte intra-orale.
