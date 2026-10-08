# Third-party notices

SHAR VR is built from other people's work. This is what ends up in the app you build, where it
comes from, and the license it keeps.

## In this repository

| Component | What it does here | License |
|---|---|---|
| [SMAA](https://github.com/iryoku/smaa) by Jorge Jimenez, Jose I. Echevarria, Belen Masia, Fernando Navarro and Diego Gutierrez | The SMAA anti-aliasing option. Its lookup tables and its shader, translated to Metal by `scripts/generate-smaa-msl.py`, are in `visionos/engine/code/vr/visionos/smaa/`. | MIT ([`smaa/LICENSE.txt`](visionos/engine/code/vr/visionos/smaa/LICENSE.txt)) |
| [Space Mono](https://github.com/googlefonts/spacemono) and [Roboto](https://github.com/googlefonts/roboto-classic) | The launcher's fonts, bundled in `visionos/TrevorbiltKit/Sources/TrevorbiltKit/Resources/Fonts/`. | SIL Open Font License 1.1 ([`OFL-SpaceMono.txt`](visionos/TrevorbiltKit/Sources/TrevorbiltKit/Resources/Fonts/OFL-SpaceMono.txt), [`OFL-Roboto.txt`](visionos/TrevorbiltKit/Sources/TrevorbiltKit/Resources/Fonts/OFL-Roboto.txt)) |

## Downloaded by the build

| Component | What it does here | License |
|---|---|---|
| [MoltenVK](https://github.com/KhronosGroup/MoltenVK) v1.4.2, by The Brenwill Workshop and the Khronos Group | Runs the game's Vulkan renderer on Metal. `scripts/fetch-moltenvk.sh` downloads its prebuilt static library and the Vulkan headers into `visionos/ThirdParty/`. | Apache 2.0 (its `LICENSE` is saved alongside) |

## Part of the upstream source the build clones

These come with [kote2345/The-Simpsons-Hit-and-Run-VR](https://github.com/kote2345/The-Simpsons-Hit-and-Run-VR)
under `libs/`, and are compiled into the app:

| Component | What it does here | License |
|---|---|---|
| [SDL](https://www.libsdl.org) 3.5 | The game's platform layer: threads, files, its gamepad plumbing. | zlib |
| [OpenAL Soft](https://openal-soft.org) | The game's 3D audio. | LGPL 2 |
| [FFmpeg](https://ffmpeg.org) 8.0 | Plays the game's Bink movies (only the Bink demuxer and decoders are built). | LGPL 2.1 or later |
| [libpng](http://www.libpng.org/pub/png/libpng.html) 1.0.3 | Loads PNG images. | libpng license |

OpenAL Soft and FFmpeg are linked statically. You build the app yourself from source, which keeps
the LGPL's relinking terms easy to meet; if you hand a build to anyone else, those terms apply to
you.

## From Apple's SDK

zlib and libarchive (which unpacks the game archive you import) are the system's own.

## The game

*The Simpsons: Hit & Run* was developed by Radical Entertainment and published in 2003 by Vivendi
Universal Games and Fox Interactive. *The Simpsons*, its characters and the game belong to their
respective rights holders. None of the game's files are included in this repository or produced by
its build: you supply your own.
