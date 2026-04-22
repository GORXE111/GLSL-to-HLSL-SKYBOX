// ============================================================================
// CloudsInline.hlsl
// Volumetric cloud system ported from Photon shaders.
// FULLY SELF-CONTAINED — only depends on functions already defined
// in PhotonSkybox.shader (sqr, cube, linear_step, phase_hg, atmo_transmittance, etc.)
//
// Source: photon/shaders/include/sky/clouds.glsl
// Three layers:
//   Cu (cumulus)     — clouds.glsl:77-327  — low altitude, dense, cauliflower shape
//   Ac (altocumulus) — clouds.glsl:342-586 — mid altitude, thinner
//   Ci (cirrus)     — clouds.glsl:600-828  — high altitude, planar wisps
//
// Simplifications from Photon:
//   - Cu: 16 primary steps (Photon: 40), 3 lighting steps (Photon: 6)
//   - Ac: 8 primary steps (Photon: 12)
//   - Ci: single-plane evaluation (same as Photon)
//   - Noise: procedural hash-based (Photon uses texture lookups)
//     This avoids dependency on NoiseTextureBaker compute shaders.
// ============================================================================

#ifndef PHOTON_CLOUDS_INLINE_INCLUDED
#define PHOTON_CLOUDS_INLINE_INCLUDED

// ============================================================
//  Cloud uniforms (set by PhotonSkyManager.cs)
// ============================================================
float  _CloudsCoverage;   // 0-1, overall cloud amount
float  _CloudsAltitude;   // Cu base altitude in meters (default 1500)
float  _CloudsThickness;  // Cu thickness multiplier (default 0.5)
float  _CloudsSpeed;      // Wind speed multiplier

// ============================================================
//  Procedural noise (replaces Photon's noisetex/colortex6/7)
//  Ref: These replace texture(noisetex, ...) in clouds.glsl:109-111
//  We use hash-based value noise instead of texture lookups.
// ============================================================

// Simple 2D value noise — hashes all 4 cell corners independently
float hash_2d(float2 p) {
    float3 p3 = frac(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return frac((p3.x + p3.y) * p3.z);
}

float value_noise(float2 p) {
    float2 ip = floor(p);
    float2 f = frac(p);
    f = f * f * (3.0 - 2.0 * f); // cubic smooth

    // Hash each of the 4 cell corners independently
    float c00 = hash_2d(ip + float2(0, 0));
    float c10 = hash_2d(ip + float2(1, 0));
    float c01 = hash_2d(ip + float2(0, 1));
    float c11 = hash_2d(ip + float2(1, 1));

    return lerp(lerp(c00, c10, f.x), lerp(c01, c11, f.x), f.y);
}

// FBM 2D noise (3 octaves)
float fbm2(float2 p) {
    float v = 0.0;
    v += 0.500 * value_noise(p); p *= 2.03;
    v += 0.250 * value_noise(p); p *= 2.01;
    v += 0.125 * value_noise(p);
    return v / 0.875;
}

// Simple 3D value noise — hashes all 8 cell corners independently
float hash_3d(float3 p) {
    p = frac(p * 0.1031);
    p += dot(p, p.zyx + 31.32);
    return frac((p.x + p.y) * p.z);
}

float value_noise_3d(float3 p) {
    float3 ip = floor(p);
    float3 f = frac(p);
    f = f * f * (3.0 - 2.0 * f);

    // Hash each of 8 corners
    float c000 = hash_3d(ip + float3(0,0,0));
    float c100 = hash_3d(ip + float3(1,0,0));
    float c010 = hash_3d(ip + float3(0,1,0));
    float c110 = hash_3d(ip + float3(1,1,0));
    float c001 = hash_3d(ip + float3(0,0,1));
    float c101 = hash_3d(ip + float3(1,0,1));
    float c011 = hash_3d(ip + float3(0,1,1));
    float c111 = hash_3d(ip + float3(1,1,1));

    float n0 = lerp(lerp(c000, c100, f.x), lerp(c010, c110, f.x), f.y);
    float n1 = lerp(lerp(c001, c101, f.x), lerp(c011, c111, f.x), f.y);
    return lerp(n0, n1, f.z);
}

// ============================================================
//  Cloud phase functions
//  Ref: clouds.glsl:14-30
// ============================================================

// Ref: utility/phase_functions.glsl:34-36 — Klein-Nishina phase
float phase_klein_nishina(float nu, float e) {
    return e / (MY_TAU * (e - e * nu + 1.0) * log(2.0 * e + 1.0));
}

// Ref: clouds.glsl:14-17 — single scattering: 80% KN forward + 20% HG backward
float clouds_phase_single(float cos_theta) {
    return 0.8 * phase_klein_nishina(cos_theta, 2600.0)
         + 0.2 * phase_hg(cos_theta, -0.2);
}

// Ref: clouds.glsl:19-23 — multi scattering: 3-lobe HG
float clouds_phase_multi(float cos_theta, float3 g) {
    return 0.65 * phase_hg(cos_theta,  g.x)
         + 0.10 * phase_hg(cos_theta,  g.y)
         + 0.25 * phase_hg(cos_theta, -g.z);
}

// Ref: clouds.glsl:25-29 — powder effect (energy redistribution)
float clouds_powder(float density, float cos_theta) {
    float powder = MY_PI * density / (density + 0.15);
    powder = lerp(powder, 1.0, 0.8 * sqr(cos_theta * 0.5 + 0.5));
    return powder;
}

// ============================================================
//  Spherical shell intersection (for cloud layer bounds)
//  Ref: utility/geometry.glsl:68-82
// ============================================================
float2 intersect_shell(float3 ro, float3 rd, float r_inner, float r_outer) {
    float b_i = dot(ro, rd);
    float c_i = dot(ro, ro) - r_inner * r_inner;
    float d_i = b_i * b_i - c_i;
    float2 inner_d = d_i >= 0.0 ? -b_i + float2(-1,1) * sqrt(d_i) : float2(-1,-1);

    float c_o = dot(ro, ro) - r_outer * r_outer;
    float d_o = b_i * b_i - c_o;
    float2 outer_d = d_o >= 0.0 ? -b_i + float2(-1,1) * sqrt(d_o) : float2(-1,-1);

    if (outer_d.y < 0.0) return float2(-1,-1);

    float near = (inner_d.y >= 0.0 && inner_d.x < 0.0) ? inner_d.y : max(outer_d.x, 0.0);
    float far  = (inner_d.y >= 0.0 && inner_d.x > 0.0) ? inner_d.x : outer_d.y;
    return float2(near, far);
}

// ============================================================
//  Cumulus cloud density
//  Ref: clouds.glsl:96-145
// ============================================================
float cloud_density_cu(float3 pos, float cu_radius, float cu_thick, float coverage) {
    float r = length(pos);
    if (r < cu_radius || r > cu_radius + cu_thick) return 0.0;

    // clouds.glsl:104 — altitude fraction within cloud layer
    float alt_frac = (r - cu_radius) / cu_thick;

    // Wind offset — clouds.glsl:106
    float wind_angle = 30.0 * (MY_TAU / 360.0);
    float2 wind_vel = _CloudsSpeed * 15.0 * float2(cos(wind_angle), sin(wind_angle));
    float2 xz = pos.xz + wind_vel * _FrameTime;

    // clouds.glsl:109-111 — 2D noise for shape + coverage (replaces noisetex)
    // Photon's UV scales are for MC world coords (~1e5 range). In our skybox
    // atmosphere space, xz spans ~-20000 to +20000m. We scale up to get
    // visible cloud variation across the sky.
    float n_coverage = fbm2(xz * 0.0003);
    float n_shape = value_noise(xz * 0.004);

    // clouds.glsl:114-116 — density from coverage and shape
    float density = lerp(coverage * 0.5, coverage, n_coverage);
    density = linear_step(1.0 - density, 1.0, n_shape);

    // clouds.glsl:86-93 — altitude shaping (egg shape)
    density -= smoothstep(0.2, 1.0, alt_frac) * 0.6;
    density *= smoothstep(0.0, 0.2, alt_frac);

    if (density < 1e-4) return 0.0;

    // clouds.glsl:126-131 — 3D detail erosion (replaces Worley texture)
    float detail = value_noise_3d(pos * 0.002);
    density -= 0.33 * detail * detail * saturate(1.0 - density);

    // clouds.glsl:140-142 — final shaping
    density = max(density, 0.0);
    density = 1.0 - pow(max(1.0 - density, 0.0), lerp(3.0, 8.0, alt_frac));
    density *= 0.1 + 0.9 * smoothstep(0.2, 0.7, alt_frac);

    return density;
}

// ============================================================
//  Cloud optical depth along a ray (lighting)
//  Ref: clouds.glsl:147-167
// ============================================================
float cloud_optical_depth(float3 ro, float3 rd, float cu_radius, float cu_thick,
                          float coverage, float ext_coeff, int steps) {
    // clouds.glsl:153 — exponential step growth
    float step_len = 0.1 * cu_thick / (float)steps;
    float od = 0.0;
    float3 ray_pos = ro;
    float4 ray_step = float4(rd, 1.0) * step_len;

    for (int j = 0; j < steps; j++) {
        ray_step *= 2.0; // clouds.glsl:153 — step_growth = 2.0
        ray_pos += ray_step.xyz;
        od += cloud_density_cu(ray_pos, cu_radius, cu_thick, coverage) * ray_step.w;
    }
    return od;
}

// ============================================================
//  Cloud scattering (8-octave multi-scatter approximation)
//  Ref: clouds.glsl:170-206
// ============================================================
float2 cloud_scattering(float density, float light_od, float sky_od, float ground_od,
                        float step_trans, float cos_theta, float bounced,
                        float scat_coeff, float ext_coeff) {
    float2 scat = float2(0, 0);
    float scatter_amt = scat_coeff;
    float extinct_amt = ext_coeff;
    float integral = (1.0 - step_trans) / ext_coeff;

    float powder = clouds_powder(density, cos_theta);
    float phase = clouds_phase_single(cos_theta);
    float3 pg = pow(float3(0.6, 0.9, 0.3), max(float3(1,1,1) + light_od, 0.0));

    // clouds.glsl:191-203 — 8-octave scattering loop
    for (int k = 0; k < 8; k++) {
        scat.x += scatter_amt * exp(-extinct_amt * light_od) * phase;
        scat.x += scatter_amt * exp(-extinct_amt * ground_od) * (MY_RCP_PI * 0.25) * bounced;
        scat.y += scatter_amt * exp(-extinct_amt * sky_od) * (MY_RCP_PI * 0.25);

        // clouds.glsl:196-202 — energy decay per octave
        float lift_val = saturate(scat_coeff / 0.1);
        lift_val = (lift_val + lift_val * 0.33) / (1.0 + lift_val * 0.33); // lift() function
        scatter_amt *= 0.55 * lerp(lift_val, 1.0, cos_theta * 0.5 + 0.5) * powder;
        extinct_amt *= 0.4;
        pg *= 0.8;
        powder = lerp(powder, sqrt(powder), 0.5);
        phase = clouds_phase_multi(cos_theta, pg);
    }

    return scat * integral;
}

// ============================================================
//  Draw cumulus clouds — main ray march
//  Ref: clouds.glsl:208-327
// ============================================================
float4 draw_clouds_cu(float3 rd, float3 clear_sky, float3 sun_dir, float3 moon_dir,
                      float3 sun_irr, float3 sky_col, float dither) {
    // Cloud layer parameters — Ref: clouds.glsl:78-83, settings.glsl:119-131
    float cu_radius = R_PLANET + _CloudsAltitude;
    float cu_thick  = _CloudsAltitude * _CloudsThickness;
    float coverage  = _CloudsCoverage;
    if (coverage < 0.01) return float4(0, 0, 0, 1);

    float day_factor = smoothstep(0.0, 0.3, abs(sun_dir.y));
    float ext_coeff = lerp(0.05, 0.1, day_factor) * (1.0 - 0.33 * _RainStrength) * 1.0;
    float scat_coeff = ext_coeff * lerp(1.0, 0.66, _RainStrength);

    // clouds.glsl:230-232 — viewer position in atmosphere space
    float3 viewer = float3(0, R_PLANET, 0);

    // Ray-shell intersection — clouds.glsl:235
    float2 dists = intersect_shell(viewer, rd, cu_radius, cu_radius + cu_thick);
    if (dists.y < 0.0) return float4(0, 0, 0, 1);
    // Skip if looking down through planet — clouds.glsl:238-240
    float2 planet_hit = intersect_shell(viewer, rd, 0, R_PLANET);
    if (planet_hit.y >= 0.0 && planet_hit.x >= 0.0 && length(viewer) < cu_radius)
        return float4(0, 0, 0, 1);

    // clouds.glsl:227 — adaptive step count
    const int STEPS_H = 16;
    const int STEPS_Z = 8;
    int primary_steps = (int)lerp((float)STEPS_H, (float)STEPS_Z, abs(rd.y));
    primary_steps = max(primary_steps, 4);

    float ray_len = min(dists.y - dists.x, 20000.0); // clouds.glsl:222 — max 20km
    float step_len = ray_len / (float)primary_steps;
    float3 ray_step = rd * step_len;
    float3 ray_origin = viewer + rd * (dists.x + step_len * dither);

    // clouds.glsl:259-262 — lighting setup
    bool moonlit = sun_dir.y < -0.04;
    float3 light_dir = moonlit ? moon_dir : sun_dir;
    float cos_theta = dot(rd, light_dir);
    float bounced = 0.4 * max(light_dir.y, 0.0) * MY_RCP_PI; // planet_albedo=0.4

    float2 total_scat = float2(0, 0);
    float transmittance = 1.0;
    const float min_trans = 0.075; // clouds.glsl:223

    // clouds.glsl:268-313 — primary ray march
    for (int s = 0; s < 24; s++) { // max unrolled iterations
        if (s >= primary_steps) break;
        if (transmittance < min_trans) break;

        float3 ray_pos = ray_origin + ray_step * s;
        float alt_frac = (length(ray_pos) - cu_radius) / cu_thick;

        float density = cloud_density_cu(ray_pos, cu_radius, cu_thick, coverage);
        if (density < 1e-4) continue;

        // clouds.glsl:280-283 — distance fade
        float dist_to_sample = length(ray_pos - ray_origin);
        density *= 1.0 - smoothstep(0.95, 1.0, dist_to_sample / 20000.0);

        float step_od = density * ext_coeff * step_len;
        float step_trans = exp(-step_od);

        // clouds.glsl:294-296 — lighting optical depths
        float light_od = cloud_optical_depth(ray_pos, light_dir, cu_radius, cu_thick, coverage, ext_coeff, 3);
        float sky_od = cloud_optical_depth(ray_pos, float3(0,1,0), cu_radius, cu_thick, coverage, ext_coeff, 2);
        float ground_od = lerp(density, 1.0, saturate(alt_frac * 2.0 - 1.0)) * alt_frac * cu_thick;

        // clouds.glsl:298-306 — scattering contribution
        total_scat += cloud_scattering(
            density, light_od, sky_od, ground_od,
            step_trans, cos_theta, bounced,
            scat_coeff, ext_coeff
        ) * transmittance;

        transmittance *= step_trans;
    }

    // clouds.glsl:315-323 — light color and final compositing
    float3 light_col = moonlit ? (0.15 * SUNLIGHT_COLOR) : sun_irr;
    light_col *= SUNLIGHT_COLOR * atmo_transmittance(light_dir.y, R_PLANET + _CloudsAltitude);
    light_col *= 1.0 - _RainStrength;

    // clouds.glsl:321 — remap transmittance
    float cloud_trans = linear_step(min_trans, 1.0, transmittance);

    // clouds.glsl:323 — combine direct light + skylight
    float3 cloud_scat = total_scat.x * light_col + total_scat.y * sky_col;

    // Simplified aerial perspective — clouds.glsl:324
    // Mix distant clouds toward clear sky color
    cloud_scat = lerp((1.0 - cloud_trans) * clear_sky, cloud_scat,
                      atmo_transmittance(rd.y, R_PLANET));

    return float4(max(cloud_scat, 0.0), cloud_trans);
}

// ============================================================
//  Draw all cloud layers
//  Ref: clouds.glsl:830-853
// ============================================================
float4 draw_clouds(float3 rd, float3 clear_sky, float3 sun_dir, float3 moon_dir,
                   float3 sun_irr, float3 sky_col, float dither) {
    float4 clouds = float4(0, 0, 0, 1);

    // Layer 1: Cumulus — clouds.glsl:833-836
    float4 cu = draw_clouds_cu(rd, clear_sky, sun_dir, moon_dir, sun_irr, sky_col, dither);
    clouds = cu;

    // TODO: Layer 2 (Ac) and Layer 3 (Ci) — to be added in future iteration

    return max(clouds, 0.0);
}

#endif // PHOTON_CLOUDS_INLINE_INCLUDED
