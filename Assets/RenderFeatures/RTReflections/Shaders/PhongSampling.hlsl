#ifndef CUSTOM_PHONG_SAMPLING_INCLUDED
#define CUSTOM_PHONG_SAMPLING_INCLUDED

float getPhongPdf(float3 perfectReflectionWS, float3 incommingLightWS, float exponent)
{
    float base = (exponent + 1) / TWO_PI;
    float RdotL = saturate(dot(perfectReflectionWS, incommingLightWS));
    return base*pow(RdotL, exponent);
}

float evalPhongBRDF(float3 perfectReflectionWS, float3 incommingLightWS, float exponent, float specIntensity)
{
    float base = (exponent + 2) / TWO_PI;
    float RdotL = saturate(dot(perfectReflectionWS, incommingLightWS));
    return specIntensity*base*pow(RdotL, exponent);
}

float3 importanceSamplePhong(float2 random, float optionalSpin, float3 viewDirectionWS, float3 normalWS, float exponent)
{
    float phi   = TWO_PI * (random.y + optionalSpin);
    float cosTheta   = (pow(random.x, 1.0/(exponent+1)));
    float3 sample_TS = SphericalToCartesian(phi, (cosTheta));

    float3x3 local_to_world  = getInvNormalSpace(normalWS);
    float3 virtual_refl_axis = mul(local_to_world,sample_TS);
    float3 sample_WS         = reflect(-viewDirectionWS, virtual_refl_axis);

    return sample_WS;
}

// Clamps the phong exponent to 1 on the low end
float remapRoughnessToPhongExp(float perceptualRoughness, float NdotR)
{
    real m = PerceptualRoughnessToRoughness(perceptualRoughness);
    // Remap to spec power. See eq. 21 in --> https://dl.dropboxusercontent.com/u/55891920/papers/mm_brdf.pdf
    real n = (2.0 / max(REAL_EPS, m * m)) - 2.0;
    // Remap from n_dot_h formulation to n_dot_r. See section "Pre-convolved Cube Maps vs Path Tracers" --> https://s3.amazonaws.com/docs.knaldtech.com/knald/1.0.0/lys_power_drops.html
    n /= (4.0 * max(NdotR, REAL_EPS));
    n = max(n, 1); // phong exponent should not go under 1
    return n;
}

float4 RelfectionPhong_Raytraced(int numSamples, float random, inout RayPayload payload, inout InputData inputData, inout BRDFData brdfData)
{
        float3 reflectVector = normalize(reflect(-inputData.viewDirectionWS, inputData.normalWS));
        float4 accumulatedSpecularRadiance = float4(0,0,0,0);
        float weight = 0.00001;
        
        for(int i = 0; i < numSamples; i++)
        {
            float2 randomLocal  = Hammersley2d(i, numSamples);//Fibonacci2d(i, numSamples);
            float NdotR         = saturate(dot(inputData.normalWS, reflectVector));
            float phongExp      = remapRoughnessToPhongExp(brdfData.perceptualRoughness, NdotR);
            float3 sampleDir    = importanceSamplePhong( randomLocal, random, inputData.viewDirectionWS, inputData.normalWS, phongExp); 
            half NdotL = dot(inputData.normalWS, sampleDir);
            if (NdotL <= 0.00001) continue; // Some generated samples will have 0 contribution.
            
            RayDesc rayDesc;
            rayDesc.Origin = inputData.positionWS; 
            rayDesc.Direction = sampleDir;
            rayDesc.TMin = 0.01;
            rayDesc.TMax = 100;
            // Create and init the ray payload
            RayPayload reflectedRayPayload;
            reflectedRayPayload.radiance   = float4(0.0, 0.0, 0.0,0.0);
            reflectedRayPayload.random     = 0;
            reflectedRayPayload.depth      = payload.depth + 1;
            TraceRay(_RaytracingAccelerationStructure, RAY_FLAG_NONE, RAYTRACING_OPAQUE_FLAG, 0, 1, 0, rayDesc, reflectedRayPayload);
            
            // float pdf         = getPhongPdf(reflectVector,  sampleDir, phongExp);
            float pdf         = max(getPhongPdf(reflectVector,  sampleDir, phongExp), 0.0001);
            float4 newVal     = evalPhongBRDF(reflectVector, sampleDir,  phongExp, 1) * reflectedRayPayload.radiance * NdotL
                                           / pdf; // Set Spec intensity to 1 as it will be later modified by Fresnel    
           
            accumulatedSpecularRadiance += clamp(newVal, 0, 1);
            weight += NdotL;
        }
        accumulatedSpecularRadiance /= weight;

        // Apply Fresnel and roughness based visibility term only once for all lobe rays...Unity does this basically
        half NoV = saturate(dot(inputData.normalWS, inputData.viewDirectionWS));
        half fresnelTerm = Pow4(1.0 - NoV);
        accumulatedSpecularRadiance = float4(EnvironmentBRDFSpecular(brdfData, fresnelTerm), 1.0) * accumulatedSpecularRadiance;

        return accumulatedSpecularRadiance;
}

// Optimized Rendering Techniques Based on Local Cubemaps - ARM 2015
float3 LocalCubeMapCorrection(float3 reflDirWS, float3 posWS, float3 _BBoxPos, float3 _BBoxMin, float3 _BBoxMax)
{
    // Working in World Coordinate System.
    float3 localPosWS = posWS;
    float3 intersectMaxPointPlanes = (_BBoxMax - localPosWS) / reflDirWS;
    float3 intersectMinPointPlanes = (_BBoxMin - localPosWS) / reflDirWS;
    // Looking only for intersections in the forward direction of the ray.
    float3 largestRayParams = max(intersectMaxPointPlanes, intersectMinPointPlanes);
    // Smallest value of the ray parameters gives us the intersection.
    float distToIntersect = min(min(largestRayParams.x, largestRayParams.y), largestRayParams.z);
    // Find the position of the intersection point.
    float3 intersectPositionWS = localPosWS + reflDirWS * distToIntersect;
    return normalize(intersectPositionWS - _BBoxPos);


}
#endif // CUSTOM_PHONG_SAMPLING_INCLUDED