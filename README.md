# 🎵 Musync

Musync est un lecteur de musique local pour Android/desktop, avec gestion et
synchronisation des paroles. Développé en Flutter/Dart.

## Fonctionnalités

- **Bibliothèque locale** — scan de la musique de l'appareil (MediaStore)
- **Lecture audio** — lecture en arrière-plan avec intégration au lockscreen
  et à la notification média
- **Paroles synchronisées** — recherche de paroles via l'API LRCLIB,
  affichage synchronisé pendant la lecture
- **Éditeur de synchronisation** — ajustement manuel du timing des paroles
- **Tags ID3** — lecture/écriture des métadonnées audio, avec support des
  tags SYLT/USLT pour les paroles synchronisées
- **Thème Material You** — couleurs dynamiques dérivées du fond d'écran
  (Android 12+)

## Stack technique

- **State management** : Riverpod
- **Audio** : just_audio, audio_service, just_audio_background
- **Scan musical** : on_audio_query
- **Réseau** : http (API LRCLIB)

## Structure du projet

```
lib/
├── core/
│   ├── id3/       # Lecture/écriture des tags ID3, parsing LRC
│   ├── router/    # Navigation
│   ├── services/  # Permissions, etc.
│   └── theme/     # Thème Material You
└── features/
    ├── library/       # Bibliothèque musicale
    ├── player/        # Lecteur audio
    ├── lyrics/        # Recherche de paroles
    └── sync_editor/   # Éditeur de synchronisation
```

## Démarrage

```bash
flutter pub get
flutter run
```

Un projet [Flutter](https://flutter.dev) — voir la
[documentation officielle](https://docs.flutter.dev/) pour plus d'infos sur
l'environnement de développement.
