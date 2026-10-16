# AbelNotes Flatpak repository

Signed Flatpak repository for [AbelNotes](https://github.com/abelnotes/abelnotes),
served from GitHub Pages until the app is on Flathub.

**Install:** <https://abelnotes.github.io/flatpak/> — one click adds this
repository, and updates then arrive through GNOME Software, KDE Discover or
`flatpak update`.

```sh
flatpak install --user https://abelnotes.github.io/flatpak/abelnotes.flatpakref
```

## How it is built

`.github/workflows/publish.yml` runs daily. When a newer AbelNotes release is
published on GitHub, `ci/build.sh` builds it from the tagged source in the
Flathub CI container, offline and sandboxed:

1. takes the packaging (`flatpak/` in the app repository) from the release
   tag, pins its manifest template to that tag and regenerates the offline
   sources with [flatpak-flutter](https://github.com/TheAppgineer/flatpak-flutter);
2. adds a `<release>` entry to the metainfo from the GitHub release notes;
3. builds with `flatpak-builder --sandbox` and signs the OSTree repository;
4. writes `abelnotes.flatpakref`, `abelnotes.flatpakrepo` and a single-file
   `abelnotes.flatpak`, scans everything for leaked local paths, and publishes
   the site.

The repository is signed with key `470F B712 EAA3 383E BE73 7959 D5C0 72DD 570C 9170`;
the build refuses to sign with any other.

This repository holds only the pipeline; the manifest, metainfo and the notes
on why each module and permission exists are in the app repository under
`flatpak/`, so a packaging change ships with the release that needs it.
Runtime: `org.freedesktop.Platform` 25.08.
