#ifndef PHOTON_ACES_INCLUDED
#define PHOTON_ACES_INCLUDED

#include "Common.hlsl"
#include "FastMath.hlsl"
#include "ColorSpace.hlsl"

// ============================================================================
//  ACES Reference Rendering Transform + Output Device Transform
//  Ported from Photon shaders: aces/aces.glsl, aces/tonescales.glsl, aces/utility.glsl
//  Following the reference implementation from https://github.com/ampas/aces-dev (rev 1.3)
// ============================================================================

// --- Constants ---
static const float rrt_glow_gain   = 0.1;
static const float rrt_glow_mid    = 0.08;
static const float rrt_red_scale   = 1.0;
static const float rrt_red_pivot   = 0.03;
static const float rrt_red_hue     = 0.0;
static const float rrt_red_width   = 135.0;
static const float rrt_sat_factor  = 0.96;
static const float odt_sat_factor  = 1.0;
static const float rrt_gamma_curve = 0.96;
static const float cinema_white    = 48.0;
static const float cinema_black    = 0.02;

// --- ACES Utility ---

float3 XYZ_to_xy_y(float3 XYZ) {
    float m = 1.0 / max(XYZ.x + XYZ.y + XYZ.z, 1e-10);
    return float3(XYZ.x * m, XYZ.y * m, XYZ.y);
}

float3 xy_y_to_XYZ(float3 xyY) {
    float m = xyY.z / max(xyY.y, 1e-10);
    return float3(xyY.x * m, xyY.z, (1.0 - xyY.x - xyY.y) * m);
}

float rgb_to_saturation(float3 rgb) {
    float max_c = max(max_of(rgb), 1e-10);
    float min_c = max(min_of(rgb), 1e-10);
    return (max_c - min_c) / max_c;
}

float rgb_to_hue(float3 rgb) {
    if (rgb.r == rgb.g && rgb.g == rgb.b) return 0.0;
    float hue = (360.0 / TAU) * atan2(2.0 * rgb.r - rgb.g - rgb.b, sqrt(3.0) * (rgb.g - rgb.b));
    if (hue < 0.0) hue += 360.0;
    return hue;
}

float rgb_to_yc(float3 rgb) {
    const float yc_radius_weight = 1.75;
    float chroma = sqrt(rgb.b * (rgb.b - rgb.g) + rgb.g * (rgb.g - rgb.r) + rgb.r * (rgb.r - rgb.b));
    return rcp(3.0) * (rgb.r + rgb.g + rgb.b + yc_radius_weight * chroma);
}

float aces_log10(float x) {
    return log(x) * rcp(log(10.0));
}

float3 y_to_lin_c_v(float3 y, float y_max, float y_min) {
    return (y - y_min) / (y_max - y_min);
}

// --- Glow module ---
float glow_fwd(float yc_in, float glow_gain_in, float glow_mid) {
    if (yc_in <= 2.0 / 3.0 * glow_mid)
        return glow_gain_in;
    else if (yc_in >= 2.0 * glow_mid)
        return 0.0;
    else
        return glow_gain_in * (glow_mid / yc_in - 0.5);
}

float sigmoid_shaper(float x) {
    float t = max0(1.0 - abs(0.5 * x));
    float y = 1.0 + sign(x) * (1.0 - t * t);
    return 0.5 * y;
}

// --- Red modifier ---
float cubic_basis_shaper_fit(float x, float width) {
    float radius = 0.5 * width;
    return abs(x) < radius
        ? sqr(cubic_smooth(1.0 - abs(x) / radius))
        : 0.0;
}

float center_hue(float hue, float center_h) {
    float hue_centered = hue - center_h;
    if (hue_centered < -180.0) return hue_centered + 360.0;
    else if (hue_centered > 180.0) return hue_centered - 360.0;
    else return hue_centered;
}

// --- Tonescale splines ---

// Textbook monomial to basis-function conversion matrix
static const float3x3 spline_M = float3x3(
     0.5, -1.0,  0.5,
    -1.0,  1.0,  0.5,
     0.5,  0.0,  0.0
);

float segmented_spline_c5_fwd(float x) {
    // RRT parameters
    static const float2 log_min_point = log(float2(0.18 * exp2(-15.0), 0.0001)) * rcp(log(10.0));
    static const float2 log_mid_point = log(float2(0.18,               4.8))    * rcp(log(10.0));
    static const float2 log_max_point = log(float2(0.18 * exp2( 18.0), 1000.0)) * rcp(log(10.0));

    static const float coeff_low[6]  = {-4.0, -4.0, -3.1573765773, -0.4852499958, 1.8477324706, 1.8477324706};
    static const float coeff_high[6] = {-0.7185482425, 2.0810307172, 3.6681241237, 4.0, 4.0, 4.0};

    float log_x = aces_log10(max(x, EPS));
    float log_y;

    if (log_x <= log_min_point.x) {
        log_y = log_x * 0.0 + log_min_point.y; // slope_low = 0
    } else if (log_x < log_mid_point.x) {
        float knot_coord = 3.0 * (log_x - log_min_point.x) / (log_mid_point.x - log_min_point.x);
        uint i = (uint)knot_coord;
        float f = frac(knot_coord);
        i = min(i, 3u);
        float3 cf = float3(coeff_low[i], coeff_low[i+1], coeff_low[i+2]);
        float3 monomials = float3(f * f, f, 1.0);
        log_y = dot(monomials, mul(cf, spline_M));
    } else if (log_x <= log_max_point.x) {
        float knot_coord = 3.0 * (log_x - log_mid_point.x) / (log_max_point.x - log_mid_point.x);
        uint i = (uint)knot_coord;
        float f = frac(knot_coord);
        i = min(i, 3u);
        float3 cf = float3(coeff_high[i], coeff_high[i+1], coeff_high[i+2]);
        float3 monomials = float3(f * f, f, 1.0);
        log_y = dot(monomials, mul(cf, spline_M));
    } else {
        log_y = log_x * 0.0 + log_max_point.y; // slope_high = 0
    }

    return pow(10.0, log_y);
}

float segmented_spline_c9_fwd(float x) {
    // 48nit ODT parameters (precomputed min/mid/max points)
    static const float2 log_min_point = float2(-2.5406231880, -1.6989699602);
    static const float2 log_mid_point = float2( 0.6812411547,  0.6812412143);
    static const float2 log_max_point = float2( 3.0024764538,  1.6812412739);

    static const float coeff_low[10]  = {-1.6989700043, -1.6989700043, -1.4779, -1.2291, -0.8648, -0.4480, 0.00518, 0.4511080334, 0.9113744414, 0.9113744414};
    static const float coeff_high[10] = { 0.5154386965,  0.8470437783,  1.1358,  1.3802,  1.5197,  1.5985, 1.6467,  1.6746091357, 1.6878733390, 1.6878733390};

    float log_x = aces_log10(max(x, EPS));
    float log_y;

    if (log_x <= log_min_point.x) {
        log_y = log_x * 0.0 + log_min_point.y;
    } else if (log_x < log_mid_point.x) {
        float knot_coord = 7.0 * (log_x - log_min_point.x) / (log_mid_point.x - log_min_point.x);
        uint i = (uint)knot_coord;
        float f = frac(knot_coord);
        i = min(i, 7u);
        float3 cf = float3(coeff_low[i], coeff_low[i+1], coeff_low[i+2]);
        float3 monomials = float3(f * f, f, 1.0);
        log_y = dot(monomials, mul(cf, spline_M));
    } else if (log_x <= log_max_point.x) {
        float knot_coord = 7.0 * (log_x - log_mid_point.x) / (log_max_point.x - log_mid_point.x);
        uint i = (uint)knot_coord;
        float f = frac(knot_coord);
        i = min(i, 7u);
        float3 cf = float3(coeff_high[i], coeff_high[i+1], coeff_high[i+2]);
        float3 monomials = float3(f * f, f, 1.0);
        log_y = dot(monomials, mul(cf, spline_M));
    } else {
        log_y = log_x * 0.04 + (log_max_point.y - 0.04 * log_max_point.x);
    }

    return pow(10.0, log_y);
}

// --- RRT Sweeteners ---
float3 rrt_sweeteners(float3 aces) {
    float saturation = rgb_to_saturation(aces);
    float yc_in = rgb_to_yc(aces);
    float s = sigmoid_shaper(5.0 * saturation - 2.0);
    float added_glow = 1.0 + glow_fwd(yc_in, rrt_glow_gain * s, rrt_glow_mid);

    aces *= added_glow;

    // Red modifier
    float hue = rgb_to_hue(aces);
    float centered_hue = center_hue(hue, rrt_red_hue);
    float hue_weight = cubic_basis_shaper_fit(centered_hue, rrt_red_width);

    aces.r = aces.r + hue_weight * saturation * (rrt_red_pivot - aces.r) * (1.0 - rrt_red_scale);

    // ACES to RGB rendering space (AP0 -> AP1)
    float3 rgb_pre = max0(mul(aces, ap0_to_ap1));

    // Global desaturation
    float luminance = dot(rgb_pre, luminance_weights_ap1);
    rgb_pre = lerp(float3(luminance, luminance, luminance), rgb_pre, rrt_sat_factor);

    // Gamma adjustment
    rgb_pre = pow(max(rgb_pre, 0.0), rrt_gamma_curve);

    return rgb_pre;
}

// --- RRT ---
float3 aces_rrt(float3 aces) {
    float3 rgb_pre = rrt_sweeteners(aces);

    float3 rgb_post;
    rgb_post.r = segmented_spline_c5_fwd(rgb_pre.r);
    rgb_post.g = segmented_spline_c5_fwd(rgb_pre.g);
    rgb_post.b = segmented_spline_c5_fwd(rgb_pre.b);

    return rgb_post;
}

// --- ODT (Rec.709) ---
float3 dark_surround_to_dim_surround(float3 linear_c_v) {
    const float dim_surround_gamma = 0.9811;

    float3 XYZ = mul(linear_c_v, ap1_to_xyz);
    float3 xyY = XYZ_to_xy_y(XYZ);

    xyY.z = max0(xyY.z);
    xyY.z = pow(xyY.z, dim_surround_gamma);

    return mul(xy_y_to_XYZ(xyY), xyz_to_ap1);
}

float3 aces_odt(float3 rgb_pre) {
    float3 rgb_post;
    rgb_post.r = segmented_spline_c9_fwd(rgb_pre.r);
    rgb_post.g = segmented_spline_c9_fwd(rgb_pre.g);
    rgb_post.b = segmented_spline_c9_fwd(rgb_pre.b);

    float3 linear_c_v = y_to_lin_c_v(rgb_post, cinema_white, cinema_black);

    linear_c_v = dark_surround_to_dim_surround(linear_c_v);

    float luminance = dot(linear_c_v, luminance_weights_ap1);
    linear_c_v = lerp(float3(luminance, luminance, luminance), linear_c_v, odt_sat_factor);

    return linear_c_v;
}

// --- Simplified RRT+ODT fit by Stephen Hill ---
float3 rrt_and_odt_fit(float3 rgb) {
    float3 a = rgb * (rgb + 0.0245786) - 0.000090537;
    float3 b = rgb * (0.983729 * rgb + 0.4329510) + 0.238081;
    return a / b;
}

// --- Full ACES pipeline ---
// Input: scene-referred linear Rec.2020
// Output: display-referred linear sRGB (for Unity's linear workflow)
float3 aces_tonemap(float3 color_rec2020) {
    // Rec.2020 -> ACES AP0
    float3 aces = mul(color_rec2020, rec2020_to_ap0);

    // RRT
    float3 oces = aces_rrt(aces);

    // ODT (outputs in AP1)
    float3 display_ap1 = aces_odt(oces);

    // AP1 -> Rec.709 (sRGB primaries, linear)
    float3 display_rec709 = mul(display_ap1, ap1_to_rec709);

    return saturate(display_rec709);
}

#endif // PHOTON_ACES_INCLUDED
