#ifndef PHOTON_COLORSPACE_INCLUDED
#define PHOTON_COLORSPACE_INCLUDED

#include "Common.hlsl"
#include "FastMath.hlsl"

// ============================================================================
//  Color space conversion matrices and utility
//  Ported from Photon shaders: utility/color.glsl + aces/matrices.glsl
//
//  IMPORTANT: GLSL mat3(a,b,c,d,e,f,g,h,i) fills COLUMNS (column-major).
//  HLSL float3x3(a,b,c,d,e,f,g,h,i) fills ROWS (row-major).
//  GLSL "v * M" == HLSL "mul(M, v)" when constructor numbers are IDENTICAL.
//  So we keep the exact same numbers as GLSL — NO transposing.
// ============================================================================

// Luminance weights
static const float3 luminance_weights_rec709  = float3(0.2126, 0.7152, 0.0722);
static const float3 luminance_weights_rec2020 = float3(0.2627, 0.6780, 0.0593);
static const float3 luminance_weights_ap1     = float3(0.2722, 0.6741, 0.0537);
#define luminance_weights luminance_weights_rec2020

static const float3 primary_wavelengths_rec2020 = float3(660.0, 550.0, 440.0);
static const float3 primary_wavelengths_ap1     = float3(630.0, 530.0, 465.0);
#define primary_wavelengths primary_wavelengths_rec2020

// --- Color space matrices (same numbers as GLSL constructors) ---

// Rec.709 (sRGB primaries)
static const float3x3 xyz_to_rec709 = float3x3(
     3.2406, -1.5372, -0.4986,
    -0.9689,  1.8758,  0.0415,
     0.0557, -0.2040,  1.0570
);
static const float3x3 rec709_to_xyz = float3x3(
     0.4124,  0.3576,  0.1805,
     0.2126,  0.7152,  0.0722,
     0.0193,  0.1192,  0.9505
);

// Rec.2020 (working color space)
static const float3x3 xyz_to_rec2020 = float3x3(
     1.7166084, -0.3556621, -0.2533601,
    -0.6666829,  1.6164776,  0.0157685,
     0.0176422, -0.0427763,  0.94222867
);
static const float3x3 rec2020_to_xyz = float3x3(
     0.6369736, 0.1446172, 0.1688585,
     0.2627066, 0.6779996, 0.0592938,
     0.0000000, 0.0280728, 1.0608437
);

// Rec.709 <-> Rec.2020
float3x3 get_rec709_to_rec2020() { return mul(rec709_to_xyz, xyz_to_rec2020); }
float3x3 get_rec2020_to_rec709() { return mul(rec2020_to_xyz, xyz_to_rec709); }
#define rec709_to_rec2020 get_rec709_to_rec2020()
#define rec2020_to_rec709 get_rec2020_to_rec709()

// ACES AP0 <-> XYZ
static const float3x3 ap0_to_xyz = float3x3(
     0.9525523959,  0.0000000000,  0.0000936786,
     0.3439664498,  0.7281660966, -0.0721325464,
     0.0000000000,  0.0000000000,  1.0088251844
);
static const float3x3 xyz_to_ap0 = float3x3(
     1.0498110175,  0.0000000000, -0.0000974845,
    -0.4959030231,  1.3733130458,  0.0982400361,
     0.0000000000,  0.0000000000,  0.9912520182
);

// ACES AP1 <-> XYZ
static const float3x3 ap1_to_xyz = float3x3(
     0.6624541811,  0.1340042065,  0.1561876870,
     0.2722287168,  0.6740817658,  0.0536895174,
    -0.0055746495,  0.0040607335,  1.0103391003
);
static const float3x3 xyz_to_ap1 = float3x3(
     1.6410233797, -0.3248032942, -0.2364246952,
    -0.6636628587,  1.6153315917,  0.0167563477,
     0.0117218943, -0.0082844420,  0.9883948585
);

// Bradford chromatic adaptation D60 <-> D65
static const float3x3 d60_to_d65 = float3x3(
     0.9872240000, -0.0061132700,  0.0159533000,
    -0.0075983600,  1.0018600000,  0.0053300200,
     0.0030725700, -0.0050959500,  1.0816800000
);
static const float3x3 d65_to_d60 = float3x3(
     1.0130349240,  0.0061053089, -0.0149709632,
     0.0076982300,  0.9981648318, -0.0050320341,
    -0.0028413125,  0.0046851556,  0.9245066529
);

// Composite transforms
// GLSL: A * B means mul(A, B) columns, but since we use v*M pattern,
// "rec709_to_xyz * xyz_to_rec2020" in GLSL with v*M means:
// v * (A * B) = (v * A) * B — chain of transforms.
// In HLSL with mul(M, v): mul(B, mul(A, v)) = mul(mul(B, A), v)
// So GLSL "A * B" used as "v * (A*B)" becomes HLSL "mul(mul(B, A), v)"
// i.e., the multiplication order of matrices REVERSES.

// With mul(v, M) convention and same constructor values as GLSL,
// composite order is SAME as GLSL: GLSL "A * B" = HLSL "mul(A, B)"
float3x3 get_ap0_to_ap1()     { return mul(ap0_to_xyz, xyz_to_ap1); }
float3x3 get_ap1_to_ap0()     { return mul(ap1_to_xyz, xyz_to_ap0); }
float3x3 get_rec709_to_ap0()  { return mul(mul(rec709_to_xyz, d65_to_d60), xyz_to_ap0); }
float3x3 get_ap0_to_rec709()  { return mul(mul(ap0_to_xyz, d60_to_d65), xyz_to_rec709); }
float3x3 get_rec709_to_ap1()  { return mul(mul(rec709_to_xyz, d65_to_d60), xyz_to_ap1); }
float3x3 get_ap1_to_rec709()  { return mul(mul(ap1_to_xyz, d60_to_d65), xyz_to_rec709); }
float3x3 get_rec2020_to_ap0() { return mul(mul(rec2020_to_xyz, d65_to_d60), xyz_to_ap0); }
float3x3 get_ap0_to_rec2020() { return mul(mul(ap0_to_xyz, d60_to_d65), xyz_to_rec2020); }
float3x3 get_rec2020_to_ap1() { return mul(mul(rec2020_to_xyz, d65_to_d60), xyz_to_ap1); }
float3x3 get_ap1_to_rec2020() { return mul(mul(ap1_to_xyz, d60_to_d65), xyz_to_rec2020); }

#define ap0_to_ap1     get_ap0_to_ap1()
#define ap1_to_ap0     get_ap1_to_ap0()
#define rec709_to_ap0  get_rec709_to_ap0()
#define ap0_to_rec709  get_ap0_to_rec709()
#define rec709_to_ap1  get_rec709_to_ap1()
#define ap1_to_rec709  get_ap1_to_rec709()
#define rec2020_to_ap0 get_rec2020_to_ap0()
#define ap0_to_rec2020 get_ap0_to_rec2020()
#define rec2020_to_ap1 get_rec2020_to_ap1()
#define ap1_to_rec2020 get_ap1_to_rec2020()

// --- Transfer functions ---

float3 srgb_eotf(float3 linear_col) { // linear -> sRGB
    return 1.14374 * (-0.126893 * linear_col + sqrt(max(linear_col, 0.0)));
}
float3 srgb_eotf_inv(float3 srgb) { // sRGB -> linear
    return srgb * (srgb * (srgb * 0.305306011 + 0.682171111) + 0.012522878);
}

float3 from_srgb(float3 x) { return mul(pow(abs(x), 2.2), get_rec709_to_rec2020()); }

// --- Color representations ---

float3 rgb_to_hsl(float3 c) {
    const float4 K = float4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
    float4 p = (c.b < c.g) ? float4(c.bg, K.wz) : float4(c.gb, K.xy);
    float4 q = (p.x < c.r) ? float4(c.r, p.yzx) : float4(p.xyw, c.r);
    float d = q.x - min(q.w, q.y);
    float e = 1e-6;
    return float3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
}

// Blackbody radiation
float3 blackbody(float temperature) {
    const float3 lambda  = primary_wavelengths_ap1;
    const float3 lambda2 = lambda * lambda;
    const float3 lambda5 = lambda2 * lambda2 * lambda;

    const float h = 6.63e-16;
    const float k = 1.38e-5;
    const float c = 3.0e17;

    const float3 a = lambda5 / (2.0 * h * c * c);
    const float3 b = (h * c) / (k * lambda);
    float3 d = exp(b / temperature);

    float3 rgb = a * d - a;
    return min_of(rgb) / rgb;
}

float isolate_hue(float3 hsl, float center, float width) {
    if (hsl.y < 1e-2 || hsl.z < 1e-2) return 0.0;
    return pulse(hsl.x * 360.0, center, width);
}

#endif // PHOTON_COLORSPACE_INCLUDED
