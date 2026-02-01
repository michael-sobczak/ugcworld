# Manual VoxelTerrain Setup

After installing Voxel Tools addon, add a VoxelTerrain to Main.tscn:

## Steps

1. Open `client/scenes/Main.tscn` in Godot Editor

2. Select the `VoxelWorld` node

3. Add Child Node > Search for `VoxelTerrain` > Create

4. Select the new `VoxelTerrain` node

5. In Inspector, configure:

   **Generator** (create new VoxelGeneratorFlat):
   - Height: -1000 (this makes the world start empty)
   - Channel: 0
   
   **Mesher** (create new VoxelMesherBlocky or VoxelMesherCubes):
   - Default settings are fine
   
   **Bounds** (if available):
   - Min: (-512, -128, -512)
   - Max: (512, 128, 512)

6. Make sure VoxelTerrain is ABOVE VoxelBackend in the node tree
   (so VoxelBackend can find it on _ready)

7. Save the scene

## Alternative: VoxelLodTerrain

For larger worlds with level-of-detail:

1. Add `VoxelLodTerrain` instead of `VoxelTerrain`
2. Configure `lod_count` (e.g., 4)
3. Use `VoxelMesherTransvoxel` for smoother terrain
4. Same generator setup applies

## Testing

1. Run the scene (F5 or click Play)
2. Press F1 to start local server
3. Press 1 to create land
4. You should see voxel terrain appear!

If terrain doesn't appear:
- Check console for VoxelBackend messages
- Verify VoxelTerrain is in the scene tree
- Ensure addon is properly installed (VoxelTerrain class exists)
