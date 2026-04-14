#ifndef PHOTON_ATMOSPHERE_INCLUDED
#define PHOTON_ATMOSPHERE_INCLUDED

#include "Common.hlsl"
#include "FastMath.hlsl"
#include "ColorSpace.hlsl"
#include "Geometry.hlsl"
#include "PhaseFunction.hlsl"

// ============================================================================
//  Atmosphere model
//  Ported from Photon shaders: sky/atmosphere.glsl
//  Based on Eric Bruneton's 2020 precomputed atmospheric scattering
// ============================================================================

// Sunlight color in space (from AM0 solar irradiance spectrum)
static const float3 sunlight_color = float3(1.051, 0.985, 0.940);

// Angular radii (defaults)
#ifndef SUN_ANGULAR_RADIUS
#define SUN_ANGULAR_RADIUS 2.0
#endif
#ifndef MOON_ANGULAR_RADIUS
#define MOON_ANGULAR_RADIUS 2.5
#endif

static const float sun_angular_radius  = SUN_ANGULAR_RADIUS * DEGREE;
static const float moon_angular_radius = MOON_ANGULAR_RADIUS * DEGREE;

// LUT resolutions
static const int2 transmittance_res = int2(256, 64);
static const int3 scattering_res    = int3(16, 64, 32);

static const float min_mu_s = -0.35;

// --- Atmosphere boundaries ---
static const float planet_radius = 6371e3; // m
static const float atmosphere_inner_radius = planet_radius - 1e3; // m
static const float atmosphere_outer_radius = planet_radius + 110e3; // m

static const float planet_radius_sq = planet_radius * planet_radius;
static const float atmosphere_thickness = atmosphere_outer_radius - atmosphere_inner_radius;
static const float atmosphere_inner_radius_sq = atmosphere_inner_radius * atmosphere_inner_radius;
static const float atmosphere_outer_radius_sq = atmosphere_outer_radius * atmosphere_outer_radius;

// --- Atmosphere coefficients ---
static const float air_mie_albedo           = 0.9;
static const float air_mie_energy_parameter = 3000.0;
static const float air_mie_g               = 0.77;

static const float2 air_scale_heights = float2(8.4e3, 1.25e3); // m

// Coefficients in Rec.2020 working space
// We precompute the matrix multiplication result for the default rec709_to_rec2020 transform
static const float3 air_rayleigh_coefficient_base = float3(8.059375432e-06, 1.671209429e-05, 4.080133294e-05);
static const float3 air_mie_coefficient_base      = float3(1.666442358e-06, 1.812685127e-06, 1.958927896e-06);
static const float3 air_ozone_coefficient_base    = float3(8.304280072e-07, 1.314911970e-06, 5.440679729e-08);

// Transform to working color space (Rec.2020)
#define air_rayleigh_coefficient mul(air_rayleigh_coefficient_base, rec709_to_rec2020)
#define air_mie_coefficient      mul(air_mie_coefficient_base, rec709_to_rec2020)
#define air_ozone_coefficient    mul(air_ozone_coefficient_base, rec709_to_rec2020)

// --- Density distribution ---
float3 atmosphere_density(float r) {
    const float2 rcp_scale_heights = rcp(air_scale_heights);
    const float2 scaled_planet_radius = planet_radius * rcp_scale_heights;

    float2 rayleigh_mie = exp(r * -rcp_scale_heights + scaled_planet_radius);

    // Ozone density from Jessie
    float altitude_km = r * 1e-3 - (planet_radius * 1e-3);
    float o1 = 12.5 * exp(rcp(8.0)   * (0.0  - altitude_km));
    float o2 = 30.0 * exp(rcp(80.0)  * (18.0 - altitude_km) * (altitude_km - 18.0));
    float o3 = 75.0 * exp(rcp(50.0)  * (23.5 - altitude_km) * (altitude_km - 23.5));
    float o4 = 50.0 * exp(rcp(150.0) * (30.0 - altitude_km) * (altitude_km - 30.0));
    float ozone = 7.428e-3 * (o1 + o2 + o3 + o4);

    return float3(rayleigh_mie, ozone);
}

// --- Transmittance LUT mapping ---
float2 atmosphere_transmittance_uv(float mu, float r) {
    const float H = sqrt(max(atmosphere_outer_radius_sq - atmosphere_inner_radius_sq, 0.0));
    float rho = sqrt(max0(r * r - atmosphere_inner_radius_sq));

    float d = intersect_sphere(mu, r, atmosphere_outer_radius).y;
    float d_min = atmosphere_outer_radius - r;
    float d_max = rho + H;

    float u_mu = get_uv_from_unit_range((d - d_min) / (d_max - d_min), transmittance_res.x);
    float u_r  = get_uv_from_unit_range(rho / H, transmittance_res.y);

    return float2(u_mu, u_r);
}

// Decode (mu, r) from UV coordinates
void atmosphere_transmittance_uv_to_mu_r(float2 uv, out float mu, out float r) {
    const float H = sqrt(max(atmosphere_outer_radius_sq - atmosphere_inner_radius_sq, 0.0));

    float u_mu = get_unit_range_from_uv(uv.x, transmittance_res.x);
    float u_r  = get_unit_range_from_uv(uv.y, transmittance_res.y);

    float rho = u_r * H;
    r = sqrt(rho * rho + atmosphere_inner_radius_sq);

    float d_min = atmosphere_outer_radius - r;
    float d_max = rho + H;
    float d = d_min + u_mu * (d_max - d_min);

    mu = (d == 0.0) ? 1.0 : (H * H - rho * rho - d * d) / (2.0 * r * d);
    mu = clamp(mu, -1.0, 1.0);
}

// --- Scattering LUT mapping ---
float3 atmosphere_scattering_uv(float nu, float mu, float mu_s) {
    // Improved mapping for nu from Spectrum by Zombye
    float half_range_nu = sqrt((1.0 - mu * mu) * (1.0 - mu_s * mu_s));
    float nu_min = mu * mu_s - half_range_nu;
    float nu_max = mu * mu_s + half_range_nu;

    float u_nu = (nu_min == nu_max) ? nu_min : (nu - nu_min) / (nu_max - nu_min);
    u_nu = get_uv_from_unit_range(u_nu, scattering_res.x);

    // Stretch the sky near the horizon upwards
    if (mu > 0.0) mu *= sqrt(sqrt(mu));

    // Mapping for mu
    const float r = planet_radius;
    const float H = sqrt(atmosphere_outer_radius_sq - atmosphere_inner_radius_sq);
    const float rho = sqrt(max0(planet_radius * planet_radius - atmosphere_inner_radius_sq));

    float rmu = r * mu;
    float discriminant = rmu * rmu - r * r + atmosphere_inner_radius_sq;

    float u_mu;
    if (mu < 0.0 && discriminant >= 0.0) {
        float d = -rmu - sqrt(max0(discriminant));
        float d_min = r - atmosphere_inner_radius;
        float d_max = rho;

        u_mu = d_max == d_min ? 0.0 : (d - d_min) / (d_max - d_min);
        u_mu = get_uv_from_unit_range(u_mu, scattering_res.y / 2);
        u_mu = 0.5 - 0.5 * u_mu;
    } else {
        float d = -rmu + sqrt(discriminant + H * H);
        float d_min = atmosphere_outer_radius - r;
        float d_max = rho + H;

        u_mu = (d - d_min) / (d_max - d_min);
        u_mu = get_uv_from_unit_range(u_mu, scattering_res.y / 2);
        u_mu = 0.5 + 0.5 * u_mu;
    }

    // Mapping for mu_s
    float d_s = intersect_sphere(mu_s, atmosphere_inner_radius, atmosphere_outer_radius).y;
    float d_s_min = atmosphere_thickness;
    float d_s_max = H;
    float a = (d_s - d_s_min) / (d_s_max - d_s_min);

    float D = intersect_sphere(min_mu_s, atmosphere_inner_radius, atmosphere_outer_radius).y;
    float A = (D - d_s_min) / (d_s_max - d_s_min);

    float u_mu_s = get_uv_from_unit_range(max0(1.0 - a / A) / (1.0 + a), scattering_res.z);

    return float3(u_nu, u_mu, u_mu_s);
}

// --- Chapman function approximation (fallback when no LUT) ---
// Source: http://www.thetenthplanet.de/archives/4519
float chapman_function_approx(float x, float cos_theta) {
    float c = sqrt(HALF_PI * x);

    if (cos_theta >= 0.0) {
        return c / ((c - 1.0) * cos_theta + 1.0);
    } else {
        float sin_theta = sqrt(clamp01(1.0 - sqr(cos_theta)));
        return c / ((c - 1.0) * cos_theta - 1.0) + 2.0 * c * exp(x - x * sin_theta) * sqrt(sin_theta);
    }
}

// Compute transmittance analytically (used by compute shader during LUT bake)
float3 atmosphere_transmittance_analytic(float mu, float r) {
    if (intersect_sphere(mu, max(r, planet_radius + 10.0), planet_radius).x >= 0.0) return float3(0.0, 0.0, 0.0);

    float3 rayleigh_coeff = air_rayleigh_coefficient;
    float3 mie_coeff = air_mie_coefficient;
    float3 ozone_coeff = air_ozone_coefficient;

    const float2 rcp_scale_heights = rcp(air_scale_heights);
    const float2 scaled_planet_radius = planet_radius * rcp_scale_heights;
    float2 density = exp(r * -rcp_scale_heights + scaled_planet_radius);

    float2 airmass = air_scale_heights * density;
    airmass.x *= chapman_function_approx(r * rcp_scale_heights.x, mu);
    airmass.y *= chapman_function_approx(r * rcp_scale_heights.y, mu);

    float3 optical_depth = rayleigh_coeff * airmass.x + mie_coeff * airmass.y + ozone_coeff * airmass.x;
    return clamp01(exp(-optical_depth));
}

#endif // PHOTON_ATMOSPHERE_INCLUDED
