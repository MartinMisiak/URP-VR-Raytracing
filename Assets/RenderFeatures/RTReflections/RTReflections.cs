using System.Collections.Generic;
using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;
using UnityEngine.Experimental.Rendering;
using System;

public class RTReflections : ScriptableRendererFeature
{
    class RTReflectionPass : ScriptableRenderPass
    {
        private static readonly int s_RT_SpecularRadianceID = Shader.PropertyToID("_RT_SpecularRadiance");
        private RenderTargetIdentifier m_RT_SpecularRadianceTarget = new RenderTargetIdentifier(s_RT_SpecularRadianceID, 0, CubemapFace.Unknown, -1);
        private RenderTargetHandle m_SpecularMaskTarget;
        private Material m_copyColorMat;
        ProfilingSampler m_ProfilingSampler_specularRT = new ProfilingSampler("Raytrace Specular");
        private RayTracingAccelerationStructure m_acceleration_structure;
        private RayTracingShader m_primaryRayShader;
        private Matrix4x4[] m_CameraToWorld = new Matrix4x4[2];
        private Matrix4x4[] m_CameraInverseProjection = new Matrix4x4[2];
        private float[] m_SpreadAngle = new float[2];
        private int m_primaryRays;
        private int m_reflectionRays;
        private bool m_cullPeripheryRays;
        private Material m_specularMaskingMaterial;
        private int m_downsampling_factor;
        private DrawingSettings m_drawSettings;
        private FilteringSettings m_filterSettings;
        private int m_frameCounter = 0;

        // Temporal Accumulation variables
        private float m_temporalFade = 0.9f;
        private Material m_taaMat;
        private RenderTexture[] m_historyBuffer;
        private RenderTargetIdentifier[] m_historyRTI;
        private Matrix4x4[] m_prevViewProjectionMatrix = new Matrix4x4[2];
        private Matrix4x4[] m_FrameMatrix = new Matrix4x4[2];
        private Matrix4x4[] m_InverseProjection = new Matrix4x4[2];

        public bool SetupPass(RayTracingShader rayGenShader, int numPrimRays, int numReflRays, RayTracingAccelerationStructure accStruct, bool cullPeripheryRays, Material copyMat, Material taaMat, float taaFade, int downsampling, RenderTargetHandle maskTarget)
        {
            m_copyColorMat = copyMat;
            m_taaMat = taaMat;
            m_temporalFade = taaFade;
            m_specularMaskingMaterial = new Material(Shader.Find("Universal Render Pipeline/Unlit"));
            m_primaryRayShader = rayGenShader;
            m_primaryRays = numPrimRays;
            m_reflectionRays = numReflRays;
            m_acceleration_structure = accStruct;
            m_cullPeripheryRays = cullPeripheryRays;
            m_downsampling_factor = downsampling;
            m_SpecularMaskTarget = maskTarget;

            if (m_copyColorMat == null || m_primaryRayShader == null || m_acceleration_structure == null)
                return false;

            m_filterSettings = FilteringSettings.defaultValue;
            return true;
        }


        private void ClearRenderTexture(ref RenderTexture rt)
        {
            if (rt != null)
            {
                rt.Release();
                rt = null;
            }
        }

        // Called from outside to free allocated Textures of the history buffer
        public void ClearTemporalAccumulationTextures()
        {
            if (m_historyBuffer != null)
            {
                ClearRenderTexture(ref m_historyBuffer[0]);
                ClearRenderTexture(ref m_historyBuffer[1]);
                m_historyBuffer = null;
            }
        }

        private void EnsureHistoryBuffer(RenderTextureDescriptor desc)
        {
            if (m_historyBuffer == null || m_historyBuffer.Length != 2)
            {
                m_historyBuffer = new RenderTexture[2];
                m_historyRTI = new RenderTargetIdentifier[2];
                // for (int i = 0; i <= 2; i++)
                //     m_historyBuffer[i] = default(RenderTexture);
            }

            if (m_historyBuffer[0] != null && (m_historyBuffer[0].width != desc.width || m_historyBuffer[0].height != desc.height || m_historyBuffer[0].format != desc.colorFormat))
                ClearRenderTexture(ref m_historyBuffer[0]);
            if (m_historyBuffer[0] == null)
            {
                m_historyBuffer[0] = new RenderTexture(desc);
                m_historyBuffer[0].Create();
                m_historyRTI[0] = new RenderTargetIdentifier(m_historyBuffer[0], 0, CubemapFace.Unknown, -1);
            }

            if (m_historyBuffer[1] != null && (m_historyBuffer[1].width != desc.width || m_historyBuffer[1].height != desc.height || m_historyBuffer[1].format != desc.colorFormat))
                ClearRenderTexture(ref m_historyBuffer[1]);
            if (m_historyBuffer[1] == null)
            {
                m_historyBuffer[1] = new RenderTexture(desc);
                m_historyBuffer[1].Create();
                m_historyRTI[1] = new RenderTargetIdentifier(m_historyBuffer[1], 0, CubemapFace.Unknown, -1);
            }

            return;
        }


        // This method is called before executing the render pass.
        // It can be used to configure render targets and their clear state. Also to create temporary render target textures.
        // When empty this render pass will render to the active camera render target.
        // You should never call CommandBuffer.SetRenderTarget. Instead call <c>ConfigureTarget</c> and <c>ConfigureClear</c>.
        // The render pipeline will ensure target setup and clearing happens in a performant manner.
        public override void OnCameraSetup(CommandBuffer cmd, ref RenderingData renderingData)
        {
            RenderTextureDescriptor cameraTargetDescriptor = renderingData.cameraData.cameraTargetDescriptor;

            int eyeCount = 1;
            if (XRGraphics.enabled)
                eyeCount = (XRGraphics.stereoRenderingMode == XRGraphics.StereoRenderingMode.SinglePassInstanced) ? 2 : 1;

            for (int eyeIndex = 0; eyeIndex < eyeCount; eyeIndex++)
            {
                Matrix4x4 view = renderingData.cameraData.GetViewMatrix(eyeIndex);
                Matrix4x4 proj = renderingData.cameraData.GetProjectionMatrix(eyeIndex);

                Matrix4x4 projInv = Matrix4x4.Inverse(proj);
                Matrix4x4 viewInv = Matrix4x4.Inverse(view);

                m_CameraToWorld[eyeIndex] = viewInv;
                m_CameraInverseProjection[eyeIndex] = projInv;
                float vertFOV = Mathf.Atan(1.0f / proj.m11) * 2.0f;
                m_SpreadAngle[eyeIndex] = vertFOV / (cameraTargetDescriptor.height / m_downsampling_factor);

                // TAA
                if (m_taaMat != null)
                    m_FrameMatrix[eyeIndex] = m_prevViewProjectionMatrix[eyeIndex] * viewInv;
            }

            RenderTextureDescriptor specularRadianceDesc = cameraTargetDescriptor;
            specularRadianceDesc.width /= m_downsampling_factor;
            specularRadianceDesc.height /= m_downsampling_factor;
            specularRadianceDesc.dimension = cameraTargetDescriptor.dimension; // Force Texture to be Array, as it is implemented so in the .raytrace shader. #ifdef do not seem to work in .raytrace shaders (???)
            specularRadianceDesc.enableRandomWrite = true;
            specularRadianceDesc.msaaSamples = 1;
            specularRadianceDesc.depthBufferBits = 0;
            specularRadianceDesc.autoGenerateMips = false;

            cmd.GetTemporaryRT(s_RT_SpecularRadianceID, specularRadianceDesc, FilterMode.Bilinear);

            if(m_taaMat != null)
                EnsureHistoryBuffer(specularRadianceDesc);
        }

        // Here you can implement the rendering logic.
        // Use <c>ScriptableRenderContext</c> to issue drawing commands or execute command buffers
        // https://docs.unity3d.com/ScriptReference/Rendering.ScriptableRenderContext.html
        // You don't have to call ScriptableRenderContext.submit, the render pipeline will call it at specific points in the pipeline.
        public override void Execute(ScriptableRenderContext context, ref RenderingData renderingData)
        {
            m_frameCounter++;
            RenderTargetIdentifier cameraTarget = renderingData.cameraData.renderer.cameraColorTarget;
            RenderTextureDescriptor cameraTargetDescriptor = renderingData.cameraData.cameraTargetDescriptor;
            uint rt_width = (uint)(cameraTargetDescriptor.width / m_downsampling_factor);
            uint rt_height = (uint)(cameraTargetDescriptor.height / m_downsampling_factor);

            int rt_views = 1;
            if (XRGraphics.enabled)
                rt_views = (XRGraphics.stereoRenderingMode == XRGraphics.StereoRenderingMode.SinglePassInstanced) ? 2 : 1;

            CommandBuffer cmd = CommandBufferPool.Get();
            using (new ProfilingScope(cmd, m_ProfilingSampler_specularRT))
            {
                renderingData.perObjectData |= PerObjectData.ReflectionProbes;
                renderingData.perObjectData |= PerObjectData.ReflectionProbeData;

                // Raytracing
                cmd.BuildRayTracingAccelerationStructure(m_acceleration_structure);
                cmd.SetRayTracingMatrixArrayParam(m_primaryRayShader, "_CameraToWorld", m_CameraToWorld);
                cmd.SetRayTracingMatrixArrayParam(m_primaryRayShader, "_CameraInverseProjection", m_CameraInverseProjection);
                cmd.SetRayTracingFloatParams(m_primaryRayShader, "_SpreadAngle", m_SpreadAngle);
                cmd.SetRayTracingIntParam(m_primaryRayShader, "_NumPrimarySamples", m_primaryRays);
                cmd.SetGlobalInt("_NumReflectionSamples", m_reflectionRays);
                cmd.SetGlobalInt("_FrameCounter", m_frameCounter);
                cmd.SetGlobalInt("_CullPeripheryRays", Convert.ToInt32(m_cullPeripheryRays));

                cmd.SetRayTracingShaderPass(m_primaryRayShader, "PrimaryPass");
                cmd.SetRayTracingAccelerationStructure(m_primaryRayShader, "_RaytracingAccelerationStructure", m_acceleration_structure);
                cmd.SetRayTracingTextureParam(m_primaryRayShader, "_RT_SpecularMask", m_SpecularMaskTarget.Identifier());
                cmd.SetRayTracingTextureParam(m_primaryRayShader, "_RT_SpecularRadiance", m_RT_SpecularRadianceTarget);
                cmd.DispatchRays(m_primaryRayShader, "PrimaryRayGeneration", rt_width, rt_height, (uint)rt_views);

                if (m_taaMat != null)
                {
                    cmd.SetGlobalTexture("_TemporalAATexture", m_historyRTI[0]);
                    cmd.SetGlobalMatrixArray("_invP", m_CameraInverseProjection);
                    cmd.SetGlobalMatrixArray("_FrameMatrix", m_FrameMatrix);
                    cmd.SetGlobalMatrixArray("_Debug_CameraToWorldMatrix", m_CameraToWorld); // Only needed for location based debug TAA-on-off
                    cmd.SetGlobalFloat("_TemporalFade", m_temporalFade);
                    cmd.SetGlobalFloat("_ResolutionX", m_historyBuffer[0].width);
                    cmd.SetGlobalFloat("_ResolutionY", m_historyBuffer[0].height);

                    // TAA-Step -> Blend History-Buffer with current image
                    cmd.SetRenderTarget(m_historyRTI[1]);
                    cmd.SetGlobalTexture("_MainTex", m_RT_SpecularRadianceTarget);
                    cmd.DrawMesh(RenderingUtils.fullscreenMesh, Matrix4x4.identity, m_taaMat);
                    /////////////////////////////////////////////////
                    context.ExecuteCommandBuffer(cmd);
                    cmd.Clear();
                    // Copy TAA-result into Screen
                    cmd.SetRenderTarget(cameraTarget);
                    cmd.SetGlobalTexture("_CopySourceTex", m_historyRTI[1]);
                    cmd.DrawMesh(RenderingUtils.fullscreenMesh, Matrix4x4.identity, m_copyColorMat);

                    //Ping pong
                    RenderTargetIdentifier tempRTI = m_historyRTI[0];
                    m_historyRTI[0] = m_historyRTI[1];
                    m_historyRTI[1] = tempRTI;
                }
                else
                {
                    // Blit Raytraced result into camera target
                    cmd.SetRenderTarget(cameraTarget);
                    cmd.SetGlobalTexture("_CopySourceTex", m_RT_SpecularRadianceTarget);
                    cmd.DrawMesh(RenderingUtils.fullscreenMesh, Matrix4x4.identity, m_copyColorMat);
                }
            }
            context.ExecuteCommandBuffer(cmd);
            CommandBufferPool.Release(cmd);

            if (m_taaMat != null)
            {
                for (int eyeIndex = 0; eyeIndex < rt_views; eyeIndex++)
                {
                    Matrix4x4 view = renderingData.cameraData.GetViewMatrix(eyeIndex);
                    Matrix4x4 proj = renderingData.cameraData.GetProjectionMatrix(eyeIndex);
                    m_prevViewProjectionMatrix[eyeIndex] = proj * view;
                }
            }

        }

        // Cleanup any allocated resources that were created during the execution of this render pass.
        public override void OnCameraCleanup(CommandBuffer cmd)
        {
            cmd.ReleaseTemporaryRT(m_SpecularMaskTarget.id);
            cmd.ReleaseTemporaryRT(s_RT_SpecularRadianceID);
        }
    }

    [SerializeField, HideInInspector] private Shader m_copyShader = null;
    [SerializeField, HideInInspector] private Shader m_specularMaskShader = null;
    [SerializeField, HideInInspector] private Shader m_taaShader = null;
    Material m_copyMaterial = null;
    Material m_specularMaskMaterial = null;
    Material m_taaMaterial;
    RTReflectionPass m_ScriptablePass = null;
    CustomDrawObjectsPass m_specularMaskPass = null;
    private RayTracingAccelerationStructure m_acceleration_structure = null;
    private RayTracingShader m_currentlyUsedRTShader = null;
    [SerializeField] RayTracingShader m_primaryRayShader;
    [SerializeField] RayTracingShader m_primaryRayShaderViewport;
    [SerializeField] public int m_downsampling_factor = 1;
    [SerializeField] public int m_primaryRays = 8;
    [SerializeField] public int m_reflectionRays = 1;
    [SerializeField] public bool m_cullPeripheryRays = true;
    [SerializeField] public bool m_useTemporalAccumulation = true;
    [SerializeField] public float m_temporalFade  = 0.99f;
    [SerializeField, HideInInspector] public bool m_rebuildRTAccelerationStruct = true;

    // SpecularMask is allocated by the first pass (SpecularMask), and freed by the second pass (Raytracing)
    private RenderTargetHandle m_RT_SpecularMaskTarget;

    /// <inheritdoc/>
    public override void Create()
    {
        if (!m_RT_SpecularMaskTarget.HasInternalRenderTargetId())
            m_RT_SpecularMaskTarget.Init("_RT_SpecularMask");

        if (m_specularMaskPass == null)
        {
            m_specularMaskPass = new CustomDrawObjectsPass();
            // When rendering the skybox, Unity does not change render targets...meaning we cannot inject our pass before the skybox pass, or it would render the skybox into our specular mask *Unity 2021.3.6f1
            m_specularMaskPass.renderPassEvent = RenderPassEvent.AfterRenderingSkybox;
        }

        if (m_ScriptablePass == null)
        {
            m_ScriptablePass = new RTReflectionPass();
            m_ScriptablePass.renderPassEvent = RenderPassEvent.AfterRenderingTransparents;
        }

        GetMaterial();
    }

    private RenderTextureDescriptor ConfigureSpecularMaskDescriptor(RenderTextureDescriptor cameraDescriptor)
    {
        RenderTextureDescriptor specularMaskDesc = cameraDescriptor;
        specularMaskDesc.graphicsFormat = GraphicsFormat.R8_UNorm;
        specularMaskDesc.msaaSamples = 8;
        specularMaskDesc.autoGenerateMips = false;
        specularMaskDesc.dimension = cameraDescriptor.dimension;

        return specularMaskDesc;
    }

    // Here you can inject one or multiple render passes in the renderer.
    // This method is called when setting up the renderer once per-camera.
    public override void AddRenderPasses(ScriptableRenderer renderer, ref RenderingData renderingData)
    {
        if (!GetMaterial())
            return;

        Camera camera = renderingData.cameraData.camera;

        if (XRGraphics.enabled)
            m_currentlyUsedRTShader = m_primaryRayShader;
        else
            m_currentlyUsedRTShader = m_primaryRayShaderViewport;

        if (renderingData.cameraData.cameraType == CameraType.Game && camera.tag != "MainCamera")
             return;

        // Not sure why, but RT will not show in sceneview otherwise...
        if (renderingData.cameraData.cameraType == CameraType.SceneView)
            m_ScriptablePass.renderPassEvent = RenderPassEvent.AfterRenderingPostProcessing;
        else
            m_ScriptablePass.renderPassEvent = RenderPassEvent.AfterRenderingTransparents;

        InitRaytracingAccelerationStructure();
        m_specularMaskPass.ConfigureInput(ScriptableRenderPassInput.Depth);
        m_ScriptablePass.ConfigureInput(ScriptableRenderPassInput.Depth);

        RenderTextureDescriptor specularMaskDesc = ConfigureSpecularMaskDescriptor(renderingData.cameraData.cameraTargetDescriptor);
        Material taaMat = m_useTemporalAccumulation ? m_taaMaterial : null;
        bool shouldAddMask = m_specularMaskPass.SetupPass(true, m_RT_SpecularMaskTarget, specularMaskDesc);
        bool shouldAddRT   = m_ScriptablePass.SetupPass(m_currentlyUsedRTShader, m_primaryRays, m_reflectionRays,
                                                         m_acceleration_structure, m_cullPeripheryRays,
                                                         m_copyMaterial, taaMat, m_temporalFade,
                                                         m_downsampling_factor, m_RT_SpecularMaskTarget);

        if (shouldAddMask && shouldAddRT)
        {
            renderer.EnqueuePass(m_specularMaskPass);
            renderer.EnqueuePass(m_ScriptablePass);
        }
    }

    private void InitRaytracingAccelerationStructure()
    {
        if (m_rebuildRTAccelerationStruct && m_acceleration_structure != null)
        {
            m_acceleration_structure.Release();
            m_acceleration_structure = null;
            m_rebuildRTAccelerationStruct = false;
        }

        if (m_acceleration_structure == null)
        {
            RayTracingAccelerationStructure.RASSettings settings = new RayTracingAccelerationStructure.RASSettings();
            settings.layerMask = ~LayerMask.GetMask("UI");//~0;
            settings.managementMode = RayTracingAccelerationStructure.ManagementMode.Automatic;
            settings.rayTracingModeMask = RayTracingAccelerationStructure.RayTracingModeMask.DynamicTransform | RayTracingAccelerationStructure.RayTracingModeMask.Static;
            m_acceleration_structure = new RayTracingAccelerationStructure(settings);



            // For manual ManagementMode:
            // Renderer[] renderers = FindObjectsOfType<Renderer>();
            // foreach (Renderer r in renderers)
            // {
            //     IgnoreRaytracing overrideComponent = r.gameObject.GetComponent<IgnoreRaytracing>();
            //     if(overrideComponent != null)
            //         continue;

            //     m_acceleration_structure.AddInstance(r);
            // }
        }
    }

    private bool GetMaterial()
    {
        if (m_copyMaterial != null && m_specularMaskMaterial != null && m_taaMaterial != null)
            return true;

        if (m_copyShader == null)
        {
            m_copyShader = Shader.Find("CustomShaders/AddTexture");
            if (m_copyShader == null)
                return false;
        }

        if (m_specularMaskShader == null)
        {
            m_specularMaskShader = Shader.Find("CustomShaders/SpecularMasking");
            if (m_specularMaskShader == null)
                return false;
        }

        if (m_taaShader == null)
        {
            m_taaShader = Shader.Find("CustomShaders/TemporalAAShader");
            if (m_taaShader == null)
                return false;
        }

        m_copyMaterial = CoreUtils.CreateEngineMaterial(m_copyShader);
        m_specularMaskMaterial = CoreUtils.CreateEngineMaterial(m_specularMaskShader);
        m_taaMaterial = CoreUtils.CreateEngineMaterial(m_taaShader);

        return m_copyMaterial != null && m_specularMaskMaterial != null && m_taaMaterial != null;
    }

    protected override void Dispose(bool disposing)
    {
        CoreUtils.Destroy(m_specularMaskMaterial);
        CoreUtils.Destroy(m_copyMaterial);
        m_ScriptablePass.ClearTemporalAccumulationTextures();
    }
}


