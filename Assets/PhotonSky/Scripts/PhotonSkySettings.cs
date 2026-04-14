using UnityEngine;

namespace PhotonSky
{
    [CreateAssetMenu(fileName = "PhotonSkySettings", menuName = "Photon Sky/Settings")]
    public class PhotonSkySettings : ScriptableObject
    {
        [Header("Day/Night Cycle")]
        [Range(0f, 24f)] public float timeOfDay = 12f;
        [Range(0f, 10f)] public float daySpeed = 1f;
        public bool autoTime = true;

        [Header("Sun")]
        [Range(0.1f, 10f)] public float sunIntensity = 7f;
        public Color sunTintMorning = Color.white;
        public Color sunTintNoon = Color.white;
        public Color sunTintEvening = Color.white;
        [Range(0f, 90f)] public float sunPathTilt = 30f; // Axial tilt in degrees

        [Header("Moon")]
        [Range(0.1f, 5f)] public float moonIntensity = 0.66f;
        public Color moonTint = new Color(0.6f, 0.7f, 1.0f);
        [Range(0f, 1f)] public float moonPhaseBrightness = 1f;

        [Header("Weather")]
        [Range(0f, 1f)] public float rainStrength = 0f;
        [Range(0f, 1f)] public float biomeCave = 0f;
        [Range(0f, 1f)] public float biomeMaySnow = 0f;

        [Header("Clouds - Cumulus (Low)")]
        public bool enableCumulusClouds = true;
        [Range(0f, 1f)] public float cloudsCuCoverageMin = 0.3f;
        [Range(0f, 1f)] public float cloudsCuCoverageMax = 0.6f;
        [Range(500f, 5000f)] public float cloudsCuAltitude = 1500f;
        [Range(0.1f, 1f)] public float cloudsCuThickness = 0.5f;
        [Range(0.01f, 0.2f)] public float cloudsCuDensity = 0.1f;

        [Header("Clouds - Altocumulus (Mid)")]
        public bool enableAltocumulusClouds = true;
        [Range(0f, 1f)] public float cloudsAcCoverageMin = 0.2f;
        [Range(0f, 1f)] public float cloudsAcCoverageMax = 0.5f;
        [Range(2000f, 8000f)] public float cloudsAcAltitude = 3000f;
        [Range(0.1f, 1f)] public float cloudsAcThickness = 0.25f;

        [Header("Clouds - Cirrus (High)")]
        public bool enableCirrusClouds = true;
        [Range(0f, 1f)] public float cloudsCiCoverageMin = 0.3f;
        [Range(0f, 1f)] public float cloudsCiCoverageMax = 0.5f;
        [Range(8000f, 15000f)] public float cloudsCiAltitude = 10000f;
    }
}
