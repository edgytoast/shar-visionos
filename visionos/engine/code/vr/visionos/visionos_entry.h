// Entry point for the SwiftUI shell. Import from a bridging header; Swift passes its
// LayerRenderer directly, since it is the same object as cp_layer_renderer_t.
#ifndef SHAR_VISIONOS_ENTRY_H
#define SHAR_VISIONOS_ENTRY_H

#include <CompositorServices/CompositorServices.h>
#include <simd/simd.h>
#include <stdbool.h>
#include <stdint.h>
#ifdef __OBJC__
#import <Metal/Metal.h>
#endif

#ifdef __cplusplus
extern "C" {
#endif

// Hands the immersive space's layer renderer to the engine, makes `dataDirectory` (the retail PC
// game files) the working directory the engine loads from, and runs the game on its own thread.
// Call once; later calls are ignored.
// Starts the engine on its own thread with this renderer. Called again when the immersive space
// reopens (visionOS can dismiss it); the running engine then resumes on the new renderer. The
// game's window launches it with no renderer.
void SharVisionOS_Launch(cp_layer_renderer_t _Nullable renderer, const char* _Nonnull dataDirectory);

// Whether the engine has been started, so the launcher can offer to resume it.
bool SharVisionOS_IsEngineRunning(void);

// The game's View setting (VR menu): 0 full immersion, 1 progressive, 2 the shared-space window.
// The handler is called from the engine thread whenever it changes, and the app switches the
// immersive space's style or moves the game between it and the window to match.
typedef void (*SharVisionOS_ViewHandler)(int mode);
void SharVisionOS_SetViewHandler(SharVisionOS_ViewHandler _Nullable handler);

// visionOS moved the space's origin to where the player faces (a Digital Crown recenter); the
// engine re-anchors the game's front on its next frame (in Progressive, turning to keep the view).
void SharVisionOS_WorldRecentered(void);

// The launcher's "Show my room around menus": View Full opens a mixed space, and frames the world
// doesn't cover (menus, loading, films) show the room around what's drawn, while gameplay stays
// opaque; the whole frame fades into the room 1.2-1.6 m from where the space opened.
void SharVisionOS_SetRoomBehindMenus(bool enabled);

// The game's shared-space window (View: Window). While it's open the engine renders to it rather
// than the immersive space, one frame per tick: each eye's image and a relief of its depth, which
// the window shows through a portal, and the HUD on its own (see visionos_window.h).
void SharVisionOS_SetWindowActive(bool active);
// Call on each of the window's RealityKit updates: the engine renders a frame per tick.
void SharVisionOS_WindowTick(void);
// The window's width in metres, which sets how far apart the engine's eyes are.
void SharVisionOS_SetWindowWidth(float metres);
// Whether the window's scene is in the foreground. While it isn't (in the background), the engine
// holds the game as it does with the headset off: no frames, no GPU work, no sound.
void SharVisionOS_SetWindowVisible(bool visible);

// visionOS interrupted the app's audio (Siri, a call, an alarm), or the interruption ended: the
// game's sound pauses until then. Reactivate the audio session before saying it ended.
void SharVisionOS_SetAudioInterrupted(bool interrupted);

// The app is back in the foreground, where the player may have just allowed hand tracking in
// Settings: if bare hands aren't being tracked, the engine asks again and restarts tracking.
void SharVisionOS_RetryHandTracking(void);
// The latest finished frame's serial (0 before the first), each eye's picture size and the HUD's.
uint64_t SharVisionOS_WindowFrame(int* _Nullable eyeWidth, int* _Nullable eyeHeight, int* _Nullable hudWidth,
                                  int* _Nullable hudHeight);

// Each eye's relief is a grid of this many cells across and down its picture, plus a skirt: a ring
// of vertices around it that carries the picture's edge outwards, so looking in at a steep angle
// shows the edge colour stretched rather than nothing. So (columns + 3) x (rows + 3) vertices, row by
// row from the top left, the first and last of each row and column being the skirt; each a packed
// float3 position in window units (the window 1 wide, its face at z = 0, +z towards the viewer).
// Each cell is two triangles: six 32-bit indices, row by row.
#define SHARVISIONOS_WINDOW_GRID_COLUMNS 384
#define SHARVISIONOS_WINDOW_GRID_ROWS 216
#define SHARVISIONOS_WINDOW_GRID_VERTICES \
    ((SHARVISIONOS_WINDOW_GRID_COLUMNS + 3) * (SHARVISIONOS_WINDOW_GRID_ROWS + 3))
#define SHARVISIONOS_WINDOW_GRID_INDICES \
    ((SHARVISIONOS_WINDOW_GRID_COLUMNS + 2) * (SHARVISIONOS_WINDOW_GRID_ROWS + 2) * 6)

#ifdef __OBJC__
// Encodes a copy of the latest frame (see visionos_window.h for the layers):
//   colour     both eyes' pictures side by side (2 x eye width by eye height, BGRA8 sRGB);
//   hud        the HUD (HUD size, BGRA8 sRGB, transparent where there is none);
//   positions  six vertex buffers: the left eye's primary, secondary and backstop layers, then the
//              right eye's;
//   indices    four index buffers: the left eye's cut primary and secondary, then the right eye's.
//              The backstops use every cell.
void SharVisionOS_CopyWindowFrame(id<MTLCommandBuffer> _Nonnull commands, id<MTLTexture> _Nonnull colour,
                                  id<MTLTexture> _Nonnull hud, NSArray<id<MTLBuffer>>* _Nonnull positions,
                                  NSArray<id<MTLBuffer>>* _Nonnull indices);
// With the scene mirror, only the HUD (premultiplied alpha) is needed from each frame. Into the HUD's
// top level; a mipmapped HUD texture gets its other levels regenerated.
void SharVisionOS_CopyWindowHud(id<MTLCommandBuffer> _Nonnull commands, id<MTLTexture> _Nonnull hud);
#endif

// The window's scene mirror (visionos_mirror.h): the game's 3D draws for RealityKit to render from
// the viewer's real eyes. Off unless the app turns it on; turning it on starts afresh, every mesh
// and texture sent again as the draws use them, for a new window's mirror.
void SharVisionOS_SetMirrorEnabled(bool enabled);

#define SHARVISIONOS_MIRROR_TWO_SIDED 1u
// Lit by the frame's lights (SharVisionOSMirrorFrame.lights) as the engine's lit materials are:
// the colour times ambient plus each light's colour times N.L. Unlit draws (the level's own
// geometry, whose vertex colours are prelit) take the colour as it is.
#define SHARVISIONOS_MIRROR_LIT 2u
// A blended draw the game writes depth for (blended draws are drawn in the game's order, so it
// hides what the game's hides).
#define SHARVISIONOS_MIRROR_DEPTH_WRITE 4u
// A lit draw's own ambient term (the light's ambient times its material's, plus what it emits) is
// its `ambient`; unlit draws' is 0.

// Pure3D's blend modes (PDDI_BLEND_*), which a draw's `blend` holds.
#define SHARVISIONOS_MIRROR_BLEND_NONE 0u
#define SHARVISIONOS_MIRROR_BLEND_ALPHA 1u       // src * a + dst * (1 - a)
#define SHARVISIONOS_MIRROR_BLEND_ADD 2u         // src + dst
#define SHARVISIONOS_MIRROR_BLEND_SUBTRACT 3u    // dst - src
#define SHARVISIONOS_MIRROR_BLEND_MODULATE 4u    // src * dst
#define SHARVISIONOS_MIRROR_BLEND_MODULATE2 5u   // 2 * src * dst
#define SHARVISIONOS_MIRROR_BLEND_ADDMODULATEALPHA 6u  // src + dst * a

// One draw of a mesh with a texture (0: none, white), placed in window units (the window 1 wide,
// its face at z = 0, +z towards the viewer), its colour multiplied by the material's colour and
// the vertex colour. Alpha below alphaCutoff (when not 0) is cut out.
typedef struct
{
    uint64_t mesh;
    uint64_t texture;
    simd_float4x4 transform;
    simd_float4 colour;
    simd_float4 ambient;
    float alphaCutoff;
    uint32_t flags;
    uint32_t blend;
} SharVisionOSMirrorDraw;

// This frame's dynamic geometry (skinned characters, particles, sprites) comes as one mesh, already
// in window units, with a part per material: this part's triangles, as a draw's material.
typedef struct
{
    uint32_t firstIndex, indexCount;
    uint64_t texture;
    simd_float4 colour;
    simd_float4 ambient;
    float alphaCutoff;
    uint32_t flags;
    uint32_t blend;
} SharVisionOSMirrorPart;

// A mesh: 36-byte vertices (position float3 at 0, normal float3 at 12, uv float2 at 24, colour
// RGBA8 at 32), already right-handed; 16-bit indices, a triangle list wound for RealityKit
// (counter-clockwise front faces).
typedef struct
{
    uint64_t id;
    const void* _Nonnull vertices;
    uint32_t vertexCount;
    const uint16_t* _Nonnull indices;
    uint32_t indexCount;
    simd_float3 boundsMin, boundsMax;
} SharVisionOSMirrorMesh;

// A texture: BGRA8, sRGB-encoded, rows in the order the engine samples them (no V flip). Mipmap it
// only when the engine does. `cutout`: its alpha is all but on or off (foliage, fences, trim), so
// its mipmaps should keep the coverage its full size has at an alpha of a half.
typedef struct
{
    uint64_t id;
    const void* _Nonnull pixels;
    uint32_t width, height;
    bool mipmapped;
    bool cutout;
} SharVisionOSMirrorTexture;

typedef struct
{
    uint64_t serial;  // the latest frame's; 0 before the first
    const SharVisionOSMirrorDraw* _Nullable draws;
    uint32_t drawCount;
    const SharVisionOSMirrorMesh* _Nullable meshes;
    uint32_t meshCount;
    const SharVisionOSMirrorTexture* _Nullable textures;
    uint32_t textureCount;
    const uint64_t* _Nullable removed;  // meshes and textures no longer used
    uint32_t removedCount;
    // The dynamic mesh: 36-byte vertices (position float3 at 0, normal float3 at 12, uv float2 at
    // 24, colour RGBA8 at 32), 32-bit indices of a triangle list, parts.
    const void* _Nullable dynamicVertices;
    uint32_t dynamicVertexCount;
    const uint32_t* _Nullable dynamicIndices;
    uint32_t dynamicIndexCount;
    const SharVisionOSMirrorPart* _Nullable dynamicParts;
    uint32_t dynamicPartCount;
    // It's two meshes: the solid parts' (opaque and cut out: characters) and the blended parts'
    // (particles, glows, a fading character), each with vertices of its own. The first
    // dynamicSolidVertexCount vertices, dynamicSolidIndexCount indices and dynamicSolidPartCount
    // parts are the solid ones; the blended parts' indices count from the first vertex after them.
    uint32_t dynamicSolidVertexCount, dynamicSolidIndexCount, dynamicSolidPartCount;
    // Each mesh's bounds, [0] the solid one's and [1] the blended one's: apart, so a stray particle
    // can't change how the characters are culled.
    simd_float3 dynamicBoundsMin[2], dynamicBoundsMax[2];
    // What the engine's HDR resolve multiplies the scene by before its tone curve (ACES, fitted).
    float exposure;
    // The lights of the frame's lit draws (Pure3D's rig for characters and props, fixed to the
    // camera): the ambient term and up to three directional lights, each a direction towards the
    // light in window space and a colour, black when unused.
    simd_float3 ambient;
    simd_float3 lightDirections[3], lightColours[3];
} SharVisionOSMirrorFrame;

// Takes the latest frame's draws and every mesh, texture and removal since the last call; the
// pointers stay valid until the next. False, taking nothing, until the first frame. Main thread.
bool SharVisionOS_MirrorAcquire(SharVisionOSMirrorFrame* _Nonnull frame);

#ifdef __cplusplus
}
#endif

#endif
