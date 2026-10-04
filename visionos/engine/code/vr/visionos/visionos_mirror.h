// The shared-space window's scene mirror (View: Window, experimental): the game's own 3D draws,
// replayed into the app's RealityKit window so that RealityKit renders the level from the
// viewer's real eyes. visionOS keeps head pose from apps outside a Full Space, so the engine can
// only render from where it guesses the eyes are; a mirror of the geometry itself has no such
// limit, and shows what's behind Homer however far you lean.
//
// The PDDI (libs/pure3d/pddi/vulkan/vkdevice.cpp) says what each retained draw is (its mesh, with
// the CPU copy of its vertices and indices, and its texture); VulkanContext::DrawPddiGeometry says
// where it goes (the eye's modelview and the material). The left eye's world draws into the
// window's picture are recorded, each mesh and texture copied once into a queue for the app
// (SharVisionOS_MirrorAcquire in visionos_entry.h), and the draw list published per frame.
//
// Plain C++: included by the PDDI and the Vulkan context.
#ifndef SHAR_VISIONOS_MIRROR_H
#define SHAR_VISIONOS_MIRROR_H

#include <cstdint>
#include <vector>

namespace SharOpenXR { struct VulkanMaterialState; }

namespace SharVisionOS
{
    // What the PDDI is about to draw. `vertices` is its 80-byte VulkanVertex array; `indices` are
    // 16-bit, or none for a non-indexed draw. `version` changes whenever the data does.
    struct MirrorSource
    {
        const void* mesh;
        uint32_t version;
        const void* vertices;
        uint32_t vertexCount;
        const uint16_t* indices;
        uint32_t indexCount;
        uint32_t topology;  // 0 triangle list, 1 triangle strip, anything else isn't mirrored
        void* texture;      // the PDDI texture, or null
        // Whether it has mipmaps. Some are palettes of small colour swatches (the characters'),
        // which mipmaps would blend together.
        bool textureMipmapped;
        // Copies a texture's level-zero BGRA8 pixels (pddiVulkanCopyTexturePixels).
        bool (*copyPixels)(void* texture, std::vector<unsigned char>* pixels, unsigned* width, unsigned* height);
    };

    // Whether the app wants the mirror; the PDDI skips its work when not.
    bool IsMirrorEnabled();

    // Around each retained draw (null after it).
    void SetMirrorSource(const MirrorSource* source);

    // A mesh or texture the PDDI destroyed (its address may be reused).
    void ForgetMirrorObject(const void* object);

    // A draw into the window's picture: records the current source with this modelview (object to
    // eye view, Pure3D's row-vector float[16]). Only perspective draws are the world; screen-space
    // ones (lens flares, fades) carry their own orthographic projection and aren't mirrored. `centreEye` is a multiview draw (modelview to the
    // centre between the eyes) rather than the left eye's own.
    void MirrorDraw(const float* projection, const float* modelview, const SharOpenXR::VulkanMaterialState& material,
                    bool centreEye);

    // A window frame starts (with the eyes' offset from the centre, game metres, and the exposure
    // the HDR resolve would give it) and ends.
    void BeginMirrorFrame(float eyeOffset, float exposure);
    void EndMirrorFrame();
}

#endif
