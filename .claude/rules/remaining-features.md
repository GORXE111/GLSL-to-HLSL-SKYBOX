# Remaining Features — Photon → Unity Port

## Priority 🔴 HIGH

### 1. Volumetric Cumulus Clouds (Cu)
- **Source:** `clouds.glsl:77-327`
- **Status:** ❌ Not connected (Clouds.hlsl exists but has broken matrix deps)
- **Technique:** 40-step ray march, Worley noise detail, curl distortion, altitude shaping, powder effect, 8-octave multi-scattering, aerial perspective
- **Dependencies:** Noise textures (noisetex → 2D, colortex6 → 3D Worley, colortex7 → 3D Curl)
- **Parameters:** Coverage, altitude 1500m, thickness, density, wind angle/speed (settings.glsl:119-132)

### 2. Volumetric Altocumulus Clouds (Ac)
- **Source:** `clouds.glsl:342-586`
- **Status:** ❌ Not connected
- **Technique:** 12-step ray march, same noise system, thinner/sparser than Cu
- **Parameters:** Coverage, altitude 3000m, thickness (settings.glsl:134-147)

### 3. Volumetric Cirrus Clouds (Ci)
- **Source:** `clouds.glsl:600-828`
- **Status:** ❌ Not connected
- **Technique:** Planar (not volumetric ray march), curl noise distortion, 4-octave detail erosion
- **Parameters:** Coverage, altitude 10000m, thickness 1500m (settings.glsl:149-164)

### 4. Volumetric Fog + God Rays
- **Source:** `fog/air_fog_vl.glsl`
- **Status:** ❌ Not started
- **Technique:** 8-25 step ray march, Rayleigh+Mie in air, shadow-mapped directionality, noise density variation
- **Needs:** ScriptableRenderFeature (separate pass at half-res)

## Priority 🟡 MEDIUM

### 5. Cloud Shadows
- **Source:** `light/cloud_shadows.glsl`
- **Status:** ❌ Not started
- **Technique:** Render cloud density into 256x256 shadow texture, fisheye projection, applied to terrain

### 6. CAS Sharpening
- **Source:** `post/final.glsl`
- **Status:** ❌ Not started
- **Technique:** FidelityFX Contrast Adaptive Sharpening, 3x3 neighborhood

### 7. Motion Blur
- **Source:** `post/motion_blur.glsl`
- **Status:** ❌ Not started
- **Technique:** Temporal reprojection, 20-sample blur along motion vectors

## Priority 🟢 LOW

### 8. Depth of Field
- **Source:** `post/dof.glsl`
- **Status:** ❌ Not started

### 9. TAA + Auto Exposure
- **Source:** `post/temporal.glsl`
- **Status:** ❌ Not started
- **Technique:** Jitter accumulation, histogram-based luminance for exposure

### 10. FXAA
- **Source:** `post/fxaa.glsl`
- **Status:** ❌ Not started (URP has built-in option)

## Completed ✅

- Atmosphere scattering (32-step ray march, Chapman transmittance)
- Sun disk + limb darkening (sky.glsl:20-29)
- Star field + twinkle (sky.glsl:32-86)
- Rayleigh phase with depolarization (phase_functions.glsl:8-16)
- Mie HG phase g=0.77 (phase_functions.glsl:18-22)
- Lottes tonemap (grade.glsl:236-253)
- Color grading pre/post tonemap (grade.glsl:119-186)
- Time-varying exposure (light_color.glsl:10-18)
- Multi-scale bloom (post/bloom/*.glsl)
- Day/night cycle with sun/moon
- Rain/weather sky blend
