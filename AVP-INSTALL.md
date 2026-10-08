# Installing SHAR VR on Apple Vision Pro

SHAR VR is [Trevorbilt](https://trevorbilt.com)'s native visionOS port, built on
[kote2345's VR mod](https://github.com/kote2345/The-Simpsons-Hit-and-Run-VR); the
[README](README.md#credits) credits everyone it builds on.

*The Simpsons: Hit & Run* runs natively on Apple Vision Pro once you build this project with Xcode
and install it on your own headset. There's no ready-made app to download, and none of the game's
files are here: you bring your own copy of the game.

## Requirements

- **Apple Vision Pro** on visionOS 26 or later.
- **A Mac with Apple silicon** and **Xcode 27** (built and tested with Xcode 27.0). Open Xcode once
  so it finishes installing, then add its visionOS platform in Xcode › Settings › Components.
- **An Apple Account** signed in to Xcode (Xcode › Settings › Accounts). A free account works, but
  apps it signs stop opening after 7 days until you install them again.
- **Homebrew** ([brew.sh](https://brew.sh)) and four tools from it:

  ```bash
  brew install cmake ninja pkgconf xcodegen
  ```

- **About 5 GB of free disk space.** The first build takes 10 to 20 minutes.
- **A controller is recommended:** PS VR2 Sense controllers, or a DualSense, Xbox or other gamepad.
  Without one, the Full and Progressive views play with your bare hands; the Window view needs a
  controller.

## Game Files

You supply the game's files yourself; this repository contains none, and the build never downloads
any of them.

1. **Install your PC copy** of *The Simpsons: Hit & Run* (2003), without mods.
2. **Find its install folder.** It's the one with the `art`, `movies`, `scripts` and `sound` folders
   next to the game's `.rcf` files (about ten, such as `scripts.rcf`, `dialog.rcf`, `music00.rcf`
   and `soundfx.rcf`), along with `Simpsons.exe`. If those are there, it's the right folder.
3. **Get it ready to move.** The files go onto the headset after the app is installed (the last
   section below). If you'll AirDrop them, zip that folder on your Mac now (RAR and 7z work too).

## Get the code

If you came from the AVP Ports Index and already cloned the commit it lists, skip this step and
build from that folder.

```bash
git clone https://github.com/edgytoast/shar-visionos.git shar-visionos
cd shar-visionos
```

## Build

From the project's folder:

```bash
./scripts/build.sh
```

Here's everything it does on your Mac. It never uses `sudo`, and apart from temporary files (and a
compiler cache, if you've installed ccache) it writes only inside this folder, or in
`~/Library/Developer/SHARVR` if this folder's path has a space in it:

1. **Checks** for Apple silicon, Xcode's visionOS SDK and the four Homebrew tools, and says what's
   missing.
2. **Clones the upstream VR mod** from [kote2345/The-Simpsons-Hit-and-Run-VR](https://github.com/kote2345/The-Simpsons-Hit-and-Run-VR)
   into `build/upstream`, checks out the exact commit named in `patches/UPSTREAM_BASE`, and applies
   this project's changes from `patches/`. Pushing from that clone is switched off. If this folder's
   path has a space in it, the clone goes in `~/Library/Developer/SHARVR` instead, because FFmpeg's
   build can't handle a space.
3. **Downloads MoltenVK** v1.4.2 from [KhronosGroup's GitHub releases](https://github.com/KhronosGroup/MoltenVK/releases/tag/v1.4.2)
   and checks it against its SHA-256 (in `scripts/fetch-moltenvk.sh`) before using it.
4. **Builds FFmpeg** (only its decoder for the game's Bink movies) from the copy that comes with the
   upstream code, **then the game's engine**. Their logs go in `build/upstream/build/logs/`.
5. **Generates the Xcode project** and sets up signing. If you're signed in to Xcode with one team,
   it reads that team's ID from Xcode's own settings and writes it to
   `visionos/App/Local.xcconfig`; nothing leaves your Mac. If you're in several teams, it lists them:
   copy `visionos/App/Local.xcconfig.example` to `visionos/App/Local.xcconfig` and put the one to use
   in it.

## Install on Apple Vision Pro

1. **Connect the headset.** If you haven't run your own apps on it before, pair it with Xcode
   (Window › Devices and Simulators) and turn on Developer Mode on the headset (Settings › Privacy &
   Security › Developer Mode).
2. **Run the app.** Open `visionos/App/SHARVR.xcodeproj`, choose your Apple Vision Pro as the run
   destination, and press ⌘R.
3. **Trust it, with a free Apple Account.** The headset won't open the app until you trust your
   developer certificate: Settings › General › VPN & Device Management.
4. **Add your game files**, any one of these ways:
   - AirDrop the zipped folder to your Vision Pro and choose **SHAR VR** from the apps to open it
     with. The app unpacks it, installs it, and deletes the AirDropped copy.
   - Put the archive or folder anywhere Files can reach, then tap **Import game files** in SHAR VR
     (once a copy is in, it's under **Manage**).
   - Copy what's inside the game folder (`art`, the `.rcf` files and the rest) straight into SHAR
     VR's own folder in Files (On My Apple Vision Pro › SHAR VR).
5. **Play.** Pick a view (Full, Progressive or Window) and tap **Play**.

To update later: pull the new code (`git pull`), run `./scripts/build.sh` again, and run the app from
Xcode. Your game files and saves stay on the headset.

## Controls and known issues

- **Full and Progressive:** PS VR2 Sense controllers and gamepads use the VR mod's layout, and the
  game's tutorials name the buttons on whatever you're holding. Swing a tracked hand to attack. With
  no controller connected, your bare hands play: pinches are the buttons and a held pinch, moved,
  walks and turns. The launcher's **Controls** tab shows every control, with drawings of the
  hand gestures; the [README](README.md#play) has them too.
- **Window:** it plays like the original game, so it needs a controller and takes the original
  layout: A jumps, B sprints, X attacks, Y talks and gets in and out of cars, and when you're
  driving, the right trigger is gas and the left one brakes. Look at the game window to give it
  your controller: visionOS sends a controller's input to the window you're looking at (SHAR VR's
  own launcher leaves it with the game).
- **Settings:** the game's VR menu has View (switch between Full, Progressive and Window, even
  mid-game) and Move Direction; its Graphics menu has Anti-Aliasing and Render Scale.

Known issues:

- The Window view recreates the game's scene in visionOS's own renderer, so it has no sun shadows
  and no distant haze, and blob shadows sit just off the ground.
- "Pace frames on the GPU", under the launcher's Advanced, is experimental. If Full or Progressive ever shows
  nothing, quit the app, open it again, and turn it off before pressing Play.
- Apps signed with a free Apple Account stop opening after 7 days. Run it from Xcode again; your
  game files and saves stay.

Troubleshooting is in the [README](README.md#if-something-goes-sideways).
