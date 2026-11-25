shader_type spatial;
// 2D-Feld auf einer Flaeche (Bild, CA auf Ebene/Kugel/Torus).
// Die Textur hat die Breite ny und die Hoehe nx (MATLAB-Spaltenreihenfolge),
// daher werden u (x) und v (y) beim Abtasten vertauscht.
// Bewusst ohne ALPHA: Sonst wird das Material transparent (ohne Tiefenschreiben),
// und bei Kugel und Torus verdecken Rueckseiten die Vorderseiten.
render_mode unshaded, cull_disabled, depth_draw_opaque;

#include "res://colormap.gdshaderinc"

uniform sampler2D tex : filter_linear, repeat_disable;
uniform float value_scale = 1.0;
uniform bool nearest = false;
// Gepackte CA-Zustaende: tex enthaelt die Payload-Bytes zeilenweise, die Zelle
// (iy, ix) liegt spaltenweise bei Index iy + ny * ix.
uniform bool packed_states = false;
uniform int bits = 1;
uniform ivec2 grid = ivec2(1, 1); // (ny, nx)

void fragment() {
	float r;
	if (packed_states) {
		int iy = clamp(int(UV.y * float(grid.x)), 0, grid.x - 1);
		int ix = clamp(int(UV.x * float(grid.y)), 0, grid.y - 1);
		int cell = iy + grid.x * ix;
		int per_byte = 8 / bits;
		int byte_index = cell / per_byte;
		int shift = (cell - byte_index * per_byte) * bits;
		int w = textureSize(tex, 0).x;
		int b = int(texelFetch(tex, ivec2(byte_index % w, byte_index / w), 0).r * 255.0 + 0.5);
		r = float((b >> shift) & ((1 << bits) - 1)) / 255.0;
	} else {
		ivec2 size = textureSize(tex, 0);
		vec2 uv = vec2(UV.y, UV.x);
		if (nearest) {
			r = texelFetch(tex, clamp(ivec2(uv * vec2(size)), ivec2(0), size - ivec2(1)), 0).r;
		} else {
			r = texture(tex, uv).r;
		}
	}
	ALBEDO = apply_colormap(clamp(r * value_scale, 0.0, 1.0)).rgb;
}
