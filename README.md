# OwnMac

App légère de barre de menus pour personnaliser macOS (SwiftUI, design Liquid Glass).

- Réglages Dock, Finder (dont icônes du bureau), captures d'écran via `defaults`
- Historique du presse-papier (texte, en mémoire, ignore les contenus confidentiels)
- Lancement à la connexion
- Verrouillage si inactif et absent (webcam brève), presse-papier protégé par Touch ID
- Stats système en direct
- Dynamic Island sur l'encoche (pastille sur les écrans sans encoche) : musique, minuteur, copies, vérification de présence, alertes de surchauffe et de surcharge avec le processus responsable

## Build
```
./build.sh   # compile, assemble OwnMac.app et l'installe dans ~/Applications
```
Nécessite macOS 26+ et les outils Swift.
