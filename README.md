<p align="center"><img src="docs/banner.svg" alt="Biometric Info" width="820"></p>

# Biometric Info

Application de bureau (Windows / macOS) qui lit la puce d'un document d'identité électronique (carte d'identité, passeport — eMRTD ICAO 9303) et imprime ses informations sur une feuille A4.

## Fonctions

- **Scan MRZ** : un clic sur « Scanner la carte », puis passer la zone MRZ du document sous la **douchette**. Le n° de document et les deux dates sont remplis, et la lecture de la puce démarre seule.
- **Saisie manuelle** possible si aucun scanner n'est branché.
- **Lecture de la puce** sur un lecteur sans contact (Identiv uTrust, ACS ACR1281 ou tout lecteur PC/SC) : BAC + secure messaging, DG1 (identité), DG2 (photo), DG7 (signature) et données nationales.
- **Affichage** : photo et signature en plein écran, téléchargement en un clic dans « Téléchargements », drapeaux et noms des pays.
- **Impression A4** (PDF) en français, anglais ou arabe.
- Interface **FR / EN / AR**, pensée pour écran tactile.

## Installation (Windows)

1. Ouvrir l'onglet **Releases** du dépôt et télécharger `BiometricInfo-windows-x64.zip`.
2. Décompresser le dossier et lancer `biometric_info.exe`.
3. Brancher le lecteur de carte (pilote PC/SC) et la douchette.

## Développement

```bash
flutter pub get
flutter test
flutter run -d macos     # ou -d windows
```

| Dossier | Contenu |
|---|---|
| `lib/chip/` | PC/SC, BAC, secure messaging, lecture des DG |
| `lib/mrz/` | Parseur MRZ, popup de scan douchette |
| `lib/main.dart` | Écran, affichage et impression |

## Publier une version

Chaque push sur `main` compile l'exe Windows sur GitHub Actions (artefact du workflow). Pour une release :

```bash
git tag v1.1.0 && git push origin v1.1.0
```

Le workflow **Windows build** publie alors `BiometricInfo-windows-x64.zip` dans la section Releases.
