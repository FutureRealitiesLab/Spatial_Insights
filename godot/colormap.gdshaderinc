// Gemeinsame Farbtabelle aller Feld-Shader (Verlauf mit Deckkraft, siehe colormaps.gd).
// value_range: [unten, oben] des Wertebereichs (0..1), der auf den Verlauf abgebildet wird;
// Werte ausserhalb bekommen die Randfarben.

uniform sampler2D lut : filter_linear, repeat_disable;
uniform vec2 value_range = vec2(0.0, 1.0);

float map_value(float t) {
	return clamp((t - value_range.x) / max(value_range.y - value_range.x, 0.0001), 0.0, 1.0);
}

// rgb = Farbe, a = Deckkraft
vec4 apply_colormap(float t) {
	return textureLod(lut, vec2(map_value(t) * (255.0 / 256.0) + 0.5 / 256.0, 0.5), 0.0);
}
