shader_type spatial;
// Raymarching durch ein 3D-Skalarfeld auf einem BoxMesh (lokal -0.5..0.5).
// Rueckseiten werden gezeichnet, damit es auch mit der Kamera im Volumen funktioniert.
// Die Textur ist [ny, nx, nz] (Breite ny, Hoehe nx), daher wird (x, y) vertauscht.
render_mode unshaded, cull_front, depth_draw_never, blend_mix;

#include "res://colormap.gdshaderinc"

uniform sampler3D volume_tex : filter_linear, repeat_disable;
uniform int colormap = 0;
uniform int steps : hint_range(8, 128) = 64;
uniform float density_scale : hint_range(0.0, 20.0) = 4.0;
uniform float emission_gain : hint_range(0.0, 10.0) = 2.0;
uniform float threshold : hint_range(0.0, 1.0) = 0.05;
// Zellularautomaten: harte Zellen statt Interpolation.
uniform bool nearest = false;

const int MAX_STEPS = 128;

varying vec3 v_local;
varying vec3 v_cam_local;

void vertex() {
	v_local = VERTEX;
	v_cam_local = (inverse(MODEL_MATRIX) * vec4(CAMERA_POSITION_WORLD, 1.0)).xyz;
}

void fragment() {
	vec3 ro = v_cam_local;
	vec3 rd = normalize(v_local - ro);

	// Ray/AABB-Schnitt (Slab-Methode) im lokalen Raum
	vec3 inv = 1.0 / rd;
	vec3 t0 = (vec3(-0.5) - ro) * inv;
	vec3 t1 = (vec3(0.5) - ro) * inv;
	vec3 tmin3 = min(t0, t1);
	vec3 tmax3 = max(t0, t1);
	float t_near = max(max(max(tmin3.x, tmin3.y), tmin3.z), 0.0);
	float t_far = min(min(tmax3.x, tmax3.y), tmax3.z);

	if (t_far <= t_near) {
		discard;
	}

	float dt = (t_far - t_near) / float(steps);
	// Pixel-Jitter gegen Banding
	float jitter = fract(sin(dot(FRAGCOORD.xy, vec2(12.9898, 78.233))) * 43758.5453);
	float t = t_near + dt * jitter;

	vec3 acc_rgb = vec3(0.0);
	float acc_a = 0.0;

	for (int i = 0; i < MAX_STEPS; i++) {
		if (i >= steps || acc_a > 0.98) break;
		vec3 p = ro + rd * t + 0.5;
		vec3 q = vec3(p.y, p.x, p.z);
		float n;
		if (nearest) {
			ivec3 size = textureSize(volume_tex, 0);
			n = texelFetch(volume_tex, clamp(ivec3(q * vec3(size)), ivec3(0), size - ivec3(1)), 0).r;
		} else {
			n = textureLod(volume_tex, q, 0.0).r;
		}
		if (n > threshold) {
			// Absorption pro Schritt, unabhaengig von der Schrittzahl
			float a = 1.0 - exp(-n * n * density_scale * dt * 4.0);
			vec3 c = apply_colormap(n, colormap) * (1.0 + emission_gain * n);
			acc_rgb += (1.0 - acc_a) * a * c;
			acc_a += (1.0 - acc_a) * a;
		}
		t += dt;
	}

	if (acc_a < 0.003) {
		discard;
	}
	ALBEDO = acc_rgb / acc_a;  // blend_mix erwartet nicht-premultiplied
	ALPHA = acc_a;
}
