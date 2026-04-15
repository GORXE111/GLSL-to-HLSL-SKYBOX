Shader "Hidden/Photon/Bloom"
{
    // Multi-pass bloom following Photon's approach
    // (Sledgehammer/COD Advanced Warfare multi-scale bloom)
    // Pass 0: Prefilter + downsample
    // Pass 1: Horizontal gaussian blur
    // Pass 2: Vertical gaussian blur
    // Pass 3: Upsample + combine
    // Pass 4: Final composite (blend bloom into scene)

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

    // Soft threshold (Photon doesn't use hard threshold, bloom is applied to full image)
    // But we need slight filtering to focus bloom on bright areas (sun, glow)
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
        // Pass 0: Prefilter + 6x6 downsample (COD/Sledgehammer method)
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

                // 6x6 downsample from overlapping 4x4 box kernels
                // Weights: center(0.125), cross(0.125), diagonal-near(0.0625), diagonal-far(0.03125)
                float3 col  = SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, uv).rgb * 0.125;

                col += SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, uv + float2( 1, 1) * ts).rgb * 0.125;
                col += SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, uv + float2(-1, 1) * ts).rgb * 0.125;
                col += SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, uv + float2( 1,-1) * ts).rgb * 0.125;
                col += SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, uv + float2(-1,-1) * ts).rgb * 0.125;

                col += SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, uv + float2( 2, 0) * ts).rgb * 0.0625;
                col += SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, uv + float2(-2, 0) * ts).rgb * 0.0625;
                col += SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, uv + float2( 0, 2) * ts).rgb * 0.0625;
                col += SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, uv + float2( 0,-2) * ts).rgb * 0.0625;

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
        // ============================================================
        Pass
        {
            Name "BloomBlurH"
            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag

            // Binomial weights for 9-tap (matches Photon)
            static const float weights[5] = { 0.2734375, 0.21875, 0.109375, 0.03125, 0.00390625 };

            float4 frag(Varyings i) : SV_Target
            {
                float2 uv = i.uv;
                float2 ts = float2(_MainTex_TexelSize.x, 0.0);

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
        // ============================================================
        Pass
        {
            Name "BloomBlurV"
            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag

            static const float weights[5] = { 0.2734375, 0.21875, 0.109375, 0.03125, 0.00390625 };

            float4 frag(Varyings i) : SV_Target
            {
                float2 uv = i.uv;
                float2 ts = float2(0.0, _MainTex_TexelSize.y);

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
        // Pass 3: Upsample + combine with lower mip (tent filter)
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

                // 3x3 tent filter for smooth upsampling
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

                // Add lower mip (accumulated bloom from smaller scales)
                float3 low = SAMPLE_TEXTURE2D(_BloomLowMip, sampler_BloomLowMip, uv).rgb;
                col += low * _BloomRadius;

                return float4(col, 1.0);
            }
            ENDHLSL
        }

        // ============================================================
        // Pass 4: Final composite — blend bloom into scene
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

                // Photon: mix(scene, bloom, 0.12 * BLOOM_INTENSITY)
                float3 col = lerp(scene, bloom, _BloomIntensity);

                return float4(col, 1.0);
            }
            ENDHLSL
        }
    }
}
