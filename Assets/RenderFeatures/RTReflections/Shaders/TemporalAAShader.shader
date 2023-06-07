/*
MIT License

Copyright (c) 2022 Pascal Zwick

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
*/

Shader "CustomShaders/TemporalAAShader"
{
    SubShader
    {
        Tags { "RenderType"="Opaque" "RenderPipeline" = "UniversalPipeline"}
        LOD 100
        // No culling or depth
        // Cull Back ZWrite Off ZTest Always
        ZWrite Off Cull Off

        Pass
        {
            Name "TemporalAAPass"

            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag

            #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/Common.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/DeclareDepthTexture.hlsl"

            #if defined(USING_STEREO_MATRICES)
                #define unity_eyeIndex unity_StereoEyeIndex
            #else
                #define unity_eyeIndex 0
            #endif

            struct Attributes
            {
                float4 positionHCS   : POSITION;
                float2 uv            : TEXCOORD0;
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };

            struct Varyings
            {
                float4  positionCS  : SV_POSITION;
                float2  uv          : TEXCOORD0;
                UNITY_VERTEX_OUTPUT_STEREO
            };

            Varyings vert(Attributes input)
            {
                Varyings output;
                UNITY_SETUP_INSTANCE_ID(input);
                UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(output);

                // Note: The pass is setup with a mesh already in clip
                // space, that's why, it's enough to just output vertex
                // positions
                output.positionCS = float4(input.positionHCS.xyz, 1.0);

                #if UNITY_UV_STARTS_AT_TOP
                output.positionCS.y *= -1;
                #endif

                output.uv = input.uv;
                return output;
            }

            TEXTURE2D_X(_MainTex); 
            TEXTURE2D_X(_TemporalAATexture); 
            SAMPLER(sampler_MainTex);
            SAMPLER(sampler_TemporalAATexture);
            //sampler2D _MotionVectorTexture;
			
			float _TemporalFade;
            float4x4 _invP[2];
            float4x4 _FrameMatrix[2];
            float4x4 _Debug_CameraToWorldMatrix[2];

            float  maxComponent(float3 v) { return max (max (v.x, v.y), v.z); }
            float  minComponent(float3 v) { return min (min (v.x, v.y), v.z); }
            float  safeInverse(float x)   { return (x == 0.0) ? 1000000000000.0 : (1.0 / x); }
            float3 safeInverse(float3 v)  { return float3(safeInverse(v.x), safeInverse(v.y), safeInverse(v.z)); }

            // Bicubic Catmull-Rom texture filtering using 9 tap
            // https://gist.github.com/TheRealMJP/c83b8c0f46b63f3a88a5986f4fa982b1 (MIT License)
            float4 bicubicSample_CatmullRom(TEXTURE2D_X_PARAM(tex, sampler_tex), float2 uv, float2 texSize)
            {
                // We're going to sample a a 4x4 grid of texels surrounding the target UV coordinate. We'll do this by rounding
                // down the sample location to get the exact center of our "starting" texel. The starting texel will be at
                // location [1, 1] in the grid, where [0, 0] is the top left corner.
                float2 samplePos = uv * texSize;
                float2 texPos1 = floor(samplePos - 0.5) + 0.5;

                // Compute the fractional offset from our starting texel to our original sample location, which we'll
                // feed into the Catmull-Rom spline function to get our filter weights.
                float2 f = samplePos - texPos1;

                // Compute the Catmull-Rom weights using the fractional offset that we calculated earlier.
                // These equations are pre-expanded based on our knowledge of where the texels will be located,
                // which lets us avoid having to evaluate a piece-wise function.
                float2 w0 = f * (-0.5f + f * (1.0f - 0.5f * f));
                float2 w1 = 1.0f + f * f * (-2.5f + 1.5f * f);
                float2 w2 = f * (0.5f + f * (2.0f - 1.5f * f));
                float2 w3 = f * f * (-0.5f + 0.5f * f);

                // Work out weighting factors and sampling offsets that will let us use bilinear filtering to
                // simultaneously evaluate the middle 2 samples from the 4x4 grid.
                float2 w12 = w1 + w2;
                float2 offset12 = w2 / (w1 + w2);

                // Compute the final UV coordinates we'll use for sampling the texture
                float2 texPos0 = texPos1 - 1;
                float2 texPos3 = texPos1 + 2;
                float2 texPos12 = texPos1 + offset12;

                texPos0 /= texSize;
                texPos3 /= texSize;
                texPos12 /= texSize;

                float4 result = float4(0,0,0,0);

                result += SAMPLE_TEXTURE2D_X_LOD( tex, sampler_tex, float2(texPos0.x, texPos0.y), 0 ) * w0.x * w0.y;
                result += SAMPLE_TEXTURE2D_X_LOD( tex, sampler_tex, float2(texPos12.x, texPos0.y), 0 ) * w12.x * w0.y;
                result += SAMPLE_TEXTURE2D_X_LOD( tex, sampler_tex, float2(texPos3.x, texPos0.y), 0 ) * w3.x * w0.y;

                result += SAMPLE_TEXTURE2D_X_LOD( tex, sampler_tex, float2(texPos0.x, texPos12.y), 0 ) * w0.x * w12.y;
                result += SAMPLE_TEXTURE2D_X_LOD( tex, sampler_tex, float2(texPos12.x, texPos12.y), 0 ) * w12.x * w12.y;
                result += SAMPLE_TEXTURE2D_X_LOD( tex, sampler_tex, float2(texPos3.x, texPos12.y), 0 ) * w3.x * w12.y;
                
                result += SAMPLE_TEXTURE2D_X_LOD( tex, sampler_tex, float2(texPos0.x, texPos3.y), 0 ) * w0.x * w3.y;
                result += SAMPLE_TEXTURE2D_X_LOD( tex, sampler_tex, float2(texPos12.x, texPos3.y), 0 ) * w12.x * w3.y;
                result += SAMPLE_TEXTURE2D_X_LOD( tex, sampler_tex, float2(texPos3.x, texPos3.y), 0 ) * w3.x * w3.y;

                return result;
            }

            float loadDepth(uint2 uv) {
                float rd = LoadSceneDepth(uv);
                return Linear01Depth(rd, _ZBufferParams);
            }


            uint2 convertToPixelCoords(float2 uv)
            {
                return uint2( uint(uv.x * _ScreenParams.x), uint(uv.y * _ScreenParams.y) );
            }

            // [Pedersen16] - https://github.com/playdeadgames/temporal/
            // Adapted from   https://github.com/gokselgoktas/temporal-anti-aliasing/
            // Assumes the current color is in the bbox center, and clips towards it. 
            float3 clip_color_approx(float3 color_input, float3 color_min, float3 color_max)
            {
                float3  center = 0.5 * (color_max + color_min);
                float3  extent = 0.5 * (color_max - color_min);

                float3  unclipped = color_input - center;
                float3  aabbspace = abs( unclipped * safeInverse(extent) );
                float max_comp  = maxComponent(aabbspace);

                if( max_comp > 1.0 )
                {
                    // point outside aabb
                    return center + unclipped / max_comp;
                }
                else
                {
                    // point inside aabb
                    return color_input;
                }
            }

            void neighborhood_min_max_3(uint2 pixelCoords, inout float3 color_min, inout float3 color_max, bool useVarianceClipping )
            {
                int filterWidth = 1;
                int totalSamples = (filterWidth*2)+1;
	            totalSamples    *= totalSamples;

                float3 first_moment    = 0;
	            float3 second_moment   = 0;
                
                for (int x = -filterWidth; x <= filterWidth; ++x) {
                    for (int y = -filterWidth; y <= filterWidth; ++y) {
                        
                        float3 s = LOAD_TEXTURE2D_X(_MainTex, pixelCoords + uint2(x,y)).xyz;
                        color_min = min(color_min, s);
                        color_max = max(color_max, s);

                        if(useVarianceClipping)
			            {
				            first_moment  += s;
				            second_moment += s*s;
			            }
                    }
                }

                if(useVarianceClipping)
	            {
                    float gamma = 1.0;
                    float3 mu     = first_moment / totalSamples;
                    float3 sigma  = sqrt( (second_moment / totalSamples) - mu*mu);

                    float3 color_min_vc = mu - gamma * sigma;
                    float3 color_max_vc = mu + gamma * sigma;

                    color_min = clamp(color_min_vc, color_min, color_max);
                    color_max = clamp(color_max_vc, color_min, color_max);
                }

            }

            half4 frag(Varyings input) : SV_Target
            {
                UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(input);
                uint2 pixelCoords = convertToPixelCoords(input.uv);
                float3 curCol = LOAD_TEXTURE2D_X(_MainTex, pixelCoords).rgb;

                //temporal reprojection
                float d0 = loadDepth(pixelCoords);
                float d01 = (d0 * (_ProjectionParams.z - _ProjectionParams.y) + _ProjectionParams.y) / _ProjectionParams.z; // why this step? d0 already has Linear01Depth(d0) applied
                float3 pos = float3(input.uv * 2.0 - 1.0, 1.0);
                float4 rd = mul(_invP[unity_eyeIndex], float4(pos, 1));
                rd.xyz /= rd.w;

                // ENABLE ONLY FOR TAA-TEST CONDITION !!!
                // Manual Hack TAA-on-off based on world space position...
                //float4 fragmentWS = mul(_Debug_CameraToWorldMatrix[unity_eyeIndex], float4(rd.xyz * d01, 1));
                //if(fragmentWS.x < 0)
                //    return float4(curCol, 1);
                // Manual Hack TAA-on-off based on world space position...


                float4 temporalUV = mul(_FrameMatrix[unity_eyeIndex], float4(rd.xyz * d01, 1));
                temporalUV /= temporalUV.w;                 
                float2 temporalUV_01 = temporalUV.xy*0.5+0.5;

                // Naive bilinear sampling
                // float3 lastCol = SAMPLE_TEXTURE2D_X(_TemporalAATexture, sampler_TemporalAATexture, temporalUV.xy*0.5+0.5).xyz;
                // Bicubic Sampling - improves sharpness
                float3 lastCol = bicubicSample_CatmullRom(TEXTURE2D_X_ARGS(_TemporalAATexture, sampler_TemporalAATexture), temporalUV_01, _ScreenParams.xy ).rgb;

                // temporal blending of samples which have previously been culled from the periphery causes noticeable ghosting, best to ignore taa for these samples
                float fovealCenter_offset    = 0.05 * (1.0 - 2.0*unity_eyeIndex); // offset the center of each eye in the nasal direction (inwards towards the nose), due to asymmetric projection frusta
                float2 fovealCenter          = float2(0.5 + fovealCenter_offset, 0.5);
                float dist_from_center       = length(fovealCenter - temporalUV_01);
                float eccentricity_threshold = 0.3;

                if (abs(temporalUV.x) > 1 || abs(temporalUV.y) > 1 || dist_from_center > eccentricity_threshold)
                    lastCol = curCol;

                // Neighbourhood clipping
                float3 minCol = curCol;
                float3 maxCol = curCol;
                neighborhood_min_max_3(pixelCoords, minCol, maxCol, true );
                lastCol = clip_color_approx(lastCol, minCol, maxCol);
                // Lerp current color with clipped history-buffer color
                float3 finalCol = lerp(curCol, lastCol, _TemporalFade);
                // NaN and INF safeguard
                if (AnyIsNaN(finalCol) || AnyIsInf(finalCol))
                    finalCol = float3(0,0,0);

                return float4(finalCol.rgb, 1);
            }
            ENDHLSL
        }
    }
}
