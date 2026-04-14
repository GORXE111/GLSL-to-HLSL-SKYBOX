Shader "Photon/Skybox"
{
    Properties
    {
        [Header(Atmosphere)]
        _SunAngularRadius ("Sun Angular Radius", Range(0.1, 4.0)) = 2.0
        _MoonAngularRadius ("Moon Angular Radius", Range(0.1, 4.0)) = 2.5

        [Header(Stars)]
        _StarsIntensity ("Stars Intensity", Range(0, 5)) = 1.0
        _StarsCoverage ("Stars Coverage", Range(0, 5)) = 1.0

        [Header(Exposure)]
        _SunIntensity ("Sun Intensity", Range(0.1, 10)) = 1.0
        _MoonIntensity ("Moon Intensity", Range(0.1, 5)) = 0.66
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

            #include "Include/Common.hlsl"
            #include "Include/FastMath.hlsl"
            #include "Include/ColorSpace.hlsl"
            #include "Include/Geometry.hlsl"
            #include "Include/PhaseFunction.hlsl"
            #include "Include/Random.hlsl"
            #include "Include/Dithering.hlsl"
            #include "Include/Atmosphere.hlsl"
            #include "Include/ACES.hlsl"

            // --- Textures ---
            TEXTURE2D(_TransmittanceLUT);
            SAMPLER(sampler_TransmittanceLUT);
            TEXTURE3D(_ScatteringLUT);
            SAMPLER(sampler_ScatteringLUT);

            // --- Uniforms from PhotonSkyManager ---
            float3 _SunDir;
            float3 _MoonDir;
            float3 _SunColor;    // exposure * tint * sunlight_color * transmittance
            float3 _MoonColor;
            float  _SunAngle;    // 0-1 day cycle
            float  _RainStrength;
            float  _FrameTime;
            int    _FrameCounter;
            float  _TimeOfDay;   // 0-24
            float3 _WeatherColor;
            float  _BiomeCave;
            float  _TimeSunrise;
            float  _TimeSunset;
            float3 _AmbientColor;
            float3 _SkyColorTint;

            // From properties
            float _SunAngularRadius;
            float _MoonAngularRadius;
            float _StarsIntensity;
            float _StarsCoverage;
            float _SunIntensity;
            float _MoonIntensity;

            // Star rotation matrix (from C#)
            float4x4 _StarRotationMatrix;

            // Cloud includes (after all uniforms declared)
            #include "Include/Clouds.hlsl"

            struct Attributes
            {
                float4 positionOS : POSITION;
            };

            struct Varyings
            {
                float4 positionCS : SV_POSITION;
                float3 viewDirWS : TEXCOORD0;
            };

            Varyings vert(Attributes input)
            {
                Varyings output;
                output.positionCS = TransformObjectToHClip(input.positionOS.xyz);
                output.viewDirWS = TransformObjectToWorld(input.positionOS.xyz);
                return output;
            }

            // -------------------------------------------------------
            //  Analytic single-scattering (no LUT needed)
            // -------------------------------------------------------
            float3 analytic_sky_scatter(float3 ray_dir, float3 sun_dir, float3 sun_col, float3 moon_dir, float3 moon_col, float3 view_transmittance)
            {
                // Simple analytic atmosphere: integrate scattering along view ray
                const int STEPS = 16;
                float mu = ray_dir.y;

                // Clamp to above horizon
                mu = max(mu, -0.01);
                float3 adjusted_ray = float3(ray_dir.x, mu, ray_dir.z);
                adjusted_ray = normalize(adjusted_ray);

                // Ray from ground level through atmosphere
                float r_start = planet_radius;
                float t_max = intersect_sphere(mu, r_start, atmosphere_outer_radius).y;
                if (t_max <= 0.0) return float3(0, 0, 0);

                float dt = t_max / (float)STEPS;

                float3 rayleigh_coeff = air_rayleigh_coefficient;
                float3 mie_coeff_scat = air_mie_albedo * air_mie_coefficient;

                float nu_sun = dot(adjusted_ray, sun_dir);
                float nu_moon = dot(adjusted_ray, moon_dir);

                float3 rayleigh_phase_val = rayleigh_phase(nu_sun);
                float mie_phase_sun = henyey_greenstein_phase(nu_sun, air_mie_g);
                float mie_phase_moon = henyey_greenstein_phase(nu_moon, air_mie_g);

                float3 scatter_sun = float3(0, 0, 0);
                float3 scatter_moon = float3(0, 0, 0);
                float3 optical_depth = float3(0, 0, 0);

                for (int i = 0; i < STEPS; i++)
                {
                    float t = (i + 0.5) * dt;
                    float r_sample = sqrt(r_start * r_start + 2.0 * r_start * mu * t + t * t);

                    // Density at sample
                    float3 density = atmosphere_density(r_sample);
                    float3 extinction = rayleigh_coeff * density.x + air_mie_coefficient * density.y + air_ozone_coefficient * density.z;
                    optical_depth += extinction * dt;

                    float3 trans_to_sample = exp(-optical_depth);

                    // Transmittance from sample to sun (analytic)
                    float mu_s_sun = (r_start * sun_dir.y + t * nu_sun) / r_sample;
                    float3 trans_to_sun = atmosphere_transmittance_analytic(mu_s_sun, r_sample);

                    // Transmittance from sample to moon
                    float mu_s_moon = (r_start * moon_dir.y + t * nu_moon) / r_sample;
                    float3 trans_to_moon = atmosphere_transmittance_analytic(mu_s_moon, r_sample);

                    float3 scatter_weight_sun = trans_to_sample * trans_to_sun * dt;
                    float3 scatter_weight_moon = trans_to_sample * trans_to_moon * dt;

                    // Rayleigh + Mie scattering
                    scatter_sun += (rayleigh_coeff * density.x * rayleigh_phase_val + mie_coeff_scat * density.y * mie_phase_sun) * scatter_weight_sun;
                    scatter_moon += (rayleigh_coeff * density.x * rayleigh_phase(nu_moon) + mie_coeff_scat * density.y * mie_phase_moon) * scatter_weight_moon;
                }

                return scatter_sun * sun_col + scatter_moon * moon_col;
            }

            // -------------------------------------------------------
            //  Sample transmittance LUT
            // -------------------------------------------------------
            float3 sample_transmittance_lut(float mu, float r)
            {
                if (intersect_sphere(mu, r, planet_radius).x >= 0.0) return float3(0,0,0);
                float2 uv = atmosphere_transmittance_uv(mu, r);
                return SAMPLE_TEXTURE2D_LOD(_TransmittanceLUT, sampler_TransmittanceLUT, uv, 0).rgb;
            }

            float3 sample_transmittance_lut_dir(float3 ray_origin, float3 ray_dir)
            {
                float r_sq = dot(ray_origin, ray_origin);
                float rcp_r = rsqrt(r_sq);
                float mu = dot(ray_origin, ray_dir) * rcp_r;
                float r = r_sq * rcp_r;
                return sample_transmittance_lut(mu, r);
            }

            // -------------------------------------------------------
            //  Sample scattering LUT (sun + moon combined)
            // -------------------------------------------------------
            float3 sample_atmosphere_scattering(float3 ray_dir, float3 sun_color, float3 sun_dir, float3 moon_color, float3 moon_dir)
            {
                float mu = ray_dir.y;

                float nu_sun  = dot(ray_dir, sun_dir);
                float nu_moon = dot(ray_dir, moon_dir);
                float mu_sun  = sun_dir.y;
                float mu_moon = moon_dir.y;

                // Clamp mu to prevent looking below ground
                float horizon_mu = lerp(-0.01, 0.03, saturate(smoothstep(-0.05, 0.1, mu_sun) + smoothstep(0.05, 0.1, mu_moon)));
                mu = max(mu, horizon_mu);

                // Compute UVs for sun
                float3 uv_sun = atmosphere_scattering_uv(nu_sun, mu, mu_sun);
                // Compute UVs for moon
                float3 uv_moon = atmosphere_scattering_uv(nu_moon, mu, mu_moon);

                // Sample Rayleigh + multi (left half: u_nu * 0.5)
                // Sample Mie (right half: u_nu * 0.5 + 0.5)
                float3 uv_sc = float3(uv_sun.x  * 0.5,       uv_sun.y,  uv_sun.z);
                float3 uv_sm = float3(uv_sun.x  * 0.5 + 0.5, uv_sun.y,  uv_sun.z);
                float3 uv_mc = float3(uv_moon.x * 0.5,       uv_moon.y, uv_moon.z);
                float3 uv_mm = float3(uv_moon.x * 0.5 + 0.5, uv_moon.y, uv_moon.z);

                float3 scat_sc = SAMPLE_TEXTURE3D_LOD(_ScatteringLUT, sampler_ScatteringLUT, uv_sc, 0).rgb;
                float3 scat_sm = SAMPLE_TEXTURE3D_LOD(_ScatteringLUT, sampler_ScatteringLUT, uv_sm, 0).rgb;
                float3 scat_mc = SAMPLE_TEXTURE3D_LOD(_ScatteringLUT, sampler_ScatteringLUT, uv_mc, 0).rgb;
                float3 scat_mm = SAMPLE_TEXTURE3D_LOD(_ScatteringLUT, sampler_ScatteringLUT, uv_mm, 0).rgb;

                float mie_phase_sun  = henyey_greenstein_phase(nu_sun,  air_mie_g);
                float mie_phase_moon = henyey_greenstein_phase(nu_moon, air_mie_g);

                return (scat_sc + scat_sm * mie_phase_sun)  * sun_color
                     + (scat_mc + scat_mm * mie_phase_moon) * moon_color;
            }

            // -------------------------------------------------------
            //  Draw sun disk with limb darkening
            // -------------------------------------------------------
            float3 draw_sun(float3 ray_dir)
            {
                float nu = dot(ray_dir, _SunDir);
                float angular_radius = _SunAngularRadius * DEGREE;

                const float3 alpha = float3(0.429, 0.522, 0.614);
                float center_to_edge = max0(angular_radius - fast_acos(nu));
                float3 limb_darkening = pow(max(float3(1.0, 1.0, 1.0) - sqr(1.0 - center_to_edge), 0.0), 0.5 * alpha);

                const float sun_luminance = 40.0;
                return sun_luminance * _SunColor * step(0.0, center_to_edge) * limb_darkening;
            }

            // -------------------------------------------------------
            //  Draw star field
            // -------------------------------------------------------
            float3 unstable_star_field(float2 coord, float star_threshold)
            {
                const float min_temp = 3500.0;
                const float max_temp = 9500.0;

                float4 noise = hash4(coord);

                float star = linear_step(star_threshold, 1.0, noise.x);
                star = pow4(star) * _StarsIntensity;

                float temp = lerp(min_temp, max_temp, noise.y);
                float3 color = blackbody(temp);

                const float twinkle_speed = 2.0;
                float twinkle_amount = noise.z;
                float twinkle_offset = TAU * noise.w;
                star *= 1.0 - twinkle_amount * cos(_FrameTime * twinkle_speed + twinkle_offset);

                return star * color;
            }

            float3 stable_star_field(float2 coord, float star_threshold)
            {
                coord = abs(coord) + 33.3 * step(0.0, coord);
                float2 i_part;
                float2 f = modf(coord, i_part);

                f.x = cubic_smooth(f.x);
                f.y = cubic_smooth(f.y);

                return unstable_star_field(i_part + float2(0.0, 0.0), star_threshold) * (1.0 - f.x) * (1.0 - f.y)
                     + unstable_star_field(i_part + float2(1.0, 0.0), star_threshold) * f.x * (1.0 - f.y)
                     + unstable_star_field(i_part + float2(0.0, 1.0), star_threshold) * f.y * (1.0 - f.x)
                     + unstable_star_field(i_part + float2(1.0, 1.0), star_threshold) * f.x * f.y;
            }

            float3 draw_stars(float3 ray_dir)
            {
                // Rotate stars with celestial sphere
                ray_dir = mul((float3x3)_StarRotationMatrix, ray_dir);

                float star_threshold = 1.0 - 0.008 * _StarsCoverage * smoothstep(-0.2, 0.05, -_SunDir.y);

                float2 coord = ray_dir.xy * rcp(abs(ray_dir.z) + length(ray_dir.xy)) + 41.21 * sign(ray_dir.z);
                coord *= 600.0;

                return stable_star_field(coord, star_threshold);
            }

            // -------------------------------------------------------
            //  Main sky rendering
            // -------------------------------------------------------
            float3 draw_sky(float3 ray_dir, Varyings input)
            {
                float3 atmosphere = sample_atmosphere_scattering(ray_dir, _SunColor, _SunDir, _MoonColor, _MoonDir);

                float3 sky = float3(0,0,0);

                // Stars
                sky += draw_stars(ray_dir);

                // Sun disk
                sky += draw_sun(ray_dir);

                // Apply atmospheric transmittance to sun/stars
                sky *= sample_transmittance_lut(ray_dir.y, planet_radius) * (1.0 - _RainStrength);

                // Add atmospheric scattering
                sky += atmosphere;

                // Rain sky
                float3 rain_sky = _WeatherColor * (1.0 - exp2(-0.8 / clamp01(ray_dir.y)));
                sky = lerp(sky, rain_sky, _RainStrength * lerp(1.0, 0.9, _TimeSunrise + _TimeSunset));

                // Clouds
                float cloud_dither = interleaved_gradient_noise(input.positionCS.xy);
                float4 clouds = draw_clouds(
                    ray_dir, sky, cloud_dither,
                    _SunDir, _MoonDir, _SunColor, _MoonColor,
                    _SkyColorTint, _AmbientColor,
                    _RainStrength, _TimeSunrise, _TimeSunset
                );
                sky *= clouds.a;     // transmittance
                sky += clouds.rgb;   // scattering

                // Cave fade
                float underground_sky_fade = _BiomeCave * smoothstep(-0.1, 0.1, 0.4 - ray_dir.y);
                sky = lerp(sky, float3(0,0,0), underground_sky_fade);

                return sky;
            }

            float4 frag(Varyings input) : SV_Target
            {
                float3 ray_dir = normalize(input.viewDirWS);

                // =========================================================
                // Analytic sky (no LUT dependency) for initial bring-up
                // =========================================================

                // =========================================================
                // MINIMAL atmosphere — no color space transforms, no ACES
                // Pure Rec.709 / sRGB, Reinhard tonemap
                // This isolates whether the scattering physics works
                // =========================================================

                // Raw Rayleigh/Mie coefficients in Rec.709 (skip Rec.2020 transform)
                const float3 rayleigh_coeff = float3(8.059e-06, 1.671e-05, 4.080e-05);
                const float3 mie_coeff      = float3(1.666e-06, 1.813e-06, 1.959e-06);
                const float3 ozone_coeff    = float3(8.304e-07, 1.315e-06, 5.441e-08);
                const float mie_g = 0.77;
                const float mie_albedo = 0.9;

                // Sun light: just a white light with exposure, attenuated by transmittance
                float sun_exposure = 0.1;
                float3 sun_transmit = atmosphere_transmittance_analytic(_SunDir.y, planet_radius);
                float3 sun_light = sun_exposure * float3(1.051, 0.985, 0.940) * sun_transmit;

                // Fade sun below horizon
                sun_light *= saturate(_SunDir.y * 50.0);

                // View ray transmittance
                float3 view_transmit = atmosphere_transmittance_analytic(max(ray_dir.y, -0.01), planet_radius);

                // --- Inline ray march (16 steps) ---
                float mu = max(ray_dir.y, 0.001);
                float t_max = intersect_sphere(mu, planet_radius, atmosphere_outer_radius).y;
                t_max = max(t_max, 0.0);

                const int STEPS = 24;
                float dt = t_max / (float)STEPS;

                float nu = dot(ray_dir, _SunDir);

                // Phase functions
                float3 ray_phase = rayleigh_phase(nu);
                float mie_phase_val = henyey_greenstein_phase(nu, mie_g);

                float3 scatter = float3(0, 0, 0);
                float3 od = float3(0, 0, 0);

                for (int i = 0; i < STEPS; i++)
                {
                    float t = (i + 0.5) * dt;
                    float r_s = sqrt(planet_radius * planet_radius + 2.0 * planet_radius * mu * t + t * t);

                    float3 dens = atmosphere_density(r_s);
                    float3 ext = rayleigh_coeff * dens.x + mie_coeff * dens.y + ozone_coeff * dens.z;
                    od += ext * dt;
                    float3 trans = exp(-od);

                    // Transmittance from sample to sun
                    float mu_s = (planet_radius * _SunDir.y + t * nu) / r_s;
                    float3 trans_sun = atmosphere_transmittance_analytic(mu_s, r_s);

                    float3 scat_weight = trans * trans_sun * dt;
                    scatter += (rayleigh_coeff * dens.x * ray_phase + mie_albedo * mie_coeff * dens.y * mie_phase_val) * scat_weight;
                }

                float3 sky_color = scatter * sun_light;

                // Sun disk
                float sun_nu = dot(ray_dir, _SunDir);
                float sun_ang = _SunAngularRadius * DEGREE;
                float sun_edge = max0(sun_ang - fast_acos(sun_nu));
                float sun_disk = step(0.0, sun_edge) * 40.0;
                sky_color += sun_disk * sun_light * view_transmit;

                // Stars
                float night = saturate(-_SunDir.y * 5.0);
                sky_color += draw_stars(ray_dir) * view_transmit * night;

                // Ground fade
                float gf = smoothstep(0.0, -0.05, ray_dir.y);
                sky_color = lerp(sky_color, sky_color * 0.02, gf);

                // Simple Reinhard tonemap
                sky_color = sky_color / (1.0 + sky_color);

                return float4(max(sky_color, 0.0), 1.0);
            }

            ENDHLSL
        }
    }
}
