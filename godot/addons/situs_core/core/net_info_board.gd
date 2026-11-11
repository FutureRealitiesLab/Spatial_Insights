# net_info_board.gd
# ════════════════════════════════════════════════════════════════
#  3D-Verbindungsstatusanzeige für Cassiopeia / Pablo (Debug).
#
#  Verhält sich wie eine Warntafel:
#    • Sichtbar  → solange keine Server-Verbindung besteht
#    • Unsichtbar → sobald verbunden (stört Besucher nicht)
#
#  Wird von scene_manager.gd automatisch in jede geladene Szene
#  injiziert – nicht manuell in .tscn-Dateien eintragen.
# ════════════════════════════════════════════════════════════════
extends Label3D

const UPDATE_INTERVAL: float = 1.0

var _timer: float = 0.0


func _ready() -> void:
	# Auf dem Server nicht benötigt – sofort entfernen.
	if GameState.mode == GameState.Mode.SERVER:
		queue_free()
		return
	_update()


func _process(delta: float) -> void:
	_timer += delta
	if _timer >= UPDATE_INTERVAL:
		_timer = 0.0
		_update()


func _update() -> void:
	if NetworkManager.client_connected_flag or SceneManager.standalone_mode:
		visible = false
		return

	visible = true
	var attempts: int = NetworkManager.reconnect_attempts
	var lines: PackedStringArray = []
	lines.append("No connection")
	lines.append("%s : %d" % [NetworkManager.server_ip, NetworkManager.PORT])
	if attempts > 0:
		lines.append("Attempt %d ..." % attempts)
	else:
		lines.append("Connecting ...")

	if GameState.mode == GameState.Mode.FPS:
		lines.append("")
		lines.append("On PC: press Q/E for standalone mode")
	elif GameState.mode == GameState.Mode.XR:
		lines.append("")
		lines.append("VR: press any button for standalone mode")

	text = "\n".join(lines)
