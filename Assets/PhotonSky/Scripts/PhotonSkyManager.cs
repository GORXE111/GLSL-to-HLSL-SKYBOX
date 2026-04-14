using UnityEngine;

namespace PhotonSky
{
    /// <summary>
    /// Main controller for the Photon Sky system.
    /// Manages day/night cycle, computes sun/moon directions and colors,
    /// drives atmosphere LUT baking, and updates shader uniforms.
    /// </summary>
    [ExecuteAlways]
    public class PhotonSkyManager : MonoBehaviour
    {
        [Header("References")]
        public PhotonSkySettings settings;
        public Material skyboxMaterial;
        public Light directionalLight;

        [Header("Components")]
        public AtmosphereLUTBaker lutBaker;
        public NoiseTextureBaker noiseBaker;

        // Cached state
        private float _worldAge;
        private static readonly int PropSunDir = Shader.PropertyToID("_SunDir");
        private static readonly int PropMoonDir = Shader.PropertyToID("_MoonDir");
        private static readonly int PropSunColor = Shader.PropertyToID("_SunColor");
        private static readonly int PropMoonColor = Shader.PropertyToID("_MoonColor");
        private static readonly int PropSunAngle = Shader.PropertyToID("_SunAngle");
        private static readonly int PropRainStrength = Shader.PropertyToID("_RainStrength");
        private static readonly int PropFrameTime = Shader.PropertyToID("_FrameTime");
        private static readonly int PropFrameCounter = Shader.PropertyToID("_FrameCounter");
        private static readonly int PropWeatherColor = Shader.PropertyToID("_WeatherColor");
        private static readonly int PropBiomeCave = Shader.PropertyToID("_BiomeCave");
        private static readonly int PropTimeSunrise = Shader.PropertyToID("_TimeSunrise");
        private static readonly int PropTimeSunset = Shader.PropertyToID("_TimeSunset");
        private static readonly int PropTransmittanceLUT = Shader.PropertyToID("_TransmittanceLUT");
        private static readonly int PropScatteringLUT = Shader.PropertyToID("_ScatteringLUT");
        private static readonly int PropStarRotationMatrix = Shader.PropertyToID("_StarRotationMatrix");
        private static readonly int PropAmbientColor = Shader.PropertyToID("_AmbientColor");
        private static readonly int PropSkyColorTint = Shader.PropertyToID("_SkyColorTint");

        // Cloud uniforms
        private static readonly int PropCloudsEnabled = Shader.PropertyToID("_CloudsEnabled");
        private static readonly int PropCloudsCuEnabled = Shader.PropertyToID("_CloudsCuEnabled");
        private static readonly int PropCloudsCuCoverage = Shader.PropertyToID("_CloudsCuCoverage");
        private static readonly int PropCloudsCuAltitude = Shader.PropertyToID("_CloudsCuAltitude");
        private static readonly int PropCloudsCuThickness = Shader.PropertyToID("_CloudsCuThickness");
        private static readonly int PropCloudsCuDensity = Shader.PropertyToID("_CloudsCuDensity");
        private static readonly int PropCloudsAcEnabled = Shader.PropertyToID("_CloudsAcEnabled");
        private static readonly int PropCloudsAcCoverage = Shader.PropertyToID("_CloudsAcCoverage");
        private static readonly int PropCloudsAcAltitude = Shader.PropertyToID("_CloudsAcAltitude");
        private static readonly int PropCloudsAcThickness = Shader.PropertyToID("_CloudsAcThickness");
        private static readonly int PropCloudsCiEnabled = Shader.PropertyToID("_CloudsCiEnabled");
        private static readonly int PropCloudsCiCoverage = Shader.PropertyToID("_CloudsCiCoverage");
        private static readonly int PropCloudsCiAltitude = Shader.PropertyToID("_CloudsCiAltitude");
        private static readonly int PropCloudsCiThickness = Shader.PropertyToID("_CloudsCiThickness");
        private static readonly int PropWorldAge = Shader.PropertyToID("_WorldAge");
        private static readonly int PropCameraPosition = Shader.PropertyToID("_CameraPosition");
        private static readonly int PropEyeAltitude = Shader.PropertyToID("_EyeAltitude");
        private static readonly int PropNoiseTex = Shader.PropertyToID("_NoiseTex");
        private static readonly int PropWorleyTex = Shader.PropertyToID("_WorleyTex");
        private static readonly int PropCurlTex = Shader.PropertyToID("_CurlTex");

        // Sunlight color in space (from AM0 solar irradiance spectrum)
        private static readonly Vector3 SunlightColor = new Vector3(1.051f, 0.985f, 0.940f);

        private void OnEnable()
        {
            if (settings == null)
            {
                Debug.LogWarning("[PhotonSky] Settings asset not assigned.");
                return;
            }

            if (lutBaker != null)
            {
                lutBaker.Initialize();
                lutBaker.BakeTransmittance();
            }

            if (noiseBaker != null)
            {
                noiseBaker.Initialize();
            }
        }

        private void OnDisable()
        {
            if (lutBaker != null)
                lutBaker.Cleanup();
            if (noiseBaker != null)
                noiseBaker.Cleanup();
        }

        private void Update()
        {
            if (settings == null || skyboxMaterial == null) return;

            // Advance time
            if (settings.autoTime && Application.isPlaying)
            {
                settings.timeOfDay += Time.deltaTime * settings.daySpeed * (24f / 600f); // Full day in 600s at speed 1
                if (settings.timeOfDay >= 24f) settings.timeOfDay -= 24f;
            }

            _worldAge += Time.deltaTime;

            // Compute sun/moon directions
            ComputeCelestialDirections(out Vector3 sunDir, out Vector3 moonDir, out float sunAngle);

            // Compute time-of-day weights
            ComputeTimeWeights(sunDir, out float timeSunrise, out float timeSunset);

            // Compute sun/moon colors
            ComputeSunColor(sunDir, sunAngle, timeSunrise, timeSunset, out Vector3 sunColor);
            ComputeMoonColor(out Vector3 moonColor);

            // Compute weather color
            Vector3 weatherColor = ComputeWeatherColor(sunDir);

            // Bake scattering LUT
            if (lutBaker != null)
            {
                lutBaker.BakeScattering(sunDir);
            }

            // Update shader uniforms
            UpdateShaderUniforms(sunDir, moonDir, sunColor, moonColor, sunAngle, weatherColor,
                                timeSunrise, timeSunset);

            // Update directional light
            if (directionalLight != null)
            {
                bool isNight = sunAngle > 0.5f;
                directionalLight.transform.forward = isNight ? moonDir : -sunDir;

                Vector3 lightCol = isNight ? moonColor : sunColor;
                float intensity = Mathf.Max(lightCol.x, Mathf.Max(lightCol.y, lightCol.z));
                if (intensity > 0)
                {
                    directionalLight.color = new Color(lightCol.x / intensity, lightCol.y / intensity, lightCol.z / intensity);
                    directionalLight.intensity = intensity;
                }
                else
                {
                    directionalLight.intensity = 0;
                }
            }

            // Set skybox
            if (RenderSettings.skybox != skyboxMaterial)
                RenderSettings.skybox = skyboxMaterial;
        }

        private void ComputeCelestialDirections(out Vector3 sunDir, out Vector3 moonDir, out float sunAngle)
        {
            // sunAngle: 0 = noon, 0.25 = sunset, 0.5 = midnight, 0.75 = sunrise
            sunAngle = (settings.timeOfDay / 24f + 0.25f) % 1f; // offset so noon=0.5 maps correctly

            float angleRad = sunAngle * 2f * Mathf.PI;
            float tiltRad = settings.sunPathTilt * Mathf.Deg2Rad;

            // Sun orbits in the Y-Z plane, tilted by sunPathTilt
            sunDir = new Vector3(
                Mathf.Sin(tiltRad) * Mathf.Sin(angleRad),
                -Mathf.Cos(angleRad),
                Mathf.Cos(tiltRad) * Mathf.Sin(angleRad)
            ).normalized;

            // Moon is roughly opposite, offset slightly
            moonDir = -sunDir;
            moonDir = new Vector3(moonDir.x, moonDir.y + 0.1f, moonDir.z).normalized;
        }

        private void ComputeTimeWeights(Vector3 sunDir, out float timeSunrise, out float timeSunset)
        {
            // Sunrise/sunset detection based on sun altitude
            float sunAltitude = sunDir.y;

            // Sunrise: sun near horizon going up (morning)
            timeSunrise = Mathf.Clamp01(1f - Mathf.Abs(sunAltitude - 0.15f) / 0.2f);
            timeSunrise *= (settings.timeOfDay < 12f) ? 1f : 0f;

            // Sunset: sun near horizon going down (evening)
            timeSunset = Mathf.Clamp01(1f - Mathf.Abs(sunAltitude - 0.15f) / 0.2f);
            timeSunset *= (settings.timeOfDay >= 12f) ? 1f : 0f;
        }

        private void ComputeSunColor(Vector3 sunDir, float sunAngle, float timeSunrise, float timeSunset, out Vector3 sunColor)
        {
            // Only compute exposure and tint here.
            // Atmospheric transmittance is applied in the shader using the real physical model.
            float baseScale = 7f * settings.sunIntensity;

            // Blue hour effect
            float blueHour = Mathf.Clamp01(Mathf.Exp(-190f * (sunDir.y + 0.09604f) * (sunDir.y + 0.09604f)));
            blueHour = Mathf.Max(0, (blueHour - 0.05f) / 0.95f);

            float daytimeMul = 1f + 0.5f * (timeSunset + timeSunrise) + 40f * blueHour;
            float exposure = baseScale * daytimeMul;

            // Tint interpolation
            Color tint = Color.Lerp(
                Color.Lerp(settings.sunTintNoon, settings.sunTintMorning, timeSunrise),
                settings.sunTintEvening,
                timeSunset
            );

            // Fade away during day/night transition
            float transitionFade = Mathf.Clamp01(sunDir.y / 0.02f);

            // NO atmospheric extinction here — shader handles it
            sunColor = new Vector3(
                exposure * tint.r * SunlightColor.x * transitionFade,
                exposure * tint.g * SunlightColor.y * transitionFade,
                exposure * tint.b * SunlightColor.z * transitionFade
            );
        }

        private void ComputeMoonColor(out Vector3 moonColor)
        {
            float exposure = 0.66f * settings.moonIntensity * settings.moonPhaseBrightness;
            Color tint = settings.moonTint;
            moonColor = new Vector3(
                exposure * tint.r * SunlightColor.x,
                exposure * tint.g * SunlightColor.y,
                exposure * tint.b * SunlightColor.z
            );
        }

        private Vector3 ComputeWeatherColor(Vector3 sunDir)
        {
            float brightness = Mathf.Lerp(0.033f, 0.66f, Mathf.Clamp01((sunDir.y + 0.1f) / 0.6f));
            Vector3 rainColor = brightness * new Vector3(
                SunlightColor.x * 0.49f,
                SunlightColor.y * 0.65f,
                SunlightColor.z * 1.0f
            );

            float snowBrightness = Mathf.Lerp(0.06f, 1.6f, Mathf.Clamp01((sunDir.y + 0.1f) / 0.6f));
            Vector3 snowColor = snowBrightness * new Vector3(
                SunlightColor.x * 0.49f,
                SunlightColor.y * 0.65f,
                SunlightColor.z * 1.0f
            );

            return Vector3.Lerp(rainColor, snowColor, settings.biomeMaySnow);
        }

        private void UpdateShaderUniforms(Vector3 sunDir, Vector3 moonDir, Vector3 sunColor, Vector3 moonColor,
            float sunAngle, Vector3 weatherColor, float timeSunrise, float timeSunset)
        {
            skyboxMaterial.SetVector(PropSunDir, sunDir);
            skyboxMaterial.SetVector(PropMoonDir, moonDir);
            skyboxMaterial.SetVector(PropSunColor, sunColor);
            skyboxMaterial.SetVector(PropMoonColor, moonColor);
            skyboxMaterial.SetFloat(PropSunAngle, sunAngle);
            skyboxMaterial.SetFloat(PropRainStrength, settings.rainStrength);
            skyboxMaterial.SetFloat(PropFrameTime, _worldAge);
            skyboxMaterial.SetInt(PropFrameCounter, Time.frameCount);
            skyboxMaterial.SetVector(PropWeatherColor, weatherColor);
            skyboxMaterial.SetFloat(PropBiomeCave, settings.biomeCave);
            skyboxMaterial.SetFloat(PropTimeSunrise, timeSunrise);
            skyboxMaterial.SetFloat(PropTimeSunset, timeSunset);

            // Star rotation: rotate with celestial sphere
            float starAngle = sunAngle * 360f;
            Matrix4x4 starRot = Matrix4x4.Rotate(Quaternion.Euler(starAngle, 0, settings.sunPathTilt));
            skyboxMaterial.SetMatrix(PropStarRotationMatrix, starRot);

            // Ambient / sky color approximation
            float ambientBrightness = Mathf.Lerp(0.01f, 0.15f, Mathf.Clamp01(sunDir.y + 0.1f));
            Vector3 ambientCol = new Vector3(0.5f, 0.65f, 1.0f) * ambientBrightness;
            skyboxMaterial.SetVector(PropAmbientColor, ambientCol);
            skyboxMaterial.SetVector(PropSkyColorTint, ambientCol * 0.5f);

            // Cloud uniforms
            skyboxMaterial.SetFloat(PropCloudsEnabled, 1f);
            skyboxMaterial.SetFloat(PropCloudsCuEnabled, settings.enableCumulusClouds ? 1f : 0f);
            skyboxMaterial.SetVector(PropCloudsCuCoverage, new Vector2(settings.cloudsCuCoverageMin, settings.cloudsCuCoverageMax));
            skyboxMaterial.SetFloat(PropCloudsCuAltitude, settings.cloudsCuAltitude);
            skyboxMaterial.SetFloat(PropCloudsCuThickness, settings.cloudsCuThickness);
            skyboxMaterial.SetFloat(PropCloudsCuDensity, settings.cloudsCuDensity);

            skyboxMaterial.SetFloat(PropCloudsAcEnabled, settings.enableAltocumulusClouds ? 1f : 0f);
            skyboxMaterial.SetVector(PropCloudsAcCoverage, new Vector2(settings.cloudsAcCoverageMin, settings.cloudsAcCoverageMax));
            skyboxMaterial.SetFloat(PropCloudsAcAltitude, settings.cloudsAcAltitude);
            skyboxMaterial.SetFloat(PropCloudsAcThickness, settings.cloudsAcThickness);

            skyboxMaterial.SetFloat(PropCloudsCiEnabled, settings.enableCirrusClouds ? 1f : 0f);
            skyboxMaterial.SetVector(PropCloudsCiCoverage, new Vector2(settings.cloudsCiCoverageMin, settings.cloudsCiCoverageMax));
            skyboxMaterial.SetFloat(PropCloudsCiAltitude, settings.cloudsCiAltitude);
            skyboxMaterial.SetFloat(PropCloudsCiThickness, 1500f);

            skyboxMaterial.SetFloat(PropWorldAge, _worldAge);

            Camera cam = Camera.main;
            if (cam != null)
            {
                skyboxMaterial.SetVector(PropCameraPosition, cam.transform.position);
                skyboxMaterial.SetFloat(PropEyeAltitude, cam.transform.position.y);
            }
            else
            {
                skyboxMaterial.SetVector(PropCameraPosition, Vector3.zero);
                skyboxMaterial.SetFloat(PropEyeAltitude, 0f);
            }

            // LUT textures
            if (lutBaker != null)
            {
                if (lutBaker.TransmittanceLUT != null)
                    skyboxMaterial.SetTexture(PropTransmittanceLUT, lutBaker.TransmittanceLUT);
                if (lutBaker.ScatteringLUT != null)
                    skyboxMaterial.SetTexture(PropScatteringLUT, lutBaker.ScatteringLUT);
            }

            // Noise textures
            if (noiseBaker != null)
            {
                if (noiseBaker.NoiseTex2D != null)
                    skyboxMaterial.SetTexture(PropNoiseTex, noiseBaker.NoiseTex2D);
                if (noiseBaker.WorleyTex3D != null)
                    skyboxMaterial.SetTexture(PropWorleyTex, noiseBaker.WorleyTex3D);
                if (noiseBaker.CurlTex3D != null)
                    skyboxMaterial.SetTexture(PropCurlTex, noiseBaker.CurlTex3D);
            }
        }
    }
}
