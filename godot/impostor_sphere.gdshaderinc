// Scheinkugel: ein zur Kamera gedrehtes Quadrat (2 Dreiecke), das wie eine beleuchtete
// Kugel aussieht. Fuer MultiMesh: Position aus MODEL_MATRIX, Farbe aus COLOR. Das Quadrat
// hat die Kantenlaenge 2 * Radius.
// Mit WRITE_DEPTH schreibt jedes Pixel die Tiefe der Kugeloberflaeche, damit sich Kugeln und
// Pfeile richtig durchdringen. Das kostet Leistung (kein frueher Tiefentest), deshalb gibt es
// beide Varianten.

varying vec3 v_center;
varying float v_radius;

void vertex() {
	v_center = (VIEW_MATRIX * MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	v_radius = abs(VERTEX.x);
	VERTEX = v_center + vec3(VERTEX.xy, 0.0);
}

void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	float r2 = dot(p, p);
	if (r2 > 1.0) {
		discard;
	}
	vec3 n = vec3(p.x, -p.y, sqrt(1.0 - r2));
	// Festes Licht von schraeg oben rechts im Blickraum plus Grundhelligkeit
	float diffuse = max(dot(n, normalize(vec3(0.4, 0.6, 0.7))), 0.0);
	ALBEDO = COLOR.rgb * (0.35 + 0.75 * diffuse);
#ifdef WRITE_DEPTH
	vec4 clip = PROJECTION_MATRIX * vec4(v_center + n * v_radius, 1.0);
#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
	DEPTH = clip.z / clip.w * 0.5 + 0.5;
#else
	DEPTH = clip.z / clip.w;
#endif
#endif
}
