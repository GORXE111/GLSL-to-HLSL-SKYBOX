#ifndef PHOTON_CLOUD_COMMON_INCLUDED
#define PHOTON_CLOUD_COMMON_INCLUDED

#include "Common.hlsl"
#include "FastMath.hlsl"
#include "PhaseFunction.hlsl"
#include "Atmosphere.hlsl"

// ============================================================================
//  Shared cloud functions
//  Ported from Photon shaders: sky/clouds.glsl (common parts)
// ============================================================================

// --- Cloud phase functions ---

float clouds_phase_single(float cos_theta) {
    return 0.8 * klein_nishina_phase(cos_theta, 2600.0)
         + 0.2 * henyey_greenstein_phase(cos_theta, -0.2);
}

float clouds_phase_multi(float cos_theta, float3 g) {
    return 0.65 * henyey_greenstein_phase(cos_theta,  g.x)
         + 0.10 * henyey_greenstein_phase(cos_theta,  g.y)
         + 0.25 * henyey_greenstein_phase(cos_theta, -g.z);
}

float clouds_powder_effect(float density, float cos_theta) {
    float powder = PI * density / (density + 0.15);
    powder = lerp(powder, 1.0, 0.8 * sqr(cos_theta * 0.5 + 0.5));
    return powder;
}

// --- Aerial perspective ---
// Blends cloud scattering with atmosphere between viewer and cloud

float3 clouds_aerial_perspective(
    float3 clouds_scattering,
    float clouds_transmittance,
    float3 ray_origin,      // viewer pos in atmosphere space
    float3 ray_end,         // cloud sample pos in atmosphere space
    float3 ray_dir,
    float3 clear_sky,
    float rain_strength,
    float3 sky_color_val,
    float time_sunrise,
    float time_sunset
) {
    float3 air_transmittance;

    if (length_squared(ray_origin) < length_squared(ray_end)) {
        float3 trans_0 = atmosphere_transmittance_analytic(
            dot(normalize(ray_origin), ray_dir), length(ray_origin));
        float3 trans_1 = atmosphere_transmittance_analytic(
            dot(normalize(ray_end), ray_dir), length(ray_end));
        air_transmittance = clamp01(trans_0 / max(trans_1, float3(1e-10, 1e-10, 1e-10)));
    } else {
        float3 trans_0 = atmosphere_transmittance_analytic(
            dot(normalize(ray_origin), -ray_dir), length(ray_origin));
        float3 trans_1 = atmosphere_transmittance_analytic(
            dot(normalize(ray_end), -ray_dir), length(ray_end));
        air_transmittance = clamp01(trans_1 / max(trans_0, float3(1e-10, 1e-10, 1e-10)));
    }

    // Blend to rain color during rain
    float3 rain_sky = lerp(clear_sky, sky_color_val * RCP_PI, rain_strength * lerp(1.0, 0.9, time_sunrise + time_sunset));
    clear_sky = lerp(clear_sky, rain_sky, rain_strength);
    air_transmittance = lerp(air_transmittance, float3(air_transmittance.x, air_transmittance.x, air_transmittance.x), 0.8 * rain_strength);

    return lerp((1.0 - clouds_transmittance) * clear_sky, clouds_scattering, air_transmittance);
}

// --- Multi-octave scattering computation ---
// Used by all three cloud layers with different coefficients

float2 clouds_scattering_generic(
    float density,
    float light_optical_depth,
    float sky_optical_depth,
    float ground_optical_depth,
    float step_transmittance,
    float cos_theta,
    float bounced_light,
    float scattering_coeff,
    float extinction_coeff,
    int octaves
) {
    float2 scattering = float2(0.0, 0.0);

    float scatter_amount = scattering_coeff;
    float extinct_amount = extinction_coeff;

    float scattering_integral = (1.0 - step_transmittance) / extinction_coeff;

    float powder = clouds_powder_effect(density, cos_theta);

    float phase = clouds_phase_single(cos_theta);
    float3 phase_g = pow(float3(0.6, 0.9, 0.3), max(float3(1.0, 1.0, 1.0) + light_optical_depth, 0.0));

    for (int i = 0; i < octaves; i++) {
        scattering.x += scatter_amount * exp(-extinct_amount * light_optical_depth) * phase;
        scattering.x += scatter_amount * exp(-extinct_amount * ground_optical_depth) * isotropic_phase * bounced_light;
        scattering.y += scatter_amount * exp(-extinct_amount * sky_optical_depth) * isotropic_phase;

        scatter_amount *= 0.55 * lerp(lift(clamp01(scattering_coeff / 0.1), 0.33), 1.0, cos_theta * 0.5 + 0.5) * powder;
        extinct_amount *= 0.4;
        phase_g *= 0.8;

        powder = lerp(powder, sqrt(powder), 0.5);
        phase = clouds_phase_multi(cos_theta, phase_g);
    }

    return scattering * scattering_integral;
}

#endif // PHOTON_CLOUD_COMMON_INCLUDED
