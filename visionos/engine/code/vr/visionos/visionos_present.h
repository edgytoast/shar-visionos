// The last pass of every frame: the engine's eye image into the CompositorServices drawable.
// Objective-C++ only (visionos_compositor.mm); the engine side never sees it.
#ifndef SHAR_VISIONOS_PRESENT_H
#define SHAR_VISIONOS_PRESENT_H

#import <CompositorServices/CompositorServices.h>
#import <Metal/Metal.h>
#include <simd/simd.h>

namespace SharVisionOS
{
    // A view's frustum edges as tangents at unit depth (left, right, top, bottom, all positive),
    // from the drawable's projection. cp_view_get_tangents gives the same in full immersion, but
    // visionOS refuses it in mixed immersion (the Window view) and aborts the app.
    inline simd_float4 ViewTangents(cp_drawable_t drawable, size_t view)
    {
        const simd_float4x4 p =
            cp_drawable_compute_projection(drawable, cp_axis_direction_convention_right_up_back, view);
        const float x = p.columns[0].x, y = p.columns[1].y, offsetX = p.columns[2].x, offsetY = p.columns[2].y;
        return simd_make_float4((1 - offsetX) / x, (1 + offsetX) / x, (1 + offsetY) / y, (1 - offsetY) / y);
    }

    struct PresentOptions
    {
        // Anti-aliasing on the way into the drawable: 0 none, 1 FXAA, 2 SMAA.
        int antiAliasing = 0;
        // The compositor gets this depth for the whole image.
        float planeDepthMetres = 3.0f;
        // A mixed space (the room behind menus): how far a frame shows the room where the engine's
        // image is transparent (0 opaque, 1 the image's own alpha), and how much of the frame is
        // shown at all (the safety boundary fades it into the room).
        float room = 0.0f;
        float visibility = 1.0f;
        // A dark backdrop (97% opaque: the compositor blends in linear light, where 8% of a bright room still reads as a grey veil) under the frontend panel, whose corners are given in each
        // eye's image (0-1, y down): menus drawn semi-transparent over black looked ghostly over the
        // room. Only where the room shows.
        bool backdrop = false;
        simd_float2 backdropQuad[2][4] = {};
        // The game's fade to black (its iris wipes, 0 none, 1 black), which other runtimes apply as
        // the composition layer's colour scale; with fadeToRoom, it fades into the room instead.
        float fade = 0.0f;
        bool fadeToRoom = false;
    };

    // SMAA on the first `slices` slices of `source`; returns the anti-aliased image, or `source` when
    // SMAA can't run. EncodePresent does this itself; the window's frames use it directly.
    id<MTLTexture> EncodeAntiAliasing(id<MTLCommandBuffer> commands, id<MTLTexture> source, NSUInteger slices);

    // Draws `source` (two slices, one per eye, any size) into the drawable's colour and depth in
    // one layered pass, and finishes it through the drawable's render context, which draws what
    // visionOS adds on top (the progressive immersion portal). Call after the device anchor is
    // set.
    bool EncodePresent(id<MTLCommandBuffer> commands, cp_drawable_t drawable, id<MTLTexture> source,
                       const PresentOptions& options);
}

#endif
