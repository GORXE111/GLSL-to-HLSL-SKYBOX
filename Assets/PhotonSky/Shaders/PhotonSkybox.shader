// ============================================================================
// PhotonSkybox.shader
// Unity URP port of Photon Shaders by SixthSurge (Minecraft OptiFine/Iris)
// Source repository: https://github.com/sixthsurge/photon
//
// This shader combines multiple Photon source files into a single self-contained
// skybox shader. Each section references the original GLSL source file and line
// numbers for traceability.
// ============================================================================

Shader "Photon/Skybox"
{
    Properties
    {
        [Header(Atmosphere)]
        _SunAngularRadius ("Sun Angular Radius", Range(0.5, 5.0)) = 2.0
        // Ref: photon/shaders/settings.glsl:176 — SUN_ANGULAR_RADIUS default 2.0

        [Header(Stars)]
        _StarsIntensity ("Stars Intensity", Range(0, 5)) = 1.0
        _StarsCoverage ("Stars Coverage", Range(0, 5)) = 1.0
        // Ref: photon/shaders/settings.glsl:184-185 — STARS_INTENSITY, STARS_COVERAGE
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
            //  Constants
            //  Ref: photon/shaders/include/global.glsl:12-21 — common constants
            // ================================================================
            #define MY_PI  3.14159265358979
            #define MY_TAU 6.28318530717959
            #define MY_RCP_PI 0.31830988618379

            // ================================================================
            //  Atmosphere physical parameters
            //  Ref: photon/shaders/include/sky/atmosphere.glsl:26-51
            //  Planet radius, atmosphere boundaries, scale heights, and
            //  scattering/extinction coefficients.
            //  Coefficients here are in Rec.709 (original Photon applies
            //  rec709_to_rec2020 transform; we skip that for now).
            // ================================================================
            static const float R_PLANET = 6371e3;              // atmosphere.glsl:26  planet_radius
            static const float R_ATMO   = 6481e3;              // atmosphere.glsl:30  atmosphere_outer_radius (planet + 110km)
            static const float2 SCALE_H = float2(8400.0, 1250.0); // atmosphere.glsl:43  air_scale_heights (Rayleigh, Mie)
            static const float3 SUNLIGHT_COLOR = float3(1.051, 0.985, 0.940); // atmosphere.glsl:15  sunlight_color (AM0 spectrum)

            // atmosphere.glsl:46-48 — scattering coefficients (Rec.709 primaries)
            static const float3 BETA_R  = float3(8.059e-06, 1.671e-05, 4.080e-05); // air_rayleigh_coefficient
            static const float3 BETA_M  = float3(1.8e-06, 1.8e-06, 1.8e-06);       // air_mie_coefficient (simplified)
            static const float3 BETA_OZ = float3(8.304e-07, 1.315e-06, 5.441e-08); // air_ozone_coefficient
            static const float MIE_G    = 0.77;    // atmosphere.glsl:41  air_mie_g (HG anisotropy)
            static const float MIE_ALB  = 0.9;     // atmosphere.glsl:39  air_mie_albedo

            // ================================================================
            //  Helper math
            //  Ref: photon/shaders/include/global.glsl:37-91 — sqr, cube, linear_step, cubic_smooth
            //  Ref: photon/shaders/include/utility/fast_math.glsl:9-18 — fast_acos (Lagarde 2014)
            // ================================================================
            float sqr(float x) { return x * x; }
            float cube(float x) { return x * x * x; }
            float pow4(float x) { float x2 = x*x; return x2*x2; }
            float linear_step(float a, float b, float x) { return saturate((x-a)/(b-a)); }
            float cubic_smooth(float x) { return x*x*(3.0-2.0*x); }

            // fast_math.glsl:9-18 — fast_acos, max error 3.9e-4
            float fast_acos(float x) {
                float r = (0.0464619*abs(x) - 0.201877)*abs(x) + 1.57018;
                r *= sqrt(1.0 - abs(x));
                return x >= 0 ? r : MY_PI - r;
            }

            // ================================================================
            //  Atmosphere density distribution
            //  Ref: photon/shaders/include/sky/atmosphere.glsl:63-78
            //  Returns (rayleigh_density, mie_density, ozone_density)
            //  Rayleigh/Mie use exponential falloff with scale heights.
            //  Ozone distribution from Jessie (desmos.com/calculator/b66xr8madc)
            // ================================================================
            float2 density_at(float r) {
                return exp(-(r - R_PLANET) / SCALE_H);
            }

            float3 atmosphere_density(float r) {
                float2 rm = density_at(r);
                // atmosphere.glsl:70-75 — Jessie ozone model
                float alt_km = (r - R_PLANET) * 1e-3;
                float o1 = 12.5 * exp((0.0  - alt_km) / 8.0);
                float o2 = 30.0 * exp((18.0 - alt_km) * (alt_km - 18.0) / 80.0);
                float o3 = 75.0 * exp((23.5 - alt_km) * (alt_km - 23.5) / 50.0);
                float o4 = 50.0 * exp((30.0 - alt_km) * (alt_km - 30.0) / 150.0);
                float ozone = 7.428e-3 * (o1 + o2 + o3 + o4);
                return float3(rm.x, rm.y, ozone);
            }

            // ================================================================
            //  Chapman function approximation
            //  Ref: photon/shaders/include/sky/atmosphere.glsl:330-338
            //  Source: http://www.thetenthplanet.de/archives/4519
            //  Used to estimate airmass along a ray through the atmosphere
            //  without numerical integration.
            // ================================================================
            float chapman(float x, float cosZ) {
                float c = sqrt(1.5707963 * x); // sqrt(pi/2 * x)
                if (cosZ >= 0.0)
                    return c / ((c-1.0)*cosZ + 1.0);
                else {
                    float sinZ = sqrt(max(1.0-cosZ*cosZ, 0.0));
                    return c / ((c-1.0)*cosZ - 1.0) + 2.0*c*exp(x - x*sinZ)*sqrt(sinZ);
                }
            }

            // ================================================================
            //  Analytic transmittance (no LUT)
            //  Ref: photon/shaders/include/sky/atmosphere.glsl:341-356
            //  Fallback path when ATMOSPHERE_TRANSMITTANCE_LUT is not defined.
            //  Uses Chapman function to estimate optical depth along ray.
            // ================================================================
            float3 atmo_transmittance(float mu, float r) {
                // atmosphere.glsl:342 — planet intersection check
                float disc = r*r*(mu*mu - 1.0) + R_PLANET*R_PLANET;
                if (disc >= 0.0 && (-r*mu - sqrt(max(disc,0.0))) >= 0.0)
                    return float3(0,0,0);

                // atmosphere.glsl:345-355 — Chapman-based airmass + extinction
                float2 rcp_h = 1.0 / SCALE_H;
                float2 dens = exp(-(r - R_PLANET) / SCALE_H);
                float2 am = SCALE_H * dens;
                am.x *= chapman(r * rcp_h.x, mu);
                am.y *= chapman(r * rcp_h.y, mu);

                float3 od = BETA_R * am.x + BETA_M * am.y + BETA_OZ * am.x;
                return saturate(exp(-od));
            }

            // ================================================================
            //  Rayleigh phase function with depolarization
            //  Ref: photon/shaders/include/utility/phase_functions.glsl:8-16
            //  Depolarization factors account for molecular anisotropy.
            // ================================================================
            float3 phase_rayleigh(float nu) {
                // phase_functions.glsl:9 — depolarization ratios
                float3 depol = float3(2.786, 2.842, 2.899) * 1e-2;
                float3 gamma = depol / (2.0 - depol);
                float3 k = 3.0 / (16.0 * MY_PI * (1.0 + 2.0 * gamma));
                return k * ((1.0 + 3.0*gamma) + (1.0 - gamma)*nu*nu);
            }

            // ================================================================
            //  Henyey-Greenstein phase function
            //  Ref: photon/shaders/include/utility/phase_functions.glsl:18-22
            //  Controls Mie forward scattering peak (g=0.77 gives strong
            //  forward lobe — this is what creates the sun halo/glow).
            // ================================================================
            float phase_hg(float nu, float g) {
                float gg = g*g;
                float denom = 1.0 + gg - 2.0*g*nu;
                return (MY_RCP_PI * 0.25) * (1.0-gg) / (denom * sqrt(denom));
            }

            // ================================================================
            //  Sun disk with limb darkening
            //  Ref: photon/shaders/include/sky/sky.glsl:20-29
            //  Limb darkening model from:
            //  http://www.physics.hmc.edu/faculty/esin/a101/limbdarkening.pdf
            //  Alpha coefficients control wavelength-dependent edge darkening.
            //  sun_luminance = 40.0 (sky.glsl:17)
            // ================================================================
            float3 draw_sun(float3 rd, float3 sun_dir, float3 sun_irr) {
                float nu = dot(rd, sun_dir);
                float ang = _SunAngularRadius * (MY_TAU / 360.0); // settings.glsl:176
                float edge = max(ang - fast_acos(nu), 0.0);
                if (edge <= 0.0) return float3(0,0,0);

                // sky.glsl:26 — limb darkening alpha per channel
                float3 alpha = float3(0.429, 0.522, 0.614);
                float3 limb = pow(max(float3(1,1,1) - sqr(1.0-edge), 0.0), 0.5*alpha);
                return 40.0 * sun_irr * limb; // sky.glsl:17 — sun_luminance = 40.0
            }

            // ================================================================
            //  Star field
            //  Ref: photon/shaders/include/sky/sky.glsl:32-86
            //  Hash-based procedural star generation.
            //  - hash4() from https://www.shadertoy.com/view/4djSRW (sky.glsl:32 comment)
            //  - Stable bilinear interpolation between 4 integer cells (sky.glsl:55-66)
            //  - Blackbody color for star temperature range 3500K-9500K (sky.glsl:42)
            //  - Twinkle animation using cos() with per-star random offset (sky.glsl:48)
            //  - Star visibility threshold fades with sun altitude (sky.glsl:79)
            // ================================================================
            float4 hash4(float2 p) {
                // sky.glsl:32 — hash from shadertoy.com/view/Md2SR3
                float4 p4 = frac(float4(p.xyxy) * float4(.1031, .1030, .0973, .1099));
                p4 += dot(p4, p4.wzxy + 33.33);
                return frac((p4.xxyz + p4.yzzw) * p4.zywx);
            }

            float3 blackbody_approx(float temp) {
                // Simplified version of photon's blackbody() in utility/color.glsl:108-123
                // Original uses Planck's law with AP1 wavelengths; this is a visual approximation
                float t = temp / 6500.0;
                float3 col = float3(1.0, 1.0/t, 1.0/(t*t));
                return col / max(col.x, max(col.y, col.z));
            }

            // sky.glsl:55-66 — stable_star_field (bilinear interp of 4 cells)
            float3 star_field(float2 coord, float threshold) {
                coord = abs(coord) + 33.3 * step(0.0, coord); // sky.glsl:56
                float2 ip;
                float2 f = modf(coord, ip);
                f = float2(cubic_smooth(f.x), cubic_smooth(f.y)); // sky.glsl:59

                float3 result = float3(0,0,0);
                for (int dy = 0; dy <= 1; dy++)
                for (int dx = 0; dx <= 1; dx++)
                {
                    float2 cell = ip + float2(dx, dy);
                    float4 n = hash4(cell);

                    // sky.glsl:39-40 — star brightness from hash threshold
                    float star = linear_step(threshold, 1.0, n.x);
                    star = pow4(star) * _StarsIntensity;

                    // sky.glsl:42-43 — color from blackbody temperature
                    float temp = lerp(3500.0, 9500.0, n.y);
                    float3 col = blackbody_approx(temp);

                    // sky.glsl:46-48 — twinkle animation
                    float twinkle = 1.0 - n.z * cos(_FrameTime * 2.0 + MY_TAU * n.w);
                    star *= twinkle;

                    float wx = dx == 0 ? (1.0-f.x) : f.x;
                    float wy = dy == 0 ? (1.0-f.y) : f.y;
                    result += star * col * wx * wy;
                }
                return result;
            }

            // sky.glsl:68-86 — draw_stars (project ray to plane, scale coords)
            float3 draw_stars(float3 rd) {
                float3 srd = mul((float3x3)_StarRotationMatrix, rd); // sky.glsl:72 — rotate with celestial sphere
                float threshold = 1.0 - 0.008 * _StarsCoverage * smoothstep(-0.2, 0.05, -_SunDir.y); // sky.glsl:79
                float2 coord = srd.xy / (abs(srd.z) + length(srd.xy)) + 41.21 * sign(srd.z); // sky.glsl:82
                coord *= 600.0; // sky.glsl:83
                return star_field(coord, threshold);
            }

            // ================================================================
            //  Tonemap: Lottes 2016 (Photon default)
            //  Ref: photon/shaders/program/post/grade.glsl:236-253
            //  settings.glsl:355 — "#define tonemap tonemap_lottes"
            //  Source: "Advanced Techniques and Optimization of HDR Color Pipelines"
            //  https://gpuopen.com/wp-content/uploads/2016/03/GdcVdrLottes.pdf
            // ================================================================
            float3 tonemap_lottes(float3 rgb) {
                // grade.glsl:239-243 — Lottes curve parameters
                const float3 a       = float3(1.5, 1.5, 1.5);     // Contrast
                const float3 d       = float3(0.91, 0.91, 0.91);  // Shoulder contrast
                const float3 hdr_max = float3(8.0, 8.0, 8.0);     // White point
                const float3 mid_in  = float3(0.26, 0.26, 0.26);  // Fixed midpoint x
                const float3 mid_out = float3(0.32, 0.32, 0.32);  // Fixed midpoint y

                // grade.glsl:245-250 — precomputed curve coefficients
                float3 b_coeff = (-pow(mid_in, a) + pow(hdr_max, a) * mid_out) /
                    ((pow(hdr_max, a * d) - pow(mid_in, a * d)) * mid_out);
                float3 c_coeff = (pow(hdr_max, a * d) * pow(mid_in, a) - pow(hdr_max, a) * pow(mid_in, a * d) * mid_out) /
                    ((pow(hdr_max, a * d) - pow(mid_in, a * d)) * mid_out);

                // grade.glsl:252
                return pow(abs(rgb), a) / (pow(abs(rgb), a * d) * b_coeff + c_coeff);
            }

            // ================================================================
            //  Color grading — pre-tonemap
            //  Ref: photon/shaders/program/post/grade.glsl:119-151
            //  Applied in HDR space before tonemapping.
            //  Default values: brightness=0.83, contrast=1.0, saturation=0.98
            // ================================================================
            float3 grade_input(float3 rgb) {
                // grade.glsl:122-124 — defaults from settings.glsl:358-360
                const float brightness = 0.83; // 0.83 * GRADE_BRIGHTNESS(1.0)
                const float contrast   = 1.00; // 1.00 * GRADE_CONTRAST(1.0)
                const float saturation = 0.98; // 0.98 * GRADE_SATURATION(1.0)

                // grade.glsl:127 — brightness
                rgb *= brightness;

                // grade.glsl:130-133 — contrast (log-space around midpoint 0.18)
                const float log_midpoint = -2.473931; // log2(0.18)
                rgb = log2(max(rgb, 1e-6));
                rgb = contrast * (rgb - log_midpoint) + log_midpoint;
                rgb = max(exp2(rgb) - 1e-6, 0.0);

                // grade.glsl:136-137 — saturation
                static const float3 lum_w = float3(0.2627, 0.6780, 0.0593); // Rec.2020 weights
                float lum = dot(rgb, lum_w);
                rgb = max(lerp(float3(lum,lum,lum), rgb, saturation), 0.0);

                return rgb;
            }

            // ================================================================
            //  Color grading — post-tonemap
            //  Ref: photon/shaders/program/post/grade.glsl:155-186
            //  Applied in LDR [0,1] space after tonemapping.
            //  Boosts teal saturation (sky color richness) and applies gain.
            // ================================================================
            float3 rgb_to_hsl_inline(float3 c) {
                // Ref: utility/color.glsl:72-82
                float4 K = float4(0.0, -1.0/3.0, 2.0/3.0, -1.0);
                float4 p = (c.b < c.g) ? float4(c.bg, K.wz) : float4(c.gb, K.xy);
                float4 q = (p.x < c.r) ? float4(c.r, p.yzx) : float4(p.xyw, c.r);
                float d = q.x - min(q.w, q.y);
                float e = 1e-6;
                return float3(abs(q.z + (q.w - q.y) / (6.0*d+e)), d / (q.x+e), q.x);
            }

            float3 hsl_to_rgb_inline(float3 c) {
                // Ref: utility/color.glsl:83-91
                float4 K = float4(1.0, 2.0/3.0, 1.0/3.0, 3.0);
                c.yz = saturate(c.yz);
                float3 p = abs(frac(c.xxx + K.xyz) * 6.0 - K.www);
                return c.z * lerp(K.xxx, saturate(p - K.xxx), c.y);
            }

            float isolate_hue_inline(float3 hsl, float center, float width) {
                // Ref: utility/color.glsl:126-129
                if (hsl.y < 1e-2 || hsl.z < 1e-2) return 0.0;
                float x = abs(hsl.x * 360.0 - center) / width;
                return x > 1.0 ? 0.0 : (1.0 - x*x*(3.0-2.0*x)); // cubic_smooth(1-x)
            }

            float3 grade_output(float3 rgb) {
                // grade.glsl:157 — work in perceptual (sqrt) space
                rgb = sqrt(max(rgb, 0.0));

                float3 hsl = rgb_to_hsl_inline(rgb);

                // grade.glsl:169-170 — orange sat boost (default 0.0, skip)
                // grade.glsl:173-174 — teal sat boost (default 0.10)
                float teal = isolate_hue_inline(hsl, 210.0, 20.0);
                hsl.y *= 1.0 + 0.10 * teal; // settings.glsl:363 — GRADE_TEAL_SAT_BOOST = 0.10

                rgb = hsl_to_rgb_inline(hsl);

                // grade.glsl:183 — gain(rgb, 1.05)
                // gain function: 0.5 * pow(2*x, k) for x<0.5, 1 - 0.5*pow(2*(1-x), k) for x>=0.5
                float3 gx = lerp(rgb, 1.0 - rgb, step(0.5, rgb));
                float3 ga = 0.5 * pow(max(2.0 * gx, 0.0), float3(1.05, 1.05, 1.05));
                rgb = lerp(ga, 1.0 - ga, step(0.5, rgb));

                // grade.glsl:185 — back to linear
                return rgb * rgb;
            }

            // ================================================================
            //  Full tonemap pipeline (matching Photon grade.glsl:310-344)
            // ================================================================
            float3 tonemap(float3 col) {
                // grade.glsl:336 — grade_input (pre-tonemap color grading)
                col = grade_input(col);

                // grade.glsl:340 — tonemap (Lottes, Photon default)
                col = tonemap_lottes(col);
                col = saturate(col);

                // grade.glsl:345 — grade_output (post-tonemap color grading)
                col = grade_output(col);

                return col;
            }

            // ================================================================
            //  Volumetric clouds (inline, self-contained)
            //  Ref: photon/shaders/include/sky/clouds.glsl
            // ================================================================
            #include "Include/CloudsInline.hlsl"

            // ================================================================
            //  Fragment shader — main sky rendering
            //  Ref: photon/shaders/include/sky/sky.glsl:107-166 — draw_sky()
            //  Combines atmosphere scattering, sun disk, stars, weather, caves.
            //
            //  Scattering integration follows the structure from:
            //  - Eric Bruneton's 2020 precomputed atmospheric scattering
            //    (ebruneton.github.io/precomputed_atmospheric_scattering/)
            //  - Photon's single-scattering path in atmosphere.glsl
            //  Here we do real-time ray march (32 steps) instead of LUT lookup,
            //  using the analytic Chapman transmittance as the inner integrand.
            // ================================================================
            float4 frag(Varyings i) : SV_Target
            {
                float3 rd = normalize(i.dir);
                float3 sun_dir = _SunDir;

                // Fallback if C# hasn't set sun direction yet
                float sun_valid = step(0.01, length(sun_dir));
                sun_dir = sun_valid > 0.5 ? normalize(sun_dir) : float3(0, 1, 0);

                // --- Sun exposure (time-varying) ---
                // Ref: photon/shaders/include/light/colors/light_color.glsl:10-18
                // get_sun_exposure(): base_scale=7.0, boosted during sunrise/sunset/blue hour
                float blue_hour = saturate(exp(-190.0 * sqr(sun_dir.y + 0.09604))); // light_color.glsl:13
                blue_hour = max(0.0, (blue_hour - 0.05) / 0.95);                    // light_color.glsl:21 threshold

                // light_color.glsl:15 — time weights for sunrise/sunset
                float t_sunrise = saturate(1.0 - abs(sun_dir.y - 0.15) / 0.2) * step(sun_dir.y, 0.5);
                float t_sunset  = saturate(1.0 - abs(sun_dir.y - 0.15) / 0.2) * step(0.0, sun_dir.y) * (1.0 - step(sun_dir.y, 0.5));

                // light_color.glsl:15 — daytime exposure multiplier
                float daytime_mul = 1.0 + 0.5 * (t_sunset + t_sunrise) + 40.0 * blue_hour;
                float sun_E = 7.0 * daytime_mul; // light_color.glsl:11 — base_scale = 7.0 * SUN_I

                // --- Sun irradiance ---
                // Ref: light_color.glsl:53-58 — get_light_color()
                float3 sun_trans = atmo_transmittance(sun_dir.y, R_PLANET);
                float3 sun_irr = sun_E * SUNLIGHT_COLOR * sun_trans;
                sun_irr *= smoothstep(-0.05, 0.1, sun_dir.y); // light_color.glsl:56 — fade during transition
                // light_color.glsl:57 — slight dimming near horizon to prevent over-brightness
                float horizon_pulse = abs(sun_dir.y) - 0.15;
                float hp = abs(horizon_pulse) / 0.11;
                float hp_smooth = hp > 1.0 ? 0.0 : 1.0 - hp*hp*(3.0-2.0*hp);
                sun_irr *= 1.0 - 0.25 * hp_smooth;

                // --- Moon irradiance ---
                // Ref: light_color.glsl:41-45 — get_moon_exposure()
                float3 moon_dir = _MoonDir;
                moon_dir = length(moon_dir) > 0.01 ? normalize(moon_dir) : -sun_dir;
                float3 moon_trans = atmo_transmittance(moon_dir.y, R_PLANET);
                float3 moon_irr = 0.15 * SUNLIGHT_COLOR * moon_trans; // moon base_scale = 0.66 * MOON_I
                moon_irr *= smoothstep(-0.05, 0.1, moon_dir.y);

                // --- Ray-atmosphere intersection ---
                // Ref: atmosphere.glsl uses intersect_sphere from utility/geometry.glsl:49-56
                float mu = rd.y;
                float disc = R_PLANET*R_PLANET*(mu*mu-1.0) + R_ATMO*R_ATMO;
                float t_max = -R_PLANET*mu + sqrt(max(disc, 0.0));
                t_max = min(t_max, 500000.0); // cap very long horizontal paths
                if (mu < -0.1) t_max = 0.0;   // skip deep below horizon

                // --- Phase functions ---
                float nu_sun  = dot(rd, sun_dir);
                float nu_moon = dot(rd, moon_dir);
                float3 ph_r_sun  = phase_rayleigh(nu_sun);   // phase_functions.glsl:8
                float  ph_m_sun  = phase_hg(nu_sun, MIE_G);  // phase_functions.glsl:18, g=0.77
                float3 ph_r_moon = phase_rayleigh(nu_moon);
                float  ph_m_moon = phase_hg(nu_moon, MIE_G);

                // --- Ray march single scattering ---
                // Ref: This follows the integration structure from Bruneton 2020,
                // similar to Photon's LUT precomputation in AtmosphereLUT.compute
                // but done per-pixel in real time.
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

                    // Extinction along view ray
                    float3 ext = BETA_R * dens.x + BETA_M * dens.y + BETA_OZ * dens.z;
                    od_view += ext * dt;
                    float3 T_view = exp(-od_view);

                    // Sun in-scattering
                    float mu_s_sun = (R_PLANET * sun_dir.y + t * nu_sun) / r_s;
                    float3 T_sun = atmo_transmittance(mu_s_sun, r_s);
                    float3 w_sun = T_view * T_sun * dt;
                    scatter_sun += (BETA_R * dens.x * ph_r_sun + MIE_ALB * BETA_M * dens.y * ph_m_sun) * w_sun;

                    // Moon in-scattering
                    float mu_s_moon = (R_PLANET * moon_dir.y + t * nu_moon) / r_s;
                    float3 T_moon = atmo_transmittance(mu_s_moon, r_s);
                    float3 w_moon = T_view * T_moon * dt;
                    scatter_moon += (BETA_R * dens.x * ph_r_moon + MIE_ALB * BETA_M * dens.y * ph_m_moon) * w_moon;
                }

                // sky.glsl:169 — atmosphere_scattering(ray_dir, sun_color, sun_dir, moon_color, moon_dir)
                float3 sky = scatter_sun * sun_irr + scatter_moon * moon_irr;

                // View transmittance for celestial objects
                float3 T_final = exp(-od_view);

                // --- Sun disk ---
                // Ref: sky.glsl:107-128 — draw_sky() adds sun/moon/stars then attenuates
                sky += draw_sun(rd, sun_dir, sun_irr) * T_final;

                // --- Stars ---
                // Ref: sky.glsl:118-119 — stars drawn during PROGRAM_DEFERRED3
                float night = smoothstep(0.0, -0.15, sun_dir.y);
                sky += draw_stars(rd) * T_final * night;

                // --- Clouds ---
                // Ref: sky.glsl:154-158 — clouds composited after atmosphere, before rain
                float cloud_dither = frac(52.9829189 * frac(0.06711056 * i.pos.x + 0.00583715 * i.pos.y));
                float3 sky_col_for_clouds = sky * 0.15; // approximate ambient sky color for cloud lighting
                float4 clouds = draw_clouds(rd, sky, sun_dir, moon_dir, sun_irr, sky_col_for_clouds, cloud_dither);
                sky *= clouds.a;     // transmittance — sky behind clouds is attenuated
                sky += clouds.rgb;   // scattering — cloud color added

                // --- Rain sky ---
                // Ref: sky.glsl:149-150 — weather_color blend
                // Ref: photon/shaders/include/light/colors/weather_color.glsl:6-18
                if (_RainStrength > 0.001) {
                    float3 rain_sky = _WeatherColor * (1.0 - exp2(-0.8 / max(rd.y, 0.001)));
                    sky = lerp(sky, rain_sky, _RainStrength * lerp(1.0, 0.9, _TimeSunrise + _TimeSunset));
                }

                // --- Ground fade ---
                // Ref: sky.glsl:162-163 — underground_sky_fade
                float gf = smoothstep(0.0, -0.1, rd.y);
                sky = lerp(sky, sky * 0.015, gf);

                // --- Cave fade ---
                // Ref: sky.glsl:162 — biome_cave * smoothstep
                sky = lerp(sky, float3(0,0,0), _BiomeCave * smoothstep(-0.1, 0.1, 0.4 - rd.y));

                // --- OUTPUT ---
                // Ref: photon/shaders/program/post/grade.glsl:310-344
                // Photon applies bloom in HDR space BEFORE tonemapping.
                // When PhotonBloomFeature is active, it handles tonemap in its composite pass.
                // We always tonemap here as well — bloom will work on the LDR but with
                // a low threshold to still catch the bright sun area.
                sky = tonemap(sky);
                return float4(max(sky, 0.0), 1.0);
            }

            ENDHLSL
        }
    }
}
