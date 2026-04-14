#ifndef PHOTON_CLOUDS_INCLUDED
#define PHOTON_CLOUDS_INCLUDED

#include "Common.hlsl"
#include "FastMath.hlsl"
#include "Geometry.hlsl"
#include "Random.hlsl"
#include "Dithering.hlsl"
#include "Sampling.hlsl"
#include "CloudCommon.hlsl"

// ============================================================================
//  Three-layer volumetric clouds
//  Ported from Photon shaders: sky/clouds.glsl
//  Layer 1: Cumulus (Cu)    - low altitude, cauliflower-shaped
//  Layer 2: Altocumulus (Ac) - mid altitude, puffy
//  Layer 3: Cirrus (Ci)     - high altitude, feather-like planar
// ============================================================================

// --- Noise textures ---
TEXTURE2D(_NoiseTex);
SAMPLER(sampler_NoiseTex);
TEXTURE3D(_WorleyTex);
SAMPLER(sampler_WorleyTex);
TEXTURE3D(_CurlTex);
SAMPLER(sampler_CurlTex);

// --- Cloud uniforms (set by PhotonSkyManager) ---
float  _CloudsEnabled;

// Cumulus
float  _CloudsCuEnabled;
float2 _CloudsCuCoverage;   // (min, max)
float  _CloudsCuAltitude;
float  _CloudsCuThickness;
float  _CloudsCuDensity;

// Altocumulus
float  _CloudsAcEnabled;
float2 _CloudsAcCoverage;
float  _CloudsAcAltitude;
float  _CloudsAcThickness;

// Cirrus
float  _CloudsCiEnabled;
float2 _CloudsCiCoverage;
float  _CloudsCiAltitude;
float  _CloudsCiThickness;

// Shared
float  _WorldAge;
float3 _CameraPosition;
float  _EyeAltitude;

// Light info (already declared in skybox but re-declared for standalone use)
// These come from the skybox shader's existing uniforms

// ============================================================================
//  Layer 1: Cumulus Clouds
// ============================================================================

float clouds_cu_radius()     { return planet_radius + _CloudsCuAltitude; }
float clouds_cu_thickness()  { return _CloudsCuAltitude * _CloudsCuThickness; }
float clouds_cu_top_radius() { return clouds_cu_radius() + clouds_cu_thickness(); }

float clouds_cu_extinction_coeff(float sun_y, float rain) {
    return lerp(0.05, 0.1, smoothstep(0.0, 0.3, abs(sun_y))) * (1.0 - 0.33 * rain) * _CloudsCuDensity;
}

float altitude_shaping_cu(float density, float altitude_fraction) {
    density -= smoothstep(0.2, 1.0, altitude_fraction) * 0.6;
    density *= smoothstep(0.0, 0.2, altitude_fraction);
    return density;
}

float clouds_density_cu(float3 pos, float3 sun_dir_val) {
    float cu_radius = clouds_cu_radius();
    float cu_top = clouds_cu_top_radius();
    float cu_thick = clouds_cu_thickness();

    float r = length(pos);
    if (r < cu_radius || r > cu_top) return 0.0;

    float dynamic_thickness = lerp(0.5, 1.0, smoothstep(0.4, 0.6, _CloudsCuCoverage.y));
    float altitude_fraction = 0.8 * (r - cu_radius) / (cu_thick * dynamic_thickness);

    const float wind_angle = 30.0 * DEGREE;
    const float2 wind_velocity = 15.0 * float2(cos(wind_angle), sin(wind_angle));

    float3 sample_pos = pos;
    sample_pos.xz += _CameraPosition.xz + wind_velocity * _WorldAge;

    // 2D noise for base shape and coverage
    float2 noise;
    noise.x = SAMPLE_TEXTURE2D_LOD(_NoiseTex, sampler_NoiseTex, 0.000002 * sample_pos.xz, 0).x;
    noise.y = SAMPLE_TEXTURE2D_LOD(_NoiseTex, sampler_NoiseTex, 0.000027 * sample_pos.xz, 0).w;

    float density = lerp(_CloudsCuCoverage.x, _CloudsCuCoverage.y, noise.x);
    density = linear_step(1.0 - density, 1.0, noise.y);
    density = altitude_shaping_cu(density, altitude_fraction);

    if (density < EPS) return 0.0;

    // 3D Worley noise for detail (curl + worley)
    float3 curl = 0.181 * SAMPLE_TEXTURE3D_LOD(_CurlTex, sampler_CurlTex, 0.002 * pos, 0).xyz
                * smoothstep(0.4, 1.0, 1.0 - altitude_fraction);
    // Remap curl from 0-1 to -0.5..0.5
    curl = curl * 2.0 - 1.0;

    float2 wind_xz = wind_velocity * _WorldAge; float3 wind = float3(wind_xz.x, 0.0, wind_xz.y);

    float worley_0 = SAMPLE_TEXTURE3D_LOD(_WorleyTex, sampler_WorleyTex, (pos + 0.2 * wind) * 0.001 + curl * 1.0, 0).x;
    float worley_1 = SAMPLE_TEXTURE3D_LOD(_WorleyTex, sampler_WorleyTex, (pos + 0.4 * wind) * 0.005 + curl * 3.0, 0).x;

    float detail_fade = 0.20 * smoothstep(0.85, 1.0, 1.0 - altitude_fraction)
                      - 0.35 * smoothstep(0.05, 0.5, altitude_fraction) + 0.6;

    density -= 0.33 * sqr(worley_0) * dampen(clamp01(1.0 - density));
    density -= 0.40 * sqr(worley_1) * dampen(clamp01(1.0 - density)) * detail_fade;

    density = max0(density);
    density = 1.0 - pow(max(1.0 - density, 0.0), lerp(3.0, 8.0, altitude_fraction));
    density *= 0.1 + 0.9 * smoothstep(0.2, 0.7, altitude_fraction);

    return density;
}

float clouds_optical_depth_cu(float3 ray_origin, float3 ray_dir, float dither, float3 sun_dir_val, int step_count) {
    const float step_growth = 2.0;
    float step_length = 0.1 * clouds_cu_thickness() / (float)step_count;

    float3 ray_pos = ray_origin;
    float4 ray_step = float4(ray_dir, 1.0) * step_length;

    float optical_depth = 0.0;

    for (int i = 0; i < step_count; i++) {
        ray_step *= step_growth;
        ray_pos += ray_step.xyz;
        optical_depth += clouds_density_cu(ray_pos + ray_step.xyz * dither, sun_dir_val) * ray_step.w;
    }

    return optical_depth;
}

float4 draw_clouds_cu(
    float3 ray_dir, float3 clear_sky, float dither,
    float3 sun_dir_val, float3 moon_dir_val,
    float3 sun_color_val, float3 moon_color_val,
    float3 sky_color_val, float3 ambient_color_val,
    float rain_strength, float time_sunrise, float time_sunset
) {
    if (_CloudsCuEnabled < 0.5) return float4(0, 0, 0, 1);

    const int primary_steps_h = 20;
    const int primary_steps_z = 10;
    const int lighting_steps  = 6;
    const int ambient_steps   = 2;
    const float max_ray_length = 2e4;
    const float min_transmittance = 0.075;
    const float planet_albedo = 0.4;
    const float3 sky_dir = float3(0, 1, 0);

    int primary_steps = (int)lerp((float)primary_steps_h, (float)primary_steps_z, abs(ray_dir.y));

    float3 air_viewer_pos = float3(0.0, planet_radius + _EyeAltitude, 0.0);
    float cu_radius = clouds_cu_radius();
    float cu_top = clouds_cu_top_radius();

    float2 dists = intersect_spherical_shell(air_viewer_pos, ray_dir, cu_radius, cu_top);
    bool planet_hit = intersect_sphere_vec(air_viewer_pos, ray_dir, min(length(air_viewer_pos) - 10.0, planet_radius)).y >= 0.0;

    if (dists.y < 0.0 || (planet_hit && length(air_viewer_pos) < cu_radius))
        return float4(0, 0, 0, 1);

    float ray_length = min(dists.y - dists.x, max_ray_length);
    float step_length = ray_length / (float)primary_steps;
    float3 ray_step = ray_dir * step_length;
    float3 ray_origin = air_viewer_pos + ray_dir * (dists.x + step_length * dither);

    float2 scattering = float2(0, 0);
    float transmittance = 1.0;

    bool moonlit = sun_dir_val.y < -0.04;
    float3 light_dir = moonlit ? moon_dir_val : sun_dir_val;
    float cos_theta = dot(ray_dir, light_dir);
    float bounced_light = planet_albedo * light_dir.y * RCP_PI;

    float ext_coeff = clouds_cu_extinction_coeff(sun_dir_val.y, rain_strength);
    float scat_coeff = ext_coeff * lerp(1.0, 0.66, rain_strength);

    for (int i = 0; i < primary_steps; i++) {
        if (transmittance < min_transmittance) break;

        float3 ray_pos = ray_origin + ray_step * i;
        float altitude_fraction = (length(ray_pos) - cu_radius) / clouds_cu_thickness();

        float density = clouds_density_cu(ray_pos, sun_dir_val);
        if (density < EPS) continue;

        float distance_to_sample = distance(ray_origin, ray_pos);
        float distance_fade = smoothstep(0.95, 1.0, distance_to_sample / max_ray_length);
        density *= 1.0 - distance_fade;

        float step_optical_depth = density * ext_coeff * step_length;
        float step_transmittance = exp(-step_optical_depth);

        float2 h = hash2(frac(ray_pos).xy);

        float light_od = clouds_optical_depth_cu(ray_pos, light_dir, h.x, sun_dir_val, lighting_steps);
        float sky_od = clouds_optical_depth_cu(ray_pos, sky_dir, h.y, sun_dir_val, ambient_steps);
        float ground_od = lerp(density, 1.0, clamp01(altitude_fraction * 2.0 - 1.0)) * altitude_fraction * clouds_cu_thickness();

        scattering += clouds_scattering_generic(
            density, light_od, sky_od, ground_od,
            step_transmittance, cos_theta, bounced_light,
            scat_coeff, ext_coeff, 8
        ) * transmittance;

        transmittance *= step_transmittance;
    }

    // Light color
    float3 light_color = moonlit ? moon_color_val : sun_color_val;
    light_color *= sunlight_color;
    light_color *= atmosphere_transmittance_analytic(
        dot(normalize(ray_origin), light_dir), length(ray_origin));
    light_color *= 1.0 - rain_strength;

    float clouds_trans = linear_step(min_transmittance, 1.0, transmittance);
    float3 clouds_scat = scattering.x * light_color + scattering.y * sky_color_val;

    clouds_scat = clouds_aerial_perspective(
        clouds_scat, clouds_trans, air_viewer_pos, ray_origin, ray_dir, clear_sky,
        rain_strength, sky_color_val, time_sunrise, time_sunset);

    return float4(clouds_scat, clouds_trans);
}

// ============================================================================
//  Layer 2: Altocumulus Clouds (simplified - same structure, different params)
// ============================================================================

float clouds_ac_radius()     { return planet_radius + _CloudsAcAltitude; }
float clouds_ac_thickness()  { return _CloudsAcAltitude * _CloudsAcThickness; }
float clouds_ac_top_radius() { return clouds_ac_radius() + clouds_ac_thickness(); }

float clouds_density_ac(float3 pos, float3 sun_dir_val) {
    float ac_radius = clouds_ac_radius();
    float ac_top = clouds_ac_top_radius();
    float ac_thick = clouds_ac_thickness();

    float r = length(pos);
    if (r < ac_radius || r > ac_top) return 0.0;

    float dynamic_thickness = lerp(0.5, 1.0, smoothstep(0.4, 0.6, _CloudsAcCoverage.y));
    float altitude_fraction = 0.8 * (r - ac_radius) / (ac_thick * dynamic_thickness);

    const float wind_angle = 60.0 * DEGREE;
    const float2 wind_velocity = 10.0 * float2(cos(wind_angle), sin(wind_angle));

    float3 sample_pos = pos;
    sample_pos.xz += _CameraPosition.xz + wind_velocity * _WorldAge;

    float2 noise;
    noise.x = SAMPLE_TEXTURE2D_LOD(_NoiseTex, sampler_NoiseTex, 0.000005 * sample_pos.xz, 0).x;
    noise.y = SAMPLE_TEXTURE2D_LOD(_NoiseTex, sampler_NoiseTex, 0.000047 * sample_pos.xz + 0.3, 0).w;

    float density = lerp(_CloudsAcCoverage.x, _CloudsAcCoverage.y, cubic_smooth(noise.x));
    density = linear_step(1.0 - density, 1.0, noise.y);

    // Altitude shaping (same as Cu)
    density -= smoothstep(0.2, 1.0, altitude_fraction) * 0.6;
    density *= smoothstep(0.0, 0.2, altitude_fraction);

    if (density < EPS) return 0.0;

    // Detail
    float3 curl = 0.181 * SAMPLE_TEXTURE3D_LOD(_CurlTex, sampler_CurlTex, 0.002 * pos, 0).xyz
                * smoothstep(0.4, 1.0, 1.0 - altitude_fraction);
    curl = curl * 2.0 - 1.0;

    float2 wind_xz = wind_velocity * _WorldAge; float3 wind = float3(wind_xz.x, 0.0, wind_xz.y);
    float worley = SAMPLE_TEXTURE3D_LOD(_WorleyTex, sampler_WorleyTex, (pos + 0.2 * wind) * 0.001 + curl, 0).x;

    density -= 0.44 * sqr(worley) * dampen(clamp01(1.0 - density));

    density = max0(density);
    density = 1.0 - pow(max(1.0 - density, 0.0), lerp(3.0, 8.0, altitude_fraction));
    density *= 0.1 + 0.9 * smoothstep(0.2, 0.7, altitude_fraction);

    return density;
}

float clouds_optical_depth_ac(float3 ray_origin, float3 ray_dir, float dither, float3 sun_dir_val, int step_count) {
    const float step_growth = 2.0;
    float step_length = 0.15 * clouds_ac_thickness() / (float)step_count;

    float3 ray_pos = ray_origin;
    float4 ray_step = float4(ray_dir, 1.0) * step_length;
    float optical_depth = 0.0;

    for (int i = 0; i < step_count; i++) {
        ray_step *= step_growth;
        ray_pos += ray_step.xyz;
        optical_depth += clouds_density_ac(ray_pos + ray_step.xyz * dither, sun_dir_val) * ray_step.w;
    }

    return optical_depth;
}

float4 draw_clouds_ac(
    float3 ray_dir, float3 clear_sky, float dither,
    float3 sun_dir_val, float3 moon_dir_val,
    float3 sun_color_val, float3 moon_color_val,
    float3 sky_color_val, float3 ambient_color_val,
    float rain_strength, float time_sunrise, float time_sunset
) {
    if (_CloudsAcEnabled < 0.5) return float4(0, 0, 0, 1);

    const int primary_steps_h = 6;
    const int primary_steps_z = 3;
    const int lighting_steps  = 4;
    const int ambient_steps   = 2;
    const float max_ray_length = 2e4;
    const float min_transmittance = 0.075;
    const float planet_albedo = 0.4;
    const float3 sky_dir = float3(0, 1, 0);

    int primary_steps = (int)lerp((float)primary_steps_h, (float)primary_steps_z, abs(ray_dir.y));

    float3 air_viewer_pos = float3(0.0, planet_radius + _EyeAltitude, 0.0);
    float ac_radius = clouds_ac_radius();
    float ac_top = clouds_ac_top_radius();

    float day_factor = smoothstep(0.0, 0.3, abs(sun_dir_val.y));
    float ext_coeff = lerp(0.05, 0.1, day_factor) * 0.1 * (1.0 - 0.33 * rain_strength);
    float scat_coeff = ext_coeff * lerp(1.0, 0.66, rain_strength);

    float2 dists = intersect_spherical_shell(air_viewer_pos, ray_dir, ac_radius, ac_top);
    bool planet_hit = intersect_sphere_vec(air_viewer_pos, ray_dir, min(length(air_viewer_pos) - 10.0, planet_radius)).y >= 0.0;

    if (dists.y < 0.0 || (planet_hit && length(air_viewer_pos) < ac_radius))
        return float4(0, 0, 0, 1);

    float ray_length = min(dists.y - dists.x, max_ray_length);
    float step_length = ray_length / (float)primary_steps;
    float3 ray_step = ray_dir * step_length;
    float3 ray_origin = air_viewer_pos + ray_dir * (dists.x + step_length * dither);

    float2 scattering = float2(0, 0);
    float transmittance = 1.0;

    bool moonlit = sun_dir_val.y < -0.045;
    float3 light_dir = moonlit ? moon_dir_val : sun_dir_val;
    float cos_theta = dot(ray_dir, light_dir);
    float bounced_light = planet_albedo * light_dir.y * RCP_PI;

    for (int i = 0; i < primary_steps; i++) {
        if (transmittance < min_transmittance) break;

        float3 ray_pos = ray_origin + ray_step * i;
        float density = clouds_density_ac(ray_pos, sun_dir_val);
        if (density < EPS) continue;

        float distance_to_sample = distance(ray_origin, ray_pos);
        density *= 1.0 - smoothstep(0.95, 1.0, distance_to_sample / max_ray_length);

        float step_optical_depth = density * ext_coeff * step_length;
        float step_transmittance = exp(-step_optical_depth);

        float2 h = hash2(frac(ray_pos).xy);
        float altitude_fraction = (length(ray_pos) - ac_radius) / clouds_ac_thickness();

        float light_od = clouds_optical_depth_ac(ray_pos, light_dir, h.x, sun_dir_val, lighting_steps);
        float sky_od = clouds_optical_depth_ac(ray_pos, sky_dir, h.y, sun_dir_val, ambient_steps);
        float ground_od = lerp(density, 1.0, clamp01(altitude_fraction * 2.0 - 1.0)) * altitude_fraction * clouds_ac_thickness();

        scattering += clouds_scattering_generic(
            density, light_od, sky_od, ground_od,
            step_transmittance, cos_theta, bounced_light,
            scat_coeff, ext_coeff, 8
        ) * transmittance;

        transmittance *= step_transmittance;
    }

    float3 light_color = moonlit ? moon_color_val : sun_color_val;
    light_color *= sunlight_color;
    light_color *= atmosphere_transmittance_analytic(
        dot(normalize(ray_origin), light_dir), length(ray_origin));
    light_color *= 1.0 - rain_strength;

    float clouds_trans = linear_step(min_transmittance, 1.0, transmittance);
    float3 clouds_scat = scattering.x * light_color + scattering.y * sky_color_val;

    clouds_scat = clouds_aerial_perspective(
        clouds_scat, clouds_trans, air_viewer_pos, ray_origin, ray_dir, clear_sky,
        rain_strength, sky_color_val, time_sunrise, time_sunset);

    return float4(clouds_scat, clouds_trans);
}

// ============================================================================
//  Layer 3: Cirrus Clouds (planar, high altitude)
// ============================================================================

float clouds_ci_radius() { return planet_radius + _CloudsCiAltitude; }

float clouds_density_ci(float2 coord, float altitude_fraction) {
    const float wind_angle = 90.0 * DEGREE;
    const float2 wind_velocity = 20.0 * float2(cos(wind_angle), sin(wind_angle));

    coord = coord + _CameraPosition.xz;
    coord = coord + wind_velocity * _WorldAge;

    // Curl distortion
    float2 curl = float2(0, 0);
    float2 c1 = SAMPLE_TEXTURE2D_LOD(_NoiseTex, sampler_NoiseTex, 0.00002 * coord, 0).xy * 2.0 - 1.0;
    float2 c2 = SAMPLE_TEXTURE2D_LOD(_NoiseTex, sampler_NoiseTex, 0.00004 * coord, 0).xy * 2.0 - 1.0;
    float2 c3 = SAMPLE_TEXTURE2D_LOD(_NoiseTex, sampler_NoiseTex, 0.00008 * coord, 0).xy * 2.0 - 1.0;
    curl = c1 * 0.5 + c2 * 0.25 + c3 * 0.125;

    float height_shaping = 1.0 - abs(1.0 - 2.0 * altitude_fraction);

    // Cirrus
    float cirrus = 0.7 * SAMPLE_TEXTURE2D_LOD(_NoiseTex, sampler_NoiseTex, 0.000001 * coord + 0.004 * curl, 0).x
                 + 0.3 * SAMPLE_TEXTURE2D_LOD(_NoiseTex, sampler_NoiseTex, 0.000008 * coord + 0.008 * curl, 0).x;
    cirrus = linear_step(0.7 - _CloudsCiCoverage.x, 1.0, cirrus);

    // Detail erosion
    float detail_amp = 0.2;
    float detail_freq = 0.00002;
    float curl_str = 0.1;

    for (int i = 0; i < 4; i++) {
        float detail = SAMPLE_TEXTURE2D_LOD(_NoiseTex, sampler_NoiseTex, coord * detail_freq + curl * curl_str, 0).x;
        cirrus -= detail * detail_amp;
        detail_amp *= 0.6;
        detail_freq *= 2.0;
        curl_str *= 4.0;
        coord += 0.3 * wind_velocity * _WorldAge;
    }

    float day_factor = smoothstep(0.0, 0.3, abs(_SunDir.y));
    float density = lerp(1.0, 0.75, day_factor) * cube(max0(cirrus)) * sqr(height_shaping) * 0.15;

    // Cirrocumulus
    float cc_coverage = SAMPLE_TEXTURE2D_LOD(_NoiseTex, sampler_NoiseTex, 0.0000026 * coord, 0).w;
    cc_coverage = 5.0 * linear_step(0.3, 0.7, _CloudsCiCoverage.y * cc_coverage);

    float cirrocumulus = dampen(SAMPLE_TEXTURE2D_LOD(_NoiseTex, sampler_NoiseTex, 0.000025 * coord + 0.1 * curl, 0).w);
    cirrocumulus = linear_step(1.0 - cc_coverage, 1.0, cirrocumulus);

    // CC detail
    cirrocumulus -= SAMPLE_TEXTURE2D_LOD(_NoiseTex, sampler_NoiseTex, coord * 0.00005 + 0.1 * curl, 0).y * 0.5;
    cirrocumulus -= SAMPLE_TEXTURE2D_LOD(_NoiseTex, sampler_NoiseTex, coord * 0.00015 + 0.4 * curl, 0).y * 0.125;
    cirrocumulus = max0(cirrocumulus);

    density += 0.2 * cube(max0(cirrocumulus)) * height_shaping * dampen(height_shaping) * 0.15;

    return density;
}

float clouds_optical_depth_ci(float3 ray_origin, float3 ray_dir, float dither) {
    const int step_count = 6;
    const float max_ray_length = 1e3;
    const float step_growth = 1.5;
    const float ci_thickness = _CloudsCiThickness;

    float ci_radius = clouds_ci_radius();

    float2 inner_sphere = intersect_sphere_vec(ray_origin, ray_dir, ci_radius - 0.5 * ci_thickness);
    float2 outer_sphere = intersect_sphere_vec(ray_origin, ray_dir, ci_radius + 0.5 * ci_thickness);
    float ray_length = (inner_sphere.y >= 0.0) ? inner_sphere.x : outer_sphere.y;
    ray_length = min(ray_length, max_ray_length);

    float step_coeff = (step_growth - 1.0) / (pow(step_growth, (float)step_count) - 1.0) / step_growth;
    float step_length = ray_length * step_coeff;

    float3 ray_pos = ray_origin;
    float4 ray_step = float4(ray_dir, 1.0) * step_length;

    float optical_depth = 0.0;

    for (int i = 0; i < step_count; i++) {
        ray_step *= step_growth;
        ray_pos += ray_step.xyz;

        float3 dithered_pos = ray_pos + ray_step.xyz * dither;
        float r = length(dithered_pos);
        float altitude_fraction = (r - ci_radius) / ci_thickness + 0.5;

        float3 sphere_pos = dithered_pos * (ci_radius / r);
        optical_depth += clouds_density_ci(sphere_pos.xz, altitude_fraction) * ray_step.w;
    }

    return optical_depth;
}

float4 draw_clouds_ci(
    float3 ray_dir, float3 clear_sky, float dither,
    float3 sun_dir_val, float3 moon_dir_val,
    float3 sun_color_val, float3 moon_color_val,
    float3 sky_color_val,
    float rain_strength, float time_sunrise, float time_sunset
) {
    if (_CloudsCiEnabled < 0.5) return float4(0, 0, 0, 1);

    float ci_radius = clouds_ci_radius();
    float ci_thickness = _CloudsCiThickness;
    const float ext_coeff = 0.15;
    const float scat_coeff = 0.15;

    float3 air_viewer_pos = float3(0.0, planet_radius + _EyeAltitude, 0.0);
    float r = length(air_viewer_pos);

    float2 dists = intersect_sphere_vec(air_viewer_pos, ray_dir, ci_radius);
    bool planet_hit = intersect_sphere_vec(air_viewer_pos, ray_dir, min(r - 10.0, planet_radius)).y >= 0.0;

    if (dists.y < 0.0 || (planet_hit && r < ci_radius))
        return float4(0, 0, 0, 1);

    float distance_to_sphere = (r < ci_radius) ? dists.y : dists.x;
    float3 sphere_pos = air_viewer_pos + ray_dir * distance_to_sphere;

    bool moonlit = sun_dir_val.y < -0.049;
    float3 light_dir = moonlit ? moon_dir_val : sun_dir_val;
    float cos_theta = dot(ray_dir, light_dir);

    float density = clouds_density_ci(sphere_pos.xz, 0.5);
    if (density < EPS) return float4(0, 0, 0, 1);

    float light_od = clouds_optical_depth_ci(sphere_pos, light_dir, dither);
    float view_od = density * ext_coeff * ci_thickness / (abs(ray_dir.y) + EPS);
    float view_trans = exp(-view_od);

    // Scattering (simplified 4-octave)
    float2 scattering = float2(0, 0);
    float phase = clouds_phase_single(cos_theta);
    float3 phase_g = float3(0.7, 0.9, 0.3);
    float powder = 4.0 * (1.0 - exp(-40.0 * density));
    powder = lerp(powder, 1.0, pow1d5(cos_theta * 0.5 + 0.5));

    float scatter_amt = scat_coeff;
    float extinct_amt = ext_coeff;

    for (int i = 0; i < 4; i++) {
        scattering.x += scatter_amt * exp(-extinct_amt * light_od) * phase * powder;
        scattering.y += scatter_amt * exp(-0.33 * ci_thickness * extinct_amt * density) * isotropic_phase;

        scatter_amt *= 0.5;
        extinct_amt *= 0.5;
        phase_g *= 0.8;
        phase = clouds_phase_multi(cos_theta, phase_g);
    }

    float scat_integral = (1.0 - view_trans) / ext_coeff;
    scattering *= scat_integral;

    // Light color
    float r_sq = dot(sphere_pos, sphere_pos);
    float rcp_r = rsqrt(r_sq);
    float mu_light = dot(sphere_pos, light_dir) * rcp_r;

    float3 light_color = moonlit ? moon_color_val : sun_color_val;
    light_color *= sunlight_color * atmosphere_transmittance_analytic(mu_light, r_sq * rcp_r);
    light_color *= 1.0 - rain_strength;

    float3 clouds_scat = scattering.x * light_color + scattering.y * sky_color_val;
    clouds_scat = clouds_aerial_perspective(
        clouds_scat, view_trans, air_viewer_pos, sphere_pos, ray_dir, clear_sky,
        rain_strength, sky_color_val, time_sunrise, time_sunset);

    return float4(clouds_scat, view_trans);
}

// ============================================================================
//  Combined cloud rendering (all three layers)
// ============================================================================

float4 draw_clouds(
    float3 ray_dir, float3 clear_sky, float dither,
    float3 sun_dir_val, float3 moon_dir_val,
    float3 sun_color_val, float3 moon_color_val,
    float3 sky_color_val, float3 ambient_color_val,
    float rain_strength, float time_sunrise, float time_sunset
) {
    float4 clouds = float4(0, 0, 0, 1);

    // Layer 1: Cumulus
    float4 cu = draw_clouds_cu(ray_dir, clear_sky, dither,
        sun_dir_val, moon_dir_val, sun_color_val, moon_color_val,
        sky_color_val, ambient_color_val, rain_strength, time_sunrise, time_sunset);
    clouds = cu;
    if (clouds.a < 1e-3) return clouds;

    // Layer 2: Altocumulus
    float4 ac = draw_clouds_ac(ray_dir, clear_sky, dither,
        sun_dir_val, moon_dir_val, sun_color_val, moon_color_val,
        sky_color_val, ambient_color_val, rain_strength, time_sunrise, time_sunset);
    clouds.rgb += ac.rgb * clouds.a;
    clouds.a *= ac.a;
    if (clouds.a < 1e-3) return clouds;

    // Layer 3: Cirrus
    float4 ci = draw_clouds_ci(ray_dir, clear_sky, dither,
        sun_dir_val, moon_dir_val, sun_color_val, moon_color_val,
        sky_color_val, rain_strength, time_sunrise, time_sunset);
    clouds.rgb += ci.rgb * clouds.a;
    clouds.a *= ci.a;

    return max(clouds, 0);
}

#endif // PHOTON_CLOUDS_INCLUDED
