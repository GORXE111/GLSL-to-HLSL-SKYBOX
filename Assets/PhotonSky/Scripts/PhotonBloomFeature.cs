// ============================================================================
// PhotonBloomFeature.cs
// URP ScriptableRendererFeature for Photon's multi-scale bloom.
// Source: photon/shaders/program/post/bloom/ (4 files)
//         photon/shaders/program/post/grade.glsl (bloom compositing)
//
// Photon bloom pipeline reference:
//   downsample.glsl  — 6x6 overlapping box kernel (COD AW method)
//   gaussian0.glsl   — horizontal 9-tap binomial blur per tile
//   gaussian1.glsl   — vertical 9-tap binomial blur per tile
//   grade.glsl:65-110 — get_bloom() merges 6 tiles with weight decay
//   grade.glsl:317-322 — mix(scene, bloom, 0.12 * BLOOM_INTENSITY)
// ============================================================================

using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;

namespace PhotonSky
{
    public class PhotonBloomFeature : ScriptableRendererFeature
    {
        [System.Serializable]
        public class BloomSettings
        {
            // Ref: grade.glsl:320 — bloom_intensity = 0.12 * BLOOM_INTENSITY
            // settings.glsl:338 — BLOOM_INTENSITY default 1.0, so default blend = 0.12
            [Range(0f, 1f)] public float threshold = 0.4f;  // Lower for post-tonemap LDR
            [Range(0f, 1f)] public float intensity = 0.12f; // Matches Photon default
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

            if (bloomShader != null && _bloomMaterial == null)
                _bloomMaterial = CoreUtils.CreateEngineMaterial(bloomShader);

            if (_bloomMaterial != null)
            {
                _bloomPass = new PhotonBloomPass(_bloomMaterial, settings);
                // Ref: grade.glsl runs after all scene rendering and TAA
                // AfterRenderingPostProcessing ensures skybox is fully rendered
                _bloomPass.renderPassEvent = RenderPassEvent.AfterRenderingPostProcessing;
            }
        }

        public override void AddRenderPasses(ScriptableRenderer renderer, ref RenderingData renderingData)
        {
            if (_bloomMaterial == null || _bloomPass == null) return;
            if (renderingData.cameraData.cameraType != CameraType.Game &&
                renderingData.cameraData.cameraType != CameraType.SceneView) return;

            _bloomPass.Setup(settings);
            renderer.EnqueuePass(_bloomPass);
        }

        protected override void Dispose(bool disposing)
        {
            _bloomPass?.Dispose();
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
        private RTHandle _tempRT; // Temp RT to avoid read/write to same target

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

            // Allocate temp RT at full resolution for the final composite blit
            RenderingUtils.ReAllocateIfNeeded(ref _tempRT, desc, FilterMode.Bilinear, name: "_BloomTemp");

            // Mip chain at half-res increments
            int w = desc.width;
            int h = desc.height;

            for (int i = 0; i < _settings.mipCount; i++)
            {
                w = Mathf.Max(w / 2, 1);
                h = Mathf.Max(h / 2, 1);

                var mipDesc = desc;
                mipDesc.width = w;
                mipDesc.height = h;

                RenderingUtils.ReAllocateIfNeeded(ref _mipDown[i], mipDesc, FilterMode.Bilinear, name: $"_BloomDown{i}");
                RenderingUtils.ReAllocateIfNeeded(ref _mipUp[i], mipDesc, FilterMode.Bilinear, name: $"_BloomUp{i}");
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
            // Ref: bloom/downsample.glsl — progressive 6x6 downsample
            // Mip 0: prefilter + downsample from scene
            Blit(cmd, source, _mipDown[0], _material, PassPrefilter);

            // Ref: bloom/gaussian0.glsl + gaussian1.glsl — 9-tap H+V blur per mip
            Blit(cmd, _mipDown[0], _mipUp[0], _material, PassBlurH);
            Blit(cmd, _mipUp[0], _mipDown[0], _material, PassBlurV);

            // Subsequent mips
            for (int i = 1; i < mipCount; i++)
            {
                Blit(cmd, _mipDown[i - 1], _mipDown[i], _material, PassPrefilter);
                Blit(cmd, _mipDown[i], _mipUp[i], _material, PassBlurH);
                Blit(cmd, _mipUp[i], _mipDown[i], _material, PassBlurV);
            }

            // --- Upsample chain ---
            // Ref: grade.glsl:82-109 — get_bloom() accumulates tiles with weight *= radius
            // Start from smallest mip, progressively upsample and combine
            Blit(cmd, _mipDown[mipCount - 1], _mipUp[mipCount - 1]);

            for (int i = mipCount - 2; i >= 0; i--)
            {
                cmd.SetGlobalTexture(BloomLowMipId, _mipUp[i + 1]);
                Blit(cmd, _mipDown[i], _mipUp[i], _material, PassUpsample);
            }

            // --- Final composite ---
            // Ref: grade.glsl:322 — scene_color = mix(scene_color, bloom, bloom_intensity)
            // Cannot read+write same RT, so: source → temp (with bloom blend), then temp → source
            cmd.SetGlobalTexture(BloomLowMipId, _mipUp[0]);
            Blit(cmd, source, _tempRT, _material, PassComposite);
            Blit(cmd, _tempRT, source);

            context.ExecuteCommandBuffer(cmd);
            CommandBufferPool.Release(cmd);
        }

        public override void OnCameraCleanup(CommandBuffer cmd) { }

        public void Dispose()
        {
            _tempRT?.Release();
            for (int i = 0; i < _mipDown.Length; i++)
            {
                _mipDown[i]?.Release();
                _mipUp[i]?.Release();
            }
        }
    }
}
