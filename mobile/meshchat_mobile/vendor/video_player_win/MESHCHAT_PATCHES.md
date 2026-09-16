# MeshChat Patches

Vendored from video_player_win 3.3.0 (MIT; see LICENSE).

- Set the normalized source rectangle to the full 0,0,1,1 frame explicitly.
- Bound the render loop when a display has no usable vertical-blank wait.

Media Foundation source-rectangle contract:
https://learn.microsoft.com/en-us/windows/win32/api/mfmediaengine/nf-mfmediaengine-imfmediaengine-transfervideoframe
