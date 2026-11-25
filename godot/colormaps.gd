extends RefCounted
## Farbverlaeufe: Vorlagen und die Farbtabelle fuer die Shader.
## Ein Verlauf ist {"offsets": PackedFloat32Array, "colors": PackedColorArray}; der Alphawert
## jeder Farbe ist die Deckkraft (wirkt in Volumen und Schnitten).

const NAMES := ["rainbow", "hot", "gray", "viridis", "turbo"]
const MAX_STOPS := 5

const PRESETS := {
	"rainbow": [[0.0, Color(0.05, 0.1, 0.9)], [0.33, Color(0.0, 0.9, 0.9)], [0.66, Color(1.0, 0.9, 0.1)], [1.0, Color(1.0, 0.1, 0.05)]],
	"hot": [[0.0, Color(0.0, 0.0, 0.0)], [0.33, Color(1.0, 0.0, 0.0)], [0.67, Color(1.0, 1.0, 0.0)], [1.0, Color(1.0, 1.0, 1.0)]],
	"gray": [[0.0, Color(0.0, 0.0, 0.0)], [1.0, Color(1.0, 1.0, 1.0)]],
	"viridis": [[0.0, Color(0.267, 0.005, 0.329)], [0.25, Color(0.229, 0.322, 0.546)], [0.5, Color(0.128, 0.567, 0.551)], [0.75, Color(0.369, 0.789, 0.383)], [1.0, Color(0.993, 0.906, 0.144)]],
	"turbo": [[0.0, Color(0.19, 0.07, 0.23)], [0.25, Color(0.16, 0.74, 0.92)], [0.5, Color(0.64, 0.99, 0.24)], [0.75, Color(0.98, 0.49, 0.13)], [1.0, Color(0.48, 0.02, 0.01)]],
}


static func preset(name: String) -> Dictionary:
	var offsets := PackedFloat32Array()
	var colors := PackedColorArray()
	for stop: Array in PRESETS.get(name, PRESETS["rainbow"]):
		offsets.append(stop[0])
		colors.append(stop[1])
	return {"offsets": offsets, "colors": colors}


## 256 x 1 Pixel, RGBA: Farbe und Deckkraft entlang des Verlaufs.
static func make_image(gradient: Dictionary) -> Image:
	var g := Gradient.new()
	g.offsets = gradient.offsets
	g.colors = gradient.colors
	var img := Image.create_empty(256, 1, false, Image.FORMAT_RGBA8)
	for i in 256:
		img.set_pixel(i, 0, g.sample(i / 255.0))
	return img
