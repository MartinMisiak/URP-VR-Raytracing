using System.Collections.Generic;
using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;
using UnityEngine.Experimental.Rendering;


class CustomDrawObjectsPass : ScriptableRenderPass
{
    RenderTargetHandle m_Target;
    RenderTextureDescriptor m_Target_Descriptor;
    private ProfilingSampler m_ProfilingSampler_objectPass = new ProfilingSampler("Custom Object Pass");
    private DrawingSettings m_drawSettings;
    private FilteringSettings m_filterSettings;
    private List<ShaderTagId> m_ShaderTagIdList = new List<ShaderTagId>();
    private bool m_considerOpaqueDepth;

    public CustomDrawObjectsPass()
    {
        if (m_ShaderTagIdList.Count == 0)
        {
            m_ShaderTagIdList.Add(new ShaderTagId("SpecularMask"));
        }
    }

    public bool SetupPass(bool considerOpaqueDepth, RenderTargetHandle target, RenderTextureDescriptor target_descriptor)
    {
        m_Target = target;
        m_Target_Descriptor = target_descriptor;
        m_considerOpaqueDepth = considerOpaqueDepth;
        m_filterSettings = FilteringSettings.defaultValue;
        return true;
    }

    public override void OnCameraSetup(CommandBuffer cmd, ref RenderingData renderingData)
    {
        // if (renderingData.cameraData.cameraType != CameraType.Game)
        //     return;

        // Allocate Render Textures
        cmd.GetTemporaryRT(m_Target.id, m_Target_Descriptor, FilterMode.Point);
    }

    public override void Execute(ScriptableRenderContext context, ref RenderingData renderingData)
    {
        // if (renderingData.cameraData.cameraType != CameraType.Game)
        //     return;

        CommandBuffer cmd = CommandBufferPool.Get();
        using (new ProfilingScope(cmd, m_ProfilingSampler_objectPass))
        {
            context.ExecuteCommandBuffer(cmd);
            cmd.Clear();
            cmd.SetRenderTarget(m_Target.Identifier());
            cmd.ClearRenderTarget(true, true, Color.clear);

            // Settings required by URP to make use of DrawRenderers()
            Vector4 drawObjectPassData = new Vector4(0.0f, 0.0f, 0.0f, 1.0f);
            cmd.SetGlobalVector(Shader.PropertyToID("_DrawObjectPassData"), drawObjectPassData);
            float flipSign = (renderingData.cameraData.IsCameraProjectionMatrixFlipped()) ? -1.0f : 1.0f;
            Vector4 scaleBias = (flipSign < 0.0f)
                ? new Vector4(flipSign, 1.0f, -1.0f, 1.0f)
                : new Vector4(flipSign, 0.0f, 1.0f, 1.0f);
            cmd.SetGlobalVector(Shader.PropertyToID("_ScaleBiasRt"), scaleBias);
            // Settings required by URP to make use of DrawRenderers()
            

            context.ExecuteCommandBuffer(cmd);
            cmd.Clear();
            
            m_drawSettings = CreateDrawingSettings(m_ShaderTagIdList, ref renderingData, SortingCriteria.CommonOpaque);

            context.DrawRenderers(renderingData.cullResults, ref m_drawSettings, ref m_filterSettings);
        }

        context.ExecuteCommandBuffer(cmd);
        cmd.Clear();
        CommandBufferPool.Release(cmd);
    }

}
