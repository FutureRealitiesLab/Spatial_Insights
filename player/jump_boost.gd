extends RefCounted

## jump_boost.gd – Boost-Sprung: Höhenverlauf für XR- und FPS-Spieler.
##
## Der Besitzer ruft start() beim Auslöser auf und addiert jedes Frame step(delta) auf die
## Höhe seiner Kamera (XR-Ursprung bzw. FPS-Kopf). offset ist die aktuelle Höhe über dem
## echten Boden; Boden = Position minus offset.
##
## Verlauf: Aufstieg wie ein Wurf (am Anfang schnell, nach oben läuft die Energie aus,
## am höchsten Punkt Geschwindigkeit 0), danach langsames Sinken ohne Ruck, sanfte
## Landung. In der Luft ist ein weiterer Start gesperrt.
## Höhe, Aufstiegs- und Sinkzeit: Project Settings → Situs Core → Jump.

const SitusSettings := preload("res://addons/situs_core/core/situs_settings.gd")

## Aktuelle Höhe über dem echten Boden in Metern
var offset: float = 0.0

var _phase: int = 0   # 0 = am Boden, 1 = Aufstieg, 2 = Sinken
var _time: float = 0.0


func is_flying() -> bool:
	return _phase != 0


## Startet den Sprung. Gibt false zurück, wenn abgeschaltet oder gerade in der Luft.
func start() -> bool:
	if not SitusSettings.get_jump_enabled() or _phase != 0:
		return false
	_phase = 1
	_time = 0.0
	return true


## Rechnet den Verlauf weiter und gibt die Höhenänderung seit dem letzten Aufruf zurück
## (zum Addieren auf die Kamerahöhe).
func step(delta: float) -> float:
	if _phase == 0:
		return 0.0
	var height := SitusSettings.get_jump_height()
	var new_offset := 0.0
	_time += delta
	if _phase == 1:
		var x := clampf(_time / maxf(SitusSettings.get_jump_rise(), 0.05), 0.0, 1.0)
		new_offset = height * (1.0 - (1.0 - x) * (1.0 - x))
		if x >= 1.0:
			_phase = 2
			_time = 0.0
	else:
		var x := clampf(_time / maxf(SitusSettings.get_jump_glide(), 0.5), 0.0, 1.0)
		new_offset = height * (1.0 + cos(PI * x)) / 2.0
		if x >= 1.0:
			_phase = 0
			new_offset = 0.0
	var change := new_offset - offset
	offset = new_offset
	return change
