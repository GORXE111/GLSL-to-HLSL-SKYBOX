using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;

namespace PhotonSky
{
    /// <summary>
    /// URP Renderer Feature for Photon's multi-scale bloom.
    /// Implements the Sledgehammer/COD Advanced Warfare bloom technique:
    /// - Progressive downsample with 6x6 kernel
    /// - 9-tap gaussian blur (H+V) at each mip level
    /// - Progressive upsample with tent filter, combining mip levels
    /// - Final composite: mix(scene, bloom, intensity)
    /// </summary>
    public class PhotonBloomFeature : ScriptableRendererFeature
    {
        [System.Serializable]
        public class BloomSettings
        {
            [Range(0f, 1f)] public float threshold = 0.8f;
            [Range(0f, 1f)] public float intensity = 0.15f;
            [Range(0f, 2f)] public float radius = 1.0f;
            [Range(2, 6)] public int mipCount = 5;
        }

        public BloomSettings settings = new BloomSettings();
        public Shader bloomShader;

        private PhotonBloomPass _bloomPass;
        private Material _bloomMaterial;

        public override void Create()
        {
            if (bloomShader == null)
                bloomShader = Shader.Find("Hidden/Photon/Bloom");

            if (bloomShader != null)
                _bloomMaterial = CoreUtils.CreateEngineMaterial(bloomShader);

            _bloomPass = new PhotonBloomPass(_bloomMaterial, settings);
            _bloomPass.renderPassEvent = RenderPassEvent.BeforeRenderingPostProcessing;
        }

        public override void AddRenderPasses(ScriptableRenderer renderer, ref RenderingData renderingData)
        {
            if (_bloomMaterial == null) return;
            if (renderingData.cameraData.cameraType != CameraType.Game &&
                renderingData.cameraData.cameraType != CameraType.SceneView) return;

            _bloomPass.Setup(settings);
            renderer.EnqueuePass(_bloomPass);
        }

        protected override void Dispose(bool disposing)
        {
            CoreUtils.Destroy(_bloomMaterial);
        }
    }

    public class PhotonBloomPass : ScriptableRenderPass
    {
        private Material _material;
        private PhotonBloomFeature.BloomSettings _settings;

        // Pass indices matching PhotonBloom.shader
        private const int PassPrefilter = 0;
        private const int PassBlurH     = 1;
        private const int PassBlurV     = 2;
        private const int PassUpsample  = 3;
        private const int PassComposite = 4;

        private static readonly int BloomThresholdId = Shader.PropertyToID("_BloomThreshold");
        private static readonly int BloomIntensityId = Shader.PropertyToID("_BloomIntensity");
        private static readonly int BloomRadiusId    = Shader.PropertyToID("_BloomRadius");
        private static readonly int BloomLowMipId    = Shader.PropertyToID("_BloomLowMip");

        private RTHandle[] _mipDown;
        private RTHandle[] _mipUp;

        public PhotonBloomPass(Material material, PhotonBloomFeature.BloomSettings settings)
        {
            _material = material;
            _settings = settings;
            _mipDown = new RTHandle[7];
            _mipUp = new RTHandle[7];
        }

        public void Setup(PhotonBloomFeature.BloomSettings settings)
        {
            _settings = settings;
        }

        public override void OnCameraSetup(CommandBuffer cmd, ref RenderingData renderingData)
        {
            var desc = renderingData.cameraData.cameraTargetDescriptor;
            desc.depthBufferBits = 0;
            desc.msaaSamples = 1;
            desc.colorFormat = RenderTextureFormat.DefaultHDR;

            int w = desc.width;
            int h = desc.height;

            for (int i = 0; i < _settings.mipCount; i++)
            {
                w = Mathf.Max(w / 2, 1);
                h = Mathf.Max(h / 2, 1);

                var mipDesc = desc;
                mipDesc.width = w;
                mipDesc.height = h;

                RenderingUtils.ReAllocateIfNeeded(ref _mipDown[i], mipDesc, FilterMode.Bilinear, name: $"_BloomMipDown{i}");
                RenderingUtils.ReAllocateIfNeeded(ref _mipUp[i], mipDesc, FilterMode.Bilinear, name: $"_BloomMipUp{i}");
            }
        }

        public override void Execute(ScriptableRenderContext context, ref RenderingData renderingData)
        {
            if (_material == null || _settings.intensity <= 0) return;

            CommandBuffer cmd = CommandBufferPool.Get("Photon Bloom");

            var source = renderingData.cameraData.renderer.cameraColorTargetHandle;
            int mipCount = _settings.mipCount;

            _material.SetFloat(BloomThresholdId, _settings.threshold);
            _material.SetFloat(BloomIntensityId, _settings.intensity);
            _material.SetFloat(BloomRadiusId, _settings.radius);

            // --- Downsample chain ---
            // Mip 0: prefilter + downsample from source
            Blit(cmd, source, _mipDown[0], _material, PassPrefilter);

            // Blur mip 0
            Blit(cmd, _mipDown[0], _mipUp[0], _material, PassBlurH);
            Blit(cmd, _mipUp[0], _mipDown[0], _material, PassBlurV);

            // Subsequent mips: downsample + blur
            for (int i = 1; i < mipCount; i++)
            {
                Blit(cmd, _mipDown[i - 1], _mipDown[i], _material, PassPrefilter);
                Blit(cmd, _mipDown[i], _mipUp[i], _material, PassBlurH);
                Blit(cmd, _mipUp[i], _mipDown[i], _material, PassBlurV);
            }

            // --- Upsample chain ---
            // Start from smallest mip, progressively upsample and combine
            // Copy smallest mip to its up buffer
            Blit(cmd, _mipDown[mipCount - 1], _mipUp[mipCount - 1]);

            for (int i = mipCount - 2; i >= 0; i--)
            {
                // Set the lower (smaller) mip as _BloomLowMip
                cmd.SetGlobalTexture(BloomLowMipId, _mipUp[i + 1]);
                // Upsample: read current mip (_MainTex) + add lower mip
                Blit(cmd, _mipDown[i], _mipUp[i], _material, PassUpsample);
            }

            // --- Final composite ---
            // Blend bloom (mipUp[0]) into scene
            cmd.SetGlobalTexture(BloomLowMipId, _mipUp[0]);
            Blit(cmd, source, source, _material, PassComposite);

            context.ExecuteCommandBuffer(cmd);
            CommandBufferPool.Release(cmd);
        }

        public override void OnCameraCleanup(CommandBuffer cmd)
        {
        }

        public void Dispose()
        {
            for (int i = 0; i < _mipDown.Length; i++)
            {
                _mipDown[i]?.Release();
                _mipUp[i]?.Release();
            }
        }
    }
}
