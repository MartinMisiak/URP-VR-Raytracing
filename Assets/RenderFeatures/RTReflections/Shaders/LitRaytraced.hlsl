#pragma raytracing test
#include "RT_Common.cginc"
#include "PhongSampling.hlsl"
int _NumReflectionSamples;


Varyings initLitForwardVertexStruct(IntersectionInfo intersection)
{
    float3x3 objectToWorld = (float3x3)ObjectToWorld3x4();
    float3 viewDirWS  = -WorldRayDirection(); // Unity expects viewDir to be fragment-to-camera
    // float3 positionWS = WorldRayOrigin() + RayTCurrent() * WorldRayDirection(); // DXR-defined functions
    float3 positionWS = mul(ObjectToWorld3x4(), float4(intersection.position,1)); // This should have a higher precision according to Microsofts DXR docs....
	float3 normalWS   = normalize(mul(objectToWorld, intersection.normal));
    half4 tangentWS   = half4(normalize(mul(objectToWorld, intersection.tangent.xyz)), intersection.tangent.w);
    float2 uv0        = intersection.texCoord0;
    float2 uv1        = intersection.texCoord1;
    float2 uv2        = intersection.texCoord2;

    Varyings result = (Varyings)0;
    result.uv = TRANSFORM_TEX(uv0, _BaseMap);//uv0;

    #if defined(REQUIRES_WORLD_SPACE_POS_INTERPOLATOR)
        result.positionWS = positionWS;
    #endif

    result.normalWS = normalWS;

    #if defined(REQUIRES_WORLD_SPACE_TANGENT_INTERPOLATOR)
        result.tangentWS = tangentWS;
    #endif    

    result.viewDirWS = viewDirWS;

    #ifdef _ADDITIONAL_LIGHTS_VERTEX
        result.fogFactorAndVertexLight  = half4(0,0,0,0); // Currently unsupported
    #else
        result.fogFactor                = 0; // Currently unsupported
    #endif

    #if defined(REQUIRES_VERTEX_SHADOW_COORD_INTERPOLATOR)
        result.shadowCoord              = float4(0,0,0,0); // Currently unsupported
    #endif

    #if defined(REQUIRES_TANGENT_SPACE_VIEW_DIR_INTERPOLATOR)
        result.viewDirTS                = GetViewDirectionTangentSpace(tangentWS, normalWS, viewDirWS);
    #endif    

    ////////////// Lightmaps / SHs ///////////////
    OUTPUT_LIGHTMAP_UV(uv1, unity_LightmapST, result.staticLightmapUV);
    #ifdef DYNAMICLIGHTMAP_ON
        result.dynamicLightmapUV = uv2.xy * unity_DynamicLightmapST.xy + unity_DynamicLightmapST.zw;
    #endif
    OUTPUT_SH(result.normalWS.xyz, result.vertexSH);
    //////////////////////////////////////////////

    result.positionCS               = float4(0,0,0,0); // TODO:

    return result;
}

half3 GlossyEnvironmentReflection_RT(half3 reflectVector, float3 positionWS, half perceptualRoughness, half occlusion)
{
    half3 irradiance;
    #ifdef _REFLECTION_PROBE_BLENDING
        irradiance = CalculateIrradianceFromReflectionProbes(reflectVector, positionWS, perceptualRoughness);
    #else
        #ifdef _REFLECTION_PROBE_BOX_PROJECTION
            reflectVector = BoxProjectedCubemapDirection(reflectVector, positionWS, unity_SpecCube0_ProbePosition, unity_SpecCube0_BoxMin, unity_SpecCube0_BoxMax);
        #endif // _REFLECTION_PROBE_BOX_PROJECTION
            half mip = PerceptualRoughnessToMipmapLevel(perceptualRoughness);
            half4 encodedIrradiance = half4(SAMPLE_TEXTURECUBE_LOD(unity_SpecCube0, samplerunity_SpecCube0, reflectVector, mip));

        #if defined(UNITY_USE_NATIVE_HDR)
            irradiance = encodedIrradiance.rgb;
        #else
            irradiance = DecodeHDREnvironment(encodedIrradiance, unity_SpecCube0_HDR);
        #endif // UNITY_USE_NATIVE_HDR
    #endif // _REFLECTION_PROBE_BLENDING
    return irradiance * occlusion;
}

// Computes specular reflections comming from the "Environment" (EnvironmentMap) and indirect diffuse term comming from baked GI
half3 GlobalIllumination_RT(BRDFData brdfData, BRDFData brdfDataClearCoat, float clearCoatMask,
    half3 bakedGI, half occlusion, float3 positionWS,
    half3 normalWS, half3 viewDirectionWS)
{
    half3 reflectVector = reflect(-viewDirectionWS, normalWS);
    half NoV = saturate(dot(normalWS, viewDirectionWS));
    half fresnelTerm = Pow4(1.0 - NoV);

    half3 indirectDiffuse = bakedGI;
    half3 indirectSpecular = GlossyEnvironmentReflection_RT(reflectVector, positionWS, brdfData.perceptualRoughness, 1.0h);   
    half3 color = EnvironmentBRDF(brdfData, indirectDiffuse, indirectSpecular, fresnelTerm);

    #if defined(_CLEARCOAT) || defined(_CLEARCOATMAP)
        half3 coatIndirectSpecular = GlossyEnvironmentReflection(reflectVector, positionWS, brdfDataClearCoat.perceptualRoughness, 1.0h);
        // TODO: "grazing term" causes problems on full roughness
        half3 coatColor = EnvironmentBRDFClearCoat(brdfDataClearCoat, clearCoatMask, coatIndirectSpecular, fresnelTerm);

        // Blend with base layer using khronos glTF recommended way using NoV
        // Smooth surface & "ambiguous" lighting
        // NOTE: fresnelTerm (above) is pow4 instead of pow5, but should be ok as blend weight.
        half coatFresnel = kDielectricSpec.x + kDielectricSpec.a * fresnelTerm;
        return (color * (1.0 - coatFresnel * clearCoatMask) + coatColor) * occlusion;
    #else
        return color * occlusion;
    #endif
}

half4 UniversalFragmentPBR_RT(InputData inputData, SurfaceData surfaceData)
{
    #if defined(_SPECULARHIGHLIGHTS_OFF)
    bool specularHighlightsOff = true;
    #else
    bool specularHighlightsOff = false;
    #endif

    BRDFData brdfData;
    // NOTE: can modify "surfaceData"...
    InitializeBRDFData(surfaceData, brdfData);

    // Clear-coat calculation...
    BRDFData brdfDataClearCoat = CreateClearCoatBRDFData(surfaceData, brdfData);
    half4 shadowMask = CalculateShadowMask(inputData);
    AmbientOcclusionFactor aoFactor = CreateAmbientOcclusionFactor(inputData, surfaceData); // TODO: Requires correct Varyings.positionCS so screenspaceUVs can be calculated later
    uint meshRenderingLayers = GetMeshRenderingLightLayer();
    Light mainLight = GetMainLight(inputData, shadowMask, aoFactor);
    MixRealtimeAndBakedGI(mainLight, inputData.normalWS, inputData.bakedGI); // Factor out mainLight from baked lighting (if existent), so it mixes better
    LightingData lightingData = CreateLightingData(inputData, surfaceData);
    
    lightingData.giColor = GlobalIllumination_RT(brdfData, brdfDataClearCoat, surfaceData.clearCoatMask,
                                              inputData.bakedGI, aoFactor.indirectAmbientOcclusion, inputData.positionWS,
                                              inputData.normalWS, inputData.viewDirectionWS);

    if (IsMatchingLightLayer(mainLight.layerMask, meshRenderingLayers))
    {
        lightingData.mainLightColor = LightingPhysicallyBased(brdfData, brdfDataClearCoat,
                                                              mainLight,
                                                              inputData.normalWS, inputData.viewDirectionWS,
                                                              surfaceData.clearCoatMask, specularHighlightsOff);
    }

    #if defined(_ADDITIONAL_LIGHTS)
    uint pixelLightCount = GetAdditionalLightsCount();

    #if USE_CLUSTERED_LIGHTING
    for (uint lightIndex = 0; lightIndex < min(_AdditionalLightsDirectionalCount, MAX_VISIBLE_LIGHTS); lightIndex++)
    {
        Light light = GetAdditionalLight(lightIndex, inputData, shadowMask, aoFactor);

        if (IsMatchingLightLayer(light.layerMask, meshRenderingLayers))
        {
            lightingData.additionalLightsColor += LightingPhysicallyBased(brdfData, brdfDataClearCoat, light,
                                                                          inputData.normalWS, inputData.viewDirectionWS,
                                                                          surfaceData.clearCoatMask, specularHighlightsOff);
        }
    }
    #endif

    LIGHT_LOOP_BEGIN(pixelLightCount)
        Light light = GetAdditionalLight(lightIndex, inputData, shadowMask, aoFactor);

        if (IsMatchingLightLayer(light.layerMask, meshRenderingLayers))
        {
            lightingData.additionalLightsColor += LightingPhysicallyBased(brdfData, brdfDataClearCoat, light,
                                                                          inputData.normalWS, inputData.viewDirectionWS,
                                                                          surfaceData.clearCoatMask, specularHighlightsOff);
        }
    LIGHT_LOOP_END
    #endif

    #if defined(_ADDITIONAL_LIGHTS_VERTEX)
    lightingData.vertexLightingColor += inputData.vertexLighting * brdfData.diffuse;
    #endif

    return CalculateFinalColor(lightingData, surfaceData.alpha);
}


float4 RelfectionMirror(inout RayPayload payload, inout SurfaceData surfaceData, inout InputData inputData, inout BRDFData brdfData)
{
    float3 reflectVector = normalize(reflect(-inputData.viewDirectionWS, inputData.normalWS));
    RayDesc rayDesc;
	rayDesc.Origin = inputData.positionWS; 
	rayDesc.Direction = reflectVector;
	rayDesc.TMin = 0.01;
	rayDesc.TMax = 100;
	// Create and init the ray payload
    RayPayload reflectedRayPayload;
    reflectedRayPayload.radiance = float4(0.0, 0.0, 0.0,0.0);
    reflectedRayPayload.random     = 0;
    reflectedRayPayload.depth      = payload.depth + 1;
	TraceRay(_RaytracingAccelerationStructure, RAY_FLAG_NONE, RAYTRACING_OPAQUE_FLAG, 0, 1, 0, rayDesc, reflectedRayPayload);
    // Compute weight incoming light with fresnel (most impact on non-metals)
    half NoV = saturate(dot(inputData.normalWS, inputData.viewDirectionWS));
    half fresnelTerm = Pow4(1.0 - NoV);
    float4 envSpec   = clamp(reflectedRayPayload.radiance,0,5) * float4(EnvironmentBRDFSpecular(brdfData, fresnelTerm),1);

    return envSpec;
}

[shader("closesthit")]  
void ClosestHitMain(inout RayPayload payload : SV_RayPayload, AttributeData attribs : SV_IntersectionAttributes)
{

    //payload.rayEyeIndex;
    IntersectionInfo intersection;
    GetCurrentIntersection(attribs, intersection);
    
    // Compute variables needed for fragment shading
    Varyings input  = initLitForwardVertexStruct(intersection);
    
    // Mimic functionality from LitForwardPass.hlsl
    // --------------------------------------------
    #if defined(_PARALLAXMAP)
        // TODO: make sure tangentWS.w is already multiplied by GetOddNegativeScale()
        // half3 viewDirTS = GetViewDirectionTangentSpace(input.tangentWS, input.normalWS, input.viewDirWS);
        ApplyPerPixelDisplacement(input.viewDirTS, input.uv); 
    #endif

    RayconeLOD rayconeLOD;
    rayconeLOD.footprint      = log2( payload.spreadAngle * RayTCurrent() * (1.0 / abs(dot(input.normalWS, input.viewDirWS)))); 
    rayconeLOD.texelAreaUV    = intersection.texCoord0Area;
    rayconeLOD.triangleAreaWS = intersection.triangleAreaWS;

    SurfaceData surfaceData;
    InitializeStandardLitSurfaceData(input.uv, surfaceData, rayconeLOD);
    
    InputData inputData;
    InitializeInputData(input, surfaceData.normalTS, inputData); 
    // inputData.normalizedScreenSpaceUV is likely wrong, as per camera information is required here...

    if(payload.depth == 0)
    {
        /*
        // Variable Specular highlight disparity
        #if defined(USING_STEREO_MATRICES)
            float3 cyclopeanEye = (unity_StereoWorldSpaceCameraPos[0] + unity_StereoWorldSpaceCameraPos[1]) * 0.5;
            float3 eyeOffset    = (unity_StereoWorldSpaceCameraPos[1] - unity_StereoWorldSpaceCameraPos[0]) * 0.5;
            inputData.viewDirectionWS = (cyclopeanEye + _HighlightDisparity * (-1.0 + 2.0*payload.rayEyeIndex) * eyeOffset)  - inputData.positionWS;
            inputData.viewDirectionWS = normalize(inputData.viewDirectionWS);
        #endif       
        */

        BRDFData brdfData;
        InitializeBRDFData(surfaceData, brdfData);

        float4 reflection        = float4(0,0,0,0);    
        int reflectionNum        = ceil(_NumReflectionSamples * _NumReflRayMult);
        if(reflectionNum == 1)
            reflection           = RelfectionMirror(payload, surfaceData, inputData, brdfData);
        else
        {
            #if defined (_RT_REFLECTIONS)
                reflection           = RelfectionPhong_Raytraced(reflectionNum, payload.random, payload, inputData, brdfData);
            #endif
        }
        payload.radiance = reflection;
        return;
    }
    else
    {
        half4 color = UniversalFragmentPBR_RT(inputData, surfaceData);
        payload.radiance = color;
        return;
    }
}

