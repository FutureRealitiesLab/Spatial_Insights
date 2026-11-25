shader_type spatial;
// Scheinkugel mit Tiefe der Kugeloberflaeche (wenn Pfeile dargestellt werden).
render_mode unshaded, cull_disabled, skip_vertex_transform;

#define WRITE_DEPTH
#include "res://impostor_sphere.gdshaderinc"
