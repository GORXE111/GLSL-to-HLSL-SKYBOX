#ifndef PHOTON_COMMON_INCLUDED
#define PHOTON_COMMON_INCLUDED

// ============================================================================
//  Common constants and helper functions
//  Ported from Photon shaders: global.glsl
//  NOTE: PI, TWO_PI, HALF_PI, INV_PI are already defined by URP Core.hlsl
//  We reuse those and only define what URP doesn't provide.
// ============================================================================

// Use URP's PI if available, otherwise define our own
#ifndef PI
#define PI     3.14159265358979323846
#endif
#ifndef TWO_PI
#define TWO_PI 6.28318530717958647692
#endif
#ifndef HALF_PI
#define HALF_PI 1.57079632679489661923
#endif
#ifndef INV_PI
#define INV_PI 0.31830988618379067154
#endif

// Aliases matching Photon naming
#define TAU     TWO_PI
#define RCP_PI  INV_PI
#define DEGREE  (TAU / 360.0)

static const float GOLDEN_RATIO = 1.6180339887498948482;
static const float GOLDEN_ANGLE = TAU / (GOLDEN_RATIO * GOLDEN_RATIO);
static const float EPS = 1e-6;

// Helper macros
#ifndef rcp
#define rcp(x)      (1.0 / (x))
#endif
#define clamp01(x)  saturate(x)
#define max0(x)     max(x, 0.0)
#define min1(x)     min(x, 1.0)

float sqr(float x) { return x * x; }
float2 sqr(float2 v) { return v * v; }
float3 sqr(float3 v) { return v * v; }
float4 sqr(float4 v) { return v * v; }

float cube(float x) { return x * x * x; }

float max_of(float2 v) { return max(v.x, v.y); }
float max_of(float3 v) { return max(v.x, max(v.y, v.z)); }
float max_of(float4 v) { return max(v.x, max(v.y, max(v.z, v.w))); }
float min_of(float2 v) { return min(v.x, v.y); }
float min_of(float3 v) { return min(v.x, min(v.y, v.z)); }
float min_of(float4 v) { return min(v.x, min(v.y, min(v.z, v.w))); }

float length_squared(float2 v) { return dot(v, v); }
float length_squared(float3 v) { return dot(v, v); }

float2 normalize_safe(float2 v) { return all(v == 0) ? v : normalize(v); }
float3 normalize_safe(float3 v) { return all(v == 0) ? v : normalize(v); }

// Remapping functions
float linear_step(float edge0, float edge1, float x) {
    return clamp01((x - edge0) / (edge1 - edge0));
}

float cubic_smooth(float x) {
    return sqr(x) * (3.0 - 2.0 * x);
}

float dampen(float x) {
    x = clamp01(x);
    return x * (2.0 - x);
}

float lift(float x, float amount) {
    return (x + x * amount) / (1.0 + x * amount);
}
float3 lift3(float3 x, float amount) {
    return (x + x * amount) / (1.0 + x * amount);
}

float pulse(float x, float center, float width) {
    x = abs(x - center) / width;
    return x > 1.0 ? 0.0 : 1.0 - cubic_smooth(x);
}

float pulse_periodic(float x, float center, float width, float period) {
    x = (x - center + 0.5 * period) / period;
    x = frac(x) * period - (0.5 * period);
    return pulse(x, 0.0, width);
}

// LUT coordinate mapping (from Bruneton 2020)
float get_uv_from_unit_range(float value, int res) {
    return value * (1.0 - 1.0 / (float)res) + (0.5 / (float)res);
}

float get_unit_range_from_uv(float uv, int res) {
    return (uv - 0.5 / (float)res) / (1.0 - 1.0 / (float)res);
}

#endif // PHOTON_COMMON_INCLUDED
