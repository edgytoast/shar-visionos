#!/usr/bin/env python3
"""Generates the Metal SMAA source the visionOS backend compiles at runtime.

    ./scripts/generate-smaa-msl.py <smaa checkout>

<smaa checkout> is a clone of github.com/iryoku/smaa (MIT). Writes
visionos/engine/code/vr/visionos/smaa/: the reference SMAA.hlsl turned into Metal Shading
Language (as a C++ raw string), and the AreaTex/SearchTex lookup tables copied as they are.

SMAA.hlsl is written for a small set of macros, and Metal fills most of them in directly. What
Metal lacks is HLSL's out/inout parameters, which become references; the two calls that pass a
swizzle to one go through a temporary, and the float4 SMAAMovc uses select().
"""
import pathlib
import re
import shutil
import sys

HERE = pathlib.Path(__file__).resolve().parent.parent
OUT = HERE / "visionos/engine/code/vr/visionos/smaa"

PRELUDE = """#include <metal_stdlib>
using namespace metal;

// SMAA.hlsl's shading-language macros, for Metal.
#define SMAA_CUSTOM_SL 1
#define SMAA_PRESET_HIGH 1
#define SMAA_INCLUDE_VS 0
// The render target's metrics (1/width, 1/height, width, height) are a function constant, so the
// library compiles once and each size is a specialization.
constant float4 SMAARtMetrics [[function_constant(0)]];
#define SMAA_RT_METRICS SMAARtMetrics
constexpr sampler SMAALinearSampler(filter::linear, address::clamp_to_edge);
constexpr sampler SMAAPointSampler(filter::nearest, address::clamp_to_edge);
#define SMAATexture2D(tex) texture2d<float> tex
#define SMAATexturePass2D(tex) tex
#define SMAASampleLevelZero(tex, coord) tex.sample(SMAALinearSampler, coord, level(0.0))
#define SMAASampleLevelZeroPoint(tex, coord) tex.sample(SMAAPointSampler, coord, level(0.0))
#define SMAASampleLevelZeroOffset(tex, coord, offset) tex.sample(SMAALinearSampler, coord, level(0.0), offset)
#define SMAASample(tex, coord) tex.sample(SMAALinearSampler, coord)
#define SMAASamplePoint(tex, coord) tex.sample(SMAAPointSampler, coord)
#define SMAASampleOffset(tex, coord, offset) tex.sample(SMAALinearSampler, coord, offset)
#define SMAA_FLATTEN
#define SMAA_BRANCH
#define lerp(a, b, t) mix(a, b, t)
#define mad(a, b, c) ((a) * (b) + (c))
#define discard discard_fragment()
"""

# Full-screen passes for SMAA 1x: the offsets the reference computes in its vertex shaders are
# computed per pixel instead.
PASSES = """
struct SMAAVertexOut
{
    float4 position [[position]];
    float2 texcoord;
};

vertex SMAAVertexOut SMAAVertex(uint id [[vertex_id]])
{
    const float2 uv = float2((id << 1) & 2, id & 2);
    SMAAVertexOut out;
    out.position = float4(uv * float2(2, -2) + float2(-1, 1), 0, 1);
    out.texcoord = uv;
    return out;
}

fragment float2 SMAAEdgesFragment(SMAAVertexOut in [[stage_in]], texture2d<float> colorTex [[texture(0)]])
{
    float4 offset[3];
    offset[0] = mad(SMAA_RT_METRICS.xyxy, float4(-1.0, 0.0, 0.0, -1.0), in.texcoord.xyxy);
    offset[1] = mad(SMAA_RT_METRICS.xyxy, float4( 1.0, 0.0, 0.0,  1.0), in.texcoord.xyxy);
    offset[2] = mad(SMAA_RT_METRICS.xyxy, float4(-2.0, 0.0, 0.0, -2.0), in.texcoord.xyxy);
    return SMAALumaEdgeDetectionPS(in.texcoord, offset, colorTex);
}

fragment float4 SMAAWeightsFragment(SMAAVertexOut in [[stage_in]], texture2d<float> edgesTex [[texture(0)]],
                                    texture2d<float> areaTex [[texture(1)]],
                                    texture2d<float> searchTex [[texture(2)]])
{
    const float2 pixcoord = in.texcoord * SMAA_RT_METRICS.zw;
    float4 offset[3];
    offset[0] = mad(SMAA_RT_METRICS.xyxy, float4(-0.25, -0.125,  1.25, -0.125), in.texcoord.xyxy);
    offset[1] = mad(SMAA_RT_METRICS.xyxy, float4(-0.125, -0.25, -0.125,  1.25), in.texcoord.xyxy);
    offset[2] = mad(SMAA_RT_METRICS.xxyy, float4(-2.0, 2.0, -2.0, 2.0) * float(SMAA_MAX_SEARCH_STEPS),
                    float4(offset[0].xz, offset[1].yw));
    return SMAABlendingWeightCalculationPS(in.texcoord, pixcoord, offset, edgesTex, areaTex, searchTex, float4(0.0));
}

fragment float4 SMAABlendFragment(SMAAVertexOut in [[stage_in]], texture2d<float> colorTex [[texture(0)]],
                                  texture2d<float> blendTex [[texture(1)]])
{
    const float4 offset = mad(SMAA_RT_METRICS.xyxy, float4(1.0, 0.0, 0.0, 1.0), in.texcoord.xyxy);
    return SMAANeighborhoodBlendingPS(in.texcoord, offset, colorTex, blendTex);
}
"""

REPLACEMENTS = [
    # HLSL out/inout parameters are references in Metal.
    ("void SMAAMovc(bool2 cond, inout float2 variable, float2 value) {",
     "void SMAAMovc(bool2 cond, thread float2& variable, float2 value) {"),
    ("void SMAAMovc(bool4 cond, inout float4 variable, float4 value) {\n"
     "    SMAAMovc(cond.xy, variable.xy, value.xy);\n"
     "    SMAAMovc(cond.zw, variable.zw, value.zw);\n",
     "void SMAAMovc(bool4 cond, thread float4& variable, float4 value) {\n"
     "    variable = select(variable, value, cond);\n"),
    ("float2 dir, out float2 e) {", "float2 dir, thread float2& e) {"),
    ("inout float2 weights,", "thread float2& weights,"),
    # A swizzle can't bind to a reference: go through a temporary.
    ("SMAADetectHorizontalCornerPattern(SMAATexturePass2D(edgesTex), weights.rg, coords.xyzy, d);",
     "{ float2 w = weights.rg; SMAADetectHorizontalCornerPattern(SMAATexturePass2D(edgesTex), w, coords.xyzy, d); weights.rg = w; }"),
    ("SMAADetectVerticalCornerPattern(SMAATexturePass2D(edgesTex), weights.ba, coords.xyxz, d);",
     "{ float2 w = weights.ba; SMAADetectVerticalCornerPattern(SMAATexturePass2D(edgesTex), w, coords.xyxz, d); weights.ba = w; }"),
]


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    smaa = pathlib.Path(sys.argv[1])
    source = (smaa / "SMAA.hlsl").read_bytes().decode("latin-1").replace("\r\n", "\n")
    for old, new in REPLACEMENTS:
        if old not in source:
            sys.exit(f"SMAA.hlsl changed: not found: {old[:60]!r}")
        source = source.replace(old, new)
    # Array parameters (float4 offset[3]) decay to pointers, which Metal wants in an address space.
    source, count = re.subn(r"\bfloat4 offset\[3\]", "thread const float4* offset", source)
    if count == 0:
        sys.exit("SMAA.hlsl changed: no float4 offset[3] parameters")
    msl = PRELUDE + source + PASSES
    if ")SMAA\"" in msl:
        sys.exit("the raw string delimiter appears in the source")

    OUT.mkdir(parents=True, exist_ok=True)
    header = (
        "// Generated by scripts/generate-smaa-msl.py from SMAA.hlsl (github.com/iryoku/smaa); do not\n"
        "// edit. SMAA is Copyright (C) 2013 Jorge Jimenez, Jose I. Echevarria, Belen Masia, Fernando\n"
        "// Navarro and Diego Gutierrez, under the MIT license in LICENSE.txt beside this file.\n"
        "#ifndef SHAR_VISIONOS_SMAA_SHADER_H\n#define SHAR_VISIONOS_SMAA_SHADER_H\n\n"
        "static const char kSmaaShaderSource[] = R\"SMAA(" + msl + ")SMAA\";\n\n#endif\n")
    (OUT / "SMAAShader.h").write_text(header)
    for name in ("AreaTex.h", "SearchTex.h"):
        text = (smaa / "Textures" / name).read_bytes().decode("latin-1").replace("\r\n", "\n")
        (OUT / name).write_text(text)
    shutil.copyfile(smaa / "LICENSE.txt", OUT / "LICENSE.txt")
    print(f"wrote {OUT}")


if __name__ == "__main__":
    main()
