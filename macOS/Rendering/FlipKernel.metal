#include <metal_stdlib>
using namespace metal;

// Horizontally flips a texture (mirror effect).
kernel void horizontalFlip(
    texture2d<float, access::read>  inTex  [[texture(0)]],
    texture2d<float, access::write> outTex [[texture(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= inTex.get_width() || gid.y >= inTex.get_height()) { return; }
    uint flippedX = inTex.get_width() - 1u - gid.x;
    outTex.write(inTex.read(uint2(flippedX, gid.y)), gid);
}
