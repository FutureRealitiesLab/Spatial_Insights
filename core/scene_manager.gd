# TEMPLATE CORE – nicht verändern
extends Node

## scene_manager.gd – Herzstück der Ausstellung.
##
## Lädt die aktuelle Szene, spawnt Spieler-Figuren und Avatare anderer
## Besucherinnen, und schaltet bei Bedarf in den Standalone-Modus
## (läuft ohne Server).
##
## Welche Szenen es gibt und wann gewechselt wird, bestimmt ein optionales
## Modul (z. B. modules/modul_scene_loop). Ohne Modul läuft genau eine Szene
## (ProjectSettings "situs_core/default_scene").
##
## Architektur-Übersicht:
##
##   main.tscn (persistent, läuft immer)
##     ├── Menu          – Startmenü
##     ├── SceneContainer  – hier werden Team-Szenen rein-/rausgeladen
##     ├── PlayersContainer – Avatare leben hier; überleben Szenenwechsel!
##     └── ServerHUD      – Timer-Anzeige + "Next"-Button, nur Server
##
##   SceneManager (Autoload)
##     • holt die Szenen-Liste vom scene_provider (Modul) oder nutzt die Default-Szene
##     • Server: löst Szenenwechsel via RPC aus (request_scene)
##     • Server: sendet aktuelle Szene an Späteinsteiger (by name/index)
##     • Clients: empfangen Szenenwechsel-RPC, laden lokal
##     • alle: spawnen lokalen Spieler + Remote-Avatare


const SitusSettings = preload("res://addons/situs_core/core/situs_settings.gd")

## Standard-Avatar – wird genutzt wenn die Szene keinen eigenen angibt
const DEFAULT_AVATAR_PATH = "res://addons/situs_core/avatar/variants/avatar_dynamic_cone.tscn"
const DEFAULT_SCENE_PATH  = "res://addons/situs_core/templates/team_scene.tscn"
const DEFAULT_AVATAR = preload("res://addons/situs_core/avatar/remote_avatar.tscn")
const XRPlayer       = preload("res://addons/situs_core/player/xr_player.tscn")
const FPSPlayer      = preload("res://addons/situs_core/player/fps_player.tscn")

## Index der aktuell laufenden Szene
var current_index: int = -1

## Optionaler Szenen-Lieferant (ein Modul setzt sich hier in seinem _ready()).
## Muss get_scene_list() -> Array[Dictionary] anbieten. Einträge:
##   path (Pflicht), name, duration, avatar, team, info, player_color (optional)
var scene_provider: Object = null

## Szenen-Liste (vom scene_provider oder Default-Szene)
var scenes_list: Array = []

## Referenzen auf Container-Nodes aus main.tscn (gesetzt via initialize())
var _scene_container:   Node3D = null
var _players_container: Node3D = null

## Aktuell geladene Team-Szene
var _current_scene: Node = null

## Lokaler Spieler dieser Instanz
var local_player: Node = null

## Eigener Avatar (Körper-Anzeige in First-Person) – nur wenn Avatar set_self_mode() unterstützt
var self_avatar: Node = null

## Remote-Avatare – bleiben über Szenenwechsel erhalten!
## peer_id (int) → RemoteAvatar-Node
## Wird direkt von networking/network_manager.gd gelesen.
var remote_avatars: Dictionary = {}

## Standalone-Modus: Szenen laufen lokal durch ohne Server (aktiviert via Trigger am Headset)
var standalone_mode: bool = false

## Standalone wurde ein- oder ausgeschaltet (aus, sobald doch ein Server verbunden ist).
## Projekte können hier z. B. eine eigene Datenquelle starten.
signal standalone_changed(active: bool)

signal scene_changed(index: int, scene_name: String)

## Wird vor dem Szenenwechsel emittiert. main.gd startet den Fade-Out
## und ruft danach confirm_scene_load(index) auf.
signal scene_about_to_change(index: int)

## Spieler/Controller wünschen Szene vor (+1) oder zurück (-1).
## Ohne Szenen-Modul hört niemand zu → kein Effekt.
signal scene_step_requested(direction: int)


# ══════════════════════════════════════════════════════════════════
#  Initialisierung  (aufgerufen von main.gd nach Modus-Wahl)
# ══════════════════════════════════════════════════════════════════

## Muss vor start() aufgerufen werden.
## scene_container   → Node3D "SceneContainer" aus main.tscn
## players_container → Node3D "PlayersContainer" aus main.tscn
func initialize(scene_container: Node3D, players_container: Node3D) -> void:
	_scene_container   = scene_container
	_players_container = players_container

	if scene_provider != null and scene_provider.has_method("get_scene_list"):
		scenes_list = scene_provider.get_scene_list()
		if scenes_list.is_empty():
			push_warning("[SceneManager] Szenen-Modul lieferte keine Szenen – nutze Default-Szene.")
	if scenes_list.is_empty():
		scenes_list = [_default_scene_entry()]

	NetworkManager.player_joined.connect(_on_player_joined)
	NetworkManager.player_left.connect(_on_player_left)

	if GameState.mode != GameState.Mode.SERVER:
		NetworkManager.client_connected.connect(_on_client_connected)
		NetworkManager.client_disconnected.connect(_on_client_disconnected)

	print("[SceneManager] %d Szene(n) registriert." % scenes_list.size())


## Szene ohne Modul: eine einzige Szene, kein automatischer Wechsel.
## Pfad per Project Setting "situs_core/default_scene" überschreibbar.
func _default_scene_entry() -> Dictionary:
	return {
		"path":     ProjectSettings.get_setting("situs_core/default_scene", DEFAULT_SCENE_PATH),
		"name":     "Default",
		"duration": -1.0,
		"avatar":   DEFAULT_AVATAR_PATH,
		"team":     "",
		"info":     "",
	}


## Startet das System nach initialize().
func start() -> void:
	if GameState.mode == GameState.Mode.SERVER:
		# Server lädt sofort Szene 0 und benachrichtigt alle bereits verbundenen Clients
		_load_scene_local(0)
		if multiplayer.get_peers().size() > 0:
			_rpc_change_scene.rpc(0)
	else:
		# Client: Szene 0 sofort laden – nicht auf Server-Verbindung warten.
		# Wenn der Server eine andere Szene schickt, wird per _rpc_change_scene gewechselt.
		_load_scene_local(0)


func _process(_delta: float) -> void:
	_update_self_avatar()


# ══════════════════════════════════════════════════════════════════
#  Szenenwechsel  (Server-seitig ausgelöst)
# ══════════════════════════════════════════════════════════════════

## Löst den Wechsel zu Szene `index` aus (Fade → confirm_scene_load).
## Erlaubt auf dem Server und im Standalone-Modus. Wird vom Szenen-Modul gerufen.
func request_scene(index: int) -> void:
	if not multiplayer.is_server() and not standalone_mode:
		return
	if index < 0 or index >= scenes_list.size():
		return
	scene_about_to_change.emit(index)


## Szene vor / zurück anfordern (Controller-Tasten). Das Szenen-Modul entscheidet,
## ob und wohin gewechselt wird; ohne Modul passiert nichts.
func advance_scene() -> void:
	scene_step_requested.emit(1)


func retreat_scene() -> void:
	scene_step_requested.emit(-1)


## Aktiviert den lokalen Standalone-Modus (kein Server nötig).
## Wird von xr_player.gd via Trigger und fps_player.gd via Q/E ausgelöst.
func activate_standalone() -> void:
	standalone_mode = true
	print("[SceneManager] Standalone-Modus aktiviert.")
	standalone_changed.emit(true)


## Beendet den Standalone-Modus (der Server hat Vorrang, sobald er verbunden ist).
func deactivate_standalone() -> void:
	if not standalone_mode:
		return
	standalone_mode = false
	print("[SceneManager] Standalone-Modus beendet.")
	standalone_changed.emit(false)


## Aufgerufen von main.gd nach Fade-Out.
## Führt den eigentlichen Szenenwechsel aus und benachrichtigt Clients.
func confirm_scene_load(index: int) -> void:
	_load_scene_local(index)
	if multiplayer.has_multiplayer_peer() and multiplayer.is_server():
		_rpc_change_scene.rpc(index)


# ══════════════════════════════════════════════════════════════════
#  RPC – Szene auf Clients laden
# ══════════════════════════════════════════════════════════════════

## Wird vom Server gerufen; läuft auf Clients (call_remote → nie auf Server selbst).
## Clients routen durch den gleichen Fade-Pfad wie der Server.
@rpc("authority", "reliable", "call_remote")
func _rpc_change_scene(index: int) -> void:
	if index == current_index:
		return  # Bereits geladen – verhindert Doppel-Load wenn Client kurz nach start() verbindet
	scene_about_to_change.emit(index)
	# main.gd ruft confirm_scene_load(index) nach dem Fade-Out auf.


func _load_scene_local(index: int) -> void:
	if index < 0 or index >= scenes_list.size():
		push_error("[SceneManager] Ungültiger Index: %d" % index)
		return

	current_index = index

	# Alte Szene entladen
	if is_instance_valid(_current_scene):
		_current_scene.queue_free()
		_current_scene = null

	# Lokaler Spieler bleibt persistent in PlayersContainer.
	# FPS: Position & Rotation bleiben erhalten; Restgeschwindigkeit nullen (verhindert Driften während Fade).
	# XR Multiplayer: XROrigin3D immer auf (0,0,0) fixieren, um Co-Location mit dem physischen Raum zu garantieren.
	if is_instance_valid(local_player):
		if local_player is CharacterBody3D:
			local_player.velocity = Vector3.ZERO
		elif GameState.mode == GameState.Mode.XR and not standalone_mode:
			local_player.global_position = Vector3.ZERO
			local_player.global_rotation = _room_rotation()

	if is_instance_valid(self_avatar):
		self_avatar.queue_free()
		self_avatar = null

	# Neue Szene instantiieren
	var scene_data: Dictionary = scenes_list[index]
	var packed := load(scene_data["path"]) as PackedScene
	if packed == null:
		push_error("[SceneManager] Szene nicht gefunden: " + scene_data["path"])
		return

	_current_scene = packed.instantiate()
	_scene_container.add_child(_current_scene)

	# Verbindungsstatus-Tafel in Clients injizieren (versteckt sich sobald verbunden)
	if GameState.mode != GameState.Mode.SERVER:
		_spawn_net_info_board()

	# Focus 3: Schatten weicher machen (render_scale 0.6 + PCF-Standard = pixelig)
	if _is_focus3():
		_soften_shadows(_current_scene)

	# Lokalen Spieler spawnen falls noch nicht vorhanden (nicht auf Server)
	if GameState.mode != GameState.Mode.SERVER:
		_disable_scene_cameras(_current_scene)
		if not is_instance_valid(local_player):
			_spawn_local_player()
		else:
			_activate_local_player_camera()
		call_deferred("_activate_local_player_camera")
		_spawn_self_avatar()
		_update_self_avatar()

	# Bereits verbundene Remote-Avatare mit dem Avatar-Typ dieser Szene neu spawnen
	_respawn_all_remote_avatars()

	var label: String = scene_data.get("name", "Szene %d" % index)
	print("[SceneManager] '%s' geladen (Index %d)" % [label, index])
	scene_changed.emit(index, label)


# ══════════════════════════════════════════════════════════════════
#  Spieler & Avatare
# ══════════════════════════════════════════════════════════════════

func _spawn_local_player() -> void:
	match GameState.mode:
		GameState.Mode.XR:
			local_player = XRPlayer.instantiate()
		GameState.Mode.FPS:
			local_player = FPSPlayer.instantiate()
	if local_player:
		_players_container.add_child(local_player)
		if GameState.mode == GameState.Mode.XR and not standalone_mode:
			local_player.global_rotation = _room_rotation()


## Drehung des XR-Ursprungs: bildet den Tracking-Raum der Brille auf die Spielwelt ab
## (Project Setting situs_core/room/rotation_deg). Szenen bleiben unverändert.
func _room_rotation() -> Vector3:
	return Vector3(0.0, deg_to_rad(SitusSettings.get_room_rotation_deg()), 0.0)


## Spawnt einen Avatar für den eigenen Körper (First-Person-Ansicht).
## Nur wenn das Avatar-Script set_self_mode() kennt (z. B. DynamicCone).
func _spawn_self_avatar() -> void:
	var av := _get_current_avatar_scene().instantiate()
	if not av.has_method("set_self_mode"):
		av.free()
		return
	_players_container.add_child(av)
	var color_override = scenes_list[current_index].get("player_color", null) if current_index >= 0 else null
	if color_override is Color and av.has_method("set_force_color"):
		av.set_force_color(color_override)
	av.peer_id = GameState.my_id
	av.set_self_mode(true)
	self_avatar = av


## Aktualisiert den Selbst-Avatar mit der eigenen Spielerposition.
## FPS-Player: Head-Node bei y=1.6; XR-Player: XRCamera3D.
func _update_self_avatar() -> void:
	if not is_instance_valid(self_avatar):
		return
	if not is_instance_valid(local_player):
		return
	var head_node: Node3D = local_player.get_node_or_null("Head")
	if head_node == null:
		head_node = local_player.get_node_or_null("XRCamera3D")
	var head_pos: Vector3
	if head_node:
		head_pos = head_node.global_position
	else:
		head_pos = local_player.global_position + Vector3(0.0, 1.6, 0.0)
	# Basis = Kopf-XZ auf Boden-Y projiziert: Avatar folgt physischer Bewegung,
	# nicht dem fixen XROrigin-Spawn-Punkt. Für FPS kein Unterschied (Head-XZ == Body-XZ).
	# Beim Sprung bleibt der Körper am echten Boden (XR-Spieler: get_floor_y()).
	var floor_y: float = local_player.get_floor_y() if local_player.has_method("get_floor_y") else local_player.global_position.y
	var base_pos := Vector3(head_pos.x, floor_y, head_pos.z)
	var head_rot := head_node.global_rotation if head_node != null else Vector3.ZERO
	self_avatar.update_transform(base_pos, head_pos, head_rot)


## Gibt die Avatar-Szene für die aktuelle Team-Szene zurück.
## Szenen tragen optional "avatar": "res://addons/situs_core/avatar/variants/..." ein (scene_info.cfg im Szenen-Modul).
## Fehlt der Eintrag oder ist der Pfad ungültig → DEFAULT_AVATAR.
func _get_current_avatar_scene() -> PackedScene:
	if current_index >= 0 and current_index < scenes_list.size():
		var path: String = scenes_list[current_index].get("avatar", "")
		if path != "":
			var packed := load(path) as PackedScene
			if packed:
				return packed
			push_warning("[SceneManager] Avatar-Pfad ungültig: %s – nutze Default." % path)
	return DEFAULT_AVATAR


func _spawn_remote_avatar(peer_id: int) -> void:
	if remote_avatars.has(peer_id):
		return
	# Szene-spezifischer Farb-Override: "player_color" in der Szenen-Liste
	#   Color(r,g,b,1) → alle Spieler bekommen in dieser Szene dieselbe Farbe
	#   nicht gesetzt / null → individuelle Farbe (vom Server zugewiesen)
	var avatar: Node = _get_current_avatar_scene().instantiate()
	# add_child VOR peer_id: _ready() läuft zuerst (baut Ringe, setzt _ready_done,
	# initialisiert @onready-Nodes), danach triggert der peer_id-Setter _apply_color()
	# mit vollständig initialisiertem Avatar.
	_players_container.add_child(avatar)
	# Szenen-Override DIREKT an Avatar übergeben – GameState.player_colors bleibt
	# unberührt, damit keine Farbe in die nächste Szene blutet.
	var color_override = scenes_list[current_index].get("player_color", null) if current_index >= 0 else null
	if color_override is Color and avatar.has_method("set_force_color"):
		avatar.set_force_color(color_override)
	avatar.peer_id = peer_id
	remote_avatars[peer_id] = avatar
	print("[SceneManager] Remote-Avatar für Spieler %d gespawnt." % peer_id)


## Alle vorhandenen Remote-Avatare mit dem Avatar-Typ der neuen Szene neu spawnen.
## Wird nach jedem Szenenwechsel aufgerufen.
func _respawn_all_remote_avatars() -> void:
	var peer_ids: Array = remote_avatars.keys()
	var cached_states: Dictionary = {}
	for pid in peer_ids:
		var av = remote_avatars[pid]
		if is_instance_valid(av):
			var head_node: Node3D = av.get_node_or_null("Head")
			var hpos: Vector3 = head_node.global_position if head_node else av.global_position + Vector3(0.0, 1.6, 0.0)
			var hrot: Vector3 = head_node.global_rotation if head_node else av.global_rotation
			cached_states[pid] = {
				"body_pos": av.global_position,
				"head_pos": hpos,
				"head_rot": hrot
			}
			av.queue_free()
	remote_avatars.clear()
	for pid in peer_ids:
		_spawn_remote_avatar(pid)
		if cached_states.has(pid) and remote_avatars.has(pid):
			var s: Dictionary = cached_states[pid]
			remote_avatars[pid].update_transform(s["body_pos"], s["head_pos"], s["head_rot"])


# ── Netzwerk-Callbacks ───────────────────────────────────────────

func _on_player_joined(peer_id: int) -> void:
	if GameState.mode == GameState.Mode.SERVER:
		# Späteinsteiger bekommt sofort die aktuelle Szene
		if current_index >= 0:
			_rpc_change_scene.rpc_id(peer_id, current_index)
			print("[Server] Späteinsteiger %d → Szene %d gesendet." % [peer_id, current_index])
		# Server spawnt Avatar um Positionen in der ServerView anzuzeigen
		_spawn_remote_avatar(peer_id)
		return

	# Client: Avatar für neuen Spieler spawnen
	if peer_id == multiplayer.get_unique_id():
		return
	_spawn_remote_avatar(peer_id)


func _on_player_left(peer_id: int) -> void:
	if remote_avatars.has(peer_id):
		remote_avatars[peer_id].queue_free()
		remote_avatars.erase(peer_id)
		print("[SceneManager] Remote-Avatar für Spieler %d entfernt." % peer_id)


func _on_client_connected() -> void:
	# GameState.my_id ist jetzt gesetzt. Falls self_avatar bereits gespawnt wurde
	# (während my_id noch 0 war), Farbe jetzt nachladen.
	if is_instance_valid(self_avatar):
		self_avatar.peer_id = GameState.my_id


func _on_client_disconnected() -> void:
	# Server weg → alle Remote-Avatare entfernen.
	# Nach dem Reconnect sendet der Server neue _notify_player_joined-RPCs
	# und die Avatare werden neu gespawnt.
	for pid: int in remote_avatars.keys():
		remote_avatars[pid].queue_free()
	remote_avatars.clear()
	print("[SceneManager] Alle Remote-Avatare entfernt (Verbindung verloren).")


## Aufgerufen von scene_hooks.gd._ready() jeder Team-Szene.
## Übernimmt F6-Testmodus-Erkennung und ServerCamera-Positionierung,
## damit dieser Boilerplate nicht in den Team-Szenen-Scripts steht.
func on_team_scene_ready(scene_root: Node3D) -> void:
	if scenes_list.is_empty():
		# F6-Modus: SceneManager wurde nicht von main.gd initialisiert.
		var fps := FPSPlayer.instantiate()
		scene_root.add_child(fps)
		fps.global_position = Vector3(0, 1, 0)
		print("[SceneManager] F6-Testmodus: FPS-Player gespawnt.")
		print("               WASD = Bewegen  |  Maus = Umsehen  |  ESC = Maus freigeben")
	else:
		# Spielbetrieb: ServerCamera nur auf dem Server aktivieren und per look_at() ausrichten.
		# Auf Clients (FPS/XR) bleibt sie inaktiv, damit sie nicht die Spielerkamera kapert.
		var cam := scene_root.get_node_or_null("ServerCamera") as Camera3D
		if cam:
			if GameState.mode == GameState.Mode.SERVER:
				cam.current = true
				cam.global_position = Vector3(0.0, 5.0, 5.0)
				cam.look_at(Vector3(0.0, 0.5, 0.0), Vector3.UP)
			else:
				cam.current = false
		print("[SceneManager] '%s' im Spielbetrieb geladen." % scene_root.name)


## Deaktiviert alle Camera3D-Nodes in einer geladenen Team-Szene (für Clients).
func _disable_scene_cameras(scene_root: Node) -> void:
	if not is_instance_valid(scene_root):
		return
	for cam in scene_root.find_children("*", "Camera3D", true, false):
		(cam as Camera3D).current = false


## Stellt sicher, dass die Kamera des lokalen Spielers (FPS oder XR) aktiv ist.
func _activate_local_player_camera() -> void:
	if not is_instance_valid(local_player):
		return
	var cam := local_player.get_node_or_null("Head/Camera3D") as Camera3D
	if cam:
		cam.current = true
		return
	var xr_cam := local_player.get_node_or_null("XRCamera3D") as XRCamera3D
	if xr_cam:
		xr_cam.make_current()


## Injiziert eine Label3D-Verbindungsstatusanzeige in die aktuelle Szene.
## Das Label versteckt sich sobald die Verbindung steht (→ SYSTEM/net_info_board.gd).
func _spawn_net_info_board() -> void:
	if not is_instance_valid(_current_scene):
		return
	var board := Label3D.new()
	board.name = "NetInfoBoard"
	board.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	# Position: rechte Seite, Kopfhöhe, hintere Raumhälfte –
	# außerhalb des Kunstwerk-Zentrums, gut zugänglich für Cassiopeia
	board.position = Vector3(1.6, 1.5, 2.5)
	board.pixel_size = 0.005
	board.font_size = 24
	board.outline_size = 5
	board.modulate = Color(1.0, 0.45, 0.1)        # Orange – gut sichtbar im Dunkeln
	board.outline_modulate = Color(0.0, 0.0, 0.0)  # Schwarzer Rand für Lesbarkeit
	board.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	board.set_script(load("res://addons/situs_core/core/net_info_board.gd"))
	_current_scene.add_child(board)


# ══════════════════════════════════════════════════════════════════
#  Geräte-spezifische Performance-Optimierungen
# ══════════════════════════════════════════════════════════════════

## Weichere Schatten auf Focus 3: höheres shadow_blur reduziert den pixeligen Look
## bei render_scale 0.6. DirectionalLight → 2 Kaskaden statt 4 (günstiger + sauberer
## bei kleinen Indoor-Räumen ohne langen Schattenwurf in die Ferne).
func _soften_shadows(scene_root: Node) -> void:
	var count: int = 0
	for light in scene_root.find_children("*", "DirectionalLight3D", true, false):
		var d := light as DirectionalLight3D
		d.shadow_blur = 2.5
		d.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
		count += 1
	for light in scene_root.find_children("*", "OmniLight3D", true, false):
		(light as OmniLight3D).shadow_blur = 2.0
		count += 1
	for light in scene_root.find_children("*", "SpotLight3D", true, false):
		(light as SpotLight3D).shadow_blur = 2.0
		count += 1
	if count > 0:
		print("[SceneManager] Focus 3: shadow_blur gesetzt für %d Lichtquelle(n)." % count)


## True wenn das Gerät ein HTC Focus 3 / Vive ist.
## Wird zur Laufzeit via OS.get_model_name() ermittelt.
func _is_focus3() -> bool:
	var model: String = OS.get_model_name().to_lower()
	return "focus" in model or "vive" in model


## Deaktiviert Schatten aller Lichtquellen in einer Szene.
## Focus 3: 2448×2448 px/Auge – Schatten-PCF-Taps ~66% teurer als auf Quest 2.
## Ohne Schatten: +0.8–1.2 ms Spielraum pro Frame (≈ 9–11% bei 90 Hz Budget).
func _disable_shadows(scene_root: Node) -> void:
	var lights: Array = []
	lights.append_array(scene_root.find_children("*", "DirectionalLight3D", true, false))
	lights.append_array(scene_root.find_children("*", "OmniLight3D",        true, false))
	lights.append_array(scene_root.find_children("*", "SpotLight3D",        true, false))
	for light: Node in lights:
		(light as Light3D).shadow_enabled = false
	if lights.size() > 0:
		print("[SceneManager] Focus 3: %d Lichtquelle(n) – Schatten deaktiviert." % lights.size())
