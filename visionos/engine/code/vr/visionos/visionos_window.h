// The shared-space window's frames (View: Window): the engine's stereo pair turned into what the
// app's RealityKit window shows. Objective-C++ only (visionos_compositor.mm).
//
// visionOS gives an app no head pose outside a Full Space, but RealityKit draws a window's content
// from the viewer's real eyes. So rather than a flat stereo picture, each eye's image becomes a
// relief: a grid whose vertices sit where that eye's depth buffer says the scene is, seen through a
// portal in the window. Looked at from where the engine's eye was, it is exactly the rendered image;
// from anywhere else it is that image in 3D, so leaning and moving show real parallax, and visionOS
// redraws it at the display's rate whatever the game's frame rate.
//
// The geometry, in the window's units (its width is 1, its face is z = 0, +z towards the viewer):
// the engine's eyes sit kWindowPlaneDistance game metres from a screen that is the window, with
// the window's width spanning a 72 degree view there. Game metres scale by 1 / (2 * that distance *
// tan 36) into window units, and the app scales the window units to its size in metres, so each eye
// is where a viewer's eye would be for the picture to be orthoscopic. The HUD, drawn by the engine
// at that same distance, is split out of the frame and shown flat on the window's face.
//
// A single relief has nothing behind its foreground: moving your head, a depth step (Homer's edge
// against the door) opens a gap it can only fill by stretching one onto the other. So each eye's
// relief comes in three layers, each shown to one eye (the app's material picks by camera index):
//   primary    that eye's relief, cut where a cell spans a depth step, shown to that eye. At rest
//              it is exactly the eye's picture; its foreground is dilated a cell so an edge's
//              pixels stay on it.
//   secondary  the same relief, eroded rather than dilated and cut the same way, pushed a little
//              farther along its own rays and shown to the OTHER eye: behind that eye's primary, it
//              fills the primary's cuts with what this eye saw there, which is the game's own view
//              of what the other eye's foreground hid.
//   backstop   the primary uncut, pushed farther still and shown to that eye: the stretch, now only
//              where neither eye saw anything.
// The eyes also render past the window's edges (kWindowOverscanX/Y), so looking in at an angle shows
// the game there too.
#ifndef SHAR_VISIONOS_WINDOW_H
#define SHAR_VISIONOS_WINDOW_H

#import <Metal/Metal.h>

namespace SharVisionOS
{
    // The window's picture at 100% Render Scale, its field of view, and where the eyes converge (the
    // window's face), shared by the engine's views and the relief.
    constexpr NSUInteger kWindowEyeWidth = 1600, kWindowEyeHeight = 900;
    constexpr float kWindowHalfFovTangent = 0.7265f;  // tan(36 degrees): 72 degrees across
    constexpr float kWindowPlaneDistance = 4.0f;       // game metres

    // The eyes render past the window's edges by this much (view tangent), at the same pixel density,
    // so that looking in at an angle shows the game there, not a stretched edge. About 12 cm of
    // leaning for a window a metre away.
    constexpr float kWindowOverscanX = 0.15f, kWindowOverscanY = 0.10f;

    // The window's half-height as a view tangent.
    float WindowHalfHeightTangent();

    // The engine's eye offset from the centre (game metres, positive) that puts its eyes 64 mm apart
    // for a window `widthMetres` wide.
    float WindowEyeOffset(float widthMetres);

    struct WindowFrameInput
    {
        id<MTLTexture> final;    // the engine's eye image, HUD and all (2 slices)
        id<MTLTexture> scene;    // the same before the HUD, or nil when no 3D scene was rendered
        id<MTLTexture> depth[2]; // each eye's depth (2D), nil with `scene`
        float projection[2][16]; // each eye's projection (column-major, GL depth range)
        float eyeOffset;         // game metres, each side of the centre
        // The scene mirror renders the world: the eye images hold only the HUD, over black (left)
        // and white (right), and the relief isn't needed.
        bool mirrorOnly;
    };

    // One finished frame, as the app's window takes it (see SharVisionOS_CopyWindowFrame).
    struct WindowFrameOutput
    {
        id<MTLTexture> colour;      // both eyes' pictures, side by side
        id<MTLTexture> hud;         // the HUD alone (the left eye's), the window's part, transparent elsewhere
        id<MTLBuffer> positions;    // each eye's three layers of grid vertices
        id<MTLBuffer> indices;      // each eye's cut primary and secondary triangles
        id<MTLBuffer> distances;    // each vertex's dilated and eroded distance, for the cut
    };

    // Encodes `input` into `output`, reallocating `output`'s resources when the eye size changes.
    // `colourSource` is what goes into `output.colour` (the scene, or the final image when there
    // is none, anti-aliased or not).
    bool EncodeWindowFrame(id<MTLCommandBuffer> commands, const WindowFrameInput& input, id<MTLTexture> colourSource,
                           WindowFrameOutput& output);
}

#endif
