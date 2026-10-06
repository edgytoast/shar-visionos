// visionOS presentation for the SHAR VR backend: CompositorServices frames, ARKit head pose,
// and drawable textures imported into Vulkan. Plain C++ so the engine side never sees
// Objective-C; the implementation is in visionos_compositor.mm.
#ifndef SHAR_VISIONOS_COMPOSITOR_H
#define SHAR_VISIONOS_COMPOSITOR_H

#include <vulkan/vulkan.h>
#include <openxr/openxr.h>
#include <simd/simd.h>
#include <cstdint>

namespace SharVisionOS
{
    // Starts ARKit world tracking. Needs the layer renderer from SharVisionOS_Launch.
    bool InitializeCompositor();
    void ShutdownCompositor();
    // Whether there's something to present to. While there isn't (the headset is off, neither the
    // game's space nor its window is open, or the window is in the background), it holds the game
    // thread here, with its sound paused and its rumble stopped.
    bool IsCompositorRunning();
    // Whether the game has come back from being held since the last call.
    bool ConsumeResumeFromHold();

    // The engine thread runs the game's own loop, with no autorelease pool: Objective-C objects
    // autoreleased during a frame (Metal, GameController, ARKit) would live until the thread exits.
    // Call at the start of every frame: it drains the last frame's pool and opens the next.
    void DrainFrameAutoreleasePool();

    // Whether the game should re-anchor since the last call: visionOS recentred the space, or
    // frames moved between the window and the immersive space. `byCrown`: the person recentred
    // with the Digital Crown.
    bool ConsumeWorldRecenter(bool* byCrown = nullptr);

    // Blocks until the next frame's optimal input time, then starts submission and fetches its
    // drawable. `views` receive each eye's pose in ARKit's world origin (right-handed, Y up,
    // Z back: the OpenXR convention) and its FoV. Returns false when there is no frame to render
    // (layer paused or invalidated, no drawable); nothing needs ending in that case.
    bool BeginCompositorFrame(XrView views[2], bool* tracked, uint32_t* width, uint32_t* height);

    // Whether the compositor's Metal work goes on MoltenVK's own queue, after the engine's frame
    // without waiting for it (see AdoptEngineQueue). If not, EndFrame drains the engine's queue.
    bool SharesEngineQueue();
    // Presenting paced by an event (SHAR_PRESENT_EVENT=1): the engine's queue signals the frame's
    // end for the present to wait for on the GPU. False when the frame must be waited for instead.
    bool SignalEngineFrame();

    // The room behind menus: whether it's on for this frame (a mixed Full space), and whether the
    // frame drew the world (else its empty pixels show the room).
    bool RoomBehindMenusActive();
    void SetFrameWorldDrawn(bool drawn);
    // The game's fade to black for this frame (0-1: its iris wipes), applied in the present pass.
    void SetFrameFade(float fade);
    // The frontend panel's corners in each eye's image (x, y pairs, 0-1, y down), or not shown.
    void SetMenuBackdrop(bool shown, const float quads[2][8]);

    // The current drawable's colour texture as a 2-layer VkImage (one layer per eye), imported
    // with VK_EXT_metal_objects and cached per texture, since drawables are pooled.
    VkImage GetCompositorColorImage();
    VkFormat GetCompositorColorFormat();

    // Call once all Vulkan work on the colour image has completed. Writes the compositor's depth,
    // attaches the device anchor, presents, and ends submission.
    void EndCompositorFrame();

    // A connected extended gamepad (PS5, Xbox, MFi), laid out like a pair of Touch controllers.
    // Sticks are -1..1 with +Y up; buttons and triggers are 0..1.
    struct GamepadState
    {
        float leftX,leftY,rightX,rightY;
        float a,b,x,y,menu;
        float leftTrigger,rightTrigger,leftShoulder,rightShoulder;
        float leftStickClick,rightStickClick;
    };
    bool ReadGamepad(GamepadState* state);
    // Whether a gamepad (not a Sense controller) is connected.
    bool GamepadConnected();

    // PS VR2 Sense controllers (visionOS 26 spatial controllers), read into the same layout.
    // Returns false when none is connected. Call once per frame: it also starts tracking newly
    // connected controllers.
    bool ReadSpatialControllers(GamepadState* state);

    // Each Sense controller's grip pose (0 left, 1 right) for the current frame, in the same space
    // as the views. Call between BeginCompositorFrame and EndCompositorFrame.
    void LocateSpatialControllers(XrPosef poses[2], bool valid[2]);

    // Bare hands (ARKit hand tracking) as Touch controllers, for when there's neither a Sense
    // controller nor a gamepad: buttons and clutch sticks into the same layout (false when neither
    // hand is tracked), and grip poses for the hands `valid` doesn't have yet.
    bool ReadBareHands(GamepadState* state);
    void LocateBareHands(XrPosef poses[2], bool valid[2]);

    // The head's transform in the space's origin as of the current immersive frame (false before
    // one, or in the window).
    bool CurrentHeadTransform(simd_float4x4* originFromDevice);

    // Controller vibration. PlayHaptic is one pulse on a hand (0 left, 1 right), as the VR layer
    // asks for; SetRumble follows the game's own two rumble motors (0..1, 0 stops). Both play on
    // the Sense controller in that hand, else that side of a gamepad.
    void PlayHaptic(int hand, float amplitude, double seconds);
    void SetRumble(float left, float right);

    // The engine renders at this fraction of the drawable's size (clamped to 0.25..2), scaled into
    // the drawable at present. Takes effect on the next frame.
    void SetRenderScale(float scale);

    // The Graphics menu's Anti-Aliasing (0 off, 1 FXAA, 2 SMAA), applied as the frame goes to the
    // drawable.
    void SetAntiAliasing(int mode);

    // The VR menu's View (0 full immersion, 1 progressive, 2 the shared-space window), called every
    // frame. A change is passed to the app, which switches the immersive space's style or moves the
    // game between it and the window.
    void SetView(int mode);

    // The View setting last applied (0 Full, 1 Progressive, 2 Window; -1 before any).
    int CurrentView();

    // Whether the frame in progress goes to the shared-space window, with its fixed stereo views,
    // rather than the immersive space.
    bool IsWindowPresentation();

    // The window's half-height as a view tangent. The window's eyes render wider than the window, so
    // the part of their picture that shows head-on is this much of it.
    float WindowHalfHeightTangent();

    // When the current frame's tracked accessories should be predicted for (CFTimeInterval
    // seconds), or 0 outside a frame.
    double CurrentAnchorTime();
}

#endif
