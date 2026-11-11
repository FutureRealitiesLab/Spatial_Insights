extends Label
## Zeigt Netzwerk- und Darstellungsstatistiken an (F3 schaltet um).

@export var receiver_path: NodePath
@export var view_path: NodePath


func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_F3:
		visible = not visible


func _process(_delta: float) -> void:
	var r := get_node_or_null(receiver_path)
	var v := get_node_or_null(view_path)
	if r == null or v == null:
		text = "Empfaenger oder Ansicht nicht gefunden"
		return
	# Incoming numbers: MATLAB via UDP on the server/direct instance, the server data channel on a client.
	var src := "From server in" if r.get("role_name") == "CLIENT" else "MATLAB in"
	var lines: Array[String] = [
		"Render FPS:    %d" % Engine.get_frames_per_second(),
		"UDP port:      %d (%s)" % [r.port, "listening" if r.listening else "ERROR"],
		"Sender:        %s" % r.last_sender,
		"%s: packets/s %.0f" % [src, r.packets_per_s],
		"%s: frames/s %.1f   queue: %d" % [src, r.frames_per_s, r.queue_size],
		"%s: frame %.1f KB   rate %.0f KB/s" % [src, r.kb_per_frame, r.kb_per_s],
		"Dropped:       %d   Invalid: %d" % [r.dropped_frames, r.bad_packets],
		"Session:       %d" % r.session_id,
		"Magic:         %s   Frame: %d" % [r.last_magic, r.last_frame_id],
		"Layers:        %s" % ", ".join(v.layers.keys()),
		"Colormap:      %s (set by server, C)" % v.colormap_name(),
	]
	if r.has_method("extra_lines"):
		lines.append_array(r.extra_lines())
	text = "\n".join(lines)
