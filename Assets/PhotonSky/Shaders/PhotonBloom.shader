// ============================================================================
// PhotonBloom.shader
// Unity URP port of Photon's multi-scale bloom pipeline.
// Source: photon/shaders/program/post/bloom/
//
// Photon uses the "Sledgehammer" bloom technique from:
// "Next Generation Post-Processing in Call of Duty: Advanced Warfare"
// by Jorge Jimenez (SIGGRAPH 2014)
//
// Pipeline overview (matches Photon's 4-file bloom system):
//   1. Downsample: 6x6 overlapping box kernels → bloom/downsample.glsl:77-94
//   2. Blur H:     9-tap binomial gaussian      → bloom/gaussian0.glsl:50-87
//   3. Blur V:     9-tap binomial gaussian      → bloom/gaussian1.glsl:50-104
//   4. Upsample:   tent filter + mip combine    → (implicit in Photon's tile system)
//   5. Composite:  mix(scene, bloom, intensity)  → post/grade.glsl:317-322
//
// Photon stores all bloom mips as tiles packed into a single texture.
// We use separate RT mips instead (more natural for Unity's RT system).
// The mathematical operations are identical.
// ============================================================================

Shader "Hidden/Photon/Bloom"
{
    Properties
    {
        _MainTex ("", 2D) = "white" {}
    }

    HLSLINCLUDE
    #pragma target 4.5
    #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"

    TEXTURE2D(_MainTex);
    SAMPLER(sampler_MainTex);
    float4 _MainTex_TexelSize; // (1/w, 1/h, w, h)

    TEXTURE2D(_BloomLowMip);
    SAMPLER(sampler_BloomLowMip);

    float _BloomThreshold;
    float _BloomIntensity;
    float _BloomRadius;

    struct Attributes { float4 pos : POSITION; float2 uv : TEXCOORD0; };
    struct Varyings  { float4 pos : SV_POSITION; float2 uv : TEXCOORD0; };

    Varyings vert(Attributes v)
    {
        Varyings o;
        o.pos = TransformObjectToHClip(v.pos.xyz);
        o.uv = v.uv;
        return o;
    }

    // Soft threshold — focuses bloom on bright areas (sun disk, specular highlights).
    // Photon doesn't hard-threshold; it applies bloom to the full image with mix().
    // We add a soft knee to emphasize bright sources (the sun disk at luminance=40
    // will pass through strongly, while the blue sky at ~0.5 will be suppressed).
    float3 prefilter(float3 col)
    {
        float brightness = max(col.r, max(col.g, col.b));
        float soft = brightness - _BloomThreshold + 0.5;
        soft = clamp(soft, 0.0, 1.0);
        soft = soft * soft * 0.25;
        float contribution = max(soft, brightness - _BloomThreshold);
        contribution /= max(brightness, 1e-4);
        return col * contribution;
    }

    ENDHLSL

    SubShader
    {
        Tags { "RenderPipeline"="UniversalPipeline" }
        Cull Off ZWrite Off ZTest Always

        // ============================================================
        // Pass 0: Prefilter + 6x6 downsample
        // Ref: photon/shaders/program/post/bloom/downsample.glsl:73-94
        // "6x6 downsampling filter made from overlapping 4x4 box kernels"
        // "As described in Next Generation Post-Processing in Call of Duty AW"
        //
        // Weights:
        //   Center:        0.125  (downsample.glsl:79)
        //   Cross (±1,±1): 0.125  (downsample.glsl:81-84)
        //   Edge (±2,0):   0.0625 (downsample.glsl:86-89)
        //   Corner (±2,±2):0.03125(downsample.glsl:91-94)
        //   Total = 0.125 + 4*0.125 + 4*0.0625 + 4*0.03125 = 1.0
        // ============================================================
        Pass
        {
            Name "BloomPrefilter"
            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag

            float4 frag(Varyings i) : SV_Target
            {
                float2 uv = i.uv;
                float2 ts = _MainTex_TexelSize.xy;

                // downsample.glsl:79 — center sample
                float3 col  = SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, uv).rgb * 0.125;

                // downsample.glsl:81-84 — cross neighbors (±1,±1)
                col += SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, uv + float2( 1, 1) * ts).rgb * 0.125;
                col += SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, uv + float2(-1, 1) * ts).rgb * 0.125;
                col += SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, uv + float2( 1,-1) * ts).rgb * 0.125;
                col += SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, uv + float2(-1,-1) * ts).rgb * 0.125;

                // downsample.glsl:86-89 — edge neighbors (±2,0) and (0,±2)
                col += SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, uv + float2( 2, 0) * ts).rgb * 0.0625;
                col += SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, uv + float2(-2, 0) * ts).rgb * 0.0625;
                col += SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, uv + float2( 0, 2) * ts).rgb * 0.0625;
                col += SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, uv + float2( 0,-2) * ts).rgb * 0.0625;

                // downsample.glsl:91-94 — corner neighbors (±2,±2)
                col += SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, uv + float2( 2, 2) * ts).rgb * 0.03125;
                col += SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, uv + float2(-2, 2) * ts).rgb * 0.03125;
                col += SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, uv + float2( 2,-2) * ts).rgb * 0.03125;
                col += SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, uv + float2(-2,-2) * ts).rgb * 0.03125;

                col = prefilter(col);
                return float4(col, 1.0);
            }
            ENDHLSL
        }

        // ============================================================
        // Pass 1: Horizontal 9-tap gaussian blur
        // Ref: photon/shaders/program/post/bloom/gaussian0.glsl:50-87
        // Binomial weights for 9-tap kernel (gaussian0.glsl:50-56):
        //   [0]=0.2734375, [1]=0.21875, [2]=0.109375, [3]=0.03125, [4]=0.00390625
        // Applied symmetrically: tap at offset i uses weights[abs(i)]
        // ============================================================
        Pass
        {
            Name "BloomBlurH"
            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag

            // gaussian0.glsl:50-56 — binomial_weights_9
            static const float weights[5] = { 0.2734375, 0.21875, 0.109375, 0.03125, 0.00390625 };

            float4 frag(Varyings i) : SV_Target
            {
                float2 uv = i.uv;
                float2 ts = float2(_MainTex_TexelSize.x, 0.0);

                // gaussian0.glsl:80-86 — horizontal 9-tap loop
                float3 col = float3(0, 0, 0);
                float wsum = 0.0;
                for (int k = -4; k <= 4; k++)
                {
                    float w = weights[abs(k)];
                    col += SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, uv + k * ts).rgb * w;
                    wsum += w;
                }
                return float4(col / wsum, 1.0);
            }
            ENDHLSL
        }

        // ============================================================
        // Pass 2: Vertical 9-tap gaussian blur
        // Ref: photon/shaders/program/post/bloom/gaussian1.glsl:50-104
        // Same weights as horizontal pass, applied vertically.
        // gaussian1.glsl also handles padding between tiles (lines 74-90);
        // we don't need that since we use separate RTs per mip.
        // ============================================================
        Pass
        {
            Name "BloomBlurV"
            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag

            // gaussian1.glsl:50-56 — same binomial_weights_9
            static const float weights[5] = { 0.2734375, 0.21875, 0.109375, 0.03125, 0.00390625 };

            float4 frag(Varyings i) : SV_Target
            {
                float2 uv = i.uv;
                float2 ts = float2(0.0, _MainTex_TexelSize.y);

                // gaussian1.glsl:94-103 — vertical 9-tap loop
                float3 col = float3(0, 0, 0);
                float wsum = 0.0;
                for (int k = -4; k <= 4; k++)
                {
                    float w = weights[abs(k)];
                    col += SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, uv + k * ts).rgb * w;
                    wsum += w;
                }
                return float4(col / wsum, 1.0);
            }
            ENDHLSL
        }

        // ============================================================
        // Pass 3: Upsample + combine with lower mip
        // Ref: Photon uses tile-based packing (bloom_tile_offset/scale macros),
        //      where upsample is implicit in the bicubic_filter() during merge.
        //      See: post/grade.glsl:65-110 — get_bloom() reads all tiles
        //      and combines them with weight *= radius.
        //
        // We use a 3x3 tent filter for smooth upsampling (standard practice
        // matching the COD presentation), then add the lower mip scaled by
        // _BloomRadius (equivalent to Photon's "weight *= radius" at grade.glsl:95).
        // ============================================================
        Pass
        {
            Name "BloomUpsample"
            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag

            float4 frag(Varyings i) : SV_Target
            {
                float2 uv = i.uv;
                float2 ts = _MainTex_TexelSize.xy;

                // 3x3 tent filter (1-2-1 kernel, weights sum to 16)
                float3 col  = SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, uv + float2(-1,-1) * ts).rgb;
                     col += SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, uv + float2( 0,-1) * ts).rgb * 2.0;
                     col += SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, uv + float2( 1,-1) * ts).rgb;
                     col += SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, uv + float2(-1, 0) * ts).rgb * 2.0;
                     col += SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, uv).rgb * 4.0;
                     col += SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, uv + float2( 1, 0) * ts).rgb * 2.0;
                     col += SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, uv + float2(-1, 1) * ts).rgb;
                     col += SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, uv + float2( 0, 1) * ts).rgb * 2.0;
                     col += SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, uv + float2( 1, 1) * ts).rgb;
                col /= 16.0;

                // grade.glsl:95 — weight *= radius (accumulate larger-scale bloom)
                float3 low = SAMPLE_TEXTURE2D(_BloomLowMip, sampler_BloomLowMip, uv).rgb;
                col += low * _BloomRadius;

                return float4(col, 1.0);
            }
            ENDHLSL
        }

        // ============================================================
        // Pass 4: Final composite — blend bloom into scene
        // Ref: photon/shaders/program/post/grade.glsl:320-322
        //   vec3 bloom = get_bloom(fog_bloom);
        //   float bloom_intensity = 0.12 * BLOOM_INTENSITY;
        //   scene_color = mix(scene_color, bloom, bloom_intensity);
        //
        // Default BLOOM_INTENSITY = 1.0 (settings.glsl:338), so default
        // blend factor = 0.12. We expose this as _BloomIntensity.
        // ============================================================
        Pass
        {
            Name "BloomComposite"
            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag

            float4 frag(Varyings i) : SV_Target
            {
                float3 scene = SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, i.uv).rgb;
                float3 bloom = SAMPLE_TEXTURE2D(_BloomLowMip, sampler_BloomLowMip, i.uv).rgb;

                // grade.glsl:322 — mix(scene_color, bloom, bloom_intensity)
                float3 col = lerp(scene, bloom, _BloomIntensity);

                return float4(col, 1.0);
            }
            ENDHLSL
        }
    }
}
