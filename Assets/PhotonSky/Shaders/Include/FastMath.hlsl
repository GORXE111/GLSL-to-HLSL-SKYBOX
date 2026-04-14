#ifndef PHOTON_FAST_MATH_INCLUDED
#define PHOTON_FAST_MATH_INCLUDED

#include "Common.hlsl"

// ============================================================================
//  Fast math approximations
//  Ported from Photon shaders: utility/fast_math.glsl
// ============================================================================

// Faster alternative to acos
// Source: https://seblagarde.wordpress.com/2014/12/01/inverse-trigonometric-functions-gpu-optimization-for-amd-gcn-architecture/
// Max relative error: 3.9 * 10^-4
float fast_acos(float x) {
    const float C0 = 1.57018;
    const float C1 = -0.201877;
    const float C2 = 0.0464619;

    float res = (C2 * abs(x) + C1) * abs(x) + C0;
    res *= sqrt(1.0 - abs(x));

    return x >= 0 ? res : PI - res;
}
float2 fast_acos2(float2 v) { return float2(fast_acos(v.x), fast_acos(v.y)); }

float pow4(float x) { return sqr(sqr(x)); }
float pow5(float x) { return pow4(x) * x; }
float pow6(float x) { return sqr(cube(x)); }
float pow7(float x) { return pow6(x) * x; }
float pow8(float x) { return sqr(pow4(x)); }
float pow12(float x) { return cube(pow4(x)); }

float pow16(float x) { x*=x; x*=x; x*=x; x*=x; return x; }
float pow32(float x) { x*=x; x*=x; x*=x; x*=x; x*=x; return x; }
float pow64(float x) { x*=x; x*=x; x*=x; x*=x; x*=x; x*=x; return x; }
float pow128(float x) { x*=x; x*=x; x*=x; x*=x; x*=x; x*=x; x*=x; return x; }

// x^1.5
float pow1d5(float x) {
    return x * sqrt(x);
}

float rcp_length(float2 v) { return rsqrt(dot(v, v)); }
float rcp_length(float3 v) { return rsqrt(dot(v, v)); }

#endif // PHOTON_FAST_MATH_INCLUDED
