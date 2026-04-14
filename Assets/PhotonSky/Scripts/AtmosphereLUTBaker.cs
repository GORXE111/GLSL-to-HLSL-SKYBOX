using UnityEngine;
using UnityEngine.Rendering;

namespace PhotonSky
{
    /// <summary>
    /// Manages atmosphere LUT precomputation via compute shaders.
    /// Transmittance LUT: baked once (256x64, RGBAHalf)
    /// Scattering LUT: re-baked when sun direction changes significantly (32x64x32, RGBAHalf)
    /// </summary>
    public class AtmosphereLUTBaker : MonoBehaviour
    {
        [Header("Compute Shader")]
        public ComputeShader atmosphereCompute;

        [Header("Debug")]
        public bool forceRebake = false;

        // LUT render textures
        public RenderTexture TransmittanceLUT { get; private set; }
        public RenderTexture ScatteringLUT { get; private set; }

        private int _kernelTransmittance;
        private int _kernelScattering;
        private bool _transmittanceBaked;
        private Vector3 _lastSunDir;
        private const float SunDirChangeThreshold = 0.001f;

        // LUT resolutions (must match shader constants)
        private const int TransmittanceResX = 256;
        private const int TransmittanceResY = 64;
        private const int ScatteringResX = 32; // nu*2
        private const int ScatteringResY = 64; // mu
        private const int ScatteringResZ = 32; // mu_s

        public void Initialize()
        {
            if (atmosphereCompute == null)
            {
                Debug.LogError("[PhotonSky] AtmosphereLUT compute shader not assigned!");
                return;
            }

            _kernelTransmittance = atmosphereCompute.FindKernel("BakeTransmittance");
            _kernelScattering = atmosphereCompute.FindKernel("BakeScattering");

            CreateRenderTextures();
            _transmittanceBaked = false;
            _lastSunDir = Vector3.zero;
        }

        private void CreateRenderTextures()
        {
            // Transmittance LUT: 2D, 256x64
            if (TransmittanceLUT != null) TransmittanceLUT.Release();
            TransmittanceLUT = new RenderTexture(TransmittanceResX, TransmittanceResY, 0, RenderTextureFormat.ARGBHalf)
            {
                enableRandomWrite = true,
                filterMode = FilterMode.Bilinear,
                wrapMode = TextureWrapMode.Clamp,
                name = "Photon_TransmittanceLUT"
            };
            TransmittanceLUT.Create();

            // Scattering LUT: 3D, 32x64x32
            if (ScatteringLUT != null) ScatteringLUT.Release();
            ScatteringLUT = new RenderTexture(ScatteringResX, ScatteringResY, 0, RenderTextureFormat.ARGBHalf)
            {
                dimension = TextureDimension.Tex3D,
                volumeDepth = ScatteringResZ,
                enableRandomWrite = true,
                filterMode = FilterMode.Bilinear,
                wrapMode = TextureWrapMode.Clamp,
                name = "Photon_ScatteringLUT"
            };
            ScatteringLUT.Create();
        }

        public void BakeTransmittance()
        {
            if (_transmittanceBaked && !forceRebake) return;

            atmosphereCompute.SetTexture(_kernelTransmittance, "_TransmittanceLUT", TransmittanceLUT);

            int groupsX = Mathf.CeilToInt(TransmittanceResX / 8f);
            int groupsY = Mathf.CeilToInt(TransmittanceResY / 8f);
            atmosphereCompute.Dispatch(_kernelTransmittance, groupsX, groupsY, 1);

            _transmittanceBaked = true;
        }

        public void BakeScattering(Vector3 sunDir)
        {
            if (!_transmittanceBaked || TransmittanceLUT == null || ScatteringLUT == null) return;
            if (!forceRebake && Vector3.Distance(sunDir, _lastSunDir) < SunDirChangeThreshold) return;

            // Scattering kernel needs to read the transmittance LUT
            atmosphereCompute.SetTexture(_kernelScattering, "_TransmittanceLUTRead", TransmittanceLUT);
            atmosphereCompute.SetTexture(_kernelScattering, "_ScatteringLUT", ScatteringLUT);
            atmosphereCompute.SetVector("_SunDir", sunDir);

            int groupsX = Mathf.CeilToInt(ScatteringResX / 4f);
            int groupsY = Mathf.CeilToInt(ScatteringResY / 4f);
            int groupsZ = Mathf.CeilToInt(ScatteringResZ / 4f);
            atmosphereCompute.Dispatch(_kernelScattering, groupsX, groupsY, groupsZ);

            _lastSunDir = sunDir;
            forceRebake = false;
        }

        public void Cleanup()
        {
            if (TransmittanceLUT != null) { TransmittanceLUT.Release(); TransmittanceLUT = null; }
            if (ScatteringLUT != null) { ScatteringLUT.Release(); ScatteringLUT = null; }
            _transmittanceBaked = false;
        }
    }
}
