Shader "Photon/Skybox"
{
    Properties
    {
        [Header(Atmosphere)]
        _SunAngularRadius ("Sun Angular Radius", Range(0.5, 5.0)) = 2.0

        [Header(Stars)]
        _StarsIntensity ("Stars Intensity", Range(0, 5)) = 1.0
        _StarsCoverage ("Stars Coverage", Range(0, 5)) = 1.0
    }

    SubShader
    {
        Tags { "Queue"="Background" "RenderType"="Background" "PreviewType"="Skybox" "RenderPipeline"="UniversalPipeline" }
        Cull Off
        ZWrite Off

        Pass
        {
            Name "PhotonSky"

            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #pragma target 4.5

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"

            // ================================================================
            //  Properties
            // ================================================================
            float _SunAngularRadius;
            float _StarsIntensity;
            float _StarsCoverage;

            // ================================================================
            //  Uniforms set by PhotonSkyManager.cs
            // ================================================================
            float3 _SunDir;
            float3 _MoonDir;
            float  _RainStrength;
            float  _FrameTime;
            float  _BiomeCave;
            float  _TimeSunrise;
            float  _TimeSunset;
            float3 _WeatherColor;
            float4x4 _StarRotationMatrix;

            // ================================================================
            //  Structs
            // ================================================================
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
            //  Constants (all inline, no external includes for core math)
            // ================================================================
            #define MY_PI  3.14159265358979
            #define MY_TAU 6.28318530717959
            #define MY_RCP_PI 0.31830988618379

            static const float R_PLANET = 6371e3;
            static const float R_ATMO   = 6481e3;
            static const float2 SCALE_H = float2(8400.0, 1250.0);
            static const float3 SUNLIGHT_COLOR = float3(1.051, 0.985, 0.940);

            // Scattering coefficients (Rec.709)
            static const float3 BETA_R  = float3(8.059e-06, 1.671e-05, 4.080e-05);
            static const float3 BETA_M  = float3(1.8e-06, 1.8e-06, 1.8e-06);
            static const float3 BETA_OZ = float3(8.304e-07, 1.315e-06, 5.441e-08);
            static const float MIE_G    = 0.77;
            static const float MIE_ALB  = 0.9;

            // ================================================================
            //  Helper math
            // ================================================================
            float sqr(float x) { return x * x; }
            float cube(float x) { return x * x * x; }
            float pow4(float x) { float x2 = x*x; return x2*x2; }

            float linear_step(float a, float b, float x) { return saturate((x-a)/(b-a)); }
            float cubic_smooth(float x) { return x*x*(3.0-2.0*x); }

            // Fast acos (Lagarde)
            float fast_acos(float x) {
                float r = (0.0464619*abs(x) - 0.201877)*abs(x) + 1.57018;
                r *= sqrt(1.0 - abs(x));
                return x >= 0 ? r : MY_PI - r;
            }

            // ================================================================
            //  Atmosphere core
            // ================================================================
            float2 density_at(float r) {
                return exp(-(r - R_PLANET) / SCALE_H);
            }

            float3 atmosphere_density(float r) {
                float2 rm = density_at(r);
                float alt_km = (r - R_PLANET) * 1e-3;
                float o1 = 12.5 * exp((0.0  - alt_km) / 8.0);
                float o2 = 30.0 * exp((18.0 - alt_km) * (alt_km - 18.0) / 80.0);
                float o3 = 75.0 * exp((23.5 - alt_km) * (alt_km - 23.5) / 50.0);
                float o4 = 50.0 * exp((30.0 - alt_km) * (alt_km - 30.0) / 150.0);
                float ozone = 7.428e-3 * (o1 + o2 + o3 + o4);
                return float3(rm.x, rm.y, ozone);
            }

            float chapman(float x, float cosZ) {
                float c = sqrt(1.5707963 * x);
                if (cosZ >= 0.0)
                    return c / ((c-1.0)*cosZ + 1.0);
                else {
                    float sinZ = sqrt(max(1.0-cosZ*cosZ, 0.0));
                    return c / ((c-1.0)*cosZ - 1.0) + 2.0*c*exp(x - x*sinZ)*sqrt(sinZ);
                }
            }

            float3 atmo_transmittance(float mu, float r) {
                // Planet intersection check
                float disc = r*r*(mu*mu - 1.0) + R_PLANET*R_PLANET;
                if (disc >= 0.0 && (-r*mu - sqrt(max(disc,0.0))) >= 0.0)
                    return float3(0,0,0);

                float2 rcp_h = 1.0 / SCALE_H;
                float2 dens = exp(-(r - R_PLANET) / SCALE_H);
                float2 am = SCALE_H * dens;
                am.x *= chapman(r * rcp_h.x, mu);
                am.y *= chapman(r * rcp_h.y, mu);

                float3 od = BETA_R * am.x + BETA_M * am.y + BETA_OZ * am.x;
                return saturate(exp(-od));
            }

            // Rayleigh phase with depolarization
            float3 phase_rayleigh(float nu) {
                float3 depol = float3(2.786, 2.842, 2.899) * 1e-2;
                float3 gamma = depol / (2.0 - depol);
                float3 k = 3.0 / (16.0 * MY_PI * (1.0 + 2.0 * gamma));
                return k * ((1.0 + 3.0*gamma) + (1.0 - gamma)*nu*nu);
            }

            // Henyey-Greenstein
            float phase_hg(float nu, float g) {
                float gg = g*g;
                float denom = 1.0 + gg - 2.0*g*nu;
                return (MY_RCP_PI * 0.25) * (1.0-gg) / (denom * sqrt(denom));
            }

            // ================================================================
            //  Sun disk with limb darkening
            // ================================================================
            float3 draw_sun(float3 rd, float3 sun_dir, float3 sun_irr) {
                float nu = dot(rd, sun_dir);
                float ang = _SunAngularRadius * (MY_TAU / 360.0);
                float edge = max(ang - fast_acos(nu), 0.0);
                if (edge <= 0.0) return float3(0,0,0);

                float3 alpha = float3(0.429, 0.522, 0.614);
                float3 limb = pow(max(float3(1,1,1) - sqr(1.0-edge), 0.0), 0.5*alpha);
                return 40.0 * sun_irr * limb;
            }

            // ================================================================
            //  Stars (from Photon — fully inline)
            // ================================================================
            float4 hash4(float2 p) {
                float4 p4 = frac(float4(p.xyxy) * float4(.1031, .1030, .0973, .1099));
                p4 += dot(p4, p4.wzxy + 33.33);
                return frac((p4.xxyz + p4.yzzw) * p4.zywx);
            }

            float3 blackbody_approx(float temp) {
                // Attempt simplified blackbody
                float t = temp / 6500.0;
                float3 col = float3(1.0, 1.0/t, 1.0/(t*t));
                return col / max(col.x, max(col.y, col.z));
            }

            float3 star_field(float2 coord, float threshold) {
                coord = abs(coord) + 33.3 * step(0.0, coord);
                float2 ip;
                float2 f = modf(coord, ip);
                f = float2(cubic_smooth(f.x), cubic_smooth(f.y));

                float3 result = float3(0,0,0);
                for (int dy = 0; dy <= 1; dy++)
                for (int dx = 0; dx <= 1; dx++)
                {
                    float2 cell = ip + float2(dx, dy);
                    float4 n = hash4(cell);
                    float star = linear_step(threshold, 1.0, n.x);
                    star = pow4(star) * _StarsIntensity;

                    float temp = lerp(3500.0, 9500.0, n.y);
                    float3 col = blackbody_approx(temp);

                    float twinkle = 1.0 - n.z * cos(_FrameTime * 2.0 + MY_TAU * n.w);
                    star *= twinkle;

                    float wx = dx == 0 ? (1.0-f.x) : f.x;
                    float wy = dy == 0 ? (1.0-f.y) : f.y;
                    result += star * col * wx * wy;
                }
                return result;
            }

            float3 draw_stars(float3 rd) {
                float3 srd = mul((float3x3)_StarRotationMatrix, rd);
                float threshold = 1.0 - 0.008 * _StarsCoverage * smoothstep(-0.2, 0.05, -_SunDir.y);
                float2 coord = srd.xy / (abs(srd.z) + length(srd.xy)) + 41.21 * sign(srd.z);
                coord *= 600.0;
                return star_field(coord, threshold);
            }

            // ================================================================
            //  ACES tonemap (simplified Hill fit)
            // ================================================================
            float3 aces_hill(float3 x) {
                float3 a = x * (x + 0.0245786) - 0.000090537;
                float3 b = x * (0.983729 * x + 0.4329510) + 0.238081;
                return a / b;
            }

            float3 tonemap(float3 col) {
                // sRGB → approximate ACEScg
                // Simplified Rec.709 to AP1 (no chromatic adaptation, close enough)
                static const float3x3 srgb_to_ap1 = float3x3(
                    0.6131, 0.3395, 0.0474,
                    0.0702, 0.9164, 0.0134,
                    0.0206, 0.1096, 0.8698
                );
                static const float3x3 ap1_to_srgb = float3x3(
                     1.7051, -0.6218, -0.0833,
                    -0.1302,  1.1408, -0.0106,
                    -0.0240, -0.1290,  1.1530
                );

                // These matrices are for mul(M, v) convention (standard HLSL)
                col = mul(srgb_to_ap1, col);
                col = aces_hill(col);
                col = mul(ap1_to_srgb, col);
                return saturate(col);
            }

            // ================================================================
            //  Fragment shader
            // ================================================================
            float4 frag(Varyings i) : SV_Target
            {
                float3 rd = normalize(i.dir);
                float3 sun_dir = _SunDir;

                // If sun dir not set by C#, fallback won't crash (just dark)
                float sun_valid = step(0.01, length(sun_dir));
                sun_dir = sun_valid > 0.5 ? normalize(sun_dir) : float3(0, 1, 0);

                // --- Sun irradiance ---
                float3 sun_trans = atmo_transmittance(sun_dir.y, R_PLANET);
                float sun_E = 6.0;
                float3 sun_irr = sun_E * SUNLIGHT_COLOR * sun_trans;
                sun_irr *= smoothstep(-0.05, 0.1, sun_dir.y);

                // --- Moon irradiance ---
                float3 moon_dir = _MoonDir;
                moon_dir = length(moon_dir) > 0.01 ? normalize(moon_dir) : -sun_dir;
                float3 moon_trans = atmo_transmittance(moon_dir.y, R_PLANET);
                float3 moon_irr = 0.15 * SUNLIGHT_COLOR * moon_trans;
                moon_irr *= smoothstep(-0.05, 0.1, moon_dir.y);

                // --- Ray march atmosphere ---
                float mu = rd.y;
                float disc = R_PLANET*R_PLANET*(mu*mu-1.0) + R_ATMO*R_ATMO;
                float t_max = -R_PLANET*mu + sqrt(max(disc, 0.0));
                t_max = min(t_max, 500000.0);
                if (mu < -0.1) t_max = 0.0; // deep below horizon, skip

                float nu_sun  = dot(rd, sun_dir);
                float nu_moon = dot(rd, moon_dir);

                float3 ph_r_sun  = phase_rayleigh(nu_sun);
                float  ph_m_sun  = phase_hg(nu_sun, MIE_G);
                float3 ph_r_moon = phase_rayleigh(nu_moon);
                float  ph_m_moon = phase_hg(nu_moon, MIE_G);

                const int STEPS = 32;
                float dt = t_max / (float)STEPS;
                float3 scatter_sun  = float3(0,0,0);
                float3 scatter_moon = float3(0,0,0);
                float3 od_view = float3(0,0,0);

                for (int s = 0; s < STEPS; s++)
                {
                    float t = (s + 0.5) * dt;
                    float r_s = sqrt(R_PLANET*R_PLANET + 2.0*R_PLANET*mu*t + t*t);
                    float3 dens = atmosphere_density(r_s);

                    float3 ext = BETA_R * dens.x + BETA_M * dens.y + BETA_OZ * dens.z;
                    od_view += ext * dt;
                    float3 T_view = exp(-od_view);

                    // Sun
                    float mu_s_sun = (R_PLANET * sun_dir.y + t * nu_sun) / r_s;
                    float3 T_sun = atmo_transmittance(mu_s_sun, r_s);
                    float3 w_sun = T_view * T_sun * dt;
                    scatter_sun += (BETA_R * dens.x * ph_r_sun + MIE_ALB * BETA_M * dens.y * ph_m_sun) * w_sun;

                    // Moon
                    float mu_s_moon = (R_PLANET * moon_dir.y + t * nu_moon) / r_s;
                    float3 T_moon = atmo_transmittance(mu_s_moon, r_s);
                    float3 w_moon = T_view * T_moon * dt;
                    scatter_moon += (BETA_R * dens.x * ph_r_moon + MIE_ALB * BETA_M * dens.y * ph_m_moon) * w_moon;
                }

                float3 sky = scatter_sun * sun_irr + scatter_moon * moon_irr;

                // --- View transmittance for celestial objects ---
                float3 T_final = exp(-od_view);

                // --- Sun disk ---
                sky += draw_sun(rd, sun_dir, sun_irr) * T_final;

                // --- Stars ---
                float night = smoothstep(0.0, -0.15, sun_dir.y);
                sky += draw_stars(rd) * T_final * night;

                // --- Rain ---
                if (_RainStrength > 0.001) {
                    float3 rain_sky = _WeatherColor * (1.0 - exp2(-0.8 / max(rd.y, 0.001)));
                    sky = lerp(sky, rain_sky, _RainStrength * lerp(1.0, 0.9, _TimeSunrise + _TimeSunset));
                }

                // --- Ground fade ---
                float gf = smoothstep(0.0, -0.1, rd.y);
                sky = lerp(sky, sky * 0.015, gf);

                // --- Cave fade ---
                sky = lerp(sky, float3(0,0,0), _BiomeCave * smoothstep(-0.1, 0.1, 0.4 - rd.y));

                // --- Tonemap ---
                sky = tonemap(sky);

                return float4(max(sky, 0.0), 1.0);
            }

            ENDHLSL
        }
    }
}
