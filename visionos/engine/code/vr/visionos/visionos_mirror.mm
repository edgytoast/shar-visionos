#include <vr/visionos/visionos_mirror.h>
#include <vr/visionos/visionos_entry.h>
#include <vr/visionos/visionos_window.h>
#include <vr/vulkan/material_state.h>

#import <Foundation/Foundation.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstring>
#include <map>
#include <mutex>
#include <string>
#include <tuple>
#include <unordered_map>
#include <unordered_set>

namespace
{
// Mirrors the PDDI's VulkanVertex (vkdevice.cpp).
struct Vertex
{
    float position[3], normal[3], uv[2];
    uint32_t colour;
    float uv1[2], uv2[2], skinWeights[3];
    uint32_t skinIndices[4];
};
static_assert(sizeof(Vertex) == 80, "the PDDI's vertex is 80 bytes");

// The dynamic mesh's vertex: only what the materials read, since it crosses to RealityKit's
// renderer every frame.
struct DynamicVertex
{
    float position[3], normal[3], uv[2];
    uint32_t colour;
};
static_assert(sizeof(DynamicVertex) == 36, "packed");

// The frame's lights, from its first lit draw.
struct Lights
{
    bool found = false;
    simd_float3 ambient = 0.2f, directions[3] = {}, colours[3] = {};
};

struct Mesh
{
    uint64_t id;
    std::vector<DynamicVertex> vertices;  // only what the materials read: under half the engine's
    std::vector<uint16_t> indices;
    simd_float3 boundsMin, boundsMax;
};

struct Texture
{
    uint64_t id;
    std::vector<unsigned char> pixels;
    uint32_t width, height;
    bool mipmapped, cutout;
};

// A texture's alpha: all opaque, all but on or off (foliage, hair, cut-out trim), or truly
// translucent (glass, glows, a wheel's motion blur).
enum AlphaKind : uint8_t { kAlphaOpaque, kAlphaBinary, kAlphaTranslucent };

struct Known
{
    uint32_t version;  // the one copied
    uint64_t id;
    AlphaKind alpha = kAlphaTranslucent;  // a texture's, or whether a mesh's vertex colours are opaque
    // A mesh's data changing: the latest version seen, how many times it has changed, and when.
    uint32_t latestVersion = 0, changes = 0, changedFrame = 0;
};

std::atomic<bool> gEnabled{false};

// Engine thread.
bool gRecording = false;
float gEyeOffset = 0, gExposure = 1;
Lights gBuildingLights;
SharVisionOS::MirrorSource gSource = {};
bool gHaveSource = false;
std::vector<SharVisionOSMirrorDraw> gBuilding;
// This frame's dynamic geometry (skinned characters, immediate-mode particles and sprites), already
// in window units, grouped by material: the app gets one mesh with a part per material, not a
// mesh per draw, because refilling a RealityKit mesh costs far more than filling it.
struct Group
{
    SharVisionOSMirrorPart part;
    std::vector<uint32_t> indices;
};
std::vector<DynamicVertex> gBuildingVertices;
std::vector<Group> gGroups;
size_t gLastBlendedGroup = SIZE_MAX;
struct Counts
{
    unsigned draws = 0, skinned = 0, immediate = 0, noSource = 0, screen = 0, frames = 0;
    unsigned animating = 0, madeOpaque = 0, madeCutout = 0, blended = 0, repeats = 0;
} gCounts;
// How many times this frame each (mesh, place) has been drawn: see MirrorDraw.
std::unordered_map<uint64_t, unsigned> gPasses;

// Shared with the PDDI's other threads (resources) and the main thread (the app).
std::mutex gMutex;
std::unordered_map<const void*, Known> gMeshes, gTextures;
// Textures whose pixels couldn't be copied (shown white), so a draw doesn't try again every frame.
std::unordered_set<const void*> gUncopiedTextures;
// The alpha of each texture that isn't opaque, and what a mesh's UVs cover of it (CoveredAlpha).
struct AlphaPlane
{
    uint32_t width, height;
    std::vector<uint8_t> alpha;
};
std::unordered_map<const void*, AlphaPlane> gAlphaPlanes;
std::map<std::tuple<const void*, uint32_t, const void*>, AlphaKind> gCoverage;
uint64_t gNextId = 1;
std::vector<SharVisionOSMirrorDraw> gLatest;
std::vector<DynamicVertex> gLatestVertices;
std::vector<uint32_t> gLatestIndices;
std::vector<SharVisionOSMirrorPart> gLatestParts;
uint32_t gLatestSolidVertices = 0, gLatestSolidIndices = 0, gLatestSolidParts = 0;
simd_float3 gLatestLow[2], gLatestHigh[2];
float gLatestExposure = 1;
Lights gLatestLights;
uint64_t gSerial = 0;
std::vector<Mesh> gPendingMeshes;
std::vector<Texture> gPendingTextures;
std::vector<uint64_t> gRemoved;

// Main thread: what the last SharVisionOS_MirrorAcquire handed out.
std::vector<SharVisionOSMirrorDraw> gAcquiredDraws;
std::vector<DynamicVertex> gAcquiredVertices;
std::vector<uint32_t> gAcquiredIndices;
std::vector<SharVisionOSMirrorPart> gAcquiredParts;
std::vector<Mesh> gAcquiredMeshes;
std::vector<Texture> gAcquiredTextures;
std::vector<uint64_t> gAcquiredRemoved;
std::vector<SharVisionOSMirrorMesh> gMeshViews;
std::vector<SharVisionOSMirrorTexture> gTextureViews;

// Pure3D's view space is left-handed (+z ahead); RealityKit's is right-handed (-z ahead). Meshes
// flip z as they are copied, and each transform is conjugated by the same flip, so every
// transform stays a proper rotation.
//
// The flip is along the view axis, so it leaves a triangle's winding on screen as it was, and
// Pure3D's front faces wind the other way from RealityKit's. So every triangle is turned round as
// it's copied (strips unrolled into a list to do it). Left as they were, RealityKit saw the back
// of nearly everything: double-sided draws still showed, but lit with their normals reversed.
void AppendTriangles(const uint16_t* indices, uint32_t count, bool strip, std::vector<uint16_t>* out)
{
    auto index = [&](uint32_t i) { return indices ? indices[i] : (uint16_t)i; };
    if (strip)
    {
        for (uint32_t i = 0; i + 2 < count; ++i)
        {
            const uint16_t a = index(i), b = index(i + 1), c = index(i + 2);
            if (a == b || b == c || a == c) continue;
            // A strip's odd triangles are (b, a, c); turned round, (b, c, a); the even ones (a, c, b).
            if (i & 1) out->insert(out->end(), {b, c, a});
            else out->insert(out->end(), {a, c, b});
        }
    }
    else
        for (uint32_t i = 0; i + 2 < count; i += 3) out->insert(out->end(), {index(i), index(i + 2), index(i + 1)});
}

Mesh CopyMesh(const SharVisionOS::MirrorSource& source, uint64_t id)
{
    Mesh mesh;
    mesh.id = id;
    const Vertex* vertices = static_cast<const Vertex*>(source.vertices);
    mesh.vertices.reserve(source.vertexCount);
    for (uint32_t i = 0; i < source.vertexCount; ++i)
    {
        const Vertex& v = vertices[i];
        mesh.vertices.push_back({{v.position[0], v.position[1], v.position[2]}, {v.normal[0], v.normal[1], v.normal[2]},
                                 {v.uv[0], v.uv[1]}, v.colour});
    }
    mesh.boundsMin = simd_make_float3(INFINITY, INFINITY, INFINITY);
    mesh.boundsMax = -mesh.boundsMin;
    for (DynamicVertex& vertex : mesh.vertices)
    {
        vertex.position[2] = -vertex.position[2];
        vertex.normal[2] = -vertex.normal[2];
        const simd_float3 p = simd_make_float3(vertex.position[0], vertex.position[1], vertex.position[2]);
        mesh.boundsMin = simd_min(mesh.boundsMin, p);
        mesh.boundsMax = simd_max(mesh.boundsMax, p);
    }
    const bool indexed = source.indices && source.indexCount;
    AppendTriangles(indexed ? source.indices : nullptr,
                    indexed ? source.indexCount : std::min<uint32_t>(source.vertexCount, 65536),
                    source.topology == 1, &mesh.indices);
    return mesh;
}

// The id for this mesh's current data, queueing a copy for the app when it's new.
bool VerticesOpaque(const SharVisionOS::MirrorSource& source)
{
    const Vertex* vertices = static_cast<const Vertex*>(source.vertices);
    for (uint32_t i = 0; i < source.vertexCount; ++i)
        if ((vertices[i].colour >> 24) < 250) return false;
    return true;
}

// Whether a mesh's data keeps changing (CPU-skinned skins, expression-animated vertices). Each new
// version used to be copied as a new mesh, the old one removed: a part animating every frame never
// stayed made long enough to show (a crashed Homer was left with only his eyes). Such a mesh is
// drawn as dynamic geometry until it has been still for half a second.
bool MeshAnimating(const SharVisionOS::MirrorSource& source)
{
    std::lock_guard<std::mutex> lock(gMutex);
    auto known = gMeshes.find(source.mesh);
    if (known == gMeshes.end()) return false;
    Known& mesh = known->second;
    if (source.version != mesh.latestVersion)
    {
        mesh.latestVersion = source.version;
        ++mesh.changes;
        mesh.changedFrame = gCounts.frames;
    }
    return mesh.changes >= 2 && gCounts.frames - mesh.changedFrame < 45;
}

uint64_t MeshId(const SharVisionOS::MirrorSource& source, bool* verticesOpaque)
{
    std::lock_guard<std::mutex> lock(gMutex);
    auto known = gMeshes.find(source.mesh);
    if (known != gMeshes.end() && known->second.version == source.version)
    {
        *verticesOpaque = known->second.alpha == kAlphaOpaque;
        return known->second.id;
    }
    Known mesh = {source.version, gNextId++};
    if (known != gMeshes.end())
    {
        gRemoved.push_back(known->second.id);
        mesh.changes = known->second.changes;
        mesh.changedFrame = known->second.changedFrame;
    }
    mesh.latestVersion = source.version;
    *verticesOpaque = VerticesOpaque(source);
    mesh.alpha = *verticesOpaque ? kAlphaOpaque : kAlphaTranslucent;
    gMeshes[source.mesh] = mesh;
    gPendingMeshes.push_back(CopyMesh(source, mesh.id));
    return mesh.id;
}

uint64_t TextureId(const SharVisionOS::MirrorSource& source, AlphaKind* alpha)
{
    *alpha = kAlphaOpaque;  // none: white
    if (!source.texture || !source.copyPixels) return 0;
    {
        std::lock_guard<std::mutex> lock(gMutex);
        auto known = gTextures.find(source.texture);
        if (known != gTextures.end())
        {
            *alpha = known->second.alpha;
            return known->second.id;
        }
        if (gUncopiedTextures.count(source.texture)) return 0;
    }
    Texture texture;
    unsigned width = 0, height = 0;
    if (!source.copyPixels(source.texture, &texture.pixels, &width, &height) || !width || !height)
    {
        std::lock_guard<std::mutex> lock(gMutex);
        gUncopiedTextures.insert(source.texture);
        if (gUncopiedTextures.size() <= 10)
            NSLog(@"[SharVisionOS] mirror: texture %p (%ux%u) couldn't be copied; it shows white", source.texture, width, height);
        return 0;
    }
    texture.width = width;
    texture.height = height;
    texture.mipmapped = source.textureMipmapped;
    // BGRA: alpha is every fourth byte.
    size_t translucent = 0;
    unsigned char lowest = 255;
    for (size_t i = 3; i < texture.pixels.size(); i += 4)
    {
        const unsigned char a = texture.pixels[i];
        lowest = std::min(lowest, a);
        translucent += a > 25 && a < 230;
    }
    const size_t texels = texture.pixels.size() / 4;
    *alpha = lowest >= 250 ? kAlphaOpaque : translucent * 10 <= texels ? kAlphaBinary : kAlphaTranslucent;
    texture.cutout = *alpha == kAlphaBinary;
    AlphaPlane plane = {width, height, {}};
    if (*alpha != kAlphaOpaque && texels <= 4096 * 4096)
    {
        plane.alpha.resize(texels);
        for (size_t i = 0; i < texels; ++i) plane.alpha[i] = texture.pixels[i * 4 + 3];
    }
    std::lock_guard<std::mutex> lock(gMutex);
    if (!plane.alpha.empty()) gAlphaPlanes[source.texture] = std::move(plane);
    texture.id = gNextId++;
    Known known = {0, texture.id};
    known.alpha = *alpha;
    gTextures[source.texture] = known;
    const uint64_t id = texture.id;
    gPendingTextures.push_back(std::move(texture));
    return id;
}

// Whether a part draws with a blended material (MirrorBlend), not an opaque or cut-out one.
bool BlendedPart(const SharVisionOSMirrorPart& part)
{
    return part.blend != SHARVISIONOS_MIRROR_BLEND_NONE &&
           !(part.blend == SHARVISIONOS_MIRROR_BLEND_ALPHA && part.alphaCutoff > 0);
}

// The alpha of the part of its texture a mesh's UVs cover: a traffic car's atlas is a paint mask,
// alpha 223 on most of it, so as a whole it's translucent, and the wheels and cabs drawn with it
// were blends (two-sided, writing depth, in RealityKit's order), though the texels they sample are
// all opaque. Judged once for each mesh and texture, at each triangle's corners, edge middles and
// centre, sampled as the engine does (its rows run with V).
AlphaKind CoveredAlpha(const SharVisionOS::MirrorSource& source, AlphaKind textureAlpha)
{
    if (textureAlpha == kAlphaOpaque || !source.mesh || !source.texture) return textureAlpha;
    std::lock_guard<std::mutex> lock(gMutex);
    const auto key = std::make_tuple(source.mesh, source.version, source.texture);
    auto known = gCoverage.find(key);
    if (known != gCoverage.end()) return known->second;
    AlphaKind kind = textureAlpha;
    auto plane = gAlphaPlanes.find(source.texture);
    if (plane != gAlphaPlanes.end())
    {
        const AlphaPlane& p = plane->second;
        const Vertex* vertices = static_cast<const Vertex*>(source.vertices);
        const bool indexed = source.indices && source.indexCount;
        const uint32_t count = indexed ? source.indexCount : source.vertexCount;
        auto index = [&](uint32_t i) { return indexed ? (uint32_t)source.indices[i] : i; };
        unsigned lowest = 255;
        size_t samples = 0, translucent = 0;
        auto sample = [&](float u, float v) {
            u -= std::floor(u);
            v -= std::floor(v);
            const uint32_t x = std::min((uint32_t)(u * p.width), p.width - 1), y = std::min((uint32_t)(v * p.height), p.height - 1);
            const unsigned a = p.alpha[(size_t)y * p.width + x];
            lowest = std::min(lowest, a);
            translucent += a > 25 && a < 230;
            ++samples;
        };
        auto triangle = [&](uint32_t a, uint32_t b, uint32_t c) {
            if (a >= source.vertexCount || b >= source.vertexCount || c >= source.vertexCount) return;
            const float* ua = vertices[a].uv;
            const float* ub = vertices[b].uv;
            const float* uc = vertices[c].uv;
            sample(ua[0], ua[1]);
            sample(ub[0], ub[1]);
            sample(uc[0], uc[1]);
            sample((ua[0] + ub[0]) / 2, (ua[1] + ub[1]) / 2);
            sample((ub[0] + uc[0]) / 2, (ub[1] + uc[1]) / 2);
            sample((uc[0] + ua[0]) / 2, (uc[1] + ua[1]) / 2);
            sample((ua[0] + ub[0] + uc[0]) / 3, (ua[1] + ub[1] + uc[1]) / 3);
        };
        if (source.topology == 1)
            for (uint32_t i = 0; i + 2 < count; ++i) triangle(index(i), index(i + 1), index(i + 2));
        else
            for (uint32_t i = 0; i + 2 < count; i += 3) triangle(index(i), index(i + 1), index(i + 2));
        if (samples)
            kind = lowest >= 250 ? kAlphaOpaque : translucent * 10 <= samples ? kAlphaBinary : kAlphaTranslucent;
    }
    gCoverage[key] = kind;
    return kind;
}

bool SamePart(const SharVisionOSMirrorPart& a, const SharVisionOSMirrorPart& b)
{
    return a.texture == b.texture && simd_equal(a.colour, b.colour) && simd_equal(a.ambient, b.ambient) &&
           a.alphaCutoff == b.alphaCutoff && a.flags == b.flags && a.blend == b.blend;
}

// Whether a dynamic vertex is somewhere a renderer can use (window units): a world coin's trail
// sparkles fly off with a velocity read from the wrong half of a union (coinmanager.h's ActiveCoin),
// out to 1e20 or beyond for over a second. The engine never sees them; in a dynamic mesh, whose
// bounds all its parts share, they could take everything in it with them.
bool Sane(simd_float3 p)
{
    return std::isfinite(p.x) && std::isfinite(p.y) && std::isfinite(p.z) && simd_length_squared(p) < 1e8f;
}

// A dynamic draw's geometry, skinned as the vertex shader does it (four weighted bones) when the
// material has a palette, flipped to right-handed and taken through `transform` into window units,
// its triangles (strips unrolled into a list) added to its material's group.
//
// A lit draw is lit here, per vertex, as lit.vert does it, with its own lights and ambient: its part
// is then unlit. In the materials instead, every change of a character's ambient (it changes as
// they move through the level's light) was a new material, and a frame of new materials cost the
// mirror 15 ms.
void AppendDynamic(const SharVisionOS::MirrorSource& source, const SharOpenXR::VulkanMaterialState& material,
                   const simd_float4x4& modelview, const simd_float4x4& transform, const SharVisionOSMirrorPart& part)
{
    const bool lit = part.flags & SHARVISIONOS_MIRROR_LIT;
    const Vertex* vertices = static_cast<const Vertex*>(source.vertices);
    const uint32_t base = (uint32_t)gBuildingVertices.size();
    simd_float4x4 bones[SharOpenXR::VulkanMaterialState::MaxSkinMatrices];
    const uint32_t boneCount = std::min<uint32_t>(material.skinMatrixCount, SharOpenXR::VulkanMaterialState::MaxSkinMatrices);
    for (uint32_t b = 0; b < boneCount; ++b)
        for (int c = 0; c < 4; ++c)
        {
            const float* m = material.skinMatrices[b];
            bones[b].columns[c] = simd_make_float4(m[c * 4], m[c * 4 + 1], m[c * 4 + 2], m[c * 4 + 3]);
        }
    for (uint32_t i = 0; i < source.vertexCount; ++i)
    {
        Vertex vertex = vertices[i];
        simd_float4 position = simd_make_float4(vertex.position[0], vertex.position[1], vertex.position[2], 1);
        simd_float4 normal = simd_make_float4(vertex.normal[0], vertex.normal[1], vertex.normal[2], 0);
        if (boneCount)
        {
            const float weights[4] = {vertex.skinWeights[0], vertex.skinWeights[1], vertex.skinWeights[2],
                                      1.0f - vertex.skinWeights[0] - vertex.skinWeights[1] - vertex.skinWeights[2]};
            simd_float4 skinned = 0, skinnedNormal = 0;
            for (int b = 0; b < 4; ++b)
            {
                const uint32_t bone = vertex.skinIndices[b];
                if (bone >= boneCount || weights[b] == 0.0f) continue;
                skinned += simd_mul(bones[bone], position) * weights[b];
                skinnedNormal += simd_mul(bones[bone], normal) * weights[b];
            }
            position = skinned;
            normal = skinnedNormal;
        }
        simd_float4 tint = simd_clamp(part.colour, 0.0f, 1.0f);
        if (lit)
        {
            // In Pure3D's view space, as lit.vert has it.
            const simd_float3 view = simd_mul(modelview, position).xyz;
            simd_float3 eyeNormal = simd_mul(modelview, normal).xyz;
            const float eyeLength = simd_length(eyeNormal);
            eyeNormal = eyeLength > 0 ? eyeNormal / eyeLength : simd_make_float3(0, 0, -1);
            simd_float3 light = part.ambient.xyz;
            for (int l = 0; l < 8; ++l)
            {
                if (material.lightAttenuation[l][3] < 0.5f) continue;
                const float* at = material.lightPosition[l];
                const simd_float3 delta = simd_make_float3(at[0], at[1], at[2]) - at[3] * view;
                const float distance = simd_length(delta);
                const float facing = std::max(simd_dot(eyeNormal, delta / std::max(distance, 1e-4f)), 0.0f);
                const float* k = material.lightAttenuation[l];
                const float attenuation =
                    at[3] != 0.0f ? 1.0f / std::max(k[0] + k[1] * distance + k[2] * distance * distance, 1e-4f) : 1.0f;
                light += attenuation * facing * part.colour.xyz *
                         simd_make_float3(material.lightColour[l][0], material.lightColour[l][1], material.lightColour[l][2]);
            }
            tint = simd_make_float4(simd_clamp(light, 0.0f, 1.0f), simd_clamp(part.colour.w, 0.0f, 1.0f));
        }
        position.z = -position.z;
        normal.z = -normal.z;
        position = simd_mul(transform, position);
        // The transform scales uniformly, so its rotation part takes normals too.
        simd_float3 n = simd_mul(transform, normal).xyz;
        const float length = simd_length(n);
        n = length > 0 ? n / length : simd_make_float3(0, 0, 1);
        // The colour (or the lighting) goes into the vertex colour (the material multiplies them
        // anyway), so parts differ by texture and blend, not by a particle's fade or a light.
        uint32_t colour = 0;
        for (int c = 0; c < 4; ++c)
            colour |= (uint32_t)std::lround(((vertex.colour >> (8 * c)) & 255) * tint[c]) << (8 * c);
        gBuildingVertices.push_back({{position.x, position.y, position.z}, {n.x, n.y, n.z}, {vertex.uv[0], vertex.uv[1]}, colour});
    }
    SharVisionOSMirrorPart grouped = part;
    grouped.colour = simd_make_float4(1, 1, 1, 1);
    grouped.ambient = 0;
    grouped.flags &= ~SHARVISIONOS_MIRROR_LIT;
    // A solid part joins any group of its material: depth sorts solids out. A blended one joins
    // only the last blended group, when that's of its material, so blended groups keep the order
    // the game drew them in: its translucent pass has already sorted characters, smoke and cars far
    // to near (each by its bounds' nearest point), and its sparkles and smoke puffs come after.
    // Merged across the frame and ordered by each group's centre instead, fading pedestrians far up
    // the road were drawn after the smoke in front of them whenever their centre came nearer than
    // the smoke's, so they showed through it unsmoked.
    Group* group = nullptr;
    if (!BlendedPart(grouped))
    {
        for (Group& existing : gGroups)
            if (SamePart(existing.part, grouped)) { group = &existing; break; }
    }
    else if (gLastBlendedGroup < gGroups.size() && SamePart(gGroups[gLastBlendedGroup].part, grouped))
        group = &gGroups[gLastBlendedGroup];
    if (!group)
    {
        if (BlendedPart(grouped)) gLastBlendedGroup = gGroups.size();
        gGroups.push_back({grouped, {}});
        group = &gGroups.back();
    }
    auto index = [&](uint32_t i) {
        return source.indices && source.indexCount ? (uint32_t)source.indices[i] : i;
    };
    auto sane = [&](uint32_t a, uint32_t b, uint32_t c) {
        auto at = [&](uint32_t v) {
            const float* p = gBuildingVertices[base + v].position;
            return simd_make_float3(p[0], p[1], p[2]);
        };
        return Sane(at(a)) && Sane(at(b)) && Sane(at(c));
    };
    const uint32_t count = source.indices && source.indexCount ? source.indexCount : source.vertexCount;
    // Turned round for RealityKit, as CopyMesh does it.
    if (source.topology == 1)
    {
        for (uint32_t i = 0; i + 2 < count; ++i)
        {
            const uint32_t a = index(i), b = index(i + 1), c = index(i + 2);
            if (a == b || b == c || a == c || !sane(a, b, c)) continue;
            if (i & 1) group->indices.insert(group->indices.end(), {base + b, base + c, base + a});
            else group->indices.insert(group->indices.end(), {base + a, base + c, base + b});
        }
    }
    else
        for (uint32_t i = 0; i + 2 < count; i += 3)
            if (sane(index(i), index(i + 1), index(i + 2)))
                group->indices.insert(group->indices.end(), {base + index(i), base + index(i + 2), base + index(i + 1)});
}
}

namespace SharVisionOS
{
bool IsMirrorEnabled()
{
    return gEnabled;
}

void SetMirrorSource(const MirrorSource* source)
{
    gHaveSource = source != nullptr;
    if (source) gSource = *source;
}

void ForgetMirrorObject(const void* object)
{
    std::lock_guard<std::mutex> lock(gMutex);
    gUncopiedTextures.erase(object);
    gAlphaPlanes.erase(object);
    for (auto entry = gCoverage.begin(); entry != gCoverage.end();)
    {
        if (std::get<0>(entry->first) == object || std::get<2>(entry->first) == object) entry = gCoverage.erase(entry);
        else ++entry;
    }
    for (auto* map : {&gMeshes, &gTextures})
    {
        auto known = map->find(object);
        if (known == map->end()) continue;
        gRemoved.push_back(known->second.id);
        map->erase(known);
    }
}

void MirrorDraw(const float* projection, const float* modelview, const SharOpenXR::VulkanMaterialState& material,
               bool centreEye)
{
    if (!gRecording) return;
    // A perspective projection divides by view depth (its w row picks z); an orthographic one doesn't.
    if (projection && std::fabs(projection[11]) < 0.5f)
    {
        gHaveSource = false;
        ++gCounts.screen;
        return;
    }
    if (!gHaveSource)
    {
        ++gCounts.noSource;
        return;
    }
    // One record per source: the toon outline draws the same source again.
    const MirrorSource source = gSource;
    gHaveSource = false;
    if (source.topology > 1 || !source.vertices || !source.vertexCount) return;

    SharVisionOSMirrorDraw draw = {};
    AlphaKind textureAlpha;
    draw.texture = TextureId(source, &textureAlpha);

    // Object to eye view (Pure3D row-vector rows are simd columns), flipped to right-handed, then
    // placed from that eye in window units (see visionos_window.h).
    simd_float4x4 m;
    for (int c = 0; c < 4; ++c)
        m.columns[c] = simd_make_float4(modelview[c * 4], modelview[c * 4 + 1], modelview[c * 4 + 2], modelview[c * 4 + 3]);
    const simd_float4x4 flip = simd_diagonal_matrix(simd_make_float4(1, 1, -1, 1));
    const float scale = 1.0f / (2.0f * kWindowPlaneDistance * kWindowHalfFovTangent);
    simd_float4x4 place = simd_diagonal_matrix(simd_make_float4(scale, scale, scale, 1));
    place.columns[3] = simd_make_float4(scale * (centreEye ? 0.0f : -gEyeOffset), 0, scale * kWindowPlaneDistance, 1);
    // A mesh drawn again where it was just drawn is a second pass over the first (a traffic car's
    // paint, then its trim and lamps; a decal pass). The game's LEQUAL depth test lets the later one
    // win; RealityKit's two coplanar entities would fight. Each repeat is drawn a hair nearer the eye.
    if (source.mesh)
    {
        uint64_t key = (uint64_t)(uintptr_t)source.mesh;
        for (int i = 12; i < 15; ++i)
        {
            uint32_t bits;
            std::memcpy(&bits, &modelview[i], sizeof bits);
            key = (key ^ bits) * 1099511628211ull;
        }
        const unsigned repeat = gPasses[key]++;
        if (repeat)
        {
            ++gCounts.repeats;
            const float nearer = 1.0f - 2e-4f * (float)std::min(repeat, 8u);
            m = simd_mul(simd_diagonal_matrix(simd_make_float4(nearer, nearer, nearer, 1)), m);
        }
    }
    draw.transform = simd_mul(place, simd_mul(flip, simd_mul(m, flip)));

    // The engine's colour (compact.vert, lit.vert): an unlit draw takes the vertex colour times the
    // ambient term, and a lit one times the ambient plus the material colour times the lights
    // (WindowFrame.usda does that part). The material colour's alpha applies either way.
    draw.colour = material.lit
        ? simd_make_float4(material.colour[0], material.colour[1], material.colour[2], material.colour[3])
        : simd_make_float4(material.ambientTerm[0], material.ambientTerm[1], material.ambientTerm[2], material.colour[3]);
    draw.alphaCutoff = material.alphaTest ? std::max(material.alphaRef, 0.01f) : 0.0f;
    if (material.twoSided || material.cullMode == 0) draw.flags |= SHARVISIONOS_MIRROR_TWO_SIDED;
    if (material.lit)
    {
        // Each lit draw's own ambient: the frame's lights are shared, but a draw's ambient carries
        // its material's ambient and emissive, and taken from whichever lit draw came first it set
        // every lit thing's brightness, changing as the draw order did.
        draw.flags |= SHARVISIONOS_MIRROR_LIT;
        draw.ambient = simd_make_float4(material.ambientTerm[0], material.ambientTerm[1], material.ambientTerm[2], 0);
        if (!gBuildingLights.found)
        {
            // Pure3D's lights are in view space, and a directional one's position is the direction
            // towards it: flipped to right-handed, that's window space's too.
            gBuildingLights.found = true;
            gBuildingLights.ambient = simd_make_float3(material.ambientTerm[0], material.ambientTerm[1], material.ambientTerm[2]);
            int used = 0;
            for (int i = 0; i < 8 && used < 3; ++i)
            {
                if (material.lightAttenuation[i][3] < 0.5f || material.lightPosition[i][3] != 0.0f) continue;
                const simd_float3 towards = simd_make_float3(material.lightPosition[i][0], material.lightPosition[i][1],
                                                             -material.lightPosition[i][2]);
                if (simd_length(towards) < 1e-4f) continue;
                gBuildingLights.directions[used] = simd_normalize(towards);
                gBuildingLights.colours[used] = simd_make_float3(material.lightColour[i][0], material.lightColour[i][1],
                                                                 material.lightColour[i][2]);
                ++used;
            }
        }
    }
    draw.blend = material.blendMode;
    ++gCounts.draws;
    const bool animating = source.mesh && material.skinMatrixCount == 0 && MeshAnimating(source);
    const bool dynamic = !source.mesh || material.skinMatrixCount > 0 || animating;
    bool verticesOpaque = false;
    if (!dynamic)
    {
        draw.mesh = MeshId(source, &verticesOpaque);
        textureAlpha = CoveredAlpha(source, textureAlpha);
    }
    else if (draw.blend == SHARVISIONOS_MIRROR_BLEND_ALPHA && draw.alphaCutoff == 0.0f) verticesOpaque = VerticesOpaque(source);

    // Alpha blending the game draws solid. It blends whole vehicles (every shader of a car built on
    // a traffic model, every frame: GeometryVehicle::Display) and characters, for their fades, but
    // writes their depth, so a vehicle hides its own far side. RealityKit writes no depth for a blend
    // and draws a mesh's triangles in order, so a truck's near panels showed its far side's inside.
    // A draw that can't be translucent (nothing in its texture, vertices or colour is) is opaque; one
    // whose texture is all but on or off (foliage, hair, trim) is a cutout, which keeps its depth.
    if (draw.blend == SHARVISIONOS_MIRROR_BLEND_ALPHA && draw.alphaCutoff == 0.0f && material.depthWrite &&
        material.depthTest && draw.colour.w >= 0.996f && verticesOpaque)
    {
        if (textureAlpha == kAlphaOpaque)
        {
            draw.blend = SHARVISIONOS_MIRROR_BLEND_NONE;
            ++gCounts.madeOpaque;
        }
        else if (textureAlpha == kAlphaBinary)
        {
            draw.alphaCutoff = 0.5f;
            ++gCounts.madeCutout;
        }
    }
    // A character whose texture has soft edges (hair) is still solid: as a cutout it keeps its
    // depth, so one limb doesn't show through another. Not while it fades, or it would vanish.
    if (source.mesh && material.skinMatrixCount > 0 && draw.blend == SHARVISIONOS_MIRROR_BLEND_ALPHA &&
        draw.alphaCutoff == 0.0f && draw.colour.w >= 0.996f)
        draw.alphaCutoff = 0.5f;
    if (draw.blend != SHARVISIONOS_MIRROR_BLEND_NONE &&
        !(draw.blend == SHARVISIONOS_MIRROR_BLEND_ALPHA && draw.alphaCutoff > 0.0f))
    {
        ++gCounts.blended;
        // What's still blended writes depth if the game's does: a traffic car's wheels (its atlas
        // is 87% opaque) hide their own far side in the game, and showed it in the mirror.
        if (material.depthWrite && material.depthTest) draw.flags |= SHARVISIONOS_MIRROR_DEPTH_WRITE;
        // One that writes no depth lies on something, mostly: blob shadows, skid marks, ground
        // decals. While the mirror is up the game puts them just off the ground (its own lift,
        // towards its camera, was up to a metre: patch 0002's SharOpenXR::IsSceneMirrorUp and
        // GroundShadowOffset), and a little nearer the eye still (0.4% of the way, at most 2 cm)
        // they lie on top of it at any distance rather than shimmering into it.
        else
        {
            const float nearer = 1.0f - std::min(4e-3f, 0.02f / std::max(simd_length(m.columns[3].xyz), 1e-3f));
            m = simd_mul(simd_diagonal_matrix(simd_make_float4(nearer, nearer, nearer, 1)), m);
            draw.transform = simd_mul(place, simd_mul(flip, simd_mul(m, flip)));
        }
    }
    if (dynamic)
    {
        ++(!source.mesh ? gCounts.immediate : animating ? gCounts.animating : gCounts.skinned);
        SharVisionOSMirrorPart part = {0, 0, draw.texture, draw.colour, draw.ambient, draw.alphaCutoff, draw.flags, draw.blend};
        AppendDynamic(source, material, m, draw.transform, part);
        return;
    }
    gBuilding.push_back(draw);
}

void BeginMirrorFrame(float eyeOffset, float exposure)
{
    gRecording = gEnabled;
    gEyeOffset = eyeOffset;
    gExposure = exposure;
    gBuilding.clear();
    gBuildingVertices.clear();
    gGroups.clear();
    gLastBlendedGroup = SIZE_MAX;
    gHaveSource = false;
    gBuildingLights = Lights();
    gPasses.clear();
}

void EndMirrorFrame()
{
    if (!gRecording) return;
    gRecording = false;
    // Solid groups first, then the blended ones in the order the game drew them (AppendDynamic).
    std::vector<size_t> order;
    for (size_t i = 0; i < gGroups.size(); ++i)
        if (!BlendedPart(gGroups[i].part)) order.push_back(i);
    for (size_t i = 0; i < gGroups.size(); ++i)
        if (BlendedPart(gGroups[i].part)) order.push_back(i);
    // The solid groups and the blended ones become two meshes (the app draws the solid one with the
    // level's opaque geometry, the blended one after every blended draw), so their vertices are
    // gathered apart: the solid groups' first, then the blended groups', whose indices count from
    // the first of theirs.
    // (Kept from frame to frame: each swap below hands back the last frame's, capacity and all.)
    static std::vector<DynamicVertex> vertices;
    static std::vector<uint32_t> indices, remap;
    static std::vector<SharVisionOSMirrorPart> parts;
    vertices.clear();
    indices.clear();
    parts.clear();
    remap.assign(gBuildingVertices.size(), UINT32_MAX);
    uint32_t solidVertices = 0, solidIndices = 0, solidParts = 0;
    bool solid = true;
    for (size_t entry : order)
    {
        Group& group = gGroups[entry];
        if (solid && BlendedPart(group.part))
        {
            solid = false;
            solidVertices = (uint32_t)vertices.size();
            solidIndices = (uint32_t)indices.size();
            solidParts = (uint32_t)parts.size();
        }
        group.part.firstIndex = (uint32_t)indices.size();
        group.part.indexCount = (uint32_t)group.indices.size();
        for (uint32_t i : group.indices)
        {
            uint32_t& to = remap[i];
            if (to == UINT32_MAX || (!solid && to < solidVertices))
            {
                to = (uint32_t)vertices.size();
                vertices.push_back(gBuildingVertices[i]);
            }
            indices.push_back(solid ? to : to - solidVertices);
        }
        parts.push_back(group.part);
    }
    if (solid)
    {
        solidVertices = (uint32_t)vertices.size();
        solidIndices = (uint32_t)indices.size();
        solidParts = (uint32_t)parts.size();
    }
    // Each mesh's bounds, from the vertices its triangles use (runaway ones were dropped with
    // their triangles).
    simd_float3 low[2], high[2];
    for (int layer = 0; layer < 2; ++layer)
    {
        low[layer] = simd_make_float3(INFINITY, INFINITY, INFINITY);
        high[layer] = -low[layer];
        const size_t first = layer ? solidVertices : 0, last = layer ? vertices.size() : solidVertices;
        for (size_t i = first; i < last; ++i)
        {
            const simd_float3 p = simd_make_float3(vertices[i].position[0], vertices[i].position[1], vertices[i].position[2]);
            low[layer] = simd_min(low[layer], p);
            high[layer] = simd_max(high[layer], p);
        }
    }
    {
        std::lock_guard<std::mutex> lock(gMutex);
        gLatest.swap(gBuilding);
        gLatestVertices.swap(vertices);
        gLatestIndices.swap(indices);
        gLatestParts.swap(parts);
        gLatestSolidVertices = solidVertices;
        gLatestSolidIndices = solidIndices;
        gLatestSolidParts = solidParts;
        gLatestExposure = gExposure;
        if (gBuildingLights.found) gLatestLights = gBuildingLights;
        for (int layer = 0; layer < 2; ++layer)
        {
            gLatestLow[layer] = low[layer];
            gLatestHigh[layer] = high[layer];
        }
        ++gSerial;
    }
    if (++gCounts.frames % 300 == 0)
    {
        std::lock_guard<std::mutex> lock(gMutex);
        NSLog(@"[SharVisionOS] mirror: %u draws a frame (%u skinned, %u animating, %u immediate; %u screen-space and "
              @"%u without a source skipped; %u blended, %u alpha blends drawn opaque, %u as cutouts; %u second passes "
              @"brought forward); %zu meshes, %zu textures known, %zu textures couldn't be copied", gCounts.draws / 300,
              gCounts.skinned / 300, gCounts.animating / 300, gCounts.immediate / 300, gCounts.screen / 300,
              gCounts.noSource / 300, gCounts.blended / 300, gCounts.madeOpaque / 300, gCounts.madeCutout / 300,
              gCounts.repeats / 300, gMeshes.size(), gTextures.size(), gUncopiedTextures.size());
        const unsigned frames = gCounts.frames;
        gCounts = Counts{};
        gCounts.frames = frames;
    }
}
}

extern "C" void SharVisionOS_SetMirrorEnabled(bool enabled)
{
    // A new mirror (the window opened again) has none of the meshes and textures the last one
    // was sent: forget them, so the draws that use them send them again.
    if (enabled)
    {
        std::lock_guard<std::mutex> lock(gMutex);
        gMeshes.clear();
        gTextures.clear();
        gUncopiedTextures.clear();
        gAlphaPlanes.clear();
        gCoverage.clear();
        gPendingMeshes.clear();
        gPendingTextures.clear();
        gRemoved.clear();
    }
    gEnabled = enabled;
}

extern "C" bool SharVisionOS_MirrorAcquire(SharVisionOSMirrorFrame* frame)
{
    {
        std::lock_guard<std::mutex> lock(gMutex);
        // Nothing until the first frame is done. Its meshes and textures are queued as it draws,
        // and the app drops an acquire with no frame: taken then, they were never sent again. A
        // window opened mid-level (switched to from Full) records the whole level in its first
        // frame, a few seconds of it, and showed black where those meshes should be.
        if (gSerial == 0) return false;
        gAcquiredDraws = gLatest;
        gAcquiredVertices = gLatestVertices;
        gAcquiredIndices = gLatestIndices;
        gAcquiredParts = gLatestParts;
        frame->dynamicSolidVertexCount = gLatestSolidVertices;
        frame->dynamicSolidIndexCount = gLatestSolidIndices;
        frame->dynamicSolidPartCount = gLatestSolidParts;
        for (int layer = 0; layer < 2; ++layer)
        {
            frame->dynamicBoundsMin[layer] = gLatestLow[layer];
            frame->dynamicBoundsMax[layer] = gLatestHigh[layer];
        }
        frame->exposure = gLatestExposure;
        frame->ambient = gLatestLights.ambient;
        for (int i = 0; i < 3; ++i)
        {
            frame->lightDirections[i] = gLatestLights.directions[i];
            frame->lightColours[i] = gLatestLights.colours[i];
        }
        gAcquiredMeshes.clear();
        gAcquiredMeshes.swap(gPendingMeshes);
        gAcquiredTextures.clear();
        gAcquiredTextures.swap(gPendingTextures);
        gAcquiredRemoved.clear();
        gAcquiredRemoved.swap(gRemoved);
        frame->serial = gSerial;
    }
    gMeshViews.clear();
    for (const Mesh& mesh : gAcquiredMeshes)
        gMeshViews.push_back({mesh.id, mesh.vertices.data(), (uint32_t)mesh.vertices.size(), mesh.indices.data(),
                              (uint32_t)mesh.indices.size(), mesh.boundsMin, mesh.boundsMax});
    gTextureViews.clear();
    for (const Texture& texture : gAcquiredTextures)
        gTextureViews.push_back({texture.id, texture.pixels.data(), texture.width, texture.height, texture.mipmapped,
                                 texture.cutout});
    frame->draws = gAcquiredDraws.data();
    frame->drawCount = (uint32_t)gAcquiredDraws.size();
    frame->meshes = gMeshViews.data();
    frame->meshCount = (uint32_t)gMeshViews.size();
    frame->textures = gTextureViews.data();
    frame->textureCount = (uint32_t)gTextureViews.size();
    frame->removed = gAcquiredRemoved.data();
    frame->removedCount = (uint32_t)gAcquiredRemoved.size();
    frame->dynamicVertices = gAcquiredVertices.data();
    frame->dynamicVertexCount = (uint32_t)gAcquiredVertices.size();
    frame->dynamicIndices = gAcquiredIndices.data();
    frame->dynamicIndexCount = (uint32_t)gAcquiredIndices.size();
    frame->dynamicParts = gAcquiredParts.data();
    frame->dynamicPartCount = (uint32_t)gAcquiredParts.size();
    return frame->serial != 0;
}
