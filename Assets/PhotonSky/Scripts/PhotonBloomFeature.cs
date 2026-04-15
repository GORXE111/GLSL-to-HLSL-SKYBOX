// ============================================================================
// PhotonBloomFeature.cs
// URP ScriptableRendererFeature for Photon's multi-scale bloom.
// Ref: photon/shaders/program/post/bloom/*.glsl
//      photon/shaders/program/post/grade.glsl:317-322
//
// Uses cmd.Blit() with temporary RT IDs for URP 2022.3 compatibility.
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
            [Range(0f, 1f)] public float threshold = 0.4f;
            [Range(0f, 1f)] public float intensity = 0.12f;
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
                _bloomPass.renderPassEvent = RenderPassEvent.BeforeRenderingPostProcessing;
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
            CoreUtils.Destroy(_bloomMaterial);
        }
    }

    public class PhotonBloomPass : ScriptableRenderPass
    {
        private Material _mat;
        private PhotonBloomFeature.BloomSettings _settings;

        // Pass indices
        private const int PassPrefilter = 0;
        private const int PassBlurH     = 1;
        private const int PassBlurV     = 2;
        private const int PassUpsample  = 3;
        private const int PassComposite = 4;

        private static readonly int BloomThresholdId = Shader.PropertyToID("_BloomThreshold");
        private static readonly int BloomIntensityId = Shader.PropertyToID("_BloomIntensity");
        private static readonly int BloomRadiusId    = Shader.PropertyToID("_BloomRadius");
        private static readonly int BloomLowMipId    = Shader.PropertyToID("_BloomLowMip");

        // Use int IDs for temporary RTs (reliable in all URP versions)
        private int[] _downIds;
        private int[] _upIds;
        private int _tempId;

        public PhotonBloomPass(Material material, PhotonBloomFeature.BloomSettings settings)
        {
            _mat = material;
            _settings = settings;

            _downIds = new int[7];
            _upIds = new int[7];
            for (int i = 0; i < 7; i++)
            {
                _downIds[i] = Shader.PropertyToID($"_PhotonBloomDown{i}");
                _upIds[i] = Shader.PropertyToID($"_PhotonBloomUp{i}");
            }
            _tempId = Shader.PropertyToID("_PhotonBloomTemp");
        }

        public void Setup(PhotonBloomFeature.BloomSettings settings)
        {
            _settings = settings;
        }

        public override void Execute(ScriptableRenderContext context, ref RenderingData renderingData)
        {
            if (_mat == null || _settings.intensity <= 0) return;

            CommandBuffer cmd = CommandBufferPool.Get("Photon Bloom");
            var desc = renderingData.cameraData.cameraTargetDescriptor;
            desc.depthBufferBits = 0;
            desc.msaaSamples = 1;

            var source = renderingData.cameraData.renderer.cameraColorTargetHandle;
            int mipCount = _settings.mipCount;

            _mat.SetFloat(BloomThresholdId, _settings.threshold);
            _mat.SetFloat(BloomIntensityId, _settings.intensity);
            _mat.SetFloat(BloomRadiusId, _settings.radius);

            // Allocate temp RTs for mip chain
            int w = desc.width;
            int h = desc.height;
            for (int i = 0; i < mipCount; i++)
            {
                w = Mathf.Max(w / 2, 1);
                h = Mathf.Max(h / 2, 1);
                cmd.GetTemporaryRT(_downIds[i], w, h, 0, FilterMode.Bilinear, RenderTextureFormat.DefaultHDR);
                cmd.GetTemporaryRT(_upIds[i], w, h, 0, FilterMode.Bilinear, RenderTextureFormat.DefaultHDR);
            }

            // Full-res temp for final composite
            cmd.GetTemporaryRT(_tempId, desc.width, desc.height, 0, FilterMode.Bilinear, desc.colorFormat);

            // --- Downsample chain ---
            // Ref: bloom/downsample.glsl:73-94 — 6x6 overlapping box kernel
            cmd.Blit(source, _downIds[0], _mat, PassPrefilter);

            // Ref: bloom/gaussian0.glsl + gaussian1.glsl — 9-tap blur
            cmd.Blit(_downIds[0], _upIds[0], _mat, PassBlurH);
            cmd.Blit(_upIds[0], _downIds[0], _mat, PassBlurV);

            for (int i = 1; i < mipCount; i++)
            {
                cmd.Blit(_downIds[i - 1], _downIds[i], _mat, PassPrefilter);
                cmd.Blit(_downIds[i], _upIds[i], _mat, PassBlurH);
                cmd.Blit(_upIds[i], _downIds[i], _mat, PassBlurV);
            }

            // --- Upsample chain ---
            // Ref: grade.glsl:82-109 — accumulate tiles with weight *= radius
            cmd.Blit(_downIds[mipCount - 1], _upIds[mipCount - 1]);

            for (int i = mipCount - 2; i >= 0; i--)
            {
                cmd.SetGlobalTexture(BloomLowMipId, _upIds[i + 1]);
                cmd.Blit(_downIds[i], _upIds[i], _mat, PassUpsample);
            }

            // --- Final composite ---
            // Ref: grade.glsl:322 — mix(scene_color, bloom, bloom_intensity)
            // source → temp (blend bloom), then temp → source
            cmd.SetGlobalTexture(BloomLowMipId, _upIds[0]);
            cmd.Blit(source, _tempId, _mat, PassComposite);
            cmd.Blit(_tempId, source);

            // Release temp RTs
            for (int i = 0; i < mipCount; i++)
            {
                cmd.ReleaseTemporaryRT(_downIds[i]);
                cmd.ReleaseTemporaryRT(_upIds[i]);
            }
            cmd.ReleaseTemporaryRT(_tempId);

            context.ExecuteCommandBuffer(cmd);
            CommandBufferPool.Release(cmd);
        }

        public void Dispose() { }
    }
}
