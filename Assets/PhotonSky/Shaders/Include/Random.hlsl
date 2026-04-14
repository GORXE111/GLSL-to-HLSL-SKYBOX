#ifndef PHOTON_RANDOM_INCLUDED
#define PHOTON_RANDOM_INCLUDED

#include "Common.hlsl"

// ============================================================================
//  Random and hash functions
//  Ported from Photon shaders: utility/random.glsl
// ============================================================================

// Quasirandom sequences
static const float phi1 = 1.6180339887;
static const float phi2 = 1.3247179572;
static const float phi3 = 1.2207440846;

float r1(int n, float seed) {
    return frac(seed + n * (1.0 / phi1));
}
float r1(int n) { return r1(n, 0.5); }

float2 r2(int n, float2 seed) {
    const float2 alpha = 1.0 / float2(phi2, phi2 * phi2);
    return frac(seed + n * alpha);
}
float2 r2(int n) { return r2(n, float2(0.5, 0.5)); }

// Hash functions from https://www.shadertoy.com/view/4dj_s_r_w
float hash1(float p) {
    p = frac(p * .1031);
    p *= p + 33.33;
    p *= p + p;
    return frac(p);
}

float hash1_3(float3 p3) {
    p3 = frac(p3 * .1031);
    p3 += dot(p3, p3.zyx + 31.32);
    return frac((p3.x + p3.y) * p3.z);
}

float2 hash2(float2 p) {
    float3 p3 = frac(float3(p.xyx) * float3(.1031, .1030, .0973));
    p3 += dot(p3, p3.yzx + 33.33);
    return frac((p3.xx + p3.yz) * p3.zy);
}

float2 hash2_3(float3 p3) {
    p3 = frac(p3 * float3(.1031, .1030, .0973));
    p3 += dot(p3, p3.yzx + 33.33);
    return frac((p3.xx + p3.yz) * p3.zy);
}

float4 hash4(float2 p) {
    float4 p4 = frac(float4(p.xyxy) * float4(.1031, .1030, .0973, .1099));
    p4 += dot(p4, p4.wzxy + 33.33);
    return frac((p4.xxyz + p4.yzzw) * p4.zywx);
}

float4 hash4_3(float3 p) {
    float4 p4 = frac(float4(p.xyzx) * float4(.1031, .1030, .0973, .1099));
    p4 += dot(p4, p4.wzxy + 33.33);
    return frac((p4.xxyz + p4.yzzw) * p4.zywx);
}

// Integer hash (lowbias32)
uint lowbias32(uint x) {
    x ^= x >> 16;
    x *= 0x7feb352du;
    x ^= x >> 15;
    x *= 0x846ca68bu;
    x ^= x >> 16;
    return x;
}

float rand_next_float(inout uint state) {
    state = lowbias32(state);
    return float(state) / float(0xffffffffu);
}

#endif // PHOTON_RANDOM_INCLUDED
