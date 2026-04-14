using UnityEngine;
using UnityEngine.Rendering;

namespace PhotonSky
{
    /// <summary>
    /// Generates noise textures used by the cloud system.
    /// Replaces Minecraft's noisetex (2D), colortex6 (3D Worley), and colortex7 (3D Curl).
    /// Baked once at initialization.
    /// </summary>
    public class NoiseTextureBaker : MonoBehaviour
    {
        [Header("Compute Shader")]
        public ComputeShader noiseCompute;

        [Header("Resolution")]
        public int resolution2D = 256;
        public int resolution3D = 64;

        public RenderTexture NoiseTex2D { get; private set; }
        public RenderTexture WorleyTex3D { get; private set; }
        public RenderTexture CurlTex3D { get; private set; }

        private int _kernelNoise2D;
        private int _kernelWorley3D;
        private int _kernelCurl3D;
        private bool _baked;

        public void Initialize()
        {
            if (noiseCompute == null)
            {
                Debug.LogError("[PhotonSky] NoiseGenerator compute shader not assigned!");
                return;
            }

            _kernelNoise2D = noiseCompute.FindKernel("GenerateNoise2D");
            _kernelWorley3D = noiseCompute.FindKernel("GenerateWorley3D");
            _kernelCurl3D = noiseCompute.FindKernel("GenerateCurl3D");

            CreateTextures();
            BakeAll();
        }

        private void CreateTextures()
        {
            if (NoiseTex2D != null) NoiseTex2D.Release();
            NoiseTex2D = new RenderTexture(resolution2D, resolution2D, 0, RenderTextureFormat.ARGBHalf)
            {
                enableRandomWrite = true,
                filterMode = FilterMode.Bilinear,
                wrapMode = TextureWrapMode.Repeat,
                name = "Photon_NoiseTex2D"
            };
            NoiseTex2D.Create();

            if (WorleyTex3D != null) WorleyTex3D.Release();
            WorleyTex3D = new RenderTexture(resolution3D, resolution3D, 0, RenderTextureFormat.ARGBHalf)
            {
                dimension = TextureDimension.Tex3D,
                volumeDepth = resolution3D,
                enableRandomWrite = true,
                filterMode = FilterMode.Bilinear,
                wrapMode = TextureWrapMode.Repeat,
                name = "Photon_WorleyTex3D"
            };
            WorleyTex3D.Create();

            if (CurlTex3D != null) CurlTex3D.Release();
            CurlTex3D = new RenderTexture(resolution3D, resolution3D, 0, RenderTextureFormat.ARGBHalf)
            {
                dimension = TextureDimension.Tex3D,
                volumeDepth = resolution3D,
                enableRandomWrite = true,
                filterMode = FilterMode.Bilinear,
                wrapMode = TextureWrapMode.Repeat,
                name = "Photon_CurlTex3D"
            };
            CurlTex3D.Create();
        }

        private void BakeAll()
        {
            if (_baked) return;

            noiseCompute.SetInt("_NoiseResolution2D", resolution2D);
            noiseCompute.SetInt("_NoiseResolution3D", resolution3D);

            // 2D noise
            noiseCompute.SetTexture(_kernelNoise2D, "_NoiseTex2D", NoiseTex2D);
            int groups2D = Mathf.CeilToInt(resolution2D / 8f);
            noiseCompute.Dispatch(_kernelNoise2D, groups2D, groups2D, 1);

            // 3D Worley
            noiseCompute.SetTexture(_kernelWorley3D, "_WorleyTex3D", WorleyTex3D);
            int groups3D = Mathf.CeilToInt(resolution3D / 4f);
            noiseCompute.Dispatch(_kernelWorley3D, groups3D, groups3D, groups3D);

            // 3D Curl
            noiseCompute.SetTexture(_kernelCurl3D, "_CurlTex3D", CurlTex3D);
            noiseCompute.Dispatch(_kernelCurl3D, groups3D, groups3D, groups3D);

            _baked = true;
        }

        public void Cleanup()
        {
            if (NoiseTex2D != null) { NoiseTex2D.Release(); NoiseTex2D = null; }
            if (WorleyTex3D != null) { WorleyTex3D.Release(); WorleyTex3D = null; }
            if (CurlTex3D != null) { CurlTex3D.Release(); CurlTex3D = null; }
            _baked = false;
        }
    }
}
