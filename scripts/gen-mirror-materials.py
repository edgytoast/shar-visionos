#!/usr/bin/env python3
# Regenerates the scene mirror's materials (MirrorOpaque, MirrorCutout, MirrorBlend) in
# visionos/App/Resources/WindowFrame.usda: everything from the mirror's comment to the end of the
# file. The graphs run to 60-odd nodes each and share most of them, so they're written here rather
# than by hand. RealityKit rejects the whole file for one bad node id (invalidTypeFound), so check
# ids against MaterialX's (ND_mix_vector3 has no FA variant, for one).
#
#   scripts/gen-mirror-materials.py visionos/App/Resources/WindowFrame.usda
import pathlib, sys
p=pathlib.Path(sys.argv[1]); s=p.read_text()
start=s.index("    # The window's scene mirror (MirrorScene.swift)")
head=s[:start]

def node(name, id, inputs, out):
    lines=[f'        def Shader "{name}"','        {',f'            uniform token info:id = "{id}"']
    lines+=[f'            {i}' for i in inputs]
    lines+=[f'            {out}','        }']
    return "\n".join(lines)
SPLIT="float outputs:outx\n            float outputs:outy\n            float outputs:outz\n            float outputs:outw"

def material(M, extra_inputs, surface_inputs, tail_nodes, comment, lit=False):
    R=f"/Root/{M}"
    c=lambda n,o="out": f"<{R}/{n}.outputs:{o}>"
    i=lambda n: f"<{R}.inputs:{n}>"
    def combine3(name, src):
        return node(name,"ND_combine3_vector3",[f"float inputs:in1.connect = {c(src,'outx')}",f"float inputs:in2.connect = {c(src,'outy')}",f"float inputs:in3.connect = {c(src,'outz')}"],"float3 outputs:out")
    nodes=[
        node("Surface","ND_realitykit_unlit_surfaceshader",["bool inputs:applyPostProcessToneMap = 0"]+surface_inputs,"token outputs:out"),
        node("Sample","ND_RealityKitTexture2D_vector4",[f"asset inputs:file.connect = {i('Frame')}",f"float2 inputs:texcoord.connect = {c('UV')}",
             "uniform bool inputs:no_flip_v = 1",'string inputs:u_wrap_mode = "repeat"','string inputs:v_wrap_mode = "repeat"'],"float4 outputs:out"),
        node("UV","ND_texcoord_vector2",[],"float2 outputs:out"),
        node("VertexColour","ND_geomcolor_color4",[],"color4f outputs:out"),
        node("VertexVector","ND_convert_color4_vector4",[f"color4f inputs:in.connect = {c('VertexColour')}"],"float4 outputs:out"),
        node("Tint","ND_multiply_vector4",[f"float4 inputs:in1.connect = {c('VertexVector')}",f"float4 inputs:in2.connect = {i('Colour')}"],"float4 outputs:out"),
        node("TintSplit","ND_separate4_vector4",[f"float4 inputs:in.connect = {c('Tint')}"],SPLIT),
        combine3("TintRGB","TintSplit"),
    ]
    # The frame's constants: 8x1, texel k at u = (k + 0.5) / 8. Unlit materials read only texel 0.
    for k in range(7 if lit else 1):
        nodes.append(node(f"Constant{k}","ND_RealityKitTexture2D_vector4",[f"asset inputs:file.connect = {i('Constants')}",f"float2 inputs:texcoord = ({(k+0.5)/8}, 0.5)"],"float4 outputs:out"))
        nodes.append(node(f"Constant{k}Split","ND_separate4_vector4",[f"float4 inputs:in.connect = {c(f'Constant{k}')}"],SPLIT))
    if lit:
        nodes.append(node("WorldNormal","ND_normal_vector3",['uniform string inputs:space = "world"'],"float3 outputs:out"))
        nodes.append(node("Normal","ND_normalize_vector3",[f"float3 inputs:in.connect = {c('WorldNormal')}"],"float3 outputs:out"))
    previous=None
    for l in range(3 if lit else 0):
        nodes.append(combine3(f"Light{l}Direction",f"Constant{2*l+1}Split"))
        nodes.append(combine3(f"Light{l}Colour",f"Constant{2*l+2}Split"))
        nodes.append(node(f"Light{l}Cosine","ND_dotproduct_vector3",[f"float3 inputs:in1.connect = {c('Normal')}",f"float3 inputs:in2.connect = {c(f'Light{l}Direction')}"],"float outputs:out"))
        nodes.append(node(f"Light{l}Facing","ND_max_float",[f"float inputs:in1.connect = {c(f'Light{l}Cosine')}","float inputs:in2 = 0"],"float outputs:out"))
        nodes.append(node(f"Light{l}","ND_multiply_vector3FA",[f"float3 inputs:in1.connect = {c(f'Light{l}Colour')}",f"float inputs:in2.connect = {c(f'Light{l}Facing')}"],"float3 outputs:out"))
        if previous:
            nodes.append(node(f"Lighting{l}","ND_add_vector3",[f"float3 inputs:in1.connect = {c(previous)}",f"float3 inputs:in2.connect = {c(f'Light{l}')}"],"float3 outputs:out"))
            previous=f"Lighting{l}"
        else:
            previous=f"Light{l}"
    # lit.vert: vertex colour x (ambient + material colour x the lights' sum); the material colour
    # (a car's paint) tints the lights only.
    if lit: nodes+=[
        node("VertexSplit","ND_separate4_vector4",[f"float4 inputs:in.connect = {c('VertexVector')}"],SPLIT),
        combine3("VertexRGB","VertexSplit"),
        node("ColourSplit","ND_separate4_vector4",[f"float4 inputs:in.connect = {i('Colour')}"],SPLIT),
        combine3("ColourRGB","ColourSplit"),
        node("TintedLights","ND_multiply_vector3",[f"float3 inputs:in1.connect = {c('ColourRGB')}",f"float3 inputs:in2.connect = {c(previous)}"],"float3 outputs:out"),
        node("Diffuse","ND_add_vector3",[f"float3 inputs:in1.connect = {i('Ambient')}",f"float3 inputs:in2.connect = {c('TintedLights')}"],"float3 outputs:out"),
        node("ShadedTint","ND_multiply_vector3",[f"float3 inputs:in1.connect = {c('VertexRGB')}",f"float3 inputs:in2.connect = {c('Diffuse')}"],"float3 outputs:out"),
    ]
    nodes+=[
        node("ClampedTint","ND_clamp_vector3FA",[f"float3 inputs:in.connect = {c('ShadedTint' if lit else 'TintRGB')}","float inputs:low = 0","float inputs:high = 1"],"float3 outputs:out"),
        node("LinearTint","ND_power_vector3FA",[f"float3 inputs:in1.connect = {c('ClampedTint')}","float inputs:in2 = 2.2"],"float3 outputs:out"),
        node("SampleSplit","ND_separate4_vector4",[f"float4 inputs:in.connect = {c('Sample')}"],SPLIT),
        combine3("SampleRGB","SampleSplit"),
        node("Linear","ND_multiply_vector3",[f"float3 inputs:in1.connect = {c('SampleRGB')}",f"float3 inputs:in2.connect = {c('LinearTint')}"],"float3 outputs:out"),
        node("Alpha","ND_multiply_float",[f"float inputs:in1.connect = {c('SampleSplit','outw')}",f"float inputs:in2.connect = {c('TintSplit','outw')}"],"float outputs:out"),
        node("Exposed","ND_multiply_vector3FA",[f"float3 inputs:in1.connect = {c('Linear')}",f"float inputs:in2.connect = {c('Constant0Split','outx')}"],"float3 outputs:out"),
        node("CurveA","ND_multiply_vector3FA",[f"float3 inputs:in1.connect = {c('Exposed')}","float inputs:in2 = 2.51"],"float3 outputs:out"),
        node("CurveB","ND_add_vector3FA",[f"float3 inputs:in1.connect = {c('CurveA')}","float inputs:in2 = 0.03"],"float3 outputs:out"),
        node("CurveNumerator","ND_multiply_vector3",[f"float3 inputs:in1.connect = {c('Exposed')}",f"float3 inputs:in2.connect = {c('CurveB')}"],"float3 outputs:out"),
        node("CurveC","ND_multiply_vector3FA",[f"float3 inputs:in1.connect = {c('Exposed')}","float inputs:in2 = 2.43"],"float3 outputs:out"),
        node("CurveD","ND_add_vector3FA",[f"float3 inputs:in1.connect = {c('CurveC')}","float inputs:in2 = 0.59"],"float3 outputs:out"),
        node("CurveE","ND_multiply_vector3",[f"float3 inputs:in1.connect = {c('Exposed')}",f"float3 inputs:in2.connect = {c('CurveD')}"],"float3 outputs:out"),
        node("CurveDenominator","ND_add_vector3FA",[f"float3 inputs:in1.connect = {c('CurveE')}","float inputs:in2 = 0.14"],"float3 outputs:out"),
        node("CurveRatio","ND_divide_vector3",[f"float3 inputs:in1.connect = {c('CurveNumerator')}",f"float3 inputs:in2.connect = {c('CurveDenominator')}"],"float3 outputs:out"),
        node("Mapped","ND_clamp_vector3FA",[f"float3 inputs:in.connect = {c('CurveRatio')}","float inputs:low = 0","float inputs:high = 1"],"float3 outputs:out"),
    ]+[t(c,i) for t in tail_nodes]
    body="\n\n".join(nodes)
    ins="\n".join(["        asset inputs:Frame","        asset inputs:Constants","        float4 inputs:Colour = (1, 1, 1, 1)"]
                  +(["        float3 inputs:Ambient = (0.2, 0.2, 0.2)"] if lit else [])+[f"        {x}" for x in extra_inputs])
    return f'''{comment}    def Material "{M}"
    {{
{ins}
        token outputs:mtlx:surface.connect = <{R}/Surface.outputs:out>
        token outputs:realitykit:vertex

{body}
    }}
'''

rgb_from=lambda src: (lambda c,i: node("RGB","ND_convert_vector3_color3",[f"float3 inputs:in.connect = {c(src)}"],"color3f outputs:out"))
intro='''    # The window's scene mirror (MirrorScene.swift), generated by scripts/gen-mirror-materials.py:
    # a game mesh's texture times its vertex colour
    # and material colour, unlit, as the engine's own unlit path does it (compact.frag), then
    # exposed and tone-mapped as its HDR resolve does (hdr_resolve.frag: ACES, fitted). The engine
    # multiplies in gamma space and linearises the product; the tint's colour is raised to 2.2 to
    # do the same to the linear texture. The Lit variants, for lit draws (characters, cars, props),
    # light the vertex colour as lit.vert does: the draw's Ambient plus the material colour times
    # each light's colour times N.L (the material colour, a car's paint, tints only the lights). The
    # level's own geometry is prelit, and its materials skip the lights' cost.
    # Constants is an 8x1 texture every material shares, so a frame's changes touch none of them:
    # texel 0 is (exposure, ambient), texels 1-6 each light's direction (towards it, world space)
    # and colour. Opaque, cut out below Cutoff (alpha test), and blended.
'''
def opaque(name, lit, comment=""):
    return material(name,[],[f"color3f inputs:color.connect = </Root/{name}/RGB.outputs:out>"],[rgb_from("Mapped")],comment,lit)
def cutout(name, lit):
    return material(name,["float inputs:Cutoff = 0.5"],[f"color3f inputs:color.connect = </Root/{name}/RGB.outputs:out>",
        f"float inputs:opacity.connect = </Root/{name}/Alpha.outputs:out>",f"float inputs:opacityThreshold.connect = </Root/{name}.inputs:Cutoff>"],[rgb_from("Mapped")],"",lit)
blend_tail=[
 lambda c,i: node("Curved","ND_mix_vector3",[f"float3 inputs:fg.connect = {c('Mapped')}",f"float3 inputs:bg.connect = {c('Exposed')}",f"float inputs:mix.connect = {i('Curve')}"],"float3 outputs:out"),
 lambda c,i: node("Luma","ND_dotproduct_vector3",[f"float3 inputs:in1.connect = {c('Linear')}","float3 inputs:in2 = (0.2126, 0.7152, 0.0722)"],"float outputs:out"),
 lambda c,i: node("ColourWeightAlpha","ND_multiply_float",[f"float inputs:in1.connect = {c('Alpha')}",f"float inputs:in2.connect = {i('ColourAlpha')}"],"float outputs:out"),
 lambda c,i: node("ColourWeight","ND_add_float",[f"float inputs:in1.connect = {c('ColourWeightAlpha')}",f"float inputs:in2.connect = {i('ColourBase')}"],"float outputs:out"),
 lambda c,i: node("Weighted","ND_multiply_vector3FA",[f"float3 inputs:in1.connect = {c('Curved')}",f"float inputs:in2.connect = {c('ColourWeight')}"],"float3 outputs:out"),
 lambda c,i: node("RGB","ND_convert_vector3_color3",[f"float3 inputs:in.connect = {c('Weighted')}"],"color3f outputs:out"),
 lambda c,i: node("OpacityFromAlpha","ND_multiply_float",[f"float inputs:in1.connect = {c('Alpha')}",f"float inputs:in2.connect = {i('OpacityAlpha')}"],"float outputs:out"),
 lambda c,i: node("OpacityFromLuma","ND_multiply_float",[f"float inputs:in1.connect = {c('Luma')}",f"float inputs:in2.connect = {i('OpacityLuma')}"],"float outputs:out"),
 lambda c,i: node("OpacitySum","ND_add_float",[f"float inputs:in1.connect = {c('OpacityFromAlpha')}",f"float inputs:in2.connect = {c('OpacityFromLuma')}"],"float outputs:out"),
 lambda c,i: node("Opacity","ND_add_float",[f"float inputs:in1.connect = {c('OpacitySum')}",f"float inputs:in2.connect = {i('OpacityBase')}"],"float outputs:out"),
]
blend_comment='''    # Pure3D's blend modes, through premultiplied-alpha blending (dst * (1 - opacity) + colour):
    #   colour  = mix(exposed, tone-mapped, Curve) * (ColourBase + ColourAlpha * a)
    #   opacity = OpacityBase + OpacityAlpha * a + OpacityLuma * luma(linear)
    # Alpha is (0, 1 | 0, 1, 0 | 1); add (1, 0 | 0, 0, 0 | 0); modulate, which darkens dst by src, is
    # black at 1 - luma (0, 0 | 1, 0, -1 | 0). The engine blends before its tone curve; over a picture
    # already through it, a glow added uncurved is nearer than one through the curve's dark toe.
    # MirrorScene.swift sets them per mode.
'''
def blend(name, lit, comment=""):
    return material(name,["float inputs:ColourBase = 0","float inputs:ColourAlpha = 1","float inputs:OpacityBase = 0","float inputs:OpacityAlpha = 1",
        "float inputs:OpacityLuma = 0","float inputs:Curve = 1"],["bool inputs:hasPremultipliedAlpha = 1",f"color3f inputs:color.connect = </Root/{name}/RGB.outputs:out>",
        f"float inputs:opacity.connect = </Root/{name}/Opacity.outputs:out>"],blend_tail,comment,lit)
materials=[opaque("MirrorOpaque",False,intro),opaque("MirrorOpaqueLit",True),cutout("MirrorCutout",False),cutout("MirrorCutoutLit",True),
           blend("MirrorBlend",False,blend_comment),blend("MirrorBlendLit",True)]
p.write_text(head+"\n".join(materials)+"}\n")
