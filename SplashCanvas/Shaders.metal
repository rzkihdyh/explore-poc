#include <metal_stdlib>
using namespace metal;

// MARK: - Shared types (must match GPUTypes.swift)

struct Splat {
    float2 start;
    float2 end;
    float2 velocity;
    float2 padding;
    float4 color;
    float radius;
    float drag;
    float cover;
    float swirl;
};

struct AdvectParams {
    float dt;
    float dissipation;
    float2 velocityTexel;
};

struct VorticityParams {
    float dt;
    float strength;
};

struct DisplayUniforms {
    float2 viewSize;
    float2 dyeTexel;
    float mode;
    float time;
    uint cursorCount;
    float padding;
};

struct CursorMark {
    float2 position;
    float radius;
    float progress;
    float4 color;
    float style;
    float alpha;
    float2 padding;
};

constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge,
                                filter::linear, mip_filter::linear);

static inline uint2 clampCoord(int2 c, uint2 size) {
    return uint2(clamp(c, int2(0), int2(size) - 1));
}

// Distance from p to the segment a-b; returns the offset vector.
static inline float2 segmentOffset(float2 p, float2 a, float2 b) {
    float2 pa = p - a;
    float2 ba = b - a;
    float h = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-8), 0.0, 1.0);
    return pa - ba * h;
}

// MARK: - Fluid simulation (stable fluids on a collocated grid)

kernel void clearTexture(texture2d<float, access::write> target [[texture(0)]],
                         uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= target.get_width() || gid.y >= target.get_height()) return;
    target.write(float4(0.0), gid);
}

kernel void splatVelocity(texture2d<float, access::read> source [[texture(0)]],
                          texture2d<float, access::write> target [[texture(1)]],
                          constant Splat *splats [[buffer(0)]],
                          constant uint &count [[buffer(1)]],
                          uint2 gid [[thread_position_in_grid]]) {
    uint2 size = uint2(target.get_width(), target.get_height());
    if (gid.x >= size.x || gid.y >= size.y) return;
    float2 sizeF = float2(size);
    float shortSide = min(sizeF.x, sizeF.y);
    float2 p = (float2(gid) + 0.5) / shortSide;
    float2 v = source.read(gid).xy;
    for (uint i = 0; i < count; i++) {
        Splat s = splats[i];
        float2 d = segmentOffset(p, s.start * sizeF / shortSide, s.end * sizeF / shortSide);
        float r2 = s.radius * s.radius;
        float d2 = dot(d, d);
        if (d2 > 9.0 * r2) continue;
        float g = exp(-d2 / r2);
        v += g * (s.velocity - s.drag * v);
        v += g * s.swirl * float2(-d.y, d.x) / s.radius;
    }
    target.write(float4(v, 0.0, 0.0), gid);
}

kernel void splatDye(texture2d<float, access::read> source [[texture(0)]],
                     texture2d<float, access::write> target [[texture(1)]],
                     constant Splat *splats [[buffer(0)]],
                     constant uint &count [[buffer(1)]],
                     uint2 gid [[thread_position_in_grid]]) {
    uint2 size = uint2(target.get_width(), target.get_height());
    if (gid.x >= size.x || gid.y >= size.y) return;
    float2 sizeF = float2(size);
    float shortSide = min(sizeF.x, sizeF.y);
    float2 p = (float2(gid) + 0.5) / shortSide;
    float4 dye = source.read(gid);
    for (uint i = 0; i < count; i++) {
        Splat s = splats[i];
        if (s.color.a <= 0.0 && s.cover <= 0.0) continue;
        float2 d = segmentOffset(p, s.start * sizeF / shortSide, s.end * sizeF / shortSide);
        float r2 = s.radius * s.radius;
        float d2 = dot(d, d);
        if (d2 > 9.0 * r2) continue;
        float g = exp(-d2 / r2);
        dye = dye * (1.0 - g * s.cover) + s.color * g;
    }
    // Keep density bounded while preserving hue.
    if (dye.a > 2.5) dye *= 2.5 / dye.a;
    target.write(max(dye, float4(0.0)), gid);
}

kernel void computeCurl(texture2d<float, access::read> velocity [[texture(0)]],
                        texture2d<float, access::write> curlOut [[texture(1)]],
                        uint2 gid [[thread_position_in_grid]]) {
    uint2 size = uint2(curlOut.get_width(), curlOut.get_height());
    if (gid.x >= size.x || gid.y >= size.y) return;
    int2 c = int2(gid);
    float L = velocity.read(clampCoord(c + int2(-1, 0), size)).y;
    float R = velocity.read(clampCoord(c + int2(1, 0), size)).y;
    float B = velocity.read(clampCoord(c + int2(0, -1), size)).x;
    float T = velocity.read(clampCoord(c + int2(0, 1), size)).x;
    curlOut.write(float4(0.5 * (R - L - T + B)), gid);
}

kernel void applyVorticity(texture2d<float, access::read> velocity [[texture(0)]],
                           texture2d<float, access::read> curl [[texture(1)]],
                           texture2d<float, access::write> target [[texture(2)]],
                           constant VorticityParams &params [[buffer(0)]],
                           uint2 gid [[thread_position_in_grid]]) {
    uint2 size = uint2(target.get_width(), target.get_height());
    if (gid.x >= size.x || gid.y >= size.y) return;
    int2 c = int2(gid);
    float L = curl.read(clampCoord(c + int2(-1, 0), size)).x;
    float R = curl.read(clampCoord(c + int2(1, 0), size)).x;
    float B = curl.read(clampCoord(c + int2(0, -1), size)).x;
    float T = curl.read(clampCoord(c + int2(0, 1), size)).x;
    float C = curl.read(gid).x;
    float2 force = 0.5 * float2(abs(T) - abs(B), abs(R) - abs(L));
    force /= length(force) + 0.0001;
    force *= params.strength * C;
    force.y *= -1.0;
    float2 v = velocity.read(gid).xy + force * params.dt;
    v = clamp(v, float2(-1000.0), float2(1000.0));
    target.write(float4(v, 0.0, 0.0), gid);
}

kernel void computeDivergence(texture2d<float, access::read> velocity [[texture(0)]],
                              texture2d<float, access::write> divergence [[texture(1)]],
                              uint2 gid [[thread_position_in_grid]]) {
    uint2 size = uint2(divergence.get_width(), divergence.get_height());
    if (gid.x >= size.x || gid.y >= size.y) return;
    int2 c = int2(gid);
    float2 C = velocity.read(gid).xy;
    float L = velocity.read(clampCoord(c + int2(-1, 0), size)).x;
    float R = velocity.read(clampCoord(c + int2(1, 0), size)).x;
    float B = velocity.read(clampCoord(c + int2(0, -1), size)).y;
    float T = velocity.read(clampCoord(c + int2(0, 1), size)).y;
    // Solid walls: reflect velocity at the borders.
    if (c.x == 0) L = -C.x;
    if (c.x == int(size.x) - 1) R = -C.x;
    if (c.y == 0) B = -C.y;
    if (c.y == int(size.y) - 1) T = -C.y;
    divergence.write(float4(0.5 * (R - L + T - B)), gid);
}

kernel void scaleTexture(texture2d<float, access::read> source [[texture(0)]],
                         texture2d<float, access::write> target [[texture(1)]],
                         constant float &factor [[buffer(0)]],
                         uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= target.get_width() || gid.y >= target.get_height()) return;
    target.write(source.read(gid) * factor, gid);
}

kernel void pressureJacobi(texture2d<float, access::read> pressure [[texture(0)]],
                           texture2d<float, access::read> divergence [[texture(1)]],
                           texture2d<float, access::write> target [[texture(2)]],
                           uint2 gid [[thread_position_in_grid]]) {
    uint2 size = uint2(target.get_width(), target.get_height());
    if (gid.x >= size.x || gid.y >= size.y) return;
    int2 c = int2(gid);
    float L = pressure.read(clampCoord(c + int2(-1, 0), size)).x;
    float R = pressure.read(clampCoord(c + int2(1, 0), size)).x;
    float B = pressure.read(clampCoord(c + int2(0, -1), size)).x;
    float T = pressure.read(clampCoord(c + int2(0, 1), size)).x;
    float div = divergence.read(gid).x;
    target.write(float4((L + R + B + T - div) * 0.25), gid);
}

kernel void subtractGradient(texture2d<float, access::read> pressure [[texture(0)]],
                             texture2d<float, access::read> velocity [[texture(1)]],
                             texture2d<float, access::write> target [[texture(2)]],
                             uint2 gid [[thread_position_in_grid]]) {
    uint2 size = uint2(target.get_width(), target.get_height());
    if (gid.x >= size.x || gid.y >= size.y) return;
    int2 c = int2(gid);
    float L = pressure.read(clampCoord(c + int2(-1, 0), size)).x;
    float R = pressure.read(clampCoord(c + int2(1, 0), size)).x;
    float B = pressure.read(clampCoord(c + int2(0, -1), size)).x;
    float T = pressure.read(clampCoord(c + int2(0, 1), size)).x;
    float2 v = velocity.read(gid).xy - 0.5 * float2(R - L, T - B);
    target.write(float4(v, 0.0, 0.0), gid);
}

kernel void advect(texture2d<float, access::sample> velocity [[texture(0)]],
                   texture2d<float, access::sample> source [[texture(1)]],
                   texture2d<float, access::write> target [[texture(2)]],
                   constant AdvectParams &params [[buffer(0)]],
                   uint2 gid [[thread_position_in_grid]]) {
    float2 size = float2(target.get_width(), target.get_height());
    if (float(gid.x) >= size.x || float(gid.y) >= size.y) return;
    float2 uv = (float2(gid) + 0.5) / size;
    float2 vel = velocity.sample(linearSampler, uv, level(0)).xy;
    float2 coord = uv - params.dt * vel * params.velocityTexel;
    float4 result = source.sample(linearSampler, coord, level(0));
    result /= 1.0 + params.dissipation * params.dt;
    target.write(result, gid);
}

// MARK: - Display

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex VertexOut fullscreenVertex(uint vid [[vertex_id]]) {
    float2 p = float2(float((vid << 1) & 2), float(vid & 2));
    VertexOut out;
    out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    out.uv = float2(p.x, 1.0 - p.y);
    return out;
}

static inline float hash12(float2 p) {
    float3 p3 = fract(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

static inline float valueNoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    float a = hash12(i);
    float b = hash12(i + float2(1.0, 0.0));
    float c = hash12(i + float2(0.0, 1.0));
    float d = hash12(i + float2(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

fragment float4 displayFragment(VertexOut in [[stage_in]],
                                texture2d<float> dye [[texture(0)]],
                                constant DisplayUniforms &u [[buffer(0)]],
                                constant CursorMark *cursors [[buffer(1)]]) {
    float2 uv = in.uv;
    float2 pix = in.position.xy;

    float4 d = dye.sample(linearSampler, uv, level(0.0));
    float2 tx = float2(u.dyeTexel.x * 1.5, 0.0);
    float2 ty = float2(0.0, u.dyeTexel.y * 1.5);
    float hL = min(dye.sample(linearSampler, uv - tx, level(0.0)).a, 2.5);
    float hR = min(dye.sample(linearSampler, uv + tx, level(0.0)).a, 2.5);
    float hT = min(dye.sample(linearSampler, uv - ty, level(0.0)).a, 2.5);
    float hB = min(dye.sample(linearSampler, uv + ty, level(0.0)).a, 2.5);

    // Treat paint density as a height field: glossy, wet-paint relief.
    const float bump = 5.0;
    float3 n = normalize(float3((hL - hR) * bump, (hT - hB) * bump, 1.0));
    float3 L = normalize(float3(-0.45, -0.65, 1.0));
    float3 H = normalize(L + float3(0.0, 0.0, 1.0));
    float shade = 1.0 + (dot(n, L) - L.z) * 1.4;
    float spec = max(pow(saturate(dot(n, H)), 48.0) - pow(H.z, 48.0), 0.0);
    float a = d.a;
    float grain = valueNoise(pix * 0.35) * 0.6 + hash12(pix) * 0.4;

    // Paper: pigment covering paper.
    float3 pigment = d.rgb / max(a, 0.001);
    float cover = 1.0 - exp(-a * 2.8);
    float3 paper = float3(0.975, 0.965, 0.945) * (0.965 + 0.035 * grain);
    float3 paperCol = mix(paper, pigment * (0.93 + 0.07 * grain), cover);
    paperCol *= mix(1.0, shade, cover);
    paperCol += spec * 0.55 * cover;
    float edge = length(float2(hR - hL, hB - hT));
    paperCol *= 1.0 - saturate(edge * 1.2) * 0.12;

    // Night: luminous ink with a cheap mip-chain bloom.
    float3 glow = dye.sample(linearSampler, uv, level(3.0)).rgb * 0.55
                + dye.sample(linearSampler, uv, level(5.0)).rgb * 0.45;
    float3 ink = d.rgb * mix(1.0, shade, saturate(a)) + spec * 0.7 * saturate(a);
    ink += glow * 0.5;
    ink = 1.0 - exp(-ink * 1.5);
    float3 bg = mix(float3(0.045, 0.04, 0.09), float3(0.012, 0.012, 0.03), uv.y);
    float3 nightCol = 1.0 - (1.0 - bg) * (1.0 - ink);

    float3 col = mix(paperCol, nightCol, u.mode);
    float2 vc = uv - 0.5;
    col *= 1.0 - dot(vc, vc) * mix(0.18, 0.5, u.mode);

    // Hand cursors.
    float3 inkColor = mix(float3(0.12, 0.12, 0.15), float3(1.0), u.mode);
    float3 haloColor = mix(float3(1.0), float3(0.0), u.mode);
    float minSide = min(u.viewSize.x, u.viewSize.y);
    for (uint i = 0; i < u.cursorCount; i++) {
        CursorMark cur = cursors[i];
        if (cur.alpha <= 0.001) continue;
        int style = int(cur.style + 0.5);
        float2 c = cur.position * u.viewSize;
        float r = cur.radius * minSide;
        float dist = length(pix - c);
        if (dist > r * 2.0 + 30.0) continue;
        float w = max(r * 0.08, 1.5);

        float halo = 1.0 - smoothstep(0.0, w * 3.0, abs(dist - r));
        col = mix(col, haloColor, halo * cur.alpha * 0.35);

        float ring = 1.0 - smoothstep(w * 0.5, w * 0.5 + 1.2, abs(dist - r));
        if (style == 1) {
            float ang = atan2(pix.y - c.y, pix.x - c.x);
            ring *= mix(0.2, 1.0, step(0.0, sin(ang * 8.0 + u.time * 6.0)));
        }
        col = mix(col, inkColor, ring * cur.alpha * 0.85);

        if (cur.progress > 0.0) {
            float ang = atan2(pix.x - c.x, -(pix.y - c.y));
            float frac = ang / (2.0 * M_PI_F);
            if (frac < 0.0) frac += 1.0;
            float arcR = r + w * 2.5;
            float arc = (1.0 - smoothstep(w, w + 1.2, abs(dist - arcR))) * step(frac, cur.progress);
            col = mix(col, cur.color.rgb, arc * cur.alpha);
        }

        float dotR = style == 2 ? r * 0.55 : (style == 0 || style == 4 ? r * 0.3 : 0.0);
        if (dotR > 0.0) {
            float dotMask = 1.0 - smoothstep(dotR - 1.0, dotR + 0.5, dist);
            col = mix(col, cur.color.rgb, dotMask * cur.alpha);
        }
    }

    col += (hash12(pix + fract(u.time) * 100.0) - 0.5) / 255.0;
    return float4(saturate(col), 1.0);
}
