extends Label3D

## hand_hud.gd – Kleines schwebendes HUD an einem Controller, nur für den eigenen Spieler.
##
## Der XR-Spieler hängt es an den linken Controller. Es zeigt Zustände und Bedienhinweise;
## spätere Einträge und Menüs kommen hierher: set_entry("schluessel", "Text").

## Schlüssel → Text, in der Reihenfolge des ersten Setzens angezeigt
var _entries: Dictionary = {}


func _ready() -> void:
	font_size = 32
	pixel_size = 0.0005
	billboard = BaseMaterial3D.BILLBOARD_ENABLED
	no_depth_test = true
	render_priority = 9
	outline_modulate = Color(0, 0, 0)
	position = Vector3(0.0, 0.09, -0.02)


## Setzt oder ändert einen Eintrag; ein leerer Text entfernt ihn.
func set_entry(key: String, value: String) -> void:
	if value.is_empty():
		_entries.erase(key)
	else:
		_entries[key] = value
	text = "\n\n".join(PackedStringArray(_entries.values()))
