// From: https://github.com/SlightlyMad/SimpleDxrPathTracer
// #ifndef COMMON_CGING
// #define COMMON_CGING

// #include "UnityShaderVariables.cginc" // Inclusion results in redefinitions of many values, as URP defines them again for us. I think we are good not including it as we do not need it(?)
#include "UnityRaytracingMeshUtils.cginc"



#ifndef SHADER_STAGE_COMPUTE
// raytracing scene
RaytracingAccelerationStructure  _RaytracingAccelerationStructure;
#endif

#define RAYTRACING_OPAQUE_FLAG      0x0f
#define RAYTRACING_TRANSPARENT_FLAG 0xf0


// ray payload
struct RayPayload
{
	// Color of the ray
	float4 radiance;
	float  random;
	// Recursion depth
	uint   depth;
	bool   rayEyeIndex; // 0: left, 1: right
	float  spreadAngle; // used for MipMapping based on ray cones
};

// DEFINED BY UNITY: Triangle attributes
struct AttributeData
{
	// Barycentric value of the intersection
	float2 barycentrics;
};

// compute random seed from one input
// http://reedbeta.com/blog/quick-and-easy-gpu-random-numbers-in-d3d11/
uint initRand(uint seed)
{
	seed = (seed ^ 61) ^ (seed >> 16);
	seed *= 9;
	seed = seed ^ (seed >> 4);
	seed *= 0x27d4eb2d;
	seed = seed ^ (seed >> 15);

	return seed;
}

// compute random seed from two inputs
// https://github.com/nvpro-samples/optix_prime_baking/blob/master/random.h
uint initRand(uint seed1, uint seed2)
{
	uint seed = 0;

	[unroll]
	for(uint i = 0; i < 16; i++)
	{
		seed += 0x9e3779b9;
		seed1 += ((seed2 << 4) + 0xa341316c) ^ (seed2 + seed) ^ ((seed2 >> 5) + 0xc8013ea4);
		seed2 += ((seed1 << 4) + 0xad90777d) ^ (seed1 + seed) ^ ((seed1 >> 5) + 0x7e95761e);
	}
	
	return seed1;
}

// next random number
// http://reedbeta.com/blog/quick-and-easy-gpu-random-numbers-in-d3d11/
float nextRand(inout uint seed)
{
	seed = 1664525u * seed + 1013904223u;
	return float(seed & 0x00FFFFFF) / float(0x01000000);
}

/*
* From Pixar with love: https://graphics.pixar.com/library/OrthonormalB/paper.pdf
* Does not require a random start tangent and is therefore computationally stable. Also no normalization required
*/
void buildOrthonormalBasis(float3 n, inout float3 tangent, inout float3 bitangent)
{
	n.z            += 0.00001; // Add small Delta to avoid n.z == 0
    float s         = sign(n.z);
	float a         = -1.0f / (s + n.z);
	float b         = n.x * n.y * a;
	tangent   = float3( (1.0f + s * n.x * n.x * a), (s * b), (-s * n.x) );
	bitangent = float3( (b), (s + n.y * n.y * a), (-n.y) );
}

// returns a transformation from normal-space to world-space
float3x3 getInvNormalSpace(float3 normal)
{
	float3 tangent;
	float3 biTangent;
	buildOrthonormalBasis(normal, tangent, biTangent);

	float3x3 result;	
	result._m00 = tangent.x;   result._m01 = biTangent.x; result._m02 = normal.x;
	result._m10 = tangent.y;   result._m11 = biTangent.y; result._m12 = normal.y;
	result._m20 = tangent.z;   result._m21 = biTangent.z; result._m22 = normal.z;
	return result;
}

// Macro that interpolate any attribute using barycentric coordinates
#define INTERPOLATE_RAYTRACING_ATTRIBUTE(A0, A1, A2, BARYCENTRIC_COORDINATES) (A0 * BARYCENTRIC_COORDINATES.x + A1 * BARYCENTRIC_COORDINATES.y + A2 * BARYCENTRIC_COORDINATES.z)

// Structure to fill for intersections (Used for vertices as well as interpolated fragments)
struct IntersectionInfo
{
	// Object space position
	float3 position;
	// Object space normal
	float3 normal;
	// Object space tangent
	float4 tangent;
	// UV coordinates
	float2 texCoord0;
	float2 texCoord1;
	float2 texCoord2;
	float2 texCoord3;
	// Vertex color
	float4 color;
	// Value used for LOD sampling
	float  triangleAreaWS;
	float  texCoord0Area;
	float  texCoord1Area;
	float  texCoord2Area;
	float  texCoord3Area;
};

// Fetch the intersetion vertex data given by vertex index
void FetchIntersectionVertex(uint vertexIndex, out IntersectionInfo outVertex)
{
	outVertex.position   = UnityRayTracingFetchVertexAttribute3(vertexIndex, kVertexAttributePosition);
	outVertex.normal     = UnityRayTracingFetchVertexAttribute3(vertexIndex, kVertexAttributeNormal);
	outVertex.tangent    = UnityRayTracingFetchVertexAttribute4(vertexIndex, kVertexAttributeTangent);
	outVertex.texCoord0  = UnityRayTracingFetchVertexAttribute2(vertexIndex, kVertexAttributeTexCoord0);
	outVertex.texCoord1  = UnityRayTracingFetchVertexAttribute2(vertexIndex, kVertexAttributeTexCoord1);
	outVertex.texCoord2  = UnityRayTracingFetchVertexAttribute2(vertexIndex, kVertexAttributeTexCoord2);
	outVertex.texCoord3  = UnityRayTracingFetchVertexAttribute2(vertexIndex, kVertexAttributeTexCoord3);
	outVertex.color      = UnityRayTracingFetchVertexAttribute4(vertexIndex, kVertexAttributeColor);
}

void GetCurrentIntersection(AttributeData attributeData, out IntersectionInfo intersection)
{
	// Fetch the indices of the current triangle
	uint3 triangleIndices = UnityRayTracingFetchTriangleIndices(PrimitiveIndex());

	// Fetch the 3 vertices
	IntersectionInfo v0, v1, v2;
	FetchIntersectionVertex(triangleIndices.x, v0);
	FetchIntersectionVertex(triangleIndices.y, v1);
	FetchIntersectionVertex(triangleIndices.z, v2);

	// Compute the full barycentric coordinates
	float3 barycentricCoordinates = float3(1.0 - attributeData.barycentrics.x - attributeData.barycentrics.y, attributeData.barycentrics.x, attributeData.barycentrics.y);

	// Interpolate all the data
	intersection.position   = INTERPOLATE_RAYTRACING_ATTRIBUTE(v0.position, v1.position, v2.position, barycentricCoordinates);
	intersection.normal     = INTERPOLATE_RAYTRACING_ATTRIBUTE(v0.normal, v1.normal, v2.normal, barycentricCoordinates);
	intersection.tangent    = INTERPOLATE_RAYTRACING_ATTRIBUTE(v0.tangent, v1.tangent, v2.tangent, barycentricCoordinates);
	intersection.texCoord0  = INTERPOLATE_RAYTRACING_ATTRIBUTE(v0.texCoord0, v1.texCoord0, v2.texCoord0, barycentricCoordinates);
	intersection.texCoord1  = INTERPOLATE_RAYTRACING_ATTRIBUTE(v0.texCoord1, v1.texCoord1, v2.texCoord1, barycentricCoordinates);
	intersection.texCoord2  = INTERPOLATE_RAYTRACING_ATTRIBUTE(v0.texCoord2, v1.texCoord2, v2.texCoord2, barycentricCoordinates);
	intersection.texCoord3  = INTERPOLATE_RAYTRACING_ATTRIBUTE(v0.texCoord3, v1.texCoord3, v2.texCoord3, barycentricCoordinates);
	intersection.color      = INTERPOLATE_RAYTRACING_ATTRIBUTE(v0.color, v1.color, v2.color, barycentricCoordinates);

	// Compute the lambda value (area computed in world space)
	v0.position = mul(ObjectToWorld3x4(), v0.position);
	v1.position = mul(ObjectToWorld3x4(), v1.position);
	v2.position = mul(ObjectToWorld3x4(), v2.position);

	intersection.triangleAreaWS = length(cross(v1.position - v0.position, v2.position - v0.position));
	intersection.texCoord0Area  = abs((v1.texCoord0.x - v0.texCoord0.x) * (v2.texCoord0.y - v0.texCoord0.y) - (v2.texCoord0.x - v0.texCoord0.x) * (v1.texCoord0.y - v0.texCoord0.y));
	intersection.texCoord1Area  = abs((v1.texCoord1.x - v0.texCoord1.x) * (v2.texCoord1.y - v0.texCoord1.y) - (v2.texCoord1.x - v0.texCoord1.x) * (v1.texCoord1.y - v0.texCoord1.y));
	intersection.texCoord2Area  = abs((v1.texCoord2.x - v0.texCoord2.x) * (v2.texCoord2.y - v0.texCoord2.y) - (v2.texCoord2.x - v0.texCoord2.x) * (v1.texCoord2.y - v0.texCoord2.y));
	intersection.texCoord3Area  = abs((v1.texCoord3.x - v0.texCoord3.x) * (v2.texCoord3.y - v0.texCoord3.y) - (v2.texCoord3.x - v0.texCoord3.x) * (v1.texCoord3.y - v0.texCoord3.y));
}

// #endif // COMMON_CGING