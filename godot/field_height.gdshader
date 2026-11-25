shader_type spatial;
// Hoehenflaeche fuer 2D-Skalarfelder: Hoehe entlang z, Gitter in der xy-Ebene.
// Die Textur hat die Breite ny und die Hoehe nx, daher werden u und v vertauscht.
render_mode cull_disabled;

#include "res://colormap.gdshaderinc"

uniform sampler2D tex : filter_linear, repeat_disable;
uniform vec2 extent = vec2(1.0);
uniform float height = 0.5;
// Zellularautomaten: harte Zellen statt Interpolation.
uniform bool nearest = false;

varying float v_val;

float sample_val(vec2 vxy) {
	vec2 q = vec2(vxy.y, vxy.x);
	if (nearest) {
		ivec2 size = textureSize(tex, 0);
		return texelFetch(tex, clamp(ivec2(q * vec2(size)), ivec2(0), size - ivec2(1)), 0).r;
	}
	return clamp(textureLod(tex, q, 0.0).r, 0.0, 1.0);
}

void vertex() {
	float n = sample_val(UV);
	VERTEX.z = n * height;
	v_val = n;
}

void fragment() {
	vec2 size = vec2(textureSize(tex, 0));
	float dvx = 1.0 / size.y;
	float dvy = 1.0 / size.x;
	float hl = sample_val(UV - vec2(dvx, 0.0));
	float hr = sample_val(UV + vec2(dvx, 0.0));
	float hd = sample_val(UV - vec2(0.0, dvy));
	float hu = sample_val(UV + vec2(0.0, dvy));
	float dzdx = height * (hr - hl) / (2.0 * dvx * extent.x);
	float dzdy = height * (hu - hd) / (2.0 * dvy * extent.y);
	vec3 n_local = normalize(vec3(-dzdx, -dzdy, 1.0));
	NORMAL = normalize((VIEW_MATRIX * MODEL_MATRIX * vec4(n_local, 0.0)).xyz);
	ALBEDO = apply_colormap(nearest ? sample_val(UV) : v_val).rgb;
	ROUGHNESS = 0.8;
}
