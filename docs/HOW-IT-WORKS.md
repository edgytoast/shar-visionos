# How SHAR VR works

The short version: the game's own engine runs on its own thread inside a SwiftUI app, renders with
its own Vulkan renderer through MoltenVK, and hands each frame to visionOS's CompositorServices,
which puts it in front of your eyes. Everything here is in service of that, plus the parts visionOS
does differently from a PC or a Quest. For building it, see the [README](../README.md); for working
on it, [DEVELOPING.md](DEVELOPING.md).

## The shape of it

```
SwiftUI app (visionos/App)                       main thread
  ├─ Launcher window: import the game, choose a view, Play
  ├─ ImmersiveSpace (Full: .full or .mixed; Progressive: .progressive)
  │    └─ CompositorLayer ─▶ its LayerRenderer goes to the engine
  └─ Window (View: Window): a RealityKit scene behind a portal
Engine (upstream + patches/, built by scripts/build.sh)   its own thread
  └─ the game's main loop and its VR mod
       └─ visionOS runtime (visionos/engine/code/vr/visionos)
            ├─ CompositorServices frames, ARKit head pose (cp_* from the engine thread)
            ├─ Vulkan via MoltenVK, into the engine's own 2-layer eye image
            ├─ a Metal present pass: scale, anti-alias, depth, into the drawable
            └─ GameController + ARKit: Sense controllers, gamepads, bare hands
```

- **The app owns `main`.** The engine is built as static libraries, merged into one archive
  (`libshar_engine.a`) and force-loaded into the app, because the game registers things from static
  constructors a plain link would drop. The app starts the game's `main` on its own thread, with a
  16 MB stack and an autorelease pool drained every frame (the game's loop has none).
- **The VR mod's layers are reused, not copied.** Upstream's VR mod talks to a runtime through a
  facade (`SharOpenXR`), with an OpenXR core behind it on PC and Quest. On visionOS a few lines of
  `#if` swap that core for ours (`visionos_desktop_core.inl`), so the mod's VR gameplay, body, HUD,
  menus and steering wheel run unchanged.
- **Frames.** The runtime drives CompositorServices from the engine thread through its C API
  (Swift's `LayerRenderer` is the same object as `cp_layer_renderer_t`). Each frame waits for its
  optimal input time, takes the predicted head pose from ARKit, renders both eyes in one multiview
  pass into the engine's own 2-layer image, and presents with a small Metal pass that scales it
  into the drawable, anti-aliases it, applies the game's fades, and writes reverse-Z depth (a plane
  3 m out: CompositorServices needs depth, and the game's own is forward-Z) with the frame's device
  anchor attached. Without both, the headset shows nothing at all.
- **Data.** The game loads its files from the app's Documents folder, its working directory: the
  importer puts them there, and Files can see it.

## Frames into the headset

- **Render scale.** The Graphics menu's Render Scale resizes the swapchain on PCVR. The compositor
  fixes the drawable size on visionOS, so the engine renders into its own texture at that fraction
  and the runtime scales it into the drawable with a small Metal pass. `VulkanContext` gains a
  visionOS-only `ReleaseRenderTarget`, called between frames with the queue drained, for the old
  size's image.
  - It frees that image's HDR targets. Upstream keeps them for the life of the process, keyed by
    output image, holding views of it. When the next image reused the old handle, the stale entry
    matched and the HDR pass rendered through views of a destroyed image. That crashed the headset
    going from 120% to 50% and back.
  - It also frees what upstream defers until Shutdown. Otherwise every change kept a full set of
    eye-sized HDR, froxel and depth targets alive, hundreds of MB at 120%.
  - Freeing those took two more fixes. First, the draw-state cache creates its own attachment
    view for every render target, but upstream's retire path skips it, taking it for the
    texture's. MoltenVK's view keeps the whole image alive, so the old eye images all survived.
    Second, each eye's HDR image had draw states and a depth target cached against it that nobody
    retired. Holding Render Scale's arrow on the headset leaked about 260 MB a step, until visionOS
    killed the app at its memory limit. The Simulator shows the same leak in its SimMetalHost
    processes (2.8 → 9 GB over 24 steps before, flat after).
- **Anti-Aliasing** (Graphics menu, visionOS only: Off, FXAA or SMAA). The Vulkan renderer has no
  AA besides supersampling through Render Scale, and MSAA would reach into every render pass, depth
  target and the HDR resolve. So the runtime does it on the way into the drawable.
  - **FXAA** is 3.11's console variant, in the present pass. It also softens texture detail, which
    shows at the headset's resolution.
  - **SMAA** is SMAA 1x (github.com/iryoku/smaa, MIT; `visionos/engine/code/vr/visionos/smaa/`).
    It blends only along real edges, so distant texture detail stays crisp. The runs per eye are:
    luma edges from a gamma view of the image, blending weights from the edges and SMAA's two
    lookup tables, then neighbourhood blending through an sRGB view, which the present pass scales
    into the drawable.
  - `scripts/generate-smaa-msl.py` turns the reference `SMAA.hlsl` into Metal. Metal supplies
    SMAA's shading-language macros; HLSL's out/inout parameters become references. The output is
    committed, so building doesn't need the SMAA checkout.
  - Both run after the HUD is drawn.
- **GPU pacing (optional).** With "Pace frames on the GPU" on, the present waits for the engine's
  frame on the GPU (a Vulkan timeline semaphore exported as an `MTLSharedEvent`) instead of the CPU
  draining the engine's queue every frame.

## The three views

- **Full** opens the immersive space `.full`, or `.mixed` with "Show my room around menus" on. In
  a mixed space the engine clears its eye image to transparent; the world, when drawn, covers it,
  so gameplay stays fully immersive while menus, loading screens and films leave the room showing
  around them, on a 97% dark backdrop behind the menu panel. The game's iris wipes (which the PC
  and Quest runtimes apply as a layer fade, and visionOS has no such layer) are applied in the
  present pass, fading into the room. 1.2 m from where the space opened the game starts fading into
  the room, and by 1.6 m it's gone, since visionOS's own boundary doesn't apply to a mixed space.
- **View** (VR menu, visionOS only): Full, Progressive or Window. Changing it in the menu moves the
  game live: the app restyles the immersive space, or swaps it for the window, through a handler
  the runtime calls when the setting changes.
  - Progressive lets the Digital Crown set how much of the game surrounds you (portrait portal,
    down to 10%). visionOS 26 needs the frame to end through the drawable's render context for
    that, which the present pass does. The game's front follows the space's forward axis, and a
    Digital Crown recentre (`onWorldRecenter`) re-anchors it.
  - Window is a native window in the shared space. You move and resize it with visionOS's own
    controls, beside other apps. The game is a 3D scene behind the glass, correct from any angle.
    - With other windows open, look at the game window to play it with a controller: visionOS
      sends a controller's input to the window you're looking at, and the game window takes it
      itself (`handlesGameControllerEvents`) rather than as pinches. Pinches and taps on the game
      stop at its face instead of reaching windows behind it. The view is all but flat (3 mm), so
      its face lies where the window's bar and corner handles are.
    - visionOS gives apps no head or controller tracking outside a Full Space ("ARKit data is
      available only when your app presents a Full Space"; a head anchor's transform stays at
      identity), and CompositorServices only renders into an immersive space. But RealityKit draws
      a window's content from the viewer's real eyes.
    - So the window mirrors the game's scene into RealityKit (`visionos_mirror.h`,
      `visionos/App/Sources/MirrorScene.swift`), in a portal on the window's face:
      - The PDDI says what each draw is (its mesh, with the CPU copy of its vertices and indices,
        and its texture); the Vulkan context says where it goes (the eye's modelview, the material).
        The left eye's world draws into the window's picture are recorded.
      - Each mesh and texture is copied to the app once (meshes flipped to right-handed; textures as
        BGRA8, rows reversed, mipmapped only where the engine's are), then a draw list per frame.
      - Skinned characters are skinned on the CPU as the vertex shader does it, and immediate-mode
        geometry (particles, sprites) is copied per frame. A frame's dynamic geometry is two
        RealityKit meshes with a part per material (refilling a mesh costs about the same however
        small it is): the solid parts', drawn with the level's opaque geometry, and the blended
        parts', after every blended static draw, in the order the game drew them (its translucent
        pass sorts characters, smoke and cars far to near). RealityKit draws an entity in a sort
        group in the group's order even when it's opaque, so characters in the blended mesh's
        entity came after every blended static: smoke didn't cover the people behind it. Alpha-
        blended characters at full alpha are cut out at half alpha. Lit dynamic geometry is lit on
        the CPU, per vertex, as lit.vert does it, with the draw's own lights and ambient, and drawn
        unlit. Runaway vertices (a world coin's trail sparkles fly off to 1e20) are dropped.
      - Materials are unlit ShaderGraph (`visionos/App/Resources/WindowFrame.usda`, written by
        `scripts/gen-mirror-materials.py`): texture x vertex colour x the engine's colour term,
        then the HDR resolve's exposure and tone curve (ACES, fitted). The colour term is the
        engine's own (compact.vert, lit.vert): an unlit draw takes its ambient term, and a lit one
        (cars, props; the level's own geometry is prelit) its own ambient plus the material
        colour times each light's colour times N.L, per pixel, in their own variants of the
        materials so the prelit level doesn't pay for the lights. The material colour (a car's
        paint) tints only the lights. Alpha tests cut out; the blend modes go through premultiplied
        alpha (add; modulate, for the blob shadows, as black at 1 - luma; subtract, approximated as
        darkening by the source's brightness), writing depth only where the game's draw does:
        RealityKit's default depth write let invisible surfaces hide what's behind them, which took
        tyres and glass off cars and flickered as the draw order changed.
      - Blending the game draws solid is drawn solid. The game blends every shader of a car built
        on a traffic model every frame (and characters, for fades) but writes their depth, so they
        hide their own far sides. Each texture's alpha is classified as it's copied (opaque, on or
        off, translucent), then again over just the texels each mesh's UVs cover (a traffic car's
        atlas is a paint mask, alpha 223, but its wheels sample opaque texels), and each mesh's
        vertex alpha: an alpha blend at full colour alpha that depth-tests and writes depth, with
        nothing translucent in what it samples or its vertices, is opaque; one whose texture is
        on-or-off is a cutout. Glass, glows and fades still blend, and blended entities draw in the
        engine's order (one ModelSortGroup, ordered by the draw's index), not by RealityKit's
        distance sort, which changes with every head movement.
      - Blob shadows: the game slides them towards its camera (a character's 25 cm, a car's 1 m),
        which works because it draws them before what casts them. The mirror draws them after, so
        while it's up, character and car shadows are lifted 3 cm along the ground's normal instead
        (a prop's slide is capped at 20 cm and a skid mark's lift at 3 cm:
        `SharOpenXR::GroundShadowOffset`); slid, they darkened Homer's ankles and the wheels and
        floated as the viewer leaned. The game also hides any character its camera comes within
        2.5 m of; mirrored, only one the camera is all but inside (`SharOpenXR::IsSceneMirrorUp`).
      - A mesh drawn again where it was just drawn (a traffic car's paint, then its trim and lamps)
        is placed 2e-4 of its distance nearer the eye for each repeat: the game's LEQUAL lets the
        later pass win, where RealityKit's coplanar entities fought.
      - Cut-out textures (on-or-off alpha: foliage, fences) get mipmaps that keep their full size's
        coverage at an alpha of a half, built on the CPU; the GPU's box filter thinned foliage with
        distance, and its edges shimmered as the head moved.
      - A mesh whose data keeps changing (CPU-skinned or expression-animated) goes through the
        dynamic mesh while it changes. Static meshes are copied as 36-byte vertices (only what the
        materials read).
      - Meshes are z-flipped to right-handed and every triangle turned round (strips unrolled into
        lists): the flip leaves the on-screen winding as it was, and Pure3D's front faces wind the
        other way from RealityKit's. Without it RealityKit saw the back of nearly everything and lit
        it with the normal reversed.
      - The exposure and lights reach every material through one 8x1 texture, so a frame's
        changes touch no material. The lights are Pure3D's camera-fixed rig, taken from the
        frame's first lit draw (each draw's ambient is its own); the app turns them into the
        materials' world space.
      - The engine draws only the HUD into the window's eyes (mirror-only mode): world, shadow and
        vehicle-cubemap draws are recorded for the mirror but not drawn. The left eye starts
        black and the right white, and the window recovers the HUD's colour and alpha from the
        pair.
      - The exposure is the engine's auto-exposure. Every twelfth window frame the left eye does
        draw its world, into its HDR target only, so the meter has a scene; the resolve then
        clears the window's picture to its HUD background. The exposure is a 1x1 texture every
        mirror material reads.
      - Frames without a 3D scene (menus, loading, films) show flat on the window's face.
      - Not mirrored: volumetric light (subtle: a little haze on distant things), CSM shadows (the
        game's own ground shadows show instead: `SharOpenXR::AreCsmShadowsDrawn`), fog, specular
        highlights, layered textures, reflections and the VR mod's rear-light pools. The mirror's
        colours match the engine's to a few levels.
      - Comparing with the engine's own picture in the Simulator: it renders each eye on its own
        (no multiview there), and the right eye's HDR resolve comes after the game's mid-eye
        depth clear, so its volumetric light treats every pixel as 120 m away and hazes the whole
        picture. Compare with the immersive view (the left eye), or with Volumetric Light off. The
        headset renders both eyes at once and resolves before the clear.
    - The earlier approach stays as a fallback (`SHAR_TEST_WINDOW_RELIEF=1`): each eye's picture as
      a relief, a grid whose vertices sit where that eye's depth buffer puts the scene
      (`visionos_window.h`). It shows the engine's exact look, but only what two eyes 64 mm apart
      rendered, so off-angle views stretch.
    - The engine's eyes are where a viewer's would be for the picture to be true to life: 64 mm
      apart at the window's scale, 72 degrees across the window, which sits 4 game metres out.
      Resizing the window scales the scene with it. Looked at from there, the relief is exactly
      the rendered image; from anywhere else it's that image in 3D, redrawn at the display's rate
      whatever the game's frame rate.
    - A single relief has nothing behind its foreground, so a head move opens gaps it can only fill
      by stretching (Homer smeared onto the door). So each eye's relief comes in three layers, each
      shown to one eye through the camera-index switch (opacity, cut out):
      - primary: the eye's own relief, shown to it. Cells that span a depth step are cut out. Its
        foreground is dilated a cell, so an edge's pixels stay on it. At rest it's exactly the
        eye's picture.
      - secondary: the same relief eroded instead, cut the same way, pushed 2% farther along its
        own rays and shown to the other eye. Behind that eye's primary, it fills the cuts with
        what this eye saw there: the game's own render of what the other eye's foreground hid.
      - backstop: the primary uncut, 5% farther back, shown to its eye: the stretch, now only
        where neither eye saw anything.
    - The eyes render past the window's edges (`kWindowOverscanX/Y`, about 12 cm of leaning at a
      metre) at the window's pixel density, so looking in at an angle shows the game there too. A
      skirt around each grid stretches the edge further out for steeper angles. The grid is 384 x
      216 cells per eye.
    - The engine copies the tone-mapped scene aside at its HDR resolve, before the HUD
      (`VulkanContext::SetWindowSceneCapture`). The HUD is what differs from that copy, within the
      window's part of the picture, and it goes flat on the window's face. Menus, fades and frames
      without a 3D scene go flat too.
    - The world's depth is copied into the window's own image at the first depth clear after the
      world or at the resolve, whichever comes first: the game clears depth partway through each
      eye so its later layers draw on top, and an eye's resolve can come after that clear
      (`VulkanContext::SnapshotWindowDepth`).
    - Frames are paced by the window's RealityKit updates. Each goes into one of three sets
      (pictures, HUD, layer vertices and cut indices), and the app copies the latest into its
      `LowLevelTexture`s and `LowLevelMesh`es. The materials are ShaderGraph, in
      `visionos/App/Resources/WindowFrame.usda`.
    - The window plays in Original mode, restoring VR mode on the way back. The Original HUD fills
      the window's height at its distance (`SharedVrState::flatWindowTangent`, since the picture
      is wider than the window), like the game's 4:3 HUD on a screen, and cutscenes are sized to
      the 72 degree view.
    - Its limit: the layers only hold what the two eyes rendered, 64 mm apart. Past that, a big
      lean or a steep angle still shows the backstop's stretch behind things.
  - A mixed space (the room behind menus) refuses `cp_view_get_tangents`, so the runtime takes
    every view's frustum from `cp_drawable_compute_projection`.

## Input

The runtime reads controllers itself, through GameController, and hands the VR mod the
Touch-controller-shaped input it expects:

- **PS VR2 Sense controllers**: two GameController halves (left and right, from the vendor name),
  with their poses from ARKit's accessory tracking on a session of their own, predicted to each
  frame's display time. They feed the mod's body IK arms, aiming and swinging, and haptics go back
  through GameController.
- **Gamepads** (DualSense, Xbox, MFi) are read as a pair of Touch controllers without poses.
- **Bare hands** (ARKit hand tracking) play only when neither is connected: pinches are buttons, a
  fist is grip, and two pinch "clutches", held and moved like a stick, walk and turn. Grip poses come
  from the hand's joints, in OpenXR's grip frame, so the in-game hands sit where yours are.
- SDL's own MFi driver is off (it fed each Sense half in as a separate gamepad), and one idle
  virtual SDL gamepad is attached, because the game only accepts input while it sees a gamepad.
- The Window view, outside a Full Space, has no tracking: it plays in the game's original
  third-person mode with a controller, and the window opts in to controller events so visionOS
  doesn't turn the buttons into pinches.

## What the patch changes in the engine

`patches/0002-visionos-engine-build.patch` holds every change to upstream's code. The big ones:

- **Build (CMake).** Adds a `CMAKE_SYSTEM_NAME=visionOS` branch. It uses the vendored SDL3, which
  supports visionOS, because the vendored SDL2 doesn't. It also uses the vendored libpng and OpenAL
  Soft (static), zlib from the SDK, FFmpeg through pkg-config, and MoltenVK as Vulkan. No OpenXR
  loader is linked: the shared VR layer only uses OpenXR types, and those headers come from SDL3's
  Khronos copy, as on Android. The game builds as a static `main` library for the app shell to link.
- **One key choice.** visionOS defines `SRR2_OPENXR_PLATFORM_WIN32` as well as its own
  `SRR2_OPENXR_PLATFORM_VISIONOS`. Upstream gates the desktop-VR (PCVR) paths on the Win32 macro in
  about 330 places. Checked file by file, those are VR-behaviour switches in gameplay, camera, HUD
  and render code, not Windows API calls. Adding visionOS to every one would make a large patch that
  conflicts every time upstream moves. So visionOS rides the PCVR paths, and the few genuinely
  Windows-specific sites exclude it explicitly: the crash handler and the PCVR startup splash,
  which needs a newer libpng.
- **The runtime.** `openxr_desktop_runtime.cpp` is two parts: an OpenXR core, and about 200 lines of
  glue to the shared VR layer. On visionOS a three-line `#if` swaps the core for ours
  (`visionos/engine/code/vr/visionos/visionos_desktop_core.inl`), which keeps every name the glue
  uses. The glue is reused in place, not copied.
  - The Vulkan context gets a plain MoltenVK path, since upstream creates its instance and device
    through OpenXR. That path adds `VK_EXT_metal_objects`.
  - The OpenXR loader and instance files are dropped.
- **Startup.** The Swift app owns `main`, so SDL gets `SDL_MAIN_NOIMPL` and the app calls
  `SDL_main()` on an engine thread. SDL video isn't initialized and no window is created. There's
  no OpenGL on visionOS, and the Vulkan PDDI never uses the window.
- **Linking gaps.** The OpenAL sound layer (named "win32" upstream, and shared with Android) and the
  touch-input mode manager were only compiled for Windows and Android.
- **Menus.** The 15 menu/options guards written as `RAD_PC || RAD_ANDROID` also include
  `RAD_VISIONOS`.
- **Descriptor sets.** The lit shaders declare descriptor sets 2 and 6 even for materials that
  never bind them: Lit geometry with Legacy, Phong or Toon shading. Vulkan requires every
  statically used set to be bound. Adreno and PC drivers tolerate the gap, but MoltenVK binds each
  declared set up front, so the first gameplay frame crashed in `bindMetalResources`. On visionOS,
  every slot still unbound in a pass gets the engine's existing fallback set before a material
  draw.
- **Bound pipelines outliving a failed draw.** When a draw fails after `vkCmdBindPipeline` (the
  per-frame uniform arena is full), `DrawPddiGeometry` destroyed the just-created pipeline, layout
  and shaders while the command buffer still referenced them. Desktop and Adreno drivers encode at
  record time and tolerate it. MoltenVK encodes at submit, so the headset crashed in
  `MVKCommandEncoderState::bindGraphicsPipeline`.
  - It happened in dense spots, where the arena overflows on a frame that also meets new materials:
    breaking Krusty glass, driving up to the gas station.
  - Created state is now cached even when the draw fails. This fix applies on every platform and is
    worth offering upstream.
  - On visionOS the arena is 64 MB rather than 16 MB, so dense districts stop dropping draws, and
    an overflow is logged once.
- **Controller prompts.** The PC data's tutorials name keyboard keys ("USE [W,S,A,D] TO MOVE
  AROUND", "[LEFT-CLICK] TO GET INTO CAR"), and its button legends show [ENTER] and [F1]. The PC
  text bible has console variants for only two of these.
  - On visionOS, the tutorial screen takes controller wording from
    `vr/visionos/visionos_prompts.h`, for VR or Original mode. It names PlayStation shapes on Sense,
    DualSense and DualShock controllers, and A/B/X/Y on the rest.
  - The key icons beside "Continue" and "Disable Tutorials" are hidden.
- **Move Direction** (VR menu: Head or Controller). On foot in VR mode, the left stick moves along
  the head's heading upstream. With Controller it follows the left controller's heading instead,
  from its grip pose, flattened the way `YawOnly` flattens poses. It falls back to the head while
  that controller isn't tracked. This one is platform-neutral: the setting, the menu row and both
  runtimes' `GetControllerForward` apply on the Quest and PC too.
- **The audio listener follows the head.** Upstream's `Listener::Update` places the OpenAL listener
  at the active game camera. In VR mode that carries only the body's heading, which changes on snap
  turns. After a head turn, a character straight ahead was heard off to one side. On every OpenXR
  platform the listener now takes the tracked centre camera (`GetLatestCullingCamera`) when there
  is one. This is a platform-neutral fix.
- **Menu rows.** The VR page grew from 9 rows to 10 (11 on visionOS), and Graphics from 8 to 9 on
  visionOS. Both keep their authored span with closer spacing.
- **Retired Vulkan objects are freed every frame on visionOS.** Upstream keeps every texture,
  buffer, view and pipeline the engine unloads until Shutdown (PC can afford it). On the headset,
  where visionOS ends the app at a fixed footprint, every zone and level change would add to the
  pile. `VulkanContext::ReleaseRetiredResources` frees them at the start of each frame; the last
  frame's `vkQueueWaitIdle` has already drained the queue. `DestroyTexture` also forgets a freed
  image in `mLdrOffscreenTargets`, since its handle can now be reused. Going from the menus into
  level 1 frees about 160 images and 2,900 buffers.
- **visionOS 27 SDK.** `code/ai/actor/actoranimation.h` needs `<cstddef>` for `NULL`.
- **Simulator only.** Multiview is off, because the Simulator's GPU can't render to layered
  attachments.
- **OpenAL Soft's aligned `new`.** Its fallback for macOS before 10.13 (`libs/openal-soft/common/almalloc.cpp`) also
  compiled on visionOS, because `AvailabilityMacros.h` defines `MAC_OS_X_VERSION_MIN_REQUIRED`
  there too. Its `posix_memalign` rejects alignments below `sizeof(void*)`, so every EFX effect
  allocation failed and the game's environmental audio effects never played. It's now limited to
  `TARGET_OS_OSX`.
- **SDL's virtual joystick.** It's enabled on visionOS: SDL3 gated it behind HIDAPI, which visionOS
  doesn't have, but the driver doesn't use HIDAPI.
  - The runtime turns SDL's MFi driver off and reads controllers itself. Otherwise SDL fed each
    Sense half in as its own gamepad, fighting the runtime's input.
  - The game only accepts input while a gamepad is connected (`UserController` learns its input
    names from one), so the runtime attaches one idle virtual SDL gamepad.
- **Global `new`/`delete`.** The game replaces them (`srrmemory.cpp`), and so does OpenAL Soft
  (its aligned variants). On Windows that replacement stays inside the game's own module. On Apple
  platforms, dyld makes any exported replacement process-wide, so SwiftUI and the Swift runtime end
  up freeing memory through the game's allocator. On device, that crashed at launch in
  `radMemoryFindAllocatorRecursive`, because the allocator tree was still empty. The Simulator
  didn't show it.
  - The app keeps the operators private to its own binary with `visionos/App/EngineUnexportedSymbols.txt`.
  - As a backstop, `radMemoryFree` hands anything freed before `radMemoryInitialize()` straight to
    `free()`.
  - This is safe because in this build (release, no Doug Lea heaps, no rerouting) the game's
    operators sit on `malloc`/`free`, so memory can cross between the game and system code in
    either direction.
- **Apple toolchain fixes.**
  - `malloc.h` is guarded, since Apple doesn't have it.
  - The vendored libpng 1.0.3 mistook every modern Apple target for classic Mac OS and asked for
    `<fp.h>`.
  - A few SDL2-only calls in newer files get SDL3 branches, in upstream's existing
    `#if SDL_MAJOR_VERSION` style: the file read/write helpers, haptics, and `SDL_GetBasePath`,
    whose result SDL3 owns, so freeing it would crash.
- **The room behind menus.** The Vulkan context can clear an eye image to transparent and keep its
  alpha as coverage (`SetTransparentEyeClear`), only for the mixed space.
- **Turning the view.** `SharOpenXR::AddVrYaw` turns the first-person view by the head's yaw, so
  Progressive keeps what you were looking at when you enter it or recentre with the Digital Crown.
- **Ground shadows in the Window view.** With the scene mirror up, the game's own blob shadows and
  light pools show (`SharOpenXR::AreCsmShadowsDrawn`, since the mirror draws no shadow cascades),
  sit just off the ground rather than slid towards the game's camera (`GroundShadowOffset`), and
  characters aren't hidden for the game camera being close (`IsSceneMirrorUp`).
- **Render Scale** goes to 150% on visionOS, and anti-aliasing defaults to SMAA there.
