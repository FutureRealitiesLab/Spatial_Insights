extends Node

## simulation_relay.gd – Autoload "SimulationRelay". Quelle aller Simulationsframes.
##
## Server:  empfängt MATLAB-Frames per UDP (udp_receiver.gd) und veröffentlicht sie
##          über DataChannel an alle Clients. Zeigt sie auch selbst an.
## Client:  bekommt dieselben Frames von DataChannel (Brillen, FPS-Spieler).
## Direkt:  Der Empfänger lauscht selbst auf UDP und es gibt keine Weitergabe.
##          Gilt bei F6 auf der Szene und bei Project Setting sim/udp_on_clients
##          (eine einzelne Brille, MATLAB sendet direkt an sie).
##
## Freeze: Der Server (oder die Direkt-Instanz) kann die Simulation anhalten. Neue
## Frames werden dann weder verteilt noch angezeigt, alle Brillen behalten das letzte
## Bild. Der Zustand geht per RPC an alle Clients, Neuankömmlinge bekommen ihn beim
## Beitritt. Beim Fortsetzen läuft der Strom einfach weiter.
##
## Alle Rollen lösen dasselbe Signal aus, das scene_view.gd erwartet.
## Das Debug-Overlay liest die Statistik-Felder wie beim UDP-Empfänger.

signal frame_received(magic: String, info: Dictionary, payload: PackedByteArray)
## Freeze wurde ein- oder ausgeschaltet (lokal oder vom Server).
signal frozen_changed(frozen: bool)
## Eine Darstellungs-Einstellung hat sich geaendert (lokal oder vom Server).
signal view_setting_changed(key: String, value: Variant)

const UdpReceiver := preload("res://udp_receiver.gd")
const CHANNEL_PREFIX := "sim/"
## Frames unter dieser Größe werden nicht komprimiert (Aufwand lohnt nicht).
const COMPRESS_MIN_BYTES := 4096

enum Role { NONE, SERVER, CLIENT, DIRECT }

var role: Role = Role.NONE
var role_name: String = "-"
## true = Simulation angehalten (siehe Kopfkommentar)
var frozen: bool = false
## Darstellungs-Einstellungen, die der Server fuer alle vorgibt (Schluessel -> Wert).
## Neue Schluessel hier eintragen, z. B. spaeter Farbskala; scene_view/Szene reagieren auf
## view_setting_changed. Clients uebernehmen den Stand des Servers, auch beim Late Join.
var view_settings: Dictionary = {"show_boxes": true, "colormap": 0}

# Statistik wie udp_receiver.gd (vom Debug-Overlay gelesen)
var port: int = 4242
var listening: bool = false
var last_sender: String = "-"
var packets_per_s: float = 0.0
var frames_per_s: float = 0.0
var queue_size: int = 0
var kb_per_frame: float = 0.0
var kb_per_s: float = 0.0
var dropped_frames: int = 0
var bad_packets: int = 0
var session_id: int = -1
var last_magic: String = ""
var last_frame_id: int = -1

var _receiver: Node = null
var _last_session: int = -2
## magic → {info, payload}; für Wiedergabe nach einem Szenenneuaufbau
var _last: Dictionary = {}

# Ausgehende Rate (Server -> Clients), vom Debug-Overlay gelesen
var out_frames_per_s: float = 0.0
var out_kb_per_s: float = 0.0
var out_raw_kb_per_s: float = 0.0
var _out_time: float = 0.0
var _out_prev_sent: int = 0
var _out_prev_bytes: int = 0
var _out_prev_raw: int = 0

var _rate_time: float = 0.0
var _rate_frames: int = 0
var _rate_bytes: int = 0


## Legt die Rolle fest und startet den Empfang. Wird von der Szene gerufen, wenn
## GameState.mode bekannt ist. Mehrfaches Aufrufen schadet nicht.
func attach() -> void:
	if role != Role.NONE:
		return
	var solo: bool = SceneManager.scenes_list.is_empty()  # F6 auf der Szene
	var direct: bool = solo or bool(ProjectSettings.get_setting("sim/udp_on_clients", false))
	if GameState.mode == GameState.Mode.SERVER and not solo:
		role = Role.SERVER
		_start_udp()
		# Jeder neue (oder wiederverbundene) Client erfährt den aktuellen Freeze-Zustand.
		multiplayer.peer_connected.connect(func(id: int) -> void: _rpc_frozen.rpc_id(id, frozen))
	elif direct:
		role = Role.DIRECT
		_start_udp()
	else:
		role = Role.CLIENT
		DataChannel.received.connect(_on_channel_received)
	role_name = Role.keys()[role]
	print("[SimulationRelay] Rolle: ", role_name)


## Gibt die zuletzt gesehenen Frames noch einmal aus (nach Szenen-Neuaufbau).
func replay() -> void:
	for magic: String in _last:
		var entry: Dictionary = _last[magic]
		frame_received.emit(magic, entry.info, entry.payload)


## Hält die Simulation an oder setzt sie fort. Nur Server und Direkt-Instanz
## dürfen das, Clients ignorieren den Aufruf.
func set_frozen(value: bool) -> void:
	if role != Role.SERVER and role != Role.DIRECT:
		return
	if value == frozen:
		return
	_apply_frozen(value)
	if role == Role.SERVER:
		_rpc_frozen.rpc(value)


func toggle_frozen() -> void:
	set_frozen(not frozen)


@rpc("authority", "reliable", "call_remote")
func _rpc_frozen(value: bool) -> void:
	_apply_frozen(value)


func _apply_frozen(value: bool) -> void:
	frozen = value
	print("[SimulationRelay] Freeze: ", "EIN" if frozen else "AUS")
	frozen_changed.emit(frozen)


## Setzt eine Darstellungs-Einstellung fuer alle. Nur Server und Direkt-Instanz.
func set_view_setting(key: String, value: Variant) -> void:
	if role != Role.SERVER and role != Role.DIRECT:
		return
	if view_settings.get(key) == value:
		return
	view_settings[key] = value
	view_setting_changed.emit(key, value)
	if role == Role.SERVER:
		_rpc_view_settings.rpc(view_settings)


func toggle_view_setting(key: String) -> void:
	set_view_setting(key, not bool(view_settings.get(key, false)))


@rpc("authority", "reliable", "call_remote")
func _rpc_view_settings(settings: Dictionary) -> void:
	view_settings = settings
	for key: String in settings:
		view_setting_changed.emit(key, settings[key])


func _start_udp() -> void:
	_receiver = UdpReceiver.new()
	port = int(ProjectSettings.get_setting("sim/udp_port", 4242))
	_receiver.port = port
	if GameState.local_only:
		_receiver.bind_address = "127.0.0.1"   # Einzelspieler: MATLAB muss an 127.0.0.1 senden
	add_child(_receiver)
	_receiver.frame_received.connect(_on_udp_frame)


func _on_udp_frame(magic: String, info: Dictionary, payload: PackedByteArray) -> void:
	if frozen:
		return  # angehalten: nichts verteilen, nichts anzeigen
	if role == Role.SERVER:
		# Neue MATLAB-Session: alte Frames nicht mehr an spätere Clients ausliefern.
		if _receiver.session_id != _last_session:
			_last_session = _receiver.session_id
			DataChannel.clear_all()
			_last.clear()
		DataChannel.publish(CHANNEL_PREFIX + magic, info, payload, payload.size() >= COMPRESS_MIN_BYTES)
	_emit(magic, info, payload)


func _on_channel_received(channel: String, meta: Dictionary, payload: PackedByteArray, _t: int) -> void:
	if not channel.begins_with(CHANNEL_PREFIX):
		return
	# Während Freeze bleibt das Bild stehen. Ausnahme: ein Client, der dieses Format
	# noch nie gesehen hat (Late Join), bekommt den einen Stand-Frame.
	if frozen and _last.has(channel.substr(CHANNEL_PREFIX.length())):
		return
	_rate_frames += 1
	_rate_bytes += payload.size()
	last_magic = channel.substr(CHANNEL_PREFIX.length())
	last_frame_id = int(meta.get("frame_id", last_frame_id))
	session_id = int(meta.get("session_id", session_id))
	_emit(last_magic, meta, payload)


func _emit(magic: String, info: Dictionary, payload: PackedByteArray) -> void:
	_last[magic] = {"info": info, "payload": payload}
	frame_received.emit(magic, info, payload)


func _process(delta: float) -> void:
	if _receiver != null:
		listening = _receiver.listening
		last_sender = _receiver.last_sender
		packets_per_s = _receiver.packets_per_s
		frames_per_s = _receiver.frames_per_s
		queue_size = _receiver.queue_size
		kb_per_frame = _receiver.kb_per_frame
		kb_per_s = _receiver.kb_per_s
		dropped_frames = _receiver.dropped_frames
		bad_packets = _receiver.bad_packets
		session_id = _receiver.session_id
		last_magic = _receiver.last_magic
		last_frame_id = _receiver.last_frame_id
		if role == Role.SERVER:
			_update_out_rates(delta)
	elif role == Role.CLIENT:
		listening = NetworkManager.client_connected_flag
		last_sender = NetworkManager.server_ip
		_rate_time += delta
		if _rate_time >= 1.0:
			frames_per_s = _rate_frames / _rate_time
			kb_per_s = _rate_bytes / 1024.0 / _rate_time
			kb_per_frame = (_rate_bytes / 1024.0 / _rate_frames) if _rate_frames > 0 else 0.0
			_rate_time = 0.0
			_rate_frames = 0
			_rate_bytes = 0


## Ausgehende Rate des Servers an die Clients, je Sekunde (Summe ueber alle Clients).
func _update_out_rates(delta: float) -> void:
	_out_time += delta
	if _out_time < 1.0:
		return
	var s: Dictionary = DataChannel.stats
	out_frames_per_s = (s.sent - _out_prev_sent) / _out_time
	out_kb_per_s = (s.bytes_sent - _out_prev_bytes) / 1024.0 / _out_time
	out_raw_kb_per_s = (s.bytes_raw - _out_prev_raw) / 1024.0 / _out_time
	_out_prev_sent = s.sent
	_out_prev_bytes = s.bytes_sent
	_out_prev_raw = s.bytes_raw
	_out_time = 0.0


## Zusätzliche Zeilen für das Debug-Overlay.
func extra_lines() -> Array[String]:
	var lines: Array[String] = ["Role:          %s" % role_name]
	if frozen:
		lines.append("Freeze:        ON")
	if role == Role.SERVER:
		var peers: PackedInt32Array = multiplayer.get_peers()
		lines.append("Clients:       %d  %s" % [peers.size(), str(Array(peers))])
		lines.append("Out to clients: %.1f frames/s, %.0f KB/s (raw %.0f KB/s, sum of all clients)" % [
			out_frames_per_s, out_kb_per_s, out_raw_kb_per_s])
		var s: Dictionary = DataChannel.stats
		lines.append("Relay total:   sent %d, replaced %d, %.1f MB (raw %.1f MB)" % [
			s.sent, s.skipped, s.bytes_sent / 1048576.0, s.bytes_raw / 1048576.0])
	elif role == Role.CLIENT:
		lines.append("Relay:         %d frames, %.1f MB" % [
			DataChannel.client_stats.frames, DataChannel.client_stats.bytes / 1048576.0])
	return lines
