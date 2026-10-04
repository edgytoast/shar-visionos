#include <vr/visionos/visionos_window.h>
#include <vr/visionos/visionos_entry.h>

#import <Foundation/Foundation.h>
#include <simd/simd.h>

#include <algorithm>
#include <cmath>

namespace
{
using namespace SharVisionOS;

constexpr NSUInteger kColumns = SHARVISIONOS_WINDOW_GRID_COLUMNS, kRows = SHARVISIONOS_WINDOW_GRID_ROWS;
constexpr NSUInteger kGridVertices = SHARVISIONOS_WINDOW_GRID_VERTICES;
constexpr NSUInteger kGridIndices = SHARVISIONOS_WINDOW_GRID_INDICES;
// How far the skirt reaches past the picture's edge, in view tangent (about 30 degrees).
constexpr float kSkirt = 0.6f;
// The nearest the relief comes is the window's face: anything nearer (the camera up against a
// wall) flattens onto it rather than standing out of the window, where its edges would cut it off.
// The farthest bounds the sky, which the depth buffer puts at the far plane.
constexpr float kNearest = kWindowPlaneDistance, kFarthest = 400.0f;
// A cell is cut from a layer when its corners' distances differ by more than this ratio: it
// spans a depth step, where a single surface would stretch the nearer thing onto the farther.
constexpr float kCutRatio = 1.12f;
// How far behind its own surface (a fraction of the distance, along the rays of the eye it was
// rendered from) each layer sits, so that nearer layers win where they have the scene.
constexpr float kSecondaryPush = 0.02f, kBackstopPush = 0.05f;
// A pixel belongs to the HUD when the HUD changed it by more than this (8-bit steps).
constexpr float kHudThreshold = 1.5f / 255.0f;

// Mirrors `ReliefParams` in the shader below.
struct ReliefParams
{
    simd_float4 depthTerms[2];  // each eye's projection entries 10, 11, 14 and 15
    simd_float2 eyeOffset;      // game metres from the centre, left then right
    simd_float2 halfTangent;    // the window's half-width and half-height as view tangents
    simd_float2 overscan;       // how far the picture reaches past the window, in view tangent
    simd_float3 push;           // the three layers' pushes
    float planeDistance, nearest, farthest, skirt, cutRatio;
    uint32_t columns, rows, hasDepth;
};

NSString* const kShader = @R"(
#include <metal_stdlib>
using namespace metal;

struct ReliefParams
{
    float4 depthTerms[2];
    float2 eyeOffset;
    float2 halfTangent;
    float2 overscan;
    float3 push;
    float planeDistance, nearest, farthest, skirt, cutRatio;
    uint columns, rows, hasDepth;
};

constant uint kLayers = 3;  // primary, secondary, backstop

static float Distance(float depth, float4 t, constant ReliefParams& p)
{
    // View depth from GL-range NDC depth: the projection's z and w rows involve only view z.
    const float ndc = depth * 2.0 - 1.0;
    const float distance = abs((ndc * t.w - t.z) / (t.x - ndc * t.y));
    return isfinite(distance) ? clamp(distance, p.nearest, p.farthest) : p.farthest;
}

// One vertex of an eye's grid, in each of its three layers, in window units along its pixel's ray
// from that eye. The nearest depth in the cell either side (dilated) keeps a foreground edge's
// pixels on the foreground: the primary layer and the backstop use it. The farthest (eroded) keeps
// the secondary layer, which shows to the other eye, from standing a halo in front of its view.
// A skirt vertex takes the edge's distances, further out.
kernel void WindowRelief(depth2d<float, access::read> leftDepth [[texture(0)]],
                         depth2d<float, access::read> rightDepth [[texture(1)]],
                         device packed_float3* positions [[buffer(0)]],
                         device float2* distances [[buffer(1)]],
                         constant ReliefParams& p [[buffer(2)]],
                         uint3 id [[thread_position_in_grid]])
{
    const uint across = p.columns + 3, down = p.rows + 3;
    if (id.x >= across || id.y >= down || id.z > 1) return;
    const uint2 cell = uint2(clamp(int2(id.xy) - 1, int2(0), int2(p.columns, p.rows)));
    const float u = float(cell.x) / float(p.columns), v = float(cell.y) / float(p.rows);
    const float2 skirt = float2(id.x == 0 ? -1.0 : id.x == across - 1 ? 1.0 : 0.0,
                                id.y == 0 ? 1.0 : id.y == down - 1 ? -1.0 : 0.0) * p.skirt;
    float nearest = p.planeDistance * 1.001, farthest = nearest;
    if (p.hasDepth)
    {
        const int2 size = int2(leftDepth.get_width(), leftDepth.get_height());
        const int2 centre = int2(float2(u, v) * float2(size - 1) + 0.5);
        const int2 reach = int2(ceil(float2(size) / float2(p.columns, p.rows)));
        float low = 1.0, high = 0.0;
        for (int y = -reach.y; y <= reach.y; ++y)
            for (int x = -reach.x; x <= reach.x; ++x)
            {
                const uint2 at = uint2(clamp(centre + int2(x, y), int2(0), size - 1));
                const float depth = id.z == 0 ? leftDepth.read(at) : rightDepth.read(at);
                low = min(low, depth);
                high = max(high, depth);
            }
        nearest = Distance(low, p.depthTerms[id.z], p);
        farthest = Distance(high, p.depthTerms[id.z], p);
    }
    const float offset = p.eyeOffset[id.z], shift = offset / p.planeDistance;
    const float2 reachTan = p.halfTangent + p.overscan;
    const float tanX = mix(-(reachTan.x + shift), reachTan.x - shift, u) + skirt.x;
    const float tanY = mix(reachTan.y, -reachTan.y, v) + skirt.y;
    const float scale = 1.0 / (2.0 * p.planeDistance * p.halfTangent.x);
    const uint index = id.y * across + id.x, count = across * down;
    const float layerDistance[kLayers] = {nearest, farthest * (1.0 + p.push.y), nearest * (1.0 + p.push.z)};
    for (uint layer = 0; layer < kLayers; ++layer)
    {
        const float distance = layerDistance[layer];
        positions[(id.z * kLayers + layer) * count + index] =
            packed_float3(scale * (offset + tanX * distance), scale * tanY * distance,
                          scale * (p.planeDistance - distance));
    }
    distances[id.z * count + index] = float2(nearest, farthest);
}

// Each cell's two triangles, per eye, for the primary layer (dilated distances) and the secondary
// (eroded): a cell that spans a depth step gets degenerate triangles instead, cutting it out so
// that what sits behind it (the other eye's layer, or the backstop) shows there.
kernel void WindowCut(device const float2* distances [[buffer(0)]],
                      device uint* indices [[buffer(1)]],
                      constant ReliefParams& p [[buffer(2)]],
                      uint3 id [[thread_position_in_grid]])
{
    const uint across = p.columns + 3, down = p.rows + 3;
    if (id.x >= across - 1 || id.y >= down - 1 || id.z > 1) return;
    const uint count = across * down, cells = (across - 1) * (down - 1);
    const uint topLeft = id.y * across + id.x, bottomLeft = topLeft + across;
    const float2 a = distances[id.z * count + topLeft], b = distances[id.z * count + topLeft + 1];
    const float2 c = distances[id.z * count + bottomLeft], d = distances[id.z * count + bottomLeft + 1];
    const float2 low = min(min(a, b), min(c, d)), high = max(max(a, b), max(c, d));
    const bool2 cut = high > low * p.cutRatio;
    const uint cellIndex = id.y * (across - 1) + id.x;
    for (uint layer = 0; layer < 2; ++layer)
    {
        device uint* out = indices + ((id.z * 2 + layer) * cells + cellIndex) * 6;
        if (cut[layer])
        {
            for (uint i = 0; i < 6; ++i) out[i] = topLeft;
        }
        else
        {
            // Two counter-clockwise triangles, facing the viewer.
            out[0] = topLeft; out[1] = bottomLeft; out[2] = topLeft + 1;
            out[3] = topLeft + 1; out[4] = bottomLeft; out[5] = bottomLeft + 1;
        }
    }
}

// The HUD is whatever the engine drew over the scene, in the window's part of the picture: pixels
// that differ from the scene before it, opaque in their final colour (a translucent panel keeps the
// scene it was blended with). Both images are read and written through UNORM views, so the
// comparison is on the stored bytes.
kernel void WindowHud(texture2d_array<float, access::read> final [[texture(0)]],
                      texture2d_array<float, access::read> scene [[texture(1)]],
                      texture2d<float, access::write> hud [[texture(2)]],
                      constant float& threshold [[buffer(0)]],
                      constant uint2& origin [[buffer(1)]],
                      uint2 id [[thread_position_in_grid]])
{
    if (id.x >= hud.get_width() || id.y >= hud.get_height()) return;
    const float4 drawn = final.read(origin + id, 0), under = scene.read(origin + id, 0);
    const bool changed = any(abs(drawn.rgb - under.rgb) > threshold);
    hud.write(changed ? float4(drawn.rgb, 1) : float4(0), id);
}

// With the scene mirror, the engine draws only the HUD, over black in the left eye and white in the
// right (both through UNORM views, so blending is on the stored values): the difference is how
// much of the background shows through, which gives the HUD's alpha, and over black its colour is
// already premultiplied by it.
kernel void WindowHudPair(texture2d_array<float, access::read> final [[texture(0)]],
                          texture2d<float, access::write> hud [[texture(1)]],
                          constant uint2& origin [[buffer(0)]],
                          uint2 id [[thread_position_in_grid]])
{
    if (id.x >= hud.get_width() || id.y >= hud.get_height()) return;
    const float3 black = final.read(origin + id, 0).rgb, white = final.read(origin + id, 1).rgb;
    const float alpha = saturate(1.0 - dot(white - black, float3(1.0 / 3.0)));
    hud.write(float4(black, alpha), id);
}

// With no 3D scene (menus, loading, films) the whole picture is the HUD: flat on the window's face.
kernel void WindowFlat(texture2d_array<float, access::read> final [[texture(0)]],
                       texture2d<float, access::write> hud [[texture(1)]],
                       constant uint2& origin [[buffer(0)]],
                       uint2 id [[thread_position_in_grid]])
{
    if (id.x < hud.get_width() && id.y < hud.get_height()) hud.write(float4(final.read(origin + id, 0).rgb, 1), id);
}
)";

struct Pipelines
{
    id<MTLComputePipelineState> relief, cut, hud, flat, pair;
    id<MTLTexture> noDepth;  // bound in place of the depth when there is none
};

bool LoadPipelines(id<MTLDevice> device, Pipelines& pipelines)
{
    static id<MTLDevice> loadedFor = nil;
    static Pipelines loaded;
    if (loadedFor == device)
    {
        pipelines = loaded;
        return loaded.relief != nil;
    }
    loadedFor = device;
    NSError* error = nil;
    id<MTLLibrary> library = [device newLibraryWithSource:kShader options:[MTLCompileOptions new] error:&error];
    if (library)
    {
        loaded.relief = [device newComputePipelineStateWithFunction:[library newFunctionWithName:@"WindowRelief"]
                                                              error:&error];
        loaded.cut = [device newComputePipelineStateWithFunction:[library newFunctionWithName:@"WindowCut"]
                                                           error:&error];
        loaded.hud = [device newComputePipelineStateWithFunction:[library newFunctionWithName:@"WindowHud"]
                                                           error:&error];
        loaded.flat = [device newComputePipelineStateWithFunction:[library newFunctionWithName:@"WindowFlat"]
                                                            error:&error];
        loaded.pair = [device newComputePipelineStateWithFunction:[library newFunctionWithName:@"WindowHudPair"]
                                                            error:&error];
    }
    MTLTextureDescriptor* noDepth = [MTLTextureDescriptor new];
    noDepth.pixelFormat = MTLPixelFormatDepth32Float;
    noDepth.storageMode = MTLStorageModePrivate;
    noDepth.usage = MTLTextureUsageShaderRead;
    loaded.noDepth = [device newTextureWithDescriptor:noDepth];
    if (!loaded.relief || !loaded.cut || !loaded.hud || !loaded.flat || !loaded.pair || !loaded.noDepth)
    {
        NSLog(@"[SharVisionOS] window pipelines failed: %@", error);
        loaded = Pipelines();
    }
    pipelines = loaded;
    return loaded.relief != nil;
}

// The window's part of an eye's picture: the overscan is the same on either side.
MTLSize HudSize(NSUInteger eyeWidth, NSUInteger eyeHeight)
{
    const float x = kWindowHalfFovTangent / (kWindowHalfFovTangent + kWindowOverscanX);
    const float y = WindowHalfHeightTangent() / (WindowHalfHeightTangent() + kWindowOverscanY);
    return MTLSizeMake(std::max<NSUInteger>(1, (NSUInteger)std::lround(eyeWidth * x)),
                       std::max<NSUInteger>(1, (NSUInteger)std::lround(eyeHeight * y)), 1);
}

bool PrepareOutput(id<MTLDevice> device, NSUInteger eyeWidth, NSUInteger eyeHeight, MTLPixelFormat format,
                   WindowFrameOutput& output)
{
    if (!output.colour || output.colour.width != eyeWidth * 2 || output.colour.height != eyeHeight ||
        output.colour.pixelFormat != format)
    {
        MTLTextureDescriptor* descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format
            width:eyeWidth * 2 height:eyeHeight mipmapped:NO];
        descriptor.storageMode = MTLStorageModePrivate;
        descriptor.usage = MTLTextureUsageShaderRead;
        output.colour = [device newTextureWithDescriptor:descriptor];
    }
    const MTLSize hudSize = HudSize(eyeWidth, eyeHeight);
    if (!output.hud || output.hud.width != hudSize.width || output.hud.height != hudSize.height)
    {
        MTLTextureDescriptor* descriptor = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm_sRGB width:hudSize.width
            height:hudSize.height mipmapped:NO];
        descriptor.storageMode = MTLStorageModePrivate;
        descriptor.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite | MTLTextureUsagePixelFormatView;
        output.hud = [device newTextureWithDescriptor:descriptor];
    }
    if (!output.positions)
        output.positions = [device newBufferWithLength:kGridVertices * 6 * sizeof(float) * 3
                                               options:MTLResourceStorageModePrivate];
    if (!output.indices)
        output.indices = [device newBufferWithLength:kGridIndices * 4 * sizeof(uint32_t)
                                             options:MTLResourceStorageModePrivate];
    if (!output.distances)
        output.distances = [device newBufferWithLength:kGridVertices * 2 * sizeof(float) * 2
                                               options:MTLResourceStorageModePrivate];
    return output.colour && output.hud && output.positions && output.indices && output.distances;
}

id<MTLTexture> UnormView(id<MTLTexture> texture)
{
    return texture.pixelFormat == MTLPixelFormatBGRA8Unorm_sRGB
               ? [texture newTextureViewWithPixelFormat:MTLPixelFormatBGRA8Unorm] : texture;
}
}

namespace SharVisionOS
{
float WindowHalfHeightTangent()
{
    return kWindowHalfFovTangent * kWindowEyeHeight / kWindowEyeWidth;
}

float WindowEyeOffset(float widthMetres)
{
    // 32 mm in window units (the window is 1 wide), then into game metres.
    const float width = std::min(std::max(widthMetres, 0.2f), 20.0f);
    return 0.032f / width * (2.0f * kWindowPlaneDistance * kWindowHalfFovTangent);
}

bool EncodeWindowFrame(id<MTLCommandBuffer> commands, const WindowFrameInput& input, id<MTLTexture> colourSource,
                       WindowFrameOutput& output)
{
    id<MTLDevice> device = commands.device;
    Pipelines pipelines;
    const NSUInteger eyeWidth = input.final.width, eyeHeight = input.final.height;
    if (!LoadPipelines(device, pipelines) ||
        !PrepareOutput(device, eyeWidth, eyeHeight, colourSource.pixelFormat, output))
        return false;
    const bool scene = input.scene && input.depth[0] && input.depth[1];

    if (input.mirrorOnly)
    {
        // Just the HUD.
        const simd_uint2 origin = simd_make_uint2((uint32_t)(eyeWidth - output.hud.width) / 2,
                                                  (uint32_t)(eyeHeight - output.hud.height) / 2);
        id<MTLComputeCommandEncoder> compute = [commands computeCommandEncoder];
        [compute setComputePipelineState:pipelines.pair];
        [compute setTexture:UnormView(input.final) atIndex:0];
        [compute setTexture:UnormView(output.hud) atIndex:1];
        [compute setBytes:&origin length:sizeof(origin) atIndex:0];
        [compute dispatchThreads:MTLSizeMake(output.hud.width, output.hud.height, 1)
           threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
        [compute endEncoding];
        return true;
    }

    id<MTLBlitCommandEncoder> blit = [commands blitCommandEncoder];
    for (NSUInteger eye = 0; eye < 2; ++eye)
        [blit copyFromTexture:colourSource sourceSlice:eye sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
                   sourceSize:MTLSizeMake(eyeWidth, eyeHeight, 1) toTexture:output.colour destinationSlice:0
             destinationLevel:0 destinationOrigin:MTLOriginMake(eye * eyeWidth, 0, 0)];
    [blit endEncoding];

    id<MTLComputeCommandEncoder> compute = [commands computeCommandEncoder];
    id<MTLTexture> hud = UnormView(output.hud);
    const simd_uint2 origin = simd_make_uint2((uint32_t)(eyeWidth - output.hud.width) / 2,
                                              (uint32_t)(eyeHeight - output.hud.height) / 2);
    if (scene)
    {
        const float threshold = kHudThreshold;
        [compute setComputePipelineState:pipelines.hud];
        [compute setTexture:UnormView(input.final) atIndex:0];
        [compute setTexture:UnormView(input.scene) atIndex:1];
        [compute setTexture:hud atIndex:2];
        [compute setBytes:&threshold length:sizeof(threshold) atIndex:0];
        [compute setBytes:&origin length:sizeof(origin) atIndex:1];
    }
    else
    {
        [compute setComputePipelineState:pipelines.flat];
        [compute setTexture:UnormView(input.final) atIndex:0];
        [compute setTexture:hud atIndex:1];
        [compute setBytes:&origin length:sizeof(origin) atIndex:0];
    }
    [compute dispatchThreads:MTLSizeMake(output.hud.width, output.hud.height, 1)
       threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];

    ReliefParams params = {};
    for (int eye = 0; eye < 2; ++eye)
    {
        const float* p = input.projection[eye];
        params.depthTerms[eye] = simd_make_float4(p[10], p[11], p[14], p[15]);
    }
    params.eyeOffset = simd_make_float2(-input.eyeOffset, input.eyeOffset);
    params.halfTangent = simd_make_float2(kWindowHalfFovTangent, WindowHalfHeightTangent());
    params.overscan = simd_make_float2(kWindowOverscanX, kWindowOverscanY);
    params.push = simd_make_float3(0.0f, kSecondaryPush, kBackstopPush);
    params.planeDistance = kWindowPlaneDistance;
    params.nearest = kNearest;
    params.farthest = kFarthest;
    params.skirt = kSkirt;
    params.cutRatio = kCutRatio;
    params.columns = kColumns;
    params.rows = kRows;
    params.hasDepth = scene ? 1 : 0;
    [compute setComputePipelineState:pipelines.relief];
    [compute setTexture:scene ? input.depth[0] : pipelines.noDepth atIndex:0];
    [compute setTexture:scene ? input.depth[1] : pipelines.noDepth atIndex:1];
    [compute setBuffer:output.positions offset:0 atIndex:0];
    [compute setBuffer:output.distances offset:0 atIndex:1];
    [compute setBytes:&params length:sizeof(params) atIndex:2];
    [compute dispatchThreads:MTLSizeMake(kColumns + 3, kRows + 3, 2) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
    [compute setComputePipelineState:pipelines.cut];
    [compute setBuffer:output.distances offset:0 atIndex:0];
    [compute setBuffer:output.indices offset:0 atIndex:1];
    [compute setBytes:&params length:sizeof(params) atIndex:2];
    [compute dispatchThreads:MTLSizeMake(kColumns + 2, kRows + 2, 2) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
    [compute endEncoding];
    return true;
}
}
