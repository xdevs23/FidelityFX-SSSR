/**********************************************************************
Copyright (c) 2020 Advanced Micro Devices, Inc. All rights reserved.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
********************************************************************/

#ifndef FFX_SSSR_INTERSECT
#define FFX_SSSR_INTERSECT

// In:
[[vk::binding(0, 1)]] Texture2D<FFX_SSSR_SCENE_TEXTURE_FORMAT> g_lit_scene                    : register(t0); // scene rendered with lighting and shadows
[[vk::binding(1, 1)]] Texture2D<FFX_SSSR_DEPTH_TEXTURE_FORMAT> g_depth_buffer_hierarchy       : register(t1);
[[vk::binding(2, 1)]] Texture2D<FFX_SSSR_NORMALS_TEXTURE_FORMAT> g_normal                     : register(t2);
[[vk::binding(3, 1)]] Texture2D<FFX_SSSR_ROUGHNESS_TEXTURE_FORMAT> g_roughness                : register(t3);
[[vk::binding(4, 1)]] TextureCube g_environment_map                                           : register(t4);
[[vk::binding(5, 1)]] Buffer<uint> g_sobol_buffer                                             : register(t5);
[[vk::binding(6, 1)]] Buffer<uint> g_ranking_tile_buffer                                      : register(t6);
[[vk::binding(7, 1)]] Buffer<uint> g_scrambling_tile_buffer                                   : register(t7);
[[vk::binding(8, 1)]] Buffer<uint> g_ray_list                                                 : register(t8);

// Samplers:
[[vk::binding(9, 1)]] SamplerState g_linear_sampler                                           : register(s0);
[[vk::binding(10, 1)]] SamplerState g_environment_map_sampler                                 : register(s1);

// Out:
[[vk::binding(11, 1)]] RWTexture2D<float4> g_intersection_result                              : register(u0); // reflection colors at the end of the intersect pass. 
[[vk::binding(12, 1)]] RWTexture2D<float> g_ray_lengths                                       : register(u1);
[[vk::binding(13, 1)]] RWTexture2D<float4> g_denoised_reflections                             : register(u2); // Mirror reflections don't need to be denoised, the intersection pass can just write them to the final target.

// Blue Noise Sampler by Eric Heitz. Returns a value in the range [0, 1].
float SampleRandomNumber(in uint pixel_i, in uint pixel_j, in uint sample_index, in uint sample_dimension)
{
    // Wrap arguments
    pixel_i = pixel_i & 127u;
    pixel_j = pixel_j & 127u;
    sample_index = sample_index & 255u;
    sample_dimension = sample_dimension & 255u;

    // xor index based on optimized ranking
    const uint ranked_sample_index = sample_index ^ g_ranking_tile_buffer[sample_dimension + (pixel_i + pixel_j * 128u) * 8u];

    // Fetch value in sequence
    uint value = g_sobol_buffer[sample_dimension + ranked_sample_index * 256u];

    // If the dimension is optimized, xor sequence value based on optimized scrambling
    value = value ^ g_scrambling_tile_buffer[(sample_dimension % 8u) + (pixel_i + pixel_j * 128u) * 8u];

    // Convert to float and return
    return (value + 0.5f) / 256.0f;
}

float2 SampleRandomVector2(uint2 pixel)
{
    const uint sample_index = 0;
    float2 u = float2(
        fmod(SampleRandomNumber(pixel.x, pixel.y, sample_index, 0u) + (g_frame_index & 0xFFu) * FFX_SSSR_GOLDEN_RATIO, 1.0f),
        fmod(SampleRandomNumber(pixel.x, pixel.y, sample_index, 1u) + (g_frame_index & 0xFFu) * FFX_SSSR_GOLDEN_RATIO, 1.0f));
    return u;
}

#define M_PI FFX_SSSR_PI

// http://jcgt.org/published/0007/04/01/paper.pdf by Eric Heitz
// Input Ve: view direction
// Input alpha_x, alpha_y: roughness parameters
// Input U1, U2: uniform random numbers
// Output Ne: normal sampled with PDF D_Ve(Ne) = G1(Ve) * max(0, dot(Ve, Ne)) * D(Ne) / Ve.z
float3 sampleGGXVNDF(float3 Ve, float alpha_x, float alpha_y, float U1, float U2)
{
    // Section 3.2: transforming the view direction to the hemisphere configuration
    float3 Vh = normalize(float3(alpha_x * Ve.x, alpha_y * Ve.y, Ve.z));
    // Section 4.1: orthonormal basis (with special case if cross product is zero)
    float lensq = Vh.x * Vh.x + Vh.y * Vh.y;
    float3 T1 = lensq > 0 ? float3(-Vh.y, Vh.x, 0) * rsqrt(lensq) : float3(1, 0, 0);
    float3 T2 = cross(Vh, T1);
    // Section 4.2: parameterization of the projected area
    float r = sqrt(U1);
    float phi = 2.0 * M_PI * U2;
    float t1 = r * cos(phi);
    float t2 = r * sin(phi);
    float s = 0.5 * (1.0 + Vh.z);
    t2 = (1.0 - s) * sqrt(1.0 - t1 * t1) + s * t2;
    // Section 4.3: reprojection onto hemisphere
    float3 Nh = t1 * T1 + t2 * T2 + sqrt(max(0.0, 1.0 - t1 * t1 - t2 * t2)) * Vh;
    // Section 3.4: transforming the normal back to the ellipsoid configuration
    float3 Ne = normalize(float3(alpha_x * Nh.x, alpha_y * Nh.y, max(0.0, Nh.z)));
    return Ne;
}

float3 Sample_GGX_VNDF_Ellipsoid(float3 Ve, float alpha_x, float alpha_y, float U1, float U2)
{
    return sampleGGXVNDF(Ve, alpha_x, alpha_y, U1, U2);
}

float3 Sample_GGX_VNDF_Hemisphere(float3 Ve, float alpha, float U1, float U2)
{
    return Sample_GGX_VNDF_Ellipsoid(Ve, alpha, alpha, U1, U2);
}

float3x3 CreateTBN(float3 N)
{
    float3 U;
    if (abs(N.z) > 0.0)
    {
        float k = sqrt(N.y * N.y + N.z * N.z);
        U.x = 0.0; U.y = -N.z / k; U.z = N.y / k;
    }
    else
    {
        float k = sqrt(N.x * N.x + N.y * N.y);
        U.x = N.y / k; U.y = -N.x / k; U.z = 0.0;
    }

    float3x3 TBN;
    TBN[0] = U;
    TBN[1] = cross(N, U);
    TBN[2] = N;
    return transpose(TBN);
}

float3 SampleReflectionVector(float3 view_direction, float3 normal, float roughness, int2 did)
{
    float3x3 tbn_transform = CreateTBN(normal);
    float3 view_direction_tbn = mul(-view_direction, tbn_transform);

    float2 u = SampleRandomVector2(did);
    
    float3 sampled_normal_tbn = Sample_GGX_VNDF_Hemisphere(view_direction_tbn, roughness, u.x, u.y);
    // sampled_normal_tbn = float3(0, 0, 1); // Overwrite normal sample to produce perfect reflection.

    float3 reflected_direction_tbn = reflect(-view_direction_tbn, sampled_normal_tbn);

    // Transform reflected_direction back to the initial space.
    float3x3 inv_tbn_transform = transpose(tbn_transform);
    return mul(reflected_direction_tbn, inv_tbn_transform);
}

float2 GetMipResolution(float2 screen_dimensions, int mip_level)
{
    return screen_dimensions * pow(0.5, mip_level);
}

float LoadDepth(float2 idx, int mip)
{
    return FfxSssrUnpackDepth(g_depth_buffer_hierarchy.Load(int3(idx, mip)));
}

void InitialAdvanceRay(float3 origin, float3 direction, float3 inv_direction, float2 current_mip_resolution, float2 current_mip_resolution_inv, float2 floor_offset, float2 uv_offset, out float3 position, out float current_t)
{
    float2 current_mip_position = current_mip_resolution * origin.xy;

    // Intersect ray with the half box that is pointing away from the ray origin.
    float2 xy_plane = floor(current_mip_position) + floor_offset;
    xy_plane = xy_plane * current_mip_resolution_inv + uv_offset;

    // o + d * t = p' => t = (p' - o) / d
    float2 t = (xy_plane - origin.xy) * inv_direction.xy;
    current_t = min(t.x, t.y);
    position = origin + current_t * direction;
}


bool AdvanceRay(float3 origin, float3 direction, float3 inv_direction, float2 current_mip_position, float2 current_mip_resolution_inv, float2 floor_offset, float2 uv_offset, float surface_z, inout float3 position, inout float current_t)
{
    // Create boundary planes
    float2 xy_plane = floor(current_mip_position) + floor_offset;
    xy_plane = xy_plane * current_mip_resolution_inv + uv_offset;
    float3 boundary_planes = float3(xy_plane, surface_z);

    // Intersect ray with the half box that is pointing away from the ray origin.
    // o + d * t = p' => t = (p' - o) / d
    float3 t = (boundary_planes - origin) * inv_direction;

    // Prevent using z plane when shooting out of the depth buffer.
    t.z = direction.z > 0 ? t.z : FFX_SSSR_FLOAT_MAX;

    // Choose nearest intersection with a boundary.
    float t_min = min(min(t.x, t.y), t.z);

    // Smaller z means closer to the camera.
    bool above_surface = surface_z > position.z;

    // Decide whether we are able to advance the ray until we hit the xy boundaries or if we had to clamp it at the surface.
    bool skipped_tile = t_min != t.z && above_surface;

    // Make sure to only advance the ray if we're still above the surface.
    current_t = above_surface ? t_min : current_t;

    // Advance ray
    position = origin + current_t * direction;

    return skipped_tile;
}

// Requires origin and direction of the ray to be in screen space [0, 1] x [0, 1]
float3 HierarchicalRaymarch(float3 origin, float3 direction, bool is_mirror, float2 screen_size, out bool valid_hit)
{
    int most_detailed_mip = is_mirror ? 0 : g_most_detailed_mip;

    const float3 inv_direction = direction != 0 ? 1.0 / direction : FFX_SSSR_FLOAT_MAX;

    // Start on mip with highest detail.
    int current_mip = most_detailed_mip;

    // Could recompute these every iteration, but it's faster to hoist them out and update them.
    float2 current_mip_resolution = GetMipResolution(screen_size, current_mip);
    float2 current_mip_resolution_inv = rcp(current_mip_resolution);

    // Offset to the bounding boxes in uv space to intersect the ray with the center of the next pixel.
    // This means we ever so slightly over shoot into the next region. 
    float2 uv_offset = 0.005 * exp2(most_detailed_mip) / screen_size;
    uv_offset = direction.xy < 0 ? -uv_offset : uv_offset;

    // Offset applied depending on current mip resolution to move the boundary to the left/right upper/lower border depending on ray direction.
    float2 floor_offset = direction.xy < 0 ? 0 : 1;
    
    // Initially advance ray to avoid immediate self intersections.
    float current_t;
    float3 position;
    InitialAdvanceRay(origin, direction, inv_direction, current_mip_resolution, current_mip_resolution_inv, floor_offset, uv_offset, position, current_t);

    const uint min_traversal_occupancy = g_min_traversal_occupancy;
    const uint max_traversal_intersections = g_max_traversal_intersections;

    bool exit_due_to_low_occupancy = false;
    int i = 0;
    while (i < max_traversal_intersections && current_mip >= most_detailed_mip && !exit_due_to_low_occupancy)
    {
        float2 current_mip_position = current_mip_resolution * position.xy;
        float surface_z = LoadDepth(current_mip_position, current_mip);
        bool skipped_tile = AdvanceRay(origin, direction, inv_direction, current_mip_position, current_mip_resolution_inv, floor_offset, uv_offset, surface_z, position, current_t);
        current_mip += skipped_tile ? 1 : -1;
        current_mip_resolution *= skipped_tile ? 0.5 : 2;
        current_mip_resolution_inv *= skipped_tile ? 2 : 0.5;
        ++i;

        exit_due_to_low_occupancy = !is_mirror && WaveActiveCountBits(true) <= min_traversal_occupancy;
    }

    valid_hit = (i < max_traversal_intersections);

    return position;
}

float ValidateHit(float3 hit, Ray reflected_ray, float3 world_space_ray_direction, float2 screen_size)
{
    // Reject hits outside the view frustum
    if (any(hit.xy < 0) || any(hit.xy > 1))
    {
        return 0;
    }

    // Don't lookup radiance from the background.
    int2 texel_coords = int2(screen_size * hit.xy);
    float surface_z = LoadDepth(texel_coords / 2, 1);
    if (surface_z == 1.0)
    {
        return 0;
    }

    // We check if we hit the surface from the back, these should be rejected.
    float3 hit_normal = LoadNormal(texel_coords, g_normal);
    if (dot(hit_normal, world_space_ray_direction) > 0)
    {
        return 0;
    }

    float3 view_space_surface = CreateViewSpaceRay(float3(hit.xy, surface_z)).origin;
    float3 view_space_hit = CreateViewSpaceRay(hit).origin;
    float distance = length(view_space_surface - view_space_hit);

    // Fade out hits near the screen borders
    float2 fov = 0.05 * float2(screen_size.y / screen_size.x, 1);
    float2 border = smoothstep(0, fov, hit.xy) * (1 - smoothstep(1 - fov, 1, hit.xy));
    float vignette = border.x * border.y;

    // We accept all hits that are within a reasonable minimum distance below the surface.
    // Add constant in linear space to avoid growing of the reflections toward the reflected objects.
    float confidence = 1 - smoothstep(0, g_depth_buffer_thickness, distance);
    confidence *= confidence;

    return vignette * confidence;
}

void Intersect(int2 did)
{
    uint2 screen_size;
    g_intersection_result.GetDimensions(screen_size.x, screen_size.y);

    const uint skip_denoiser = g_skip_denoiser;

    float2 uv = (did + 0.5) / screen_size;
    float3 world_space_normal = LoadNormal(did, g_normal);
    float roughness = LoadRoughness(did, g_roughness);
    bool is_mirror = IsMirrorReflection(roughness);

    int most_detailed_mip = is_mirror ? 0 : g_most_detailed_mip;
    float2 mip_resolution = GetMipResolution(screen_size, most_detailed_mip);
    float z = LoadDepth(uv * mip_resolution, most_detailed_mip);

    Ray screen_space_ray;
    screen_space_ray.origin = float3(uv, z);

    Ray view_space_ray = CreateViewSpaceRay(screen_space_ray.origin);

    float3 view_space_surface_normal = mul(float4(normalize(world_space_normal), 0), g_view).xyz;
    float3 view_space_reflected_direction = SampleReflectionVector(view_space_ray.direction, view_space_surface_normal, roughness, did);
    screen_space_ray.direction = ProjectDirection(view_space_ray.origin, view_space_reflected_direction, screen_space_ray.origin, g_proj);

    bool valid_hit;
    float3 hit = HierarchicalRaymarch(screen_space_ray.origin, screen_space_ray.direction, is_mirror, screen_size, valid_hit);
    float3 world_space_reflected_direction = mul(float4(view_space_reflected_direction, 0), g_inv_view).xyz;
    float confidence = valid_hit ? ValidateHit(hit, screen_space_ray, world_space_reflected_direction, screen_size) : 0;

    float3 world_space_origin = InvProjectPosition(screen_space_ray.origin, g_inv_view_proj);
    float3 world_space_hit = InvProjectPosition(hit, g_inv_view_proj);
    float3 world_space_ray = world_space_hit - world_space_origin.xyz;

    float3 reflection_radiance = 0;
    if (confidence > 0)
    {
        // Found an intersection with the depth buffer -> We can lookup the color from lit scene.
        reflection_radiance = FfxSssrUnpackSceneRadiance(g_lit_scene.Load(int3(screen_size * hit.xy, 0)));
    }

    // Sample environment map.
    float3 environment_lookup = g_environment_map.SampleLevel(g_environment_map_sampler, world_space_reflected_direction, 0).xyz;
    reflection_radiance = confidence * reflection_radiance + (1 - confidence) * environment_lookup;

    g_intersection_result[did] = float4(reflection_radiance, 1);
    g_ray_lengths[did] = length(world_space_ray);

    // The denoisers won't copy the value of a mirror reflection, so we write it out to the final target
    int2 idx = (is_mirror || skip_denoiser) ? did : int2(-1, -1);
    g_denoised_reflections[idx] = float4(reflection_radiance.xyz, 1);
}

[numthreads(8, 8, 1)]
void main(uint group_index : SV_GroupIndex, uint group_id : SV_GroupID)
{
    // We can encounter some remainders here. 
    // Worst case is that they are tracing a few more rays than necessary but they can't produce artifacts.
    uint ray_index = group_id * 64 + group_index;
    uint packed_coords = g_ray_list[ray_index];
    uint2 coords = Unpack(packed_coords);
    Intersect((int2)coords);
}

#endif // FFX_SSSR_INTERSECT