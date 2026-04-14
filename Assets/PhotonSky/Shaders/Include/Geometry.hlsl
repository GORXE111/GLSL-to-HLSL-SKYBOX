#ifndef PHOTON_GEOMETRY_INCLUDED
#define PHOTON_GEOMETRY_INCLUDED

#include "Common.hlsl"

// ============================================================================
//  Sphere/AABB intersection methods
//  Ported from Photon shaders: utility/geometry.glsl
// ============================================================================

// Returns +-1
float3 sign_non_zero(float3 v) {
    return float3(
        v.x >= 0.0 ? 1.0 : -1.0,
        v.y >= 0.0 ? 1.0 : -1.0,
        v.z >= 0.0 ? 1.0 : -1.0
    );
}

// Intersect ray with sphere (parametric form using mu and r)
// from https://ebruneton.github.io/precomputed_atmospheric_scattering/
float2 intersect_sphere(float mu, float r, float sphere_radius) {
    float discriminant = r * r * (mu * mu - 1.0) + sqr(sphere_radius);

    if (discriminant < 0.0) return float2(-1.0, -1.0);

    discriminant = sqrt(discriminant);
    return -r * mu + float2(-discriminant, discriminant);
}

// Intersect ray with sphere (vector form)
float2 intersect_sphere_vec(float3 ray_origin, float3 ray_dir, float sphere_radius) {
    float b = dot(ray_origin, ray_dir);
    float discriminant = sqr(b) - dot(ray_origin, ray_origin) + sqr(sphere_radius);

    if (discriminant < 0.0) return float2(-1.0, -1.0);

    discriminant = sqrt(discriminant);
    return -b + float2(-discriminant, discriminant);
}

// Intersect ray with spherical shell (between inner and outer sphere)
float2 intersect_spherical_shell(float3 ray_origin, float3 ray_dir, float inner_sphere_radius, float outer_sphere_radius) {
    float2 inner_sphere_dists = intersect_sphere_vec(ray_origin, ray_dir, inner_sphere_radius);
    float2 outer_sphere_dists = intersect_sphere_vec(ray_origin, ray_dir, outer_sphere_radius);

    bool inner_sphere_intersected = inner_sphere_dists.y >= 0.0;
    bool outer_sphere_intersected = outer_sphere_dists.y >= 0.0;

    if (!outer_sphere_intersected) return float2(-1.0, -1.0);

    float2 dists;
    dists.x = inner_sphere_intersected && inner_sphere_dists.x < 0.0 ? inner_sphere_dists.y : max0(outer_sphere_dists.x);
    dists.y = inner_sphere_intersected && inner_sphere_dists.x > 0.0 ? inner_sphere_dists.x : outer_sphere_dists.y;

    return dists;
}

#endif // PHOTON_GEOMETRY_INCLUDED
