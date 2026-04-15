Shader "Photon/SkyboxDebug"
{
    Properties
    {
        [Header(Time)]
        _TimeOfDay ("Time Of Day", Range(0, 24)) = 12.0
    }

    SubShader
    {
        Tags { "Queue"="Background" "RenderType"="Background" "PreviewType"="Skybox" "RenderPipeline"="UniversalPipeline" }
        Cull Off
        ZWrite Off

        Pass
        {
            Name "PhotonSkyDebug"

            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #pragma target 4.5

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"

            float _TimeOfDay;

            struct Attributes { float4 pos : POSITION; };
            struct Varyings  { float4 pos : SV_POSITION; float3 dir : TEXCOORD0; };

            Varyings vert(Attributes v)
            {
                Varyings o;
                o.pos = TransformObjectToHClip(v.pos.xyz);
                o.dir = TransformObjectToWorld(v.pos.xyz);
                return o;
            }

            // ================================================================
            // ALL constants and functions inline — ZERO external dependencies
            // ================================================================

            #define MY_PI 3.14159265
            #define MY_TAU 6.28318530

            // Atmosphere parameters
            static const float R_PLANET = 6371e3;
            static const float R_ATMO   = 6481e3;
            static const float2 SCALE_H = float2(8400.0, 1250.0);

            // Scattering coefficients (Rec.709, no color space transform)
            static const float3 BETA_R = float3(8.059e-06, 1.671e-05, 4.080e-05);
            static const float3 BETA_M = float3(1.8e-06, 1.8e-06, 1.8e-06);
            static const float MIE_G   = 0.76;

            // Density at radius r
            float2 density_at(float r)
            {
                float alt = r - R_PLANET;
                return exp(-alt / SCALE_H);
            }

            // Chapman function approximation for optical depth
            float chapman(float x, float cosZ)
            {
                float c = sqrt(1.5707963 * x);
                if (cosZ >= 0.0)
                    return c / ((c - 1.0) * cosZ + 1.0);
                else
                {
                    float sinZ = sqrt(max(1.0 - cosZ * cosZ, 0.0));
                    return c / ((c - 1.0) * cosZ - 1.0) + 2.0 * c * exp(x - x * sinZ) * sqrt(sinZ);
                }
            }

            // Transmittance from point at (mu, r) to atmosphere edge
            float3 transmittance(float mu, float r)
            {
                // Check planet intersection
                float disc = r * r * (mu * mu - 1.0) + R_PLANET * R_PLANET;
                if (disc >= 0.0 && (-r * mu - sqrt(disc)) >= 0.0)
                    return float3(0, 0, 0); // ray hits planet

                float2 rcp_h = 1.0 / SCALE_H;
                float2 dens = exp(-(r - R_PLANET) / SCALE_H);
                float2 am = SCALE_H * dens;
                am.x *= chapman(r * rcp_h.x, mu);
                am.y *= chapman(r * rcp_h.y, mu);

                float3 od = BETA_R * am.x + BETA_M * am.y;
                return saturate(exp(-od));
            }

            // Rayleigh phase function (simplified)
            float phase_rayleigh(float cosT)
            {
                return (3.0 / (16.0 * MY_PI)) * (1.0 + cosT * cosT);
            }

            // Henyey-Greenstein phase function
            float phase_mie(float cosT, float g)
            {
                float gg = g * g;
                float denom = 1.0 + gg - 2.0 * g * cosT;
                return (1.0 / (4.0 * MY_PI)) * (1.0 - gg) / (denom * sqrt(denom));
            }

            // Compute sun direction from time of day
            float3 get_sun_dir(float tod)
            {
                float angle = tod / 24.0 * MY_TAU;
                return normalize(float3(sin(angle) * 0.5, -cos(angle), sin(angle) * 0.866));
            }

            float4 frag(Varyings i) : SV_Target
            {
                float3 rd = normalize(i.dir);
                float3 sun_dir = get_sun_dir(_TimeOfDay);

                // Ray-atmosphere intersection
                float mu = rd.y;
                float r0 = R_PLANET;

                // t_max: distance from ground to atmosphere edge along ray
                float disc = r0 * r0 * (mu * mu - 1.0) + R_ATMO * R_ATMO;
                float t_max = -r0 * mu + sqrt(max(disc, 0.0));
                if (mu < 0.0) t_max = max(t_max, 0.0); // below horizon

                // Clamp very long horizontal paths
                t_max = min(t_max, 500000.0);

                float nu = dot(rd, sun_dir);

                // Phase functions
                float ph_r = phase_rayleigh(nu);
                float ph_m = phase_mie(nu, MIE_G);

                // Sun irradiance (just a constant)
                float sun_E = 5.0;
                float3 sun_trans = transmittance(sun_dir.y, R_PLANET);
                float3 sun_irr = sun_E * float3(1.05, 0.98, 0.94) * sun_trans;
                sun_irr *= smoothstep(-0.05, 0.1, sun_dir.y); // fade below horizon

                // Ray march
                const int STEPS = 32;
                float dt = t_max / (float)STEPS;
                float3 scatter = float3(0, 0, 0);
                float3 od_view = float3(0, 0, 0);

                for (int s = 0; s < STEPS; s++)
                {
                    float t = (s + 0.5) * dt;
                    float r_s = sqrt(r0 * r0 + 2.0 * r0 * mu * t + t * t);
                    float2 d = density_at(r_s);

                    // Extinction along view ray
                    float3 ext = BETA_R * d.x + BETA_M * d.y;
                    od_view += ext * dt;
                    float3 T_view = exp(-od_view);

                    // Sun transmittance at sample point
                    float mu_s = (r0 * sun_dir.y + t * nu) / r_s;
                    float3 T_sun = transmittance(mu_s, r_s);

                    // In-scattering
                    float3 scat_r = BETA_R * d.x * ph_r;
                    float3 scat_m = BETA_M * d.y * ph_m;
                    scatter += (scat_r + scat_m) * T_view * T_sun * dt;
                }

                float3 col = scatter * sun_irr;

                // Sun disk
                float sun_ang = 0.035; // ~2 degrees
                float sun_cos = cos(sun_ang);
                if (nu > sun_cos)
                {
                    float3 T_view = exp(-od_view);
                    col += 30.0 * sun_irr * T_view * smoothstep(sun_cos, sun_cos + 0.002, nu);
                }

                // Ground: dark below horizon
                if (rd.y < 0.0)
                {
                    float gf = smoothstep(0.0, -0.1, rd.y);
                    col = lerp(col, col * 0.01, gf);
                }

                // Reinhard tonemap
                col = col / (1.0 + col);

                return float4(max(col, 0.0), 1.0);
            }

            ENDHLSL
        }
    }
}
