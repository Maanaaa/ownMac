# OwnMac

App légère de barre de menus pour personnaliser macOS (SwiftUI, design Liquid Glass).

- Réglages Dock, Finder (dont icônes du bureau), captures d'écran via `defaults`
- Historique du presse-papier (texte, en mémoire, ignore les contenus confidentiels)
- Lancement à la connexion
- Verrouillage si inactif et absent (webcam brève), presse-papier protégé par Touch ID
- Stats système en direct
- Dynamic Island sur l'encoche (pastille sur les écrans sans encoche) : musique, minuteur, copies, vérification de présence, alertes de surchauffe et de surcharge avec le processus responsable, chargeur et batterie
- Étagère dans l'encoche : glisse des fichiers vers le haut de l'écran pour les reprendre ailleurs
- Écran de bienvenue et vérification optionnelle des mises à jour

## Télécharger

[Site](https://maanaaa.github.io/ownMac/) · [Dernière version](https://github.com/Maanaaa/ownMac/releases/latest)

Nécessite macOS 26 ou plus récent et un Mac Apple Silicon. L'app n'est pas notariée : au premier lancement, autorise-la dans Réglages Système > Confidentialité et sécurité > Ouvrir quand même.

## Compiler

```
./build.sh             # compile, installe dans ~/Applications et crée OwnMac.zip dans ~/Library/Caches/OwnMac-build
./build.sh --release   # crée seulement le zip à publier, sans toucher à l'app installée
```

## Licence

[MIT](LICENSE). OwnMac est un projet indépendant, sans lien avec Apple.
