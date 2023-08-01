# URP-VR-Raytracing
This plugin was developed for the publication "The Impact of Reflection Approximations on Visual Quality in Virtual Reality" - Mišiak et al. 2023
https://dl.acm.org/doi/10.1145/3605495.3605794

![Title_Figure](https://github.com/MartinMisiak/URP-VR-Raytracing/assets/40168931/c168f74d-1328-4771-8ffc-1d39e4d80853)



Hardware accelerated raytraced reflections for use in VR. Developed and tested with Unity 2021.3.6f1, Universal RP 12.1.7, OpenXR Plugin 1.4.2

# Ultra Quick Start
- Download repository and open as Unity project (tested on Unity 2021.3.6f1)
- Import test scene from Resources link
- Raytraced reflections should be visible in the editor viewport

# Integration into existing project
- Copy the "Editor" and "RenderFeatures" folders into your project
- Raytracing is implemented as a URP Render Feature. Make sure to add it to your "Universal Renderer Data" asset (same as adding SSAO for example)
- All objects that are considered during raytracing (are reflective themselves and are visible in the reflections) have to use the "CustomShaders/Lit" Material. This is an extension of the standard "Universal Render Pipeline/Lit" material. The "Environment Reflection Mode" of the material has to be set to "Raytraced". For objects which should only appear in reflections, the reflection mode can be set to "Unity_Default".
- The Unity player has to use DirectX 12. Without it, DirectX Raytracing will not work

# Render Feature Settings
- Downsampling Factor: Allows to calculate reflections at a much lower resolution (very naive upsampling)
- Primary Rays: Number of traced primary rays
- Reflection Rays: Number of reflection rays that are spawned when a primary ray hits a reflective surface
- Cull Periphery Rays: Does not generate primary rays in the peripheral regions
- Use Temporal Accumulation: Basically TAA, but applied only to reflections
- Temporal Fade: Weight of the previous frame during temporal accumulation

# Known Limitations
- Does not properly interact with URP "Render Scale" option
- Works only for Single-Pass Instanced. Multi-Pass is not supported.
- Objects which are marked as static in terms of Batching (Batching Static) are rendered wrong during the raytracing pass.
 This issue is probably due to Unity creating a shared material buffer for all batched meshes. This shared buffer clashes with the RT shader...
- Also objects marked as Batching Static lead to a terrible performance during raytracing. In summary, avoid marking any object as Batching Static if it should interact with raytracing in any way!!! 

# Possible Future Improvements
- Periphery Culling is implemented using a random ray termination technique based on a linear falloff. This leads to performance improvements only for areas where rays are completely culled.
Culling areas inbetween does not improve performance, as this causes idling SIMT/D lanes. A better approach would be to cull in an alternative foveal space instead of screen space...(Visual-Polar Space, Koskela et al. 2019)
- Determine the amount of traced rays based on material roughness.
- Temporal reprojection can be significantly improved if motion vectors are used

# Resources
A test scene for raytraced reflections:  
https://1drv.ms/u/s!Ap1NX8WBfJHQgtRIhIy9wTk81d02Mg?e=KyG0JC
