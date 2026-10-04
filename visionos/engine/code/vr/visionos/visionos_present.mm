#include <vr/visionos/visionos_present.h>
#include <vr/visionos/smaa/AreaTex.h>
#include <vr/visionos/smaa/SearchTex.h>
#include <vr/visionos/smaa/SMAAShader.h>

#import <Foundation/Foundation.h>

#include <cmath>
#include <map>
#include <tuple>

namespace
{
// Mirrors `Params` in the shader below.
struct PresentParams
{
    simd_float2 sourceTexel;  // 1 / engine image size
    float planeDepth;         // the reverse-Z value of options.planeDepthMetres
    uint32_t fxaa;
    float room;               // options.room
    float visibility;         // options.visibility
    uint32_t backdrop;        // options.backdrop
    simd_float2 quad[8];      // options.backdropQuad, eye by eye
    float fade;               // options.fade
    uint32_t fadeToRoom;      // options.fadeToRoom
};

// A full-screen triangle per view. The layered variant draws one instance per drawable slice and
// routes it there; the Simulator has one view and no layered rendering, so it gets the other.
NSString* const kShader = @R"(
#include <metal_stdlib>
using namespace metal;

struct Params
{
    float2 sourceTexel;
    float planeDepth;
    uint fxaa;
    float room;
    float visibility;
    uint backdrop;
    float2 quad[8];
    float fade;
    uint fadeToRoom;
};

// Whether `point` is inside the convex quad `q` (either winding).
static bool InQuad(float2 point, constant float2* q)
{
    float positive = 0, negative = 0;
    for (int i = 0; i < 4; ++i)
    {
        const float2 edge = q[(i + 1) & 3] - q[i], to = point - q[i];
        const float side = edge.x * to.y - edge.y * to.x;
        positive += side > 0 ? 1 : 0;
        negative += side < 0 ? 1 : 0;
    }
    return positive == 0 || negative == 0;
}

struct Corner
{
    float4 position [[position]];
    float2 uv;
#if LAYERED
    uint slice [[render_target_array_index]];
#endif
};

vertex Corner PresentVertex(uint id [[vertex_id]], uint instance [[instance_id]])
{
    const float2 uv = float2((id << 1) & 2, id & 2);
    Corner out;
    out.position = float4(uv * float2(2, -2) + float2(-1, 1), 0, 1);
    out.uv = uv;
#if LAYERED
    out.slice = instance;
#endif
    return out;
}

struct Output
{
    half4 colour [[color(0)]];
    float depth [[depth(any)]];
};

// Perceptual luma from the linear colour the sRGB texture returns.
static float Luma(float3 colour) { return sqrt(dot(colour, float3(0.299, 0.587, 0.114))); }

// FXAA 3.11, console variant: four diagonal taps find an edge, and two or four taps along it
// smooth it. Cheap enough for two eyes at 90 Hz.
static float3 Fxaa(texture2d_array<float> source, sampler linear, float2 uv, uint slice, float2 texel)
{
    const float3 rgbM = source.sample(linear, uv, slice).rgb;
    const float lumaM = Luma(rgbM);
    const float lumaNw = Luma(source.sample(linear, uv + float2(-0.5, -0.5) * texel, slice).rgb);
    const float lumaSw = Luma(source.sample(linear, uv + float2(-0.5, 0.5) * texel, slice).rgb);
    const float lumaNe = Luma(source.sample(linear, uv + float2(0.5, -0.5) * texel, slice).rgb) + 1.0 / 384.0;
    const float lumaSe = Luma(source.sample(linear, uv + float2(0.5, 0.5) * texel, slice).rgb);
    const float lumaMax = max(max(lumaNw, lumaSw), max(lumaNe, lumaSe));
    const float lumaMin = min(min(lumaNw, lumaSw), min(lumaNe, lumaSe));
    if (max(lumaMax, lumaM) - min(lumaMin, lumaM) < max(0.05, lumaMax * 0.125)) return rgbM;

    const float swMinusNe = lumaSw - lumaNe, seMinusNw = lumaSe - lumaNw;
    const float2 dir1 = normalize(float2(swMinusNe + seMinusNw, swMinusNe - seMinusNw));
    const float3 rgbA = source.sample(linear, uv - dir1 * texel * 0.5, slice).rgb +
                        source.sample(linear, uv + dir1 * texel * 0.5, slice).rgb;
    const float2 dir2 = clamp(dir1 / (min(abs(dir1.x), abs(dir1.y)) * 8.0), -2.0, 2.0);
    const float3 rgbB = (source.sample(linear, uv - dir2 * texel * 2.0, slice).rgb +
                         source.sample(linear, uv + dir2 * texel * 2.0, slice).rgb) * 0.25 + rgbA * 0.25;
    const float lumaB = Luma(rgbB);
    return (lumaB < lumaMin || lumaB > lumaMax) ? rgbA * 0.5 : rgbB;
}

fragment Output PresentFragment(Corner in [[stage_in]], texture2d_array<float> source [[texture(0)]],
                                sampler linear [[sampler(0)]], constant Params& p [[buffer(0)]])
{
#if LAYERED
    const uint slice = in.slice;
#else
    const uint slice = 0;
#endif
    const float4 sampled = source.sample(linear, in.uv, slice);
    // FXAA blends colour only: where the room shows, the colour must stay premultiplied by alpha.
    const float3 colour = p.fxaa && p.room == 0 ? Fxaa(source, linear, in.uv, slice, p.sourceTexel) : sampled.rgb;
    // Premultiplied: where the engine drew nothing the colour is black, so lowering alpha there
    // shows the room; the boundary scales the whole pixel towards it.
    float4 image = float4(colour, saturate(sampled.a));
    if (p.backdrop && p.room > 0 && InQuad(in.uv, &p.quad[min(slice, 1u) * 4]))
        image += (1 - image.a) * float4(0.004, 0.0035, 0.006, 0.97);
    float4 result = float4(image.rgb, mix(1.0, image.a, p.room));
    // The game's fade: to black, or (premultiplied, alpha too) into the room.
    result *= p.fadeToRoom ? float4(1 - p.fade) : float4(float3(1 - p.fade), 1);
    Output out;
    out.colour = half4(result * p.visibility);
    out.depth = p.planeDepth;
    return out;
}
)";

id<MTLRenderPipelineState> Pipeline(id<MTLDevice> device, MTLPixelFormat colour, MTLPixelFormat depth, bool layered)
{
    static std::map<std::tuple<MTLPixelFormat, MTLPixelFormat, bool>, id<MTLRenderPipelineState>> pipelines;
    const auto key = std::make_tuple(colour, depth, layered);
    auto found = pipelines.find(key);
    if (found != pipelines.end()) return found->second;

    MTLCompileOptions* options = [MTLCompileOptions new];
    options.preprocessorMacros = @{@"LAYERED": layered ? @1 : @0};
    NSError* error = nil;
    id<MTLLibrary> library = [device newLibraryWithSource:kShader options:options error:&error];
    id<MTLRenderPipelineState> pipeline = nil;
    if (library)
    {
        MTLRenderPipelineDescriptor* descriptor = [MTLRenderPipelineDescriptor new];
        descriptor.vertexFunction = [library newFunctionWithName:@"PresentVertex"];
        descriptor.fragmentFunction = [library newFunctionWithName:@"PresentFragment"];
        descriptor.colorAttachments[0].pixelFormat = colour;
        descriptor.depthAttachmentPixelFormat = depth;
        descriptor.inputPrimitiveTopology = MTLPrimitiveTopologyClassTriangle;
        pipeline = [device newRenderPipelineStateWithDescriptor:descriptor error:&error];
    }
    if (!pipeline) NSLog(@"[SharVisionOS] present pipeline failed: %@", error);
    pipelines[key] = pipeline;
    return pipeline;
}

// Reverse-Z (1 = near, 0 = far) for a plane `distance` metres away; depth range is (far, near).
float ReverseZDepth(float distance, simd_float2 depthRange)
{
    const float far = depthRange.x, near = depthRange.y;
    const float depth = std::isfinite(far) ? near * (far - distance) / (distance * (far - near)) : near / distance;
    return std::fmin(std::fmax(depth, 0.0001f), 1.0f);
}

// SMAA 1x (github.com/iryoku/smaa, MIT; see smaa/LICENSE.txt), the reference HLSL turned into
// Metal by scripts/generate-smaa-msl.py. Three passes per eye at the engine image's size: luma edges
// from a gamma view of the image, blending weights from the edges and the two lookup tables, then
// neighbourhood blending through an sRGB view into an image the present pass reads instead.
struct Smaa
{
    id<MTLLibrary> library;
    id<MTLTexture> areaTex, searchTex;
    // Per engine image size.
    NSUInteger width = 0, height = 0;
    id<MTLRenderPipelineState> edges, weights, blend;
    id<MTLTexture> edgesTex[2], blendTex[2], output;
    // Per engine image (it's replaced when Render Scale changes).
    __weak id<MTLTexture> source;
    id<MTLTexture> gammaView[2], srgbView[2];
};

bool PrepareSmaa(Smaa& smaa, id<MTLDevice> device, id<MTLTexture> source)
{
    if (!smaa.library)
    {
        NSError* error = nil;
        smaa.library = [device newLibraryWithSource:@(kSmaaShaderSource) options:[MTLCompileOptions new] error:&error];
        if (!smaa.library)
        {
            NSLog(@"[SharVisionOS] SMAA shaders failed: %@", error);
            return false;
        }
        MTLTextureDescriptor* area = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRG8Unorm
            width:AREATEX_WIDTH height:AREATEX_HEIGHT mipmapped:NO];
        smaa.areaTex = [device newTextureWithDescriptor:area];
        [smaa.areaTex replaceRegion:MTLRegionMake2D(0, 0, AREATEX_WIDTH, AREATEX_HEIGHT) mipmapLevel:0
                          withBytes:areaTexBytes bytesPerRow:AREATEX_PITCH];
        MTLTextureDescriptor* search = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm
            width:SEARCHTEX_WIDTH height:SEARCHTEX_HEIGHT mipmapped:NO];
        smaa.searchTex = [device newTextureWithDescriptor:search];
        [smaa.searchTex replaceRegion:MTLRegionMake2D(0, 0, SEARCHTEX_WIDTH, SEARCHTEX_HEIGHT) mipmapLevel:0
                            withBytes:searchTexBytes bytesPerRow:SEARCHTEX_PITCH];
    }
    if (smaa.width != source.width || smaa.height != source.height)
    {
        smaa.width = source.width;
        smaa.height = source.height;
        const simd_float4 metrics = simd_make_float4(1.0f / smaa.width, 1.0f / smaa.height, smaa.width, smaa.height);
        MTLFunctionConstantValues* constants = [MTLFunctionConstantValues new];
        [constants setConstantValue:&metrics type:MTLDataTypeFloat4 atIndex:0];
        NSError* error = nil;
        id<MTLFunction> vertex = [smaa.library newFunctionWithName:@"SMAAVertex" constantValues:constants error:&error];
        auto pipeline = [&](NSString* fragmentName, MTLPixelFormat format) -> id<MTLRenderPipelineState> {
            MTLRenderPipelineDescriptor* descriptor = [MTLRenderPipelineDescriptor new];
            descriptor.vertexFunction = vertex;
            descriptor.fragmentFunction = [smaa.library newFunctionWithName:fragmentName constantValues:constants error:nil];
            descriptor.colorAttachments[0].pixelFormat = format;
            return descriptor.fragmentFunction ? [device newRenderPipelineStateWithDescriptor:descriptor error:nil] : nil;
        };
        smaa.edges = pipeline(@"SMAAEdgesFragment", MTLPixelFormatRG8Unorm);
        smaa.weights = pipeline(@"SMAAWeightsFragment", MTLPixelFormatRGBA8Unorm);
        smaa.blend = pipeline(@"SMAABlendFragment", source.pixelFormat);
        MTLTextureDescriptor* descriptor = [MTLTextureDescriptor new];
        descriptor.width = smaa.width;
        descriptor.height = smaa.height;
        descriptor.storageMode = MTLStorageModePrivate;
        descriptor.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        for (int slice = 0; slice < 2; ++slice)
        {
            descriptor.pixelFormat = MTLPixelFormatRG8Unorm;
            smaa.edgesTex[slice] = [device newTextureWithDescriptor:descriptor];
            descriptor.pixelFormat = MTLPixelFormatRGBA8Unorm;
            smaa.blendTex[slice] = [device newTextureWithDescriptor:descriptor];
        }
        descriptor.textureType = MTLTextureType2DArray;
        descriptor.arrayLength = 2;
        descriptor.pixelFormat = source.pixelFormat;
        smaa.output = [device newTextureWithDescriptor:descriptor];
        smaa.source = nil;
    }
    if (smaa.source != source)
    {
        smaa.source = source;
        for (NSUInteger slice = 0; slice < 2; ++slice)
        {
            // Edges are found in gamma space, and colours blended in linear.
            smaa.gammaView[slice] = [source newTextureViewWithPixelFormat:MTLPixelFormatBGRA8Unorm
                textureType:MTLTextureType2D levels:NSMakeRange(0, 1) slices:NSMakeRange(slice, 1)];
            smaa.srgbView[slice] = [source newTextureViewWithPixelFormat:source.pixelFormat
                textureType:MTLTextureType2D levels:NSMakeRange(0, 1) slices:NSMakeRange(slice, 1)];
        }
    }
    return smaa.edges && smaa.weights && smaa.blend && smaa.output;
}

void EncodeSmaaPass(id<MTLCommandBuffer> commands, id<MTLRenderPipelineState> pipeline, id<MTLTexture> target,
                    NSUInteger slice, NSArray<id<MTLTexture>>* inputs)
{
    MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = target;
    pass.colorAttachments[0].slice = slice;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> encoder = [commands renderCommandEncoderWithDescriptor:pass];
    [encoder setRenderPipelineState:pipeline];
    for (NSUInteger i = 0; i < inputs.count; ++i) [encoder setFragmentTexture:inputs[i] atIndex:i];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [encoder endEncoding];
}

// Returns the image the present pass should read: SMAA's output, or `source` if SMAA can't run.
id<MTLTexture> EncodeSmaa(id<MTLCommandBuffer> commands, id<MTLTexture> source, NSUInteger slices)
{
    static Smaa smaa;
    if (!PrepareSmaa(smaa, source.device, source)) return source;
    for (NSUInteger slice = 0; slice < std::min<NSUInteger>(slices, 2); ++slice)
    {
        EncodeSmaaPass(commands, smaa.edges, smaa.edgesTex[slice], 0, @[smaa.gammaView[slice]]);
        EncodeSmaaPass(commands, smaa.weights, smaa.blendTex[slice], 0,
                       @[smaa.edgesTex[slice], smaa.areaTex, smaa.searchTex]);
        EncodeSmaaPass(commands, smaa.blend, smaa.output, slice, @[smaa.srgbView[slice], smaa.blendTex[slice]]);
    }
    return smaa.output;
}
}

namespace SharVisionOS
{
id<MTLTexture> EncodeAntiAliasing(id<MTLCommandBuffer> commands, id<MTLTexture> source, NSUInteger slices)
{
    return EncodeSmaa(commands, source, slices);
}

bool EncodePresent(id<MTLCommandBuffer> commands, cp_drawable_t drawable, id<MTLTexture> source,
                   const PresentOptions& options)
{
    id<MTLTexture> colour = cp_drawable_get_color_texture(drawable, 0);
    id<MTLTexture> depth = cp_drawable_get_depth_texture(drawable, 0);
    if (!colour || !depth || !source) return false;
    const NSUInteger slices = colour.arrayLength;
    const bool layered = slices > 1;
    id<MTLRenderPipelineState> pipeline = Pipeline(colour.device, colour.pixelFormat, depth.pixelFormat, layered);
    if (!pipeline) return false;
    if (options.antiAliasing == 2) source = EncodeSmaa(commands, source, slices);
    static id<MTLSamplerState> sampler = nil;
    static id<MTLDepthStencilState> writeDepth = nil;
    if (!sampler)
    {
        MTLSamplerDescriptor* descriptor = [MTLSamplerDescriptor new];
        descriptor.minFilter = descriptor.magFilter = MTLSamplerMinMagFilterLinear;
        descriptor.sAddressMode = descriptor.tAddressMode = MTLSamplerAddressModeClampToEdge;
        sampler = [colour.device newSamplerStateWithDescriptor:descriptor];
        MTLDepthStencilDescriptor* depthDescriptor = [MTLDepthStencilDescriptor new];
        depthDescriptor.depthCompareFunction = MTLCompareFunctionAlways;
        depthDescriptor.depthWriteEnabled = YES;
        writeDepth = [colour.device newDepthStencilStateWithDescriptor:depthDescriptor];
    }

    PresentParams params = {};
    params.sourceTexel = simd_make_float2(1.0f / source.width, 1.0f / source.height);
    params.planeDepth = ReverseZDepth(options.planeDepthMetres, cp_drawable_get_depth_range(drawable));
    params.fxaa = options.antiAliasing == 1 ? 1 : 0;
    params.room = options.room;
    params.visibility = options.visibility;
    params.backdrop = options.backdrop ? 1 : 0;
    params.fade = std::min(std::max(options.fade, 0.0f), 1.0f);
    params.fadeToRoom = options.fadeToRoom ? 1 : 0;
    for (int eye = 0; eye < 2; ++eye)
        for (int k = 0; k < 4; ++k) params.quad[eye * 4 + k] = options.backdropQuad[eye][k];

    // The render context draws what the compositor adds to the frame (the progressive immersion
    // portal); it needs the whole drawable in one layered encoder, which this pass is.
    cp_drawable_render_context_t context = cp_drawable_add_render_context(drawable, commands);

    MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = colour;
    pass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.depthAttachment.texture = depth;
    pass.depthAttachment.loadAction = MTLLoadActionDontCare;
    pass.depthAttachment.storeAction = MTLStoreActionStore;
    pass.renderTargetArrayLength = slices;
    if (cp_drawable_get_rasterization_rate_map_count(drawable) > 0)
        pass.rasterizationRateMap = cp_drawable_get_rasterization_rate_map(drawable, 0);
    id<MTLRenderCommandEncoder> encoder = [commands renderCommandEncoderWithDescriptor:pass];
    [encoder setRenderPipelineState:pipeline];
    [encoder setDepthStencilState:writeDepth];
    [encoder setFragmentTexture:source atIndex:0];
    [encoder setFragmentSamplerState:sampler atIndex:0];
    [encoder setFragmentBytes:&params length:sizeof(params) atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3 instanceCount:layered ? slices : 1];
    if (context)
        cp_drawable_render_context_end_encoding(context, encoder);
    else
        [encoder endEncoding];
    return true;
}
}
