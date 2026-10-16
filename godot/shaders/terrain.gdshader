shader_type spatial;
// RealSpace terrain: per-vertex palette colour (Gouraud in the original) with the 64x64 ground
// tiles draped per quad. Each quad is split along its top-left -> bottom-right diagonal; the
// "upper" triangle (above the diagonal) and "lower" triangle use separate tile ids. Tile texels
// with alpha 0 show the vertex colour underneath, as in the original renderer.

uniform sampler2D color_map : source_color, filter_linear, repeat_disable;  // grid colours (360x360)
uniform sampler2D tile_ids : filter_nearest, repeat_disable;               // R = upper, G = lower (id/255)
uniform sampler2DArray tiles : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
uniform float grid_size = 360.0;
uniform float spacing_m = 304.8;        // 1000 ft between grid vertices
uniform float tile_fade_start = 6000.0; // metres; tiles fade into the colour map beyond this
uniform float tile_fade_end = 30000.0;
uniform float detail_strength = 0.12;

varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float noise(vec2 p) {
	vec2 i = floor(p), f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1, 0)), u.x), mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), u.x), u.y);
}

void fragment() {
	// grid coordinates: x east, z south; (0,0) = north-west corner vertex
	vec2 g = world_pos.xz / spacing_m + grid_size * 0.5;
	vec3 base = texture(color_map, (g + 0.5) / grid_size).rgb;

	vec2 cell = floor(g);
	vec2 f = g - cell;
	vec2 ids = texelFetch(tile_ids, ivec2(clamp(cell, vec2(0.0), vec2(grid_size - 1.0))), 0).rg * 255.0;
	float id = (f.x > f.y) ? ids.r : ids.g;

	vec3 col = base;
	float dist = length(world_pos - CAMERA_POSITION_WORLD);
	if (id < 254.5) {
		vec4 t = texture(tiles, vec3(f, round(id)));
		float fade = 1.0 - smoothstep(tile_fade_start, tile_fade_end, dist);
		col = mix(base, t.rgb, t.a * fade);
	}
	// subtle procedural detail so large untextured areas don't look flat up close
	float n = noise(world_pos.xz * 0.05) * 0.6 + noise(world_pos.xz * 0.21) * 0.4;
	float near = 1.0 - smoothstep(500.0, 8000.0, dist);
	col *= 1.0 + (n - 0.5) * detail_strength * near;

	ALBEDO = col;
	ROUGHNESS = 0.95;
	SPECULAR = 0.2;
}
