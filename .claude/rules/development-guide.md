# PhotonSky Development Guide

## Project Overview

Unity URP port of **Photon Shaders** (Minecraft OptiFine/Iris shader pack by SixthSurge).
Goal: replicate Photon's sky, atmosphere, clouds, and post-processing in Unity 2022.3 URP.

Original source: `E:\photon-main\photon-main\shaders\`

## Architecture

```
Assets/PhotonSky/
├── Shaders/
│   ├── PhotonSkybox.shader       — Main skybox (atmosphere + sun + stars + weather)
│   ├── PhotonSkyboxDebug.shader  — Standalone debug version (no C# deps)
│   ├── PhotonBloom.shader        — Multi-pass bloom post-process
│   ├── NoiseGenerator.compute    — Procedural noise for clouds
│   ├── AtmosphereLUT.compute     — Precomputed transmittance/scattering (NOT YET WORKING)
│   └── Include/                  — HLSL modules (currently unused by main shader)
├── Scripts/
│   ├── PhotonSkyManager.cs       — Day/night cycle, uniform management
│   ├── PhotonBloomFeature.cs     — URP ScriptableRendererFeature for bloom
│   ├── AtmosphereLUTBaker.cs     — Compute shader dispatcher (NOT YET WORKING)
│   ├── NoiseTextureBaker.cs      — Noise texture generator
│   └── PhotonSkySettings.cs      — ScriptableObject configuration
└── Settings/
```

## Critical Rules

### 1. Source Traceability (MANDATORY)

Every ported function, constant, or algorithm MUST reference the original Photon source:

```hlsl
// Ref: photon/shaders/include/sky/atmosphere.glsl:26
static const float R_PLANET = 6371e3;
```

Format: `Ref: photon/shaders/<path>:<line_numbers> — <brief description>`

This is non-negotiable. Without references:
- We can't verify correctness against the original
- We can't debug divergences
- We can't iterate quality

### 2. GLSL → HLSL Matrix Convention

**THIS CAUSED WEEKS OF BUGS. DO NOT DEVIATE.**

Current working approach (in PhotonSkybox.shader):
- All coefficients and matrices are **hardcoded inline** in the shader
- NO dependency on ColorSpace.hlsl or Atmosphere.hlsl for the main rendering path
- If matrices are needed, use `mul(M, v)` with properly constructed HLSL row-major matrices
- Test with PhotonSkyboxDebug.shader first (zero external deps)

The Include/ directory files (ColorSpace.hlsl, Atmosphere.hlsl, etc.) have KNOWN matrix bugs.
Do NOT use them in the main shader until the `mul(v, M)` vs `mul(M, v)` issue is resolved.

If you must use color space transforms:
- GLSL `vec * mat` = HLSL `mul(v, M)` when constructor values are identical
- GLSL `mat * mat` composite `A * B` = HLSL `mul(B, A)` (REVERSED) with same constructor values
- OR: transpose constructor values and use `mul(M, v)` with same composite order
- ALWAYS verify numerically before using

### 3. Incremental Bring-Up

When adding new features:
1. First implement in PhotonSkyboxDebug.shader (standalone, no C# deps)
2. Verify visually that it matches Photon
3. Then integrate into PhotonSkybox.shader with C# uniform support
4. Never skip step 1 — the debug shader is the ground truth

### 4. Git Conventions

- Author name for all commits: **nike**
- Never include Co-Authored-By lines
- Commit messages: describe what was ported and reference Photon source files
- Push to: https://github.com/GORXE111/GLSL-to-HLSL-SKYBOX.git

Before pushing:
```bash
git filter-branch -f --env-filter '
export GIT_AUTHOR_NAME="nike"
export GIT_AUTHOR_EMAIL="nike@users.noreply.github.com"
export GIT_COMMITTER_NAME="nike"
export GIT_COMMITTER_EMAIL="nike@users.noreply.github.com"
' HEAD
```

### 5. Unity Project Settings

- Color Space: **Linear** (m_ActiveColorSpace: 1 in ProjectSettings.asset)
- Render Pipeline: URP 14.x
- Target: Unity 2022.3.62f3

## Feature Status

| Feature | Status | Photon Source | Notes |
|---------|--------|---------------|-------|
| Atmosphere scattering (analytic) | ✅ Working | sky/atmosphere.glsl | 32-step ray march, Chapman transmittance |
| Sun disk + limb darkening | ✅ Working | sky/sky.glsl:20-29 | |
| Star field + twinkle | ✅ Working | sky/sky.glsl:32-86 | |
| Rayleigh phase (depolarized) | ✅ Working | utility/phase_functions.glsl:8-16 | |
| Mie HG phase (g=0.77) | ✅ Working | utility/phase_functions.glsl:18-22 | |
| ACES tonemap (Hill fit) | ✅ Working | aces/aces.glsl:202-207 | Simplified, not full RRT+ODT |
| Day/night cycle (C#) | ✅ Working | | timeOfDay 0-24 mapping |
| Rain/weather blend | ✅ Implemented | sky/sky.glsl:149-150 | Untested |
| Bloom (multi-scale) | ⚠️ Implemented | post/bloom/*.glsl | Needs testing in Unity |
| Atmosphere LUT (precomputed) | ❌ Broken | sky/atmosphere.glsl:80-295 | Matrix bugs, use analytic path |
| Clouds - Cumulus | ❌ Implemented | sky/clouds.glsl:77-327 | Not connected to main shader |
| Clouds - Altocumulus | ❌ Implemented | sky/clouds.glsl:342-586 | Not connected to main shader |
| Clouds - Cirrus | ❌ Implemented | sky/clouds.glsl:600-828 | Not connected to main shader |
| Rec.2020 color space | ❌ Broken | utility/color.glsl | Matrix convention issue |
| Full ACES (RRT+ODT) | ❌ Broken | aces/aces.glsl | Depends on working matrices |
| Cloud shadows | ❌ Not started | sky/clouds.glsl:855-889 | |
| Color grading | ❌ Not started | post/grade.glsl:113-186 | |

## Photon Source File Map

Key source files and what they contain:

| Photon File | Contents | Unity Port |
|-------------|----------|------------|
| `include/sky/atmosphere.glsl` | Planet/atmo params, density, transmittance, scattering LUT | Inline in PhotonSkybox.shader |
| `include/sky/sky.glsl` | draw_sky(), sun disk, stars, cloud integration | Inline in PhotonSkybox.shader |
| `include/sky/clouds.glsl` | 3-layer volumetric clouds (Cu/Ac/Ci) | Include/Clouds.hlsl (not connected) |
| `include/sky/projection.glsl` | Sky map projection (Hillaire 2020) | Include/Projection.hlsl |
| `include/utility/phase_functions.glsl` | Rayleigh, HG, Klein-Nishina, bilambertian | Inline in PhotonSkybox.shader |
| `include/utility/fast_math.glsl` | fast_acos, pow variants | Inline in PhotonSkybox.shader |
| `include/utility/geometry.glsl` | Sphere/AABB intersection | Include/Geometry.hlsl |
| `include/utility/color.glsl` | Color space matrices, blackbody, HSL | Include/ColorSpace.hlsl (BROKEN) |
| `include/utility/random.glsl` | Hash functions, quasirandom sequences | Include/Random.hlsl |
| `include/aces/aces.glsl` | Full ACES RRT+ODT + Hill fit | Include/ACES.hlsl (partially working) |
| `include/light/colors/light_color.glsl` | Sun/moon exposure, tint, blue hour | PhotonSkyManager.cs |
| `include/light/colors/weather_color.glsl` | Rain/snow sky color | PhotonSkyManager.cs |
| `program/post/bloom/*.glsl` | 4-file bloom pipeline | PhotonBloom.shader |
| `program/post/grade.glsl` | Bloom merge, color grading, tonemap selection | Partially in PhotonSkybox.shader |

## Known Issues & Technical Debt

1. **ColorSpace.hlsl matrices are wrong** — GLSL column-major vs HLSL row-major confusion.
   The main shader bypasses this by hardcoding all values inline.
   TODO: Fix properly or remove the Include/ files entirely.

2. **Atmosphere LUT compute shader untested** — AtmosphereLUT.compute may have the same
   matrix issues. Currently unused; analytic path works.

3. **Cloud system not connected** — Clouds.hlsl, CloudCommon.hlsl exist but are not
   integrated into the main shader. They depend on noise textures and broken Include/ files.

4. **Performance** — 32-step ray march per pixel in the skybox is expensive.
   Long-term: get LUT precomputation working to replace real-time integration.

5. **Bloom untested** — PhotonBloomFeature.cs is implemented but not yet verified in Unity.
