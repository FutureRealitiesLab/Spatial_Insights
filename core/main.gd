# TEMPLATE CORE – nicht verändern
extends Node

## main.gd – Startpunkt und dauerhafter Rahmen der Ausstellungs-App.
##
## Läuft die gesamte Laufzeit durch — Team-Szenen, Spieler und Avatare
## werden darin hinein- und herausgeladen.
## Zuständig für: Startmenü, Einblende-Übergang beim Szenenwechsel,
## VR-Kamera-Setup, Netzwerk-Diagnose-Overlay und Server-HUD.

const SitusSettings = preload("res://addons/situs_core/core/situs_settings.gd")

## Fade-Zeiten für Szenenübergänge
const FADE_OUT_DURATION: float = 1.0
const TEXT_HOLD_DURATION: float = 2.5
const FADE_IN_DURATION:   float = 0.5

## VR-Overlay-Abstand in Metern und Lazy-Follow-Geschwindigkeit
const VR_OVERLAY_DIST:  float = 2.0
const VR_OVERLAY_SPEED: float = 4.0   # 1/s; bei 90 Hz ≈ 4 % Annäherung pro Frame

var _fade_tween: Tween = null

## Autoload "SceneLoop" aus modul_scene_loop, null wenn das Modul nicht aktiv ist
var _scene_loop: Node = null

## VR-Fade-Overlay (3D, für XR-Modus – CanvasLayer nicht zuverlässig in OpenXR)
var _vr_fade_plane: MeshInstance3D = null
var _vr_plane_mat:  StandardMaterial3D = null
var _vr_fade_label: Label3D = null

## Gespeicherte Server-IP des PC-Clients
const CLIENT_CFG := "user://situs_client.cfg"

## Prozess-ID des Server-Prozesses, den der Einzelspieler gestartet hat (-1 = keiner)
var _server_pid: int = -1

## Netzwerk-Diagnose
const DIAG_UPDATE_INTERVAL: float = 1.0
var _diag_timer: float = 0.0

## Server-HUD (oben rechts): Port und Adressen als feste Zeilen, darunter die Client-Liste.
var _hud_base_lines: PackedStringArray = []
var _hud_timer: float = 0.0


func _ready() -> void:
	# Spielfläche aus den Project Settings (Mesh ist 1 x 1 m, Größe über scale)
	var room: Vector2 = SitusSettings.get_room_size()
	$XRWalkArea.scale = Vector3(room.x, 1.0, room.y)

	var xr_interface: XRInterface = XRServer.find_interface("OpenXR")
	if xr_interface and xr_interface.is_initialized():
		print("[Main] OpenXR erkannt – starte direkt als XR-Client.")
		get_viewport().use_xr = true
		# VRS_XR explizit – redundant zu project.godot, stellt aber sicher dass
		# Godot den richtigen Pfad wählt und nicht auf VRS_DISABLED fällt.
		get_viewport().vrs_mode = Viewport.VRS_XR
		GameState.mode = GameState.Mode.XR

		# ── Render-Scale pro Gerät ───────────────────────────────────────
		# HTC Focus 3: 2448×2448 px/Auge vs Quest 2: 1832×1920 px/Auge.
		# 0.7× → ~49 % Pixelanzahl; Shadow-PCF-Taps 51 % günstiger als bei 1.0.
		var model: String = OS.get_model_name().to_lower()
		if "focus" in model or "vive" in model:
			xr_interface.render_target_size_multiplier = 0.7
			print("[Main] Focus 3 erkannt – render_target_size_multiplier = 0.7")
		# ────────────────────────────────────────────────────────────────

		_setup_vr_fade_overlay()
		NetworkManager.start_client()
		call_deferred("_launch")
	else:
		# PC-Modus (Server / FPS): VRS deaktivieren.
		# project.godot hat vrs/mode=2 (XR) – ohne XR-Device führt das zu
		# schwarzem Bildschirm, weil die VRS-Textur vom XR-Compositor fehlt.
		get_viewport().vrs_mode = Viewport.VRS_DISABLED
		$Menu.visible = true
		$Menu/Center/VBox/IpEdit.text = _load_saved_ip()
		$Menu/Center/VBox/IpEdit.text_changed.connect(_update_connect_label)
		_update_connect_label()
		call_deferred("_handle_cmdline")


## Beschriftung des Verbinden-Buttons zeigt die eingetragene Server-IP.
func _update_connect_label(_text: String = "") -> void:
	var ip: String = $Menu/Center/VBox/IpEdit.text.strip_edges()
	if ip.is_empty():
		ip = NetworkManager.server_ip
	$Menu/Center/VBox/BtnFPS.text = "Client connecting to %s" % ip


func _launch() -> void:
	$Menu.visible = false

	if GameState.mode == GameState.Mode.SERVER:
		$ServerHUD.visible = true
		var addrs: PackedStringArray = []
		for addr: String in IP.get_local_addresses():
			if "." in addr and not addr.begins_with("127.") and not addr.begins_with("169.254."):
				addrs.append(addr)
		var lines: PackedStringArray = ["Port %d  -  Listening on:" % NetworkManager.PORT]
		if GameState.local_only:
			lines.append("  127.0.0.1 (this PC only)")
		else:
			for addr in addrs:
				lines.append("  %s" % addr)
			if addrs.is_empty():
				lines.append("  (no network connection?)")
		_hud_base_lines = lines
		_update_server_hud()

	# Optionales Modul modul_scene_loop (Autoload "SceneLoop"): Timer, Auto-Wechsel, Next-Button
	_scene_loop = get_node_or_null("/root/SceneLoop")
	if _scene_loop:
		_scene_loop.timer_tick.connect(_on_timer_tick)
		_scene_loop.auto_advance_toggled.connect(_on_auto_advance_toggled)
	else:
		for n in ["TimerLabel", "TimerBar", "BtnNext", "BtnToggleAuto"]:
			get_node("ServerHUD/Panel/VBox/" + n).visible = false

	SceneManager.initialize($SceneContainer, $PlayersContainer)
	SceneManager.scene_changed.connect(_on_scene_changed)
	SceneManager.scene_about_to_change.connect(_on_scene_about_to_change)
	SceneManager.start()


# ── Menü-Buttons ────────────────────────────────────────────────

func _on_btn_fps_pressed() -> void:
	var ip: String = $Menu/Center/VBox/IpEdit.text.strip_edges()
	if ip.is_empty():
		ip = NetworkManager.server_ip
	_save_ip(ip)
	_start_pc_client(ip)


func _on_btn_fps_local_pressed() -> void:
	GameState.mode = GameState.Mode.FPS
	NetworkManager.start_client("127.0.0.1")
	_launch()


## Einzelspieler: startet denselben Programmcode als Server in einem zweiten, minimierten
## Prozess und verbindet sich dann als Spieler mit 127.0.0.1. Standardmäßig nur lokal,
## mit dem Häkchen im Menü (oder --lan) auch für Brillen und andere PCs im LAN.
func _on_btn_solo_pressed() -> void:
	var lan: bool = $Menu/Center/VBox/CheckLan.button_pressed or "--lan" in OS.get_cmdline_user_args()
	var args := PackedStringArray()
	if OS.has_feature("editor"):
		args.append_array(["--path", ProjectSettings.globalize_path("res://")])
	args.append("--minimized")
	args.append("--")   # ab hier Parameter für das Programm
	args.append("--server")
	if not lan:
		args.append("--local")
	_server_pid = OS.create_process(OS.get_executable_path(), args)
	if _server_pid <= 0:
		push_error("[Main] Server-Prozess konnte nicht gestartet werden.")
		_server_pid = -1
		return
	print("[Main] Einzelspieler: Server-Prozess %d gestartet (%s)" % [_server_pid, "LAN" if lan else "nur lokal"])
	$Menu.visible = false
	await get_tree().create_timer(1.0).timeout   # der Server soll lauschen, bevor wir verbinden
	_start_pc_client("127.0.0.1")


func _start_pc_client(ip: String) -> void:
	GameState.mode = GameState.Mode.FPS
	NetworkManager.start_client(ip)
	_launch()


## Startparameter nach "--": --server [--local], --client=<IP>, --solo [--lan].
## Ohne Parameter bleibt das Menü stehen.
func _handle_cmdline() -> void:
	var args := OS.get_cmdline_user_args()
	if "--server" in args:
		GameState.local_only = "--local" in args
		_on_btn_server_pressed_keep_flag()
		return
	if "--solo" in args:
		_on_btn_solo_pressed()
		return
	for a: String in args:
		if a.begins_with("--client="):
			_start_pc_client(a.substr("--client=".length()))
			return


func _load_saved_ip() -> String:
	var cfg := ConfigFile.new()
	if cfg.load(CLIENT_CFG) == OK:
		return str(cfg.get_value("client", "server_ip", NetworkManager.server_ip))
	return NetworkManager.server_ip


func _save_ip(ip: String) -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("client", "server_ip", ip)
	cfg.save(CLIENT_CFG)


## Beendet den vom Einzelspieler gestarteten Server-Prozess.
func _stop_server_process() -> void:
	if _server_pid > 0:
		OS.kill(_server_pid)
		_server_pid = -1


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_EXIT_TREE:
		_stop_server_process()


func _on_btn_server_pressed() -> void:
	GameState.local_only = false   # Server über das Menü ist für das LAN offen
	_on_btn_server_pressed_keep_flag()


func _on_btn_server_pressed_keep_flag() -> void:
	GameState.mode = GameState.Mode.SERVER
	NetworkManager.start_server()
	_launch()


# ── Server-HUD ──────────────────────────────────────────────────

func _on_btn_next_pressed() -> void:
	if _scene_loop:
		_scene_loop.advance_scene()


func _on_btn_toggle_auto_pressed() -> void:
	if _scene_loop:
		_scene_loop.toggle_auto_advance()


func _on_auto_advance_toggled(enabled: bool) -> void:
	if not $ServerHUD.visible:
		return
	$ServerHUD/Panel/VBox/BtnToggleAuto.text = "Auto-advance: %s  [L]" % ("ON" if enabled else "OFF")
	_update_server_hud_timer_label()


func _update_server_hud_timer_label() -> void:
	if not $ServerHUD.visible or _scene_loop == null:
		return
	$ServerHUD/Panel/VBox/TimerLabel.text = _scene_loop.get_hud_timer_text()


func _on_scene_changed(index: int, scene_name: String) -> void:
	if not $ServerHUD.visible:
		return
	$ServerHUD/Panel/VBox/SceneLabel.text = "[%d/%d]  %s" % [
		index + 1,
		SceneManager.scenes_list.size(),
		scene_name
	]
	$ServerHUD/Panel/VBox/TimerBar.value = 100.0
	_update_server_hud_timer_label()


func _on_timer_tick(remaining: float, total: float) -> void:
	if not $ServerHUD.visible:
		return
	if _scene_loop == null:
		return
	if not _scene_loop.auto_advance:
		$ServerHUD/Panel/VBox/TimerLabel.text = "Auto-advance: OFF [L] (N = manual)"
		return
	$ServerHUD/Panel/VBox/TimerLabel.text = "Next in: %ds" % max(0, int(remaining))
	if total > 0.0:
		$ServerHUD/Panel/VBox/TimerBar.value = clamp((remaining / total) * 100.0, 0.0, 100.0)


# ── Netzwerk-Diagnose-Overlay (Tab) ─────────────────────────────────

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("debug_toggle"):
		$NetDiag.visible = not $NetDiag.visible
		_diag_timer = DIAG_UPDATE_INTERVAL


## Server-HUD: Port und Adressen, darunter alle verbundenen Clients mit ID, Spielerfarbe,
## RTT, Paketverlust und IP. Die Werte liefert ENet ohne zusätzlichen Datenverkehr.
func _update_server_hud() -> void:
	var lines: PackedStringArray = _hud_base_lines.duplicate()
	var peers: PackedInt32Array = multiplayer.get_peers() if multiplayer.has_multiplayer_peer() else PackedInt32Array()
	lines.append("")
	lines.append("Clients: %d  (ID, color, RTT, loss, IP, ack)" % peers.size())
	var enet := multiplayer.multiplayer_peer as ENetMultiplayerPeer
	var channel := get_node_or_null("/root/DataChannel")   # optionales Modul modul_data_channel
	for pid: int in peers:
		var hex: String = "#%s" % GameState.get_color_for_id(pid).to_html(false).to_upper()
		var info := "  #%d  %s" % [pid, hex]
		var peer: ENetPacketPeer = enet.get_peer(pid) if enet != null else null
		if peer != null:
			var loss: float = peer.get_statistic(ENetPacketPeer.PEER_PACKET_LOSS) / 65536.0 * 100.0
			info += "  %d ms  %.1f %%  %s" % [
				int(peer.get_statistic(ENetPacketPeer.PEER_ROUND_TRIP_TIME)), loss, peer.get_remote_address()]
		if channel != null and channel.has_method("get_ack_ms") and channel.get_ack_ms(pid) >= 0.0:
			info += "  ack %d ms" % int(channel.get_ack_ms(pid))
		lines.append(info)
	$ServerHUD/Panel/VBox/NetworkLabel.text = "\n".join(lines)


func _process(delta: float) -> void:
	# Server-HUD einmal pro Sekunde aktualisieren (Clients kommen und gehen).
	if GameState.mode == GameState.Mode.SERVER and $ServerHUD.visible:
		_hud_timer += delta
		if _hud_timer >= 1.0:
			_hud_timer = 0.0
			_update_server_hud()

	# ── VR-Fade-Overlay der Kamera nachführen ──────────────────────
	if GameState.mode == GameState.Mode.XR and is_instance_valid(_vr_fade_plane):
		if _vr_fade_plane.visible or (is_instance_valid(_vr_fade_label) and _vr_fade_label.visible):
			var cam := _get_xr_camera()
			if is_instance_valid(cam):
				var target := cam.global_position - cam.global_basis.z * VR_OVERLAY_DIST
				_vr_fade_plane.global_position = _vr_fade_plane.global_position.lerp(target, delta * VR_OVERLAY_SPEED)
				_vr_fade_plane.global_basis    = cam.global_basis
				_vr_fade_label.global_position = _vr_fade_label.global_position.lerp(target, delta * VR_OVERLAY_SPEED)
				_vr_fade_label.global_basis    = cam.global_basis
	# ───────────────────────────────────────────────────────────────

	if not $NetDiag.visible:
		return
	_diag_timer += delta
	if _diag_timer < DIAG_UPDATE_INTERVAL:
		return
	_diag_timer = 0.0
	_update_net_diag()


func _update_net_diag() -> void:
	var lines: PackedStringArray = []
	lines.append("── NET DIAG  [Tab] ──")
	var mode_str: String = ["XR", "FPS", "SERVER"][GameState.mode]
	lines.append("Mode:  %s" % mode_str)

	if GameState.mode != GameState.Mode.SERVER:
		lines.append("Server: %s:%d" % [NetworkManager.server_ip, NetworkManager.PORT])
		if NetworkManager.client_connected_flag:
			lines.append("Status: Connected")
		elif NetworkManager.reconnect_attempts > 0:
			lines.append("Status: Connecting ... (attempt %d)" % NetworkManager.reconnect_attempts)
		else:
			lines.append("Status: Not connected")

	lines.append("My ID: %s" % (str(GameState.my_id) if GameState.my_id != 0 else "—"))
	lines.append("Scene: %d / %d" % [SceneManager.current_index + 1, SceneManager.scenes_list.size()])
	if multiplayer.has_multiplayer_peer():
		var peers := multiplayer.get_peers()
		lines.append("Peers: %d" % peers.size())
		for pid in peers:
			var col: Color = GameState.get_color_for_id(pid)
			var hex: String = "#%s" % col.to_html(false).substr(0, 6).to_upper()
			lines.append("  #%d  %s" % [pid, hex])
	else:
		lines.append("Peers: —")
	$NetDiag/Panel/Label.text = "\n".join(lines)


# ── Fade Overlay ─────────────────────────────────────────────────────

func _on_scene_about_to_change(index: int) -> void:
	if GameState.mode == GameState.Mode.SERVER:
		SceneManager.confirm_scene_load(index)
		return

	var d: Dictionary = SceneManager.scenes_list[index]
	var lines: PackedStringArray = ["entering:"]
	if d.get("name", "") != "":
		lines.append(d["name"])
	if d.get("team", "") != "":
		lines.append(d["team"])
	if d.get("info", "") != "":
		lines.append(d["info"])
	var info_text: String = "\n".join(lines)

	if GameState.mode == GameState.Mode.XR:
		_start_vr_scene_fade(index, info_text)
	else:
		_start_fps_scene_fade(index, info_text)


func _start_fps_scene_fade(index: int, info_text: String) -> void:
	$FadeOverlay/SceneInfoLabel.text = info_text

	if is_instance_valid(_fade_tween) and _fade_tween.is_running():
		_fade_tween.kill()
		$FadeOverlay/ColorRect.color.a         = 1.0
		$FadeOverlay/SceneInfoLabel.modulate.a = 0.0
	else:
		$FadeOverlay/ColorRect.color.a         = 0.0
		$FadeOverlay/SceneInfoLabel.modulate.a = 0.0

	$FadeOverlay.visible = true

	_fade_tween = create_tween()
	_fade_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_fade_tween.tween_property($FadeOverlay/ColorRect, "color:a", 1.0, FADE_OUT_DURATION)
	_fade_tween.tween_callback(func(): SceneManager.confirm_scene_load(index))
	_fade_tween.tween_property($FadeOverlay/SceneInfoLabel, "modulate:a", 1.0, 0.15)
	_fade_tween.tween_interval(TEXT_HOLD_DURATION)
	_fade_tween.tween_property($FadeOverlay/SceneInfoLabel, "modulate:a", 0.0, 0.15)
	_fade_tween.tween_property($FadeOverlay/ColorRect, "color:a", 0.0, FADE_IN_DURATION)
	_fade_tween.tween_callback(func():
		$FadeOverlay.visible = false
		$FadeOverlay/SceneInfoLabel.text = ""
	)


func _start_vr_scene_fade(index: int, info_text: String) -> void:
	if _vr_fade_plane == null:
		SceneManager.confirm_scene_load(index)
		return

	# Overlay sofort auf aktuelle Kameraposition einrasten (verhindert Slide aus World-Origin)
	var cam := _get_xr_camera()
	if is_instance_valid(cam):
		var start := cam.global_position - cam.global_basis.z * VR_OVERLAY_DIST
		_vr_fade_plane.global_position = start
		_vr_fade_plane.global_basis    = cam.global_basis
		_vr_fade_label.global_position = start
		_vr_fade_label.global_basis    = cam.global_basis

	_vr_fade_label.text    = info_text
	_vr_fade_plane.visible = true
	_vr_fade_label.visible = true

	if is_instance_valid(_fade_tween) and _fade_tween.is_running():
		_fade_tween.kill()
	_set_vr_fade_alpha(0.0)
	_set_vr_label_alpha(0.0)

	_fade_tween = create_tween()
	_fade_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_fade_tween.tween_method(_set_vr_fade_alpha,  0.0, 1.0, FADE_OUT_DURATION)
	_fade_tween.tween_callback(func(): SceneManager.confirm_scene_load(index))
	_fade_tween.tween_method(_set_vr_label_alpha, 0.0, 1.0, 0.15)
	_fade_tween.tween_interval(TEXT_HOLD_DURATION)
	_fade_tween.tween_method(_set_vr_label_alpha, 1.0, 0.0, 0.15)
	_fade_tween.tween_method(_set_vr_fade_alpha,  1.0, 0.0, FADE_IN_DURATION)
	_fade_tween.tween_callback(func():
		_vr_fade_plane.visible = false
		_vr_fade_label.visible = false
		_vr_fade_label.text = ""
	)


# ── VR-Overlay Hilfsfunktionen ───────────────────────────────────────

## Erstellt die 3D-Nodes für den VR-Fade-Overlay (einmalig in _ready()).
## Position/Ausrichtung wird in _process() jedes Frame aktualisiert.
## Einstellungen: VR_OVERLAY_DIST (Abstand m), VR_OVERLAY_SPEED (Lazy-Follow 1/s).
## QuadMesh 8×8 m deckt bei 2 m Abstand ~127° ab → mehr als Focus 3's 114° FoV.
func _setup_vr_fade_overlay() -> void:
	_vr_plane_mat = StandardMaterial3D.new()
	_vr_plane_mat.albedo_color    = Color(0.0, 0.0, 0.0, 0.0)
	_vr_plane_mat.transparency    = BaseMaterial3D.TRANSPARENCY_ALPHA
	_vr_plane_mat.shading_mode    = BaseMaterial3D.SHADING_MODE_UNSHADED
	_vr_plane_mat.no_depth_test   = true
	_vr_plane_mat.render_priority = 100

	var quad := QuadMesh.new()
	quad.size = Vector2(8.0, 8.0)   # 8×8 m sicher für alle VR-FoV-Winkel
	quad.surface_set_material(0, _vr_plane_mat)

	_vr_fade_plane = MeshInstance3D.new()
	_vr_fade_plane.mesh    = quad
	_vr_fade_plane.visible = false
	add_child(_vr_fade_plane)

	_vr_fade_label = Label3D.new()
	_vr_fade_label.pixel_size           = 0.004
	_vr_fade_label.font_size            = 28
	_vr_fade_label.modulate             = Color(1.0, 1.0, 1.0, 0.0)
	_vr_fade_label.outline_size         = 4
	_vr_fade_label.outline_modulate     = Color(0.0, 0.0, 0.0, 0.0)
	_vr_fade_label.no_depth_test        = true
	_vr_fade_label.render_priority      = 101
	_vr_fade_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_vr_fade_label.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	_vr_fade_label.billboard            = BaseMaterial3D.BILLBOARD_DISABLED
	_vr_fade_label.visible              = false
	add_child(_vr_fade_label)

	print("[Main] VR-Fade-Overlay (3D) initialisiert.")


func _set_vr_fade_alpha(alpha: float) -> void:
	if _vr_plane_mat != null:
		_vr_plane_mat.albedo_color.a = alpha


func _set_vr_label_alpha(alpha: float) -> void:
	if is_instance_valid(_vr_fade_label):
		_vr_fade_label.modulate.a         = alpha
		_vr_fade_label.outline_modulate.a = alpha


func _get_xr_camera() -> XRCamera3D:
	if not is_instance_valid(SceneManager.local_player):
		return null
	return SceneManager.local_player.get_node_or_null("XRCamera3D") as XRCamera3D
