shader_type canvas_item;
render_mode unshaded, blend_premul_alpha;

// All resources are immutable geometry/data, shared by every cast. Bins keep
// fragment work local; there is no loop over the whole wall or a frame atlas.
uniform sampler2D backdrop : hint_screen_texture, filter_nearest, repeat_disable;
uniform sampler2D records : filter_nearest, repeat_disable;
uniform sampler2D bins : filter_nearest, repeat_disable;
uniform sampler2D candidates : filter_nearest, repeat_disable;
uniform sampler2D settled_light : filter_linear, repeat_disable;
uniform vec4 grid; // width, height, cell size, edge record offset
uniform vec4 placement; // bin origin xy, author-to-display scale, blue tile ID
uniform vec4 clock; // author time, global fade, scan front, seated material
uniform vec2 extent;
uniform vec4 entrance[98]; // center xy, inverse rotation/scale zw
uniform vec4 entrance_visibility[98]; // alpha, extra depth, scale, reserved
varying vec4 tint;

void vertex() { tint = COLOR; }
vec4 record_at(int i) { return texelFetch(records, ivec2(i % 256, i / 256), 0); }
int candidate_at(int i) {
    int j = i / 4;
    vec4 values = texelFetch(candidates, ivec2(j % 256, j / 256), 0);
    return int(values[i % 4] + 0.5);
}
vec4 over(vec4 under, vec3 rgb, float alpha) {
    return vec4(rgb * alpha + under.rgb * (1.0 - alpha), alpha + under.a * (1.0 - alpha));
}
vec4 screen(vec4 under, vec3 rgb, float alpha) {
    vec3 ink = rgb * alpha;
    return vec4(ink + under.rgb * (1.0 - ink), alpha + under.a * (1.0 - alpha));
}
void composite(inout vec3 rgb, inout float alpha, vec4 layer, bool is_screen) {
    rgb = layer.rgb + rgb * (is_screen ? (vec3(1.0) - layer.rgb) : vec3(1.0 - layer.a));
    alpha = layer.a + alpha * (1.0 - layer.a);
}
float hex_distance(vec2 p) {
    // Fold into one edge sector for a true Euclidean distance, including the
    // corners. A max-of-planes approximation would leak beyond the glow bins.
    vec2 q = abs(p.yx);
    vec2 normal = vec2(-0.866025404, 0.5);
    q -= 2.0 * min(dot(normal, q), 0.0) * normal;
    q -= vec2(clamp(q.x, -34.64101615, 34.64101615), 60.0);
    return length(q) * sign(q.y);
}
int face_at(vec2 p) {
    if (p.y < -abs(p.x) * 0.577333333) { return p.x >= 0.0 ? 0 : 1; }
    if (p.x < 0.0) { return p.y < p.x * 1.732 + 69.28 ? 2 : 3; }
    return p.y < p.x * 0.577333333 ? 4 : 5;
}
float segment_distance(vec2 p, vec2 a, vec2 b) {
    vec2 v = b - a;
    float q = clamp(dot(p - a, v) / max(dot(v, v), 0.000001), 0.0, 1.0);
    return length(p - a - v * q);
}
float coverage(float distance, float half_width, float aa) {
    return 1.0 - smoothstep(half_width - aa, half_width + aa, distance);
}
// Finite support prevents hidden tails from extending past a spatial bin.
float soft_shape(float distance, float sigma) {
    float q = distance / sigma;
    float value = 1.0 / (1.0 + exp(1.7 * q));
    return value * (1.0 - smoothstep(2.5, 3.0, max(q, 0.0)));
}
vec4 stroke_masks(float distance, float aa) {
    return vec4(coverage(distance, 6.0, aa), coverage(distance, 2.7, aa), 0.0, soft_shape(distance - 6.0, 3.076923));
}
vec3 brighten(vec3 color) {
    return min(vec3(240.0), floor(color * 255.0 * 1.4 + 0.5)) / 255.0;
}
vec3 emission_color(vec3 color) {
    vec3 bright = color * 1.85;
    float luma = dot(bright, vec3(0.213, 0.715, 0.072));
    return clamp(vec3(luma) + (bright - vec3(luma)) * 1.12, vec3(0.0), vec3(1.0));
}

void fragment() {
    if (clock.y <= 0.0 || clock.x <= 0.0) { discard; }
    vec2 p = (UV - vec2(0.5)) * extent / placement.z;
    // Approved scan-unified-v11: one 5.4-unit cyan stroke, with a soft outer glow.
    float aa = clamp(0.5 * max(length(dFdx(p)), length(dFdy(p))), 0.35, 2.5);
    ivec2 cell = ivec2(clamp(floor((p - placement.xy) / grid.z), vec2(0.0), grid.xy - vec2(1.0)));
    float t = clock.x;
    // Replaced by a compile-time true/false for separate opening/seated shaders.
    const bool opening = true;
    int bin_id = cell.y * int(grid.x) + cell.x;
    if (!opening) { bin_id += int(grid.x * grid.y); }
    vec4 bin = texelFetch(bins, ivec2(bin_id % 256, bin_id / 256), 0);
    // Export checks conservative swept face bounds, separately from broad glow
    // bins. Eight face slots suffice; do not reserve 24 full hit records/pixel.
    vec4 hits[8];
    vec2 hit_order[8]; // projected face depth, tile edge opacity
    int hit_count = 0;
    vec3 halo_rgb = vec3(0.0);
    float halo_weight = 0.0;
    float halo_coverage = 0.0;
    vec4 accents = vec4(0.0);

    for (int n = 0; n < 24; n++) {
        if (n >= int(bin.y)) { break; }
        int id = candidate_at(int(bin.x) + n);
        vec4 properties = record_at(id * 9 + 1);
        vec2 local;
        float extra_depth = 0.0;
        float alpha = 1.0;
        float scale = 1.0;
        if (opening) {
            vec4 pose = entrance[id];
            vec4 visible = entrance_visibility[id];
            vec2 offset = p - pose.xy;
            local = vec2(offset.x * pose.z + offset.y * pose.w, -offset.x * pose.w + offset.y * pose.z);
            scale = visible.z; alpha = visible.x; extra_depth = visible.y;
        }
        else { local = p - record_at(id * 9).xy; }
        if (alpha <= 0.0) { continue; }
        float distance = hex_distance(local) * scale;
        if (distance > 93.0) { continue; }
        // Approximate the low-frequency Canvas bloom directly from each local
        // colored polygon. No full-resolution blur surfaces per cast.
        if (opening) {
            vec3 light_color = record_at(id * 9 + 2).rgb;
            float light = soft_shape(distance, 30.76923) * alpha * properties.z;
            halo_rgb += emission_color(light_color) * light;
            halo_weight += light;
            halo_coverage = 1.0 - (1.0 - halo_coverage) * (1.0 - light);
        }
        float shape = 1.0 - smoothstep(-aa, aa, distance);
        if (shape <= 0.0) { continue; }
        int face = face_at(local);
        vec4 paint = record_at(id * 9 + 3 + face);
        float depth = paint.a + extra_depth;
        int insert = hit_count;
        // Only overlapping entrance fragments require ordering. Settled tiles
        // partition the plane and generally contribute a single local hit.
        while (insert > 0) {
            if (hit_order[insert - 1].x <= depth) { break; }
            hits[insert] = hits[insert - 1];
            hit_order[insert] = hit_order[insert - 1];
            insert--;
        }
        hits[insert] = vec4(paint.rgb, alpha * shape);
        hit_order[insert] = vec2(depth, properties.z * shape);
        hit_count++;
        if (!opening && clock.z > 0.0) {
            float amount = smoothstep(properties.w + 16.0, properties.w + 150.0, clock.z);
            vec3 bright = brighten(paint.rgb);
            accents = over(accents, bright, amount * 0.95 * shape);
            accents = screen(accents, bright, amount * 0.32 * shape);
        }
    }
    vec4 wall = vec4(0.0);
    float wall_mask = 0.0;
    for (int i = 0; i < 8; i++) {
        if (i >= hit_count) { break; }
        wall = over(wall, hits[i].rgb, hits[i].a);
        wall_mask = hit_order[i].y;
    }
    wall *= wall_mask;
    vec4 ink = vec4(0.0);
    if (!opening && clock.z > 0.0 && wall_mask > 0.0) {
        // Union segments within each original energy/tier bucket before
        // compositing: junctions must not get brighter from duplicate edges.
        // Coverage is monotonic in distance. One minimum distance gives the
        // exact same four union masks, without 60 live mask scalars/pixel.
        // Energy is in [.48,1], so only original buckets 2,3,4 can occur.
        float strokes[9];
        for (int i = 0; i < 9; i++) { strokes[i] = 10000.0; }
        for (int n = 0; n < 32; n++) {
            if (n >= int(bin.w)) { break; }
            int id = candidate_at(int(bin.z) + n);
            vec4 ends = record_at(int(grid.w) + id * 2);
            vec4 path = record_at(int(grid.w) + id * 2 + 1);
            float qa = clamp((clock.z - path.x) / path.z, 0.0, 1.0);
            float qb = clamp((clock.z - path.y) / path.z, 0.0, 1.0);
            if (qa + qb <= 0.0) { continue; }
            float distance = 10000.0;
            if (qa + qb >= 1.0) { distance = segment_distance(p, ends.xy, ends.zw); }
            else {
                if (qa > 0.0) { distance = segment_distance(p, ends.xy, mix(ends.xy, ends.zw, qa)); }
                if (qb > 0.0) { distance = min(distance, segment_distance(p, mix(ends.xy, ends.zw, 1.0 - qb), ends.zw)); }
            }
            if (distance > 22.0) { continue; }
            float energy = 0.48 + 0.52 * (1.0 - smoothstep(50.0, 250.0, clock.z - min(path.x, path.y)));
            int bucket = clamp(int(floor(energy * 5.0)) - 2, 0, 2);
            int index = int(path.w) * 3 + bucket;
            strokes[index] = min(strokes[index], distance);
        }
        for (int b = 0; b < 3; b++) {
            vec4 s = stroke_masks(min(strokes[b], min(strokes[b + 3], strokes[b + 6])), aa);
            float energy = float(b + 3) / 5.0;
            accents = over(accents, vec3(5.0, 223.0, 233.0) / 255.0, s.w * energy * 0.18);
            accents = over(accents, vec3(5.0, 223.0, 233.0) / 255.0, s.x * energy * 0.18);
            accents = over(accents, vec3(8.0, 205.0, 229.0) / 255.0, s.y * energy);
        }
        for (int tier = 1; tier <= 2; tier++) {
            for (int b = 0; b < 3; b++) {
                vec4 s = stroke_masks(strokes[tier * 3 + b], aa);
                float energy = float(b + 3) / 5.0;
                float glow = tier == 2 ? 0.18 : 0.08;
                accents = screen(accents, vec3(5.0, 239.0, 245.0) / 255.0, s.w * energy * glow);
                accents = screen(accents, vec3(5.0, 239.0, 245.0) / 255.0, s.x * energy * glow);
                accents = screen(accents, vec3(8.0, 205.0, 229.0) / 255.0, s.y * energy * (tier == 2 ? 0.45 : 0.24));
            }
        }
        for (int tier = 0; tier < 3; tier++) {
            float strength = tier == 0 ? 0.94 : (tier == 1 ? 0.98 : 1.0);
            for (int b = 0; b < 3; b++) {
                float distance = strokes[tier * 3 + b];
                float s = coverage(distance, 2.7, aa);
                float energy = (0.85 + 0.15 * float(b + 3) / 5.0) * strength;
                ink = over(ink, vec3(8.0, 205.0, 229.0) / 255.0, s * energy);
            }
        }
    }
    accents *= wall_mask;
    ink *= wall_mask;
    vec3 behind = texture(backdrop, SCREEN_UV).rgb;
    vec3 result = behind;
    float alpha = 0.0;
    float fade = clock.y;
    vec3 halo_color = halo_weight > 0.00001 ? halo_rgb / halo_weight : vec3(0.0);
    vec4 halo = opening ? vec4(halo_color * halo_coverage, halo_coverage) : texture(settled_light, UV);
    // All wall tiles have seated by author time .824. Ease the tiny lookup
    // quantization/interpolation difference in before changing shader stages.
    if (opening && t > 0.824) { halo = mix(halo, texture(settled_light, UV), smoothstep(0.824, 0.85, t)); }
    composite(result, alpha, halo * (fade * 0.7 * 0.72), true);
    composite(result, alpha, wall * (fade * 0.1), false);
    vec3 wall_color = wall.a > 0.00001 ? wall.rgb / wall.a : vec3(0.0);
    vec4 emission = vec4(emission_color(wall_color) * wall.a, wall.a);
    composite(result, alpha, emission * (fade * 0.7 * 0.5), true);
    composite(result, alpha, accents * fade, true);
    composite(result, alpha, ink * fade, false);

    // The blue cube moves and receives its own stronger material, then draws
    // last just as in the approved authoring program. It never inherits .1.
    if (!opening && t > 0.86) {
        int key = int(placement.w);
        vec4 pose = record_at(key * 9);
        float travel = 1.0 - smoothstep(0.86, 1.18, t);
        float scale = 1.0 + 0.20 * travel;
        vec2 local = p - pose.xy - vec2(-90.0, 95.0) * travel;
        float angle = -0.16 * travel;
        float cs = cos(angle), sn = sin(angle);
        local = vec2(local.x * cs + local.y * sn, -local.x * sn + local.y * cs) / scale;
        float distance = hex_distance(local) * scale;
        float seated = clock.w;
        float enter = smoothstep(0.86, 0.96, t);
        float sigma = (22.0 + 16.0 * seated) / 1.3;
        if (distance < 3.0 * sigma) {
            vec4 blue = vec4(0.0);
            float glow = soft_shape(distance, sigma) * enter;
            blue = over(blue, vec3(19.0, 234.0, 250.0) / 255.0, glow * 0.72);
            float shape = 1.0 - smoothstep(-aa, aa, distance);
            vec3 color = record_at(key * 9 + 3 + face_at(local)).rgb;
            blue = over(blue, color, shape * enter * (0.98 + 0.02 * seated));
            blue = screen(blue, vec3(102.0, 236.0, 255.0) / 255.0, shape * enter * 0.48 * seated);
            float rim = coverage(abs(distance), (2.5 + 0.5 * seated) / 2.0, aa);
            blue = over(blue, vec3(146.0, 255.0, 252.0) / 255.0, rim * enter);
            composite(result, alpha, blue * fade, false);
        }
    }
    // Reconstruct premultiplied output relative to the actual preceding cast.
    // Preserves source-over/screen order and the original inherited body tint.
    COLOR = vec4((result - behind * (1.0 - alpha)) * tint.rgb * tint.a, alpha * tint.a);
}
