# TEMPLATE CORE – nicht verändern
extends Node

## game_state.gd – Gemeinsamer Datenbehälter für alle anderen Scripte.
##
## Speichert: ob diese Instanz als Server, VR-Brille oder Desktop läuft;
## welche Netzwerk-ID wir haben; und welche Farbe welchem Spieler gehört.


enum Mode { XR, FPS, SERVER }

## Aktueller Startmodus dieser Instanz
var mode: Mode = Mode.FPS

## true = Server und MATLAB-Empfang binden nur an 127.0.0.1 (Einzelspieler am PC)
var local_only: bool = false

## Eigene Peer-ID (wird nach Verbindung gesetzt)
var my_id: int = 0

## Farbzuordnung: peer_id → Color
var player_colors: Dictionary = {}

## Vordefinierte Spielerfarben (reihum vergeben)
const PLAYER_COLORS: Array[Color] = [
	Color(0.9, 0.2, 0.2, 1.0),  # Rot
	Color(0.2, 0.4, 0.9, 1.0),  # Blau
	Color(0.2, 0.85, 0.3, 1.0), # Grün
	Color(0.95, 0.85, 0.1, 1.0), # Gelb
	Color(0.85, 0.2, 0.85, 1.0), # Magenta
	Color(0.1, 0.85, 0.85, 1.0), # Cyan
	Color(0.95, 0.5, 0.1, 1.0),  # Orange
	Color(0.85, 0.85, 0.85, 1.0), # Hellgrau
]


## Gibt die Farbe für eine Peer-ID zurück.
## Wurde noch keine Farbe zugewiesen (z. B. vor dem ersten Server-RPC),
## wird lokal ein Platzhalter vergeben – der Server überschreibt ihn via RPC.
func get_color_for_id(peer_id: int) -> Color:
	if not player_colors.has(peer_id):
		var idx: int = player_colors.size() % PLAYER_COLORS.size()
		player_colors[peer_id] = PLAYER_COLORS[idx]
	return player_colors[peer_id]


## Setzt die Farbe für eine Peer-ID explizit (vom Server per RPC autorisiert).
func set_color_for_id(peer_id: int, color: Color) -> void:
	player_colors[peer_id] = color


## Setzt den Spielzustand zurück (z. B. bei Reconnect).
func reset() -> void:
	player_colors.clear()
	my_id = 0
