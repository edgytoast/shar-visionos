# Working on SHAR VR

How the repository fits together, how to change the engine, and how to test without wearing the
headset every five minutes. [HOW-IT-WORKS.md](HOW-IT-WORKS.md) explains the design.

## What's where

```
patches/                          our changes to upstream's code, applied in filename order
patches/UPSTREAM_BASE             the upstream commit the patches are written against
scripts/build.sh                  everything below, in order, then the Xcode project
scripts/bootstrap.sh              clone upstream at UPSTREAM_BASE, apply the patches, link our runtime in
scripts/export-patch.sh           write the clone's changes back into patches/0002
scripts/common.sh                 where the clone lives, and the patch's exact diff (shared by the above)
scripts/fetch-moltenvk.sh         download MoltenVK's static libraries and headers
scripts/build-ffmpeg-visionos.sh  a Bink-only static FFmpeg, from upstream's copy of its source
scripts/build-engine-visionos.sh  the engine, as one static archive for the app to force-load
scripts/gen-mirror-materials.py   writes the Window view's materials (WindowFrame.usda)
scripts/generate-smaa-msl.py      translates SMAA's reference shader to Metal
scripts/make-app-icon.py          draws the app icon's three layers
scripts/make-hand-art.py          draws the bare-hand control diagrams (the Controls guide, the README, TrevorbiltKit's tintable hands)
visionos/App/                     the SwiftUI app (an xcodegen project.yml; the .xcodeproj is generated)
visionos/engine/code/vr/visionos/ the visionOS runtime, linked into the upstream clone as code/vr/visionos
visionos/TrevorbiltKit/            the launcher every Trevorbilt port shares (brand, mode cards, inputs, controller callouts, Ports, About), a local Swift package
```

The upstream engine never lives in this repository. `build.sh` clones it into `build/upstream`
(`SHAR_WORKING_TREE` picks somewhere else; if this folder's path has a space in it, it goes in
`~/Library/Developer/SHARVR/upstream`, since FFmpeg's build can't take one), checks out
`UPSTREAM_BASE`, applies the patches, and symlinks the visionOS runtime in, so edits to the runtime
land in this repository directly. After a `git pull` that changes the patches, `build.sh` moves an
unedited clone to them by itself.

## Changing the engine

Edit upstream's files in the clone, build, then write your changes back into the patch:

```bash
./scripts/export-patch.sh
```

Every engine change this project makes lives in `patches/0002-visionos-engine-build.patch`
(`0001` is only upstream's own `vcpkg.json`, for its PC build). `git diff` leaves out files git
doesn't track yet, so `git add -N <file>` any you add to upstream first. `build.sh` refuses to build
a clone with changes the patch doesn't have, so nobody ships an engine nobody else can build; while
you're mid-change, `SHAR_KEEP_TREE=1 ./scripts/build.sh` builds it as it is.

Changes in the patch that apply on every platform, not only visionOS, are marked as such in
HOW-IT-WORKS.md. The visionOS-only ones are behind `SRR2_OPENXR_PLATFORM_VISIONOS`, or
`RAD_VISIONOS` in the engine's older layers.

To move to a newer upstream: `./scripts/bootstrap.sh <dir> --head`, rebase the patches by hand where
they don't apply, and update `UPSTREAM_BASE`.

## Building the pieces yourself

`build.sh` runs these; each can be run on its own:

```bash
./scripts/fetch-moltenvk.sh
./scripts/build-ffmpeg-visionos.sh build/upstream device      # or simulator
./scripts/build-engine-visionos.sh build/upstream device      # or simulator
(cd visionos/App && xcodegen generate)
```

(With the clone somewhere else, give its path instead of `build/upstream`.) The engine lands in
`build/upstream/build/visionos-device/libshar_engine.a` (or `visionos-simulator`). Xcode reads where from `visionos/App/Engine.xcconfig`, which `build.sh`
writes; set `SHAR_WORKING_TREE` in `Local.xcconfig` if you build by hand somewhere else.

From the command line, without signing:

```bash
cd visionos/App
xcodebuild -project SHARVR.xcodeproj -scheme SHARVR -sdk xros CODE_SIGNING_ALLOWED=NO build
```

## Reading the logs

What the runtime logs starts with `[SharVisionOS]` or `visionOS:` (the engine) or `[SHARVR]` (the
app), so Console or Xcode's filter finds it. Every five seconds there's a stats line: frame rate, how long
frames take and how late they are, and memory with the headroom left before visionOS's limit. The
Window view adds its own `mirror:` lines: draws, entities, materials, and anything waiting or
failed.

## Testing in the Simulator

The Simulator runs the whole game, which makes it good for menus, flow, crashes and memory, and
bad at judging how anything looks (below). These environment variables, set through `simctl`'s
`SIMCTL_CHILD_` prefix, drive it without a person. They exist only in Simulator builds
(`TestHooks.swift`, and `TARGET_OS_SIMULATOR` in the engine), so an app installed on a headset ignores
them; `SHAR_PRESENT_EVENT`, the launcher's toggle, is the one that works everywhere.

| Variable | What it does |
|---|---|
| `SHAR_IMPORT_PATH=<path on the Mac>` | Imports the game from that archive or folder without the picker (Simulator apps can read the Mac's files). |
| `SHAR_AUTO_PLAY=1` | Presses Play (after an import, as soon as it lands). |
| `SHAR_ARGS="skipfe skipmovie"` | Passes upstream's command-line options. `skipfe` goes straight into level 1 after the language screen. |
| `SHAR_TEST_PRESSES="A@5 A@30 RT@40~5"` | Presses gamepad buttons that many seconds in: `A B X Y MENU`, `LT RT`, `LG RG` (grips), or `UP DOWN LEFT RIGHT` on the left stick. A press lasts a quarter second, or `~seconds`. They go through the gamepad the Simulator provides. |
| `SHAR_TEST_EVENTS="break:19@55 coins:5@58"` | Plays a breakable by the player (IDs in upstream's `code/constants/breakablesenum.h`: 19 is Krusty glass, 24 a car explosion) or drops coins, that many seconds in. Also `scale:50@40` (Render Scale), `aa:1@40` (Anti-Aliasing), `view:2@40` (View) and `turn:90@40` (turns the view right, as a Digital Crown recentre would). Times count from the game's first frame. |
| `SHAR_PRESENT_EVENT=1` | The launcher's "Pace frames on the GPU". |
| `SHAR_TEST_WINDOW_TILT=25` | Turns the Window view's content 25 degrees, to see its depth from the side without moving the Simulator's camera. |
| `SHAR_TEST_CONTROLS=sense,driving` | Shows that page of the Controls guide: `hands`, `sense` or `gamepad`, plus `window` for the Window view's buttons and `driving` for the driving controls, on the launcher's Controls tab. |
| `SHAR_TEST_FEED=<path on the Mac>` | The Ports tab reads the AVP Ports Index's list from that file instead of the network (a draft feed with pictures, say, or one with a wrong SHA-256). |
| `SHAR_TEST_OFFLINE=1` | Every Ports picture download fails as it would offline (clear the app's Caches first to see the cards without pictures). |
| `SHAR_TEST_HANDS=kit` | The Controls guide's Hands page draws TrevorbiltKit's hands, as any other port shows them: each hand a skin tone from Crayola's Colors of the World set, picked at random each time the page appears, instead of SHAR's yellow ones. |
| `SHAR_TEST_PAD=none` | The Controls guide draws as if no gamepad (`none`: the DualSense kind) or an Xbox-kind pad (`xbox`) were connected, with the neutral symbols. The Simulator always has its own pad. |
| `SHAR_TEST_SHEET=manage` | Opens that sheet: `manage` or `advanced` (Play), `credits` or `diagnostics` (About), `port:<index id>` (Ports). Use with `SHAR_TEST_TAB`. |
| `SHAR_TEST_TAB=play` | Opens the launcher on that tab (`play`, `controls`, `ports` or `about`). |
| `SHAR_TEST_INPUTS=hands:denied,sense:none,gamepad:none` | Shows the launcher's inputs as given instead of what's there (hands, and `accessories` for the Sense controllers' tracking: `allowed`, `denied`, `notasked` or `unavailable`, allowed if only the other is given (with neither, the real permissions are read); sense: `none`, `L`, `R` or `LR`; gamepad: `none` or `yes`), to check what it says for each. The Controls guide still reads the real controllers. |
| `SHAR_TEST_WINDOW_HIDE=40~10` | Puts the Window view in the background 40 seconds after it opens, for 10 seconds, as leaving it would: the game holds (no frames, sound paused) and comes back on its pause menu. |
| `SHAR_TEST_WINDOW_RELIEF=1` | Shows the Window view's older depth-relief picture instead of the scene mirror (`SHAR_TEST_WINDOW_LAYERS=pb` picks its layers). |
| `SHAR_TEST_LAUNCHER_BESIDE=1` | Opens the launcher beside the Window view's window, 3 seconds after the window shows, as a look at the controls would. With `view:` events, shows what a move to Full or Progressive does with it. |

For example:

```bash
xcrun simctl install booted "<DerivedData>/Build/Products/Debug-xrsimulator/SHARVR.app"
SIMCTL_CHILD_SHAR_AUTO_PLAY=1 SIMCTL_CHILD_SHAR_ARGS="skipfe skipmovie" \
  xcrun simctl launch --console-pty booted <your bundle identifier>
xcrun simctl io booted screenshot shot.png
```

The game files have to be in the app's Documents folder first: `SHAR_IMPORT_PATH` once, or copy
them into `$(xcrun simctl get_app_container booted <bundle id> data)/Documents`. Synthesized taps
don't reach visionOS Simulator windows; the variables above are the way in.

To keep test runs away from other Simulators, use a device set of your own:
`xcrun simctl --set ~/Library/Developer/CoreSimulator/MySet create|boot|install|launch ...`. The
default set's `booted` never sees it.

### What the Simulator can't tell you

- Its GPU isn't the headset's (Apple family 2, read-write texture tier 1, against the Vision Pro's
  family 8 and tier 2). It can't render layered attachments, so the engine renders each eye
  separately there, and MoltenVK's Metal argument buffers don't write storage images there, so
  Simulator builds turn them off (`MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS=0`).
- It's mono, doesn't reproject, and doesn't need depth: a frame with no depth, which the headset
  shows as nothing at all, looks fine in the Simulator.
- In the Simulator, the right eye's HDR resolve comes after the game's mid-eye depth clear, so its
  volumetric light treats every pixel as far away and hazes the picture. Compare against the left
  eye (the immersive view), or turn Volumetric Light off.
- Its frame rates aren't the headset's: its RealityKit snaps between 90 and 45 Hz near its limit.
- It renders in step with the app, so it never shows a frame drawn between two updates. The
  headset's renderer runs on its own clock and does.

When something only happens on the headset, the logs are how you find it.
