//
//  Shaders.metal
//  AirScreen
//
//  将 NV12（YCbCr 4:2:0 双平面）纹理转换为 RGB 并渲染到屏幕
//
//  NV12 格式：
//    平面 0：Y（亮度），每像素 1 字节，尺寸 = 完整分辨率
//    平面 1：UV（色度），每像素 2 字节，尺寸 = 宽/2 × 高/2（4:2:0 下采样）
//
//  YCbCr → RGB 转换使用 BT.601 矩阵（SD）或 BT.709 矩阵（HD，iOS屏幕镜像使用）
//

#include <metal_stdlib>
using namespace metal;

// MARK: - 顶点结构

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

// MARK: - 顶点着色器
// 使用 triangle strip 绘制两个三角形（覆盖整个 NDC 空间）
// 顶点顺序：左下、右下、左上、右上
vertex VertexOut vertexShader(uint vertexID [[vertex_id]]) {
    // NDC 坐标（-1..1）
    const float4 positions[4] = {
        float4(-1.0, -1.0, 0.0, 1.0),
        float4( 1.0, -1.0, 0.0, 1.0),
        float4(-1.0,  1.0, 0.0, 1.0),
        float4( 1.0,  1.0, 0.0, 1.0),
    };
    // UV 坐标（0..1，注意 Metal 纹理 Y 轴向下）
    const float2 texCoords[4] = {
        float2(0.0, 1.0),
        float2(1.0, 1.0),
        float2(0.0, 0.0),
        float2(1.0, 0.0),
    };

    VertexOut out;
    out.position = positions[vertexID];
    out.texCoord = texCoords[vertexID];
    return out;
}

// MARK: - 片段着色器：NV12 → RGB（BT.709，适合 HD 内容）
fragment float4 fragmentShaderNV12(
    VertexOut            in          [[stage_in]],
    texture2d<float>     lumaTexture [[texture(0)]],   // Y 平面
    texture2d<float>     chromaTexture [[texture(1)]]  // UV 平面
) {
    constexpr sampler textureSampler(filter::linear, address::clamp_to_edge);

    // 采样 Y 和 UV
    float  y  = lumaTexture.sample(textureSampler, in.texCoord).r;
    float2 uv = chromaTexture.sample(textureSampler, in.texCoord).rg;

    // YCbCr 转 RGB（BT.709 有限范围，Limited Range）
    // Y:  16..235  → 0..1
    // UV: 16..240  → -0.5..0.5
    y  = (y  - 16.0  / 255.0) * (255.0 / 219.0);
    uv = (uv - 128.0 / 255.0) * (255.0 / 224.0);

    float cb = uv.x;
    float cr = uv.y;

    // BT.709 矩阵
    float r = y + 1.5748 * cr;
    float g = y - 0.1873 * cb - 0.4681 * cr;
    float b = y + 1.8556 * cb;

    return float4(clamp(r, 0.0, 1.0),
                  clamp(g, 0.0, 1.0),
                  clamp(b, 0.0, 1.0),
                  1.0);
}

// MARK: - 片段着色器：NV12 → RGB（BT.601，适合 SD 内容）
fragment float4 fragmentShaderNV12_BT601(
    VertexOut            in          [[stage_in]],
    texture2d<float>     lumaTexture [[texture(0)]],
    texture2d<float>     chromaTexture [[texture(1)]]
) {
    constexpr sampler s(filter::linear);

    float  y  = lumaTexture.sample(s, in.texCoord).r;
    float2 uv = chromaTexture.sample(s, in.texCoord).rg - 0.5;

    // BT.601 简化矩阵（Full Range 版）
    float r = y + 1.402  * uv.y;
    float g = y - 0.3441 * uv.x - 0.7141 * uv.y;
    float b = y + 1.772  * uv.x;

    return float4(clamp(r, 0.0, 1.0),
                  clamp(g, 0.0, 1.0),
                  clamp(b, 0.0, 1.0),
                  1.0);
}
