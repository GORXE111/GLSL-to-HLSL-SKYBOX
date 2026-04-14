#ifndef PHOTON_PHASE_FUNCTION_INCLUDED
#define PHOTON_PHASE_FUNCTION_INCLUDED

#include "Common.hlsl"
#include "FastMath.hlsl"

// ============================================================================
//  Phase functions for atmospheric scattering
//  Ported from Photon shaders: utility/phase_functions.glsl
// ============================================================================

static const float isotropic_phase = 0.25 / PI;

float3 rayleigh_phase(float nu) {
    const float3 depolarization = float3(2.786, 2.842, 2.899) * 1e-2;
    const float3 gamma = depolarization / (2.0 - depolarization);
    const float3 k = 3.0 / (16.0 * PI * (1.0 + 2.0 * gamma));

    float3 phase = (1.0 + 3.0 * gamma) + (1.0 - gamma) * sqr(nu);

    return k * phase;
}

float henyey_greenstein_phase(float nu, float g) {
    float gg = g * g;
    return (isotropic_phase - isotropic_phase * gg) / pow1d5(1.0 + gg - 2.0 * g * nu);
}

float cornette_shanks_phase(float nu, float g) {
    float gg = g * g;
    float p1 = 1.5 * (1.0 - gg) / (2.0 + gg);
    float p2 = (1.0 + nu * nu) / pow1d5(1.0 + gg - 2.0 * g * nu);
    return p1 * p2 * isotropic_phase;
}

// Far closer to an actual aerosol phase function than HG or CS
float klein_nishina_phase(float nu, float e) {
    return e / (TAU * (e - e * nu + 1.0) * log(2.0 * e + 1.0));
}

// Phase function specifically designed for leaves
float bilambertian_plate_phase(float nu, float k_d) {
    float phase = 2.0 * (-PI * nu * k_d + sqrt(clamp01(1.0 - sqr(nu))) + nu * fast_acos(-nu));
    return phase * rcp(3.0 * PI * PI);
}

#endif // PHOTON_PHASE_FUNCTION_INCLUDED
