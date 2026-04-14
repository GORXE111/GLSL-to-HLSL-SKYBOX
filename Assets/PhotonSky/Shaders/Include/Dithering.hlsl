#ifndef PHOTON_DITHERING_INCLUDED
#define PHOTON_DITHERING_INCLUDED

// ============================================================================
//  Dithering functions
//  Ported from Photon shaders: utility/dithering.glsl
// ============================================================================

float bayer2(float2 a) {
    a = floor(a);
    return frac(dot(a, float2(0.5, a.y * 0.75)));
}

float bayer4(float2 a)  { return 0.25 * bayer2(0.5 * a) + bayer2(a); }
float bayer8(float2 a)  { return 0.25 * bayer4(0.5 * a) + bayer2(a); }
float bayer16(float2 a) { return 0.25 * bayer8(0.5 * a) + bayer2(a); }

float interleaved_gradient_noise(float2 pos) {
    return frac(52.9829189 * frac(0.06711056 * pos.x + (0.00583715 * pos.y)));
}

float interleaved_gradient_noise_t(float2 pos, int t) {
    return interleaved_gradient_noise(pos + 5.588238 * (t & 63));
}

#endif // PHOTON_DITHERING_INCLUDED
