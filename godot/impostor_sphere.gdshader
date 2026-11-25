shader_type spatial;
// Scheinkugel ohne eigene Tiefe (schnell), siehe impostor_sphere.gdshaderinc.
render_mode unshaded, cull_disabled, skip_vertex_transform;

#include "res://impostor_sphere.gdshaderinc"
