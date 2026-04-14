#ifndef PHOTON_SAMPLING_INCLUDED
#define PHOTON_SAMPLING_INCLUDED

#include "Common.hlsl"

// ============================================================================
//  Sampling functions
//  Ported from Photon shaders: utility/sampling.glsl
// ============================================================================

float2 vogel_disk_sample(int step_index, int step_count, float rotation) {
    const float golden_angle = 2.4;
    float r = sqrt(step_index + 0.5) / sqrt((float)step_count);
    float theta = step_index * golden_angle + rotation;
    return r * float2(cos(theta), sin(theta));
}

float3 uniform_sphere_sample(float2 hash_val) {
    hash_val.x *= TAU;
    hash_val.y = 2.0 * hash_val.y - 1.0;
    float2 sc = float2(sin(hash_val.x), cos(hash_val.x)) * sqrt(1.0 - hash_val.y * hash_val.y);
    return float3(sc.x, sc.y, hash_val.y);
}

float3 uniform_hemisphere_sample(float3 normal, float2 hash_val) {
    float3 dir = uniform_sphere_sample(hash_val);
    return dot(dir, normal) < 0.0 ? -dir : dir;
}

float3 cosine_weighted_hemisphere_sample(float3 normal, float2 hash_val) {
    float3 dir = normalize(uniform_sphere_sample(hash_val) + normal);
    return dot(dir, normal) < 0.0 ? -dir : dir;
}

#endif // PHOTON_SAMPLING_INCLUDED
