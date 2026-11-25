shader_type spatial;
// Scheinkugel: ein zur Kamera gedrehtes Quadrat (2 Dreiecke), das wie eine beleuchtete
// Kugel aussieht. Fuer MultiMesh: Position und Groesse aus MODEL_MATRIX, Farbe aus COLOR.
// Das Quadrat hat die Kantenlaenge 2 * Radius.
render_mode unshaded, cull_disabled, skip_vertex_transform;

void vertex() {
	vec3 center = (VIEW_MATRIX * MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	VERTEX = center + vec3(VERTEX.xy, 0.0);
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
}
