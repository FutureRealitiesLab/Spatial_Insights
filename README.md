# Spatial Insights: MATLAB → Godot 4 per UDP

Echtzeit-Kopplung: MATLAB berechnet zeitveränderliche Felder, Partikel oder Zellularautomaten und sendet sie per UDP an Godot 4. Godot stellt sie in einem Raum von 4 × 8 m dar (2D-Daten auf dem Boden, 3D-Daten in einer 2 m hohen Box) (Bild, Höhenfläche, Schnitte, Volumen, Pfeile, Partikel, Automat auf Ebene/Kugel/Torus). Langfristiges Ziel: VR-Simulator (siehe [docs/plan.md](docs/plan.md)).

Das Protokoll ist **typisiert**: Ein vierstelliger Magic-String (z. B. `S3v0`, `V2q0`, `P2p1`, `C2s3`) wählt Datenformat und Darstellung. Studierende schreiben nur ihre Simulationsschleife und rufen `udpSend(u, data, frameid)` auf.

**Neu auf einem Rechner?** Siehe [Installation und Konfiguration](docs/INSTALL.md).

```
(MATLAB: nicht im Repo. Die aktuellen Sender und Simulationen liegen vorerst in der HTW-Cloud
 unter Spatial Insights / Simulation VR Workshop / matlab-udp; später kommt ein demo/-Ordner.
 Sender: udpOpen, udpSend, udpListen, udpReceive, udpDrawnow, udpTest, PROTOCOL.md.)
godot/
  project.godot, export_presets.cfg
  addons/situs_core/       Situs Core (git subtree, nicht hier ändern)
  simulation_scene.tscn/.gd  Startszene der Simulation (in Situs)
  simulation_relay.gd      Autoload: UDP empfangen (Server) oder Frames vom Datenkanal (Clients)
  modul_data_channel/      Datenkanal Server → Clients (generisch)
  udp_receiver.gd  UDP-Empfang, Session-/Frame-Logik, Chunk-Zusammenbau, Warteschlange
  scene_view.gd    Darstellung je Magic (Ebenen), Raum 4 × 8 × 2 m, Einpassen
  field_image.gdshader, field_height.gdshader, field_slice.gdshader, volume_raymarch.gdshader
  colormap.gdshaderinc   Farbskalen (rainbow, hot, gray, viridis)
  box_outline.gd, orbit_camera.gd, debug_overlay.gd
  main.tscn, xr_rig.gd     alter eigenständiger Betrachter ohne Situs
  selftest.gd      Test ohne Netzwerk
docs/
  INSTALL.md       Einrichtung auf einem neuen Rechner, Inhalt des Setup-Skripts
  plan.md          Architektur MATLAB → Server-PC → Brillen
tools/
  setup_android.ps1  richtet einen Rechner für den Android-Export ein
```

## Schnellstart

1. **Godot 4.7.2**: `godot/project.godot` importieren und starten (F5), dann *Als Server starten*. Das Overlay (F3) zeigt "lauscht" auf Port 4242. Einrichtung des Rechners: [docs/INSTALL.md](docs/INSTALL.md).
2. **MATLAB**: den Ordner `udp/` aus der MATLAB-Sammlung (HTW-Cloud, siehe oben) zum Pfad hinzufügen und senden:

```matlab
u = udpOpen(magic="S3v0", address="127.0.0.1", port=4242, vspan=[0 1]);
for t = 1:1000
    field = ...;              % [ny nx nz], Werte im Bereich vspan
    udpSend(u, field, t);     % t = aufsteigende Frame-ID
    pause(1/20);
end
```

Zwei Rechner: `address` auf die IPv4-Adresse des Godot-Rechners setzen und dort eingehend UDP-Port 4242 in der Firewall freigeben. `udpTest` sendet nacheinander alle Magics (je 5 s), um den Betrachter zu prüfen.

## Magics und Eingabeformate

| `magic` | Darstellung | MATLAB-Eingabe |
|---|---|---|
| `S2s<m>` / `C2s<m>` | Skalarfeld bzw. Automat, `m`: 0 Ebene, 1 HÃ¶henflÃ¤che, 2 Kugel, 3 Torus | `[ny nx]` |
| `S3s<n>` / `C3s<n>` | `n` xy-Schnitte (`0`: drei Mittelschnitte) | `[ny nx nz]` |
| `S3v<a>` / `C3v<a>` | Volumen (Raymarching), `a`: 0 Standard, 1..9 Deckkraft 0,1..0,9 | `[ny nx nz]` |
| `V2p<k>` / `V3p<k>` | Gitterpunkte, um den Vektor verschoben (`k`=1 autoskaliert, 0 OriginallÃ¤nge) | `[ny nx 1 2]` / `[ny nx nz 3]` |
| `V2q<c>` / `V3q<c>` | Pfeile mit exakter LÃ¤nge (`c`=0 Farbe nach Betrag, 1..9 feste Farbe) | wie `V2p` |
| `P2p<c>` / `P3p<c>` | Partikel (`c`=0 Farbe nach Geschwindigkeit, 1..9 feste Farbe) | `[N nd]` oder `[N 2*nd]` mit Geschwindigkeit |
| `P2q<c>` / `P3q<c>` | Partikelvektoren (auch StraÃŸen), Vektor mit Boxausdehnung skaliert | `[N 2*nd]` |
| `T...` | reserviert (Verkehr) | nicht umgesetzt |

Wichtig:
- **Achsen:** Dimension 1 = y (`ny`), Dimension 2 = x (`nx`), Dimension 3 = z, wie bei MATLAB-`imagesc`. Die Daten werden spaltenweise (`data(:)`) gesendet.
- **Wertebereich:** `vspan=[vmin vmax]` gilt fÃ¼r alle S/V-Komponenten. Die Werte werden abgeschnitten und auf 0..255 quantisiert. Partikel gehen unquantisiert als `float32`, Positionen normiert auf 0..1. Automaten werden mit 1, 2, 4 oder 8 Bit pro Zustand gepackt (`nostates`).
- **Ebenen:** Das vollstÃ¤ndige Magic ist der EbenenschlÃ¼ssel, jedes Magic ergibt eine eigene Ebene. Mehrere Magics dÃ¼rfen dieselbe Frame-ID haben, jedes wird getrennt verfolgt. Ein Magic mit anderem 4. Byte (z. B. `S3v2` statt `S3v5`) ist eine andere Ebene.
- **Spatial Box:** `udpOpen(box=[xmin xmax ymin ymax zmin zmax])` (Standard `[0 8 0 4 0 2]`, Meter) legt fest, wo die Ebene im Raum liegt. Die Box des ersten Frames eines Magics gilt fÃ¼r die ganze Session. 2D-Daten liegen bei `zmin`, HÃ¶henflÃ¤chen reichen von `zmin` bis `zmax`, Kugel und Torus sitzen in der Boxmitte mit dem Radius der kleinsten Kante. Eine Verzerrung gibt es nicht, die Daten fÃ¼llen genau die Box. Der Absender muss die Box in den Raum legen.
- **Raum und Ausrichtung:** Das Betrachtervolumen (`box_size` an der Node `View`) ist 8 m (MATLAB-x) Ã— 4 m (MATLAB-y) Ã— 2 m (MATLAB-z), MATLAB-z zeigt nach oben. Es wird in `simulation_scene.gd` aus den Situs-Settings gesetzt (lange Seite = x). `room_rotation_deg` an `View` (Situs-Szene: 90Â°) legt die lange x-Seite entlang der Godot-z-Achse, um zum echten Raum auszurichten. SpÃ¤ter soll das serverseitig einstellbar sein.
## Paketformat (Kurzfassung)

Jedes Datagramm beginnt mit 44 Byte (little-endian): Magic (4 Byte ASCII), Session-ID, Frame-ID, Chunk-Index und Chunk-Anzahl (je uint32) sowie die Spatial Box (6 Ã— float32). Danach folgt je nach `magic(1)` ein Zusatz-Header (S/V: 76 Byte gesamt, P: 52, C: 57) und die Nutzdaten. Das vollständige Format steht in `PROTOCOL.md` im MATLAB-Ordner `udp/` (HTW-Cloud).

- **Session-ID:** `udpOpen` erzeugt pro Lauf eine neue Session-ID. Godot verwirft bei einer neuen ID den alten Zustand und ignoriert späte Pakete der letzten 32 alten Sessions. Eine neu gestartete Simulation wird daher sofort angezeigt, auch wenn die Frame-ID wieder bei 0 beginnt.
- **Frame-ID:** Innerhalb einer Session werden nur Frames mit einer größeren ID als der letzten fertigen angenommen. Unvollständige Frames werden verworfen (Overlay: "Verworfen"), sobald ein neueres kommt.
- **Warteschlange:** Fertige Frames kommen in eine Warteschlange, pro Magic bleibt nur das neueste. Pro Godot-Frame wird ein Frame dargestellt.
- **Chunking:** `udpSend` baut alle Datagramme in einem Puffer und ruft `write()` **einmal pro Frame** auf. `datagramSize` (Standard 65000, Bereich 1000..65000) ist die gesamte UDP-Nutzlast inklusive Header.

## Bedienung in Godot

| Taste | Wirkung |
|---|---|
| Linke Maustaste ziehen | Kamera um den Mittelpunkt drehen (Orbit) |
| Rechte Maustaste ziehen | Ansicht verschieben (Panning) |
| Mausrad | Zoom |
| `C` | Colormap wechseln (rainbow, hot, gray, viridis) |
| `F3` | Overlay ein-/ausblenden (Pakete/s, Frames/s, Frame-Größe, Verworfen, Session, Magic, Ebenen) |

Port und Bind-Adresse stehen an der Node `Receiver` (`port`, `bind_address`, `recv_buffer_size`). Es ist IPv4 gebunden (`0.0.0.0`).

## Situs Core: Server und mehrere Brillen

Das Godot-Projekt startet jetzt mit [Situs Core](https://github.com/FutureRealitiesLab/Situs-Core) (Subtree in `godot/addons/situs_core`, Renderer GL Compatibility). Situs liefert Server, Clients, Avatare und die Spieler. Die Simulation läuft als Szene darin.

```
MATLAB --UDP 4242--> Server (godot, "Als Server starten")
                       SimulationRelay empfängt, zeigt an und veröffentlicht
                       --ENet 7777, Kanal 1 (modul_data_channel)--> Brillen und FPS-Clients
```

| Datei | Aufgabe |
|---|---|
| `simulation_scene.tscn/.gd` | Szene mit `scene_view.gd`, Raumrahmen und Overlay. Raumgröße aus den Situs-Settings |
| `simulation_relay.gd` | Autoload. Server: UDP empfangen und veröffentlichen. Client: Frames vom Datenkanal. Beide lösen das Signal `frame_received` für `scene_view.gd` aus |
| `modul_data_channel/` | Generischer Datenkanal vom Server zu den Clients ([README](godot/modul_data_channel/README.md)) |

**Einstellungen** (Project Settings, Abschnitt *Situs Core*): `network/server_ip`, `room/width_m` (4), `room/length_m` (8), `room/rotation_deg`. Die Raumdrehung wirkt auf den XR-Ursprung der Brillen, nicht auf den Inhalt. Der frühere Wert `room_rotation_deg = 90` an `View` entspricht jetzt `rotation_deg = -90` (Vorzeichen an der Brille prüfen). Weitere Details in der Situs-Core-README.

**Eigene Settings dieses Projekts** (optional): Sie gehören zu diesem Projekt, nicht zu Situs, und stehen nicht im Editor-Dialog. Man trägt sie in `godot/project.godot` unter `[sim]` ein. Fehlen sie, gelten die Standardwerte.

| Setting | Standard | Bedeutung |
|---|---|---|
| `sim/udp_port` | `4242` | UDP-Port, auf dem Godot die MATLAB-Daten empfängt. Er muss mit `udpOpen(port=...)` in MATLAB übereinstimmen. Nur ändern, wenn 4242 belegt ist. |
| `sim/udp_on_clients` | `false` | `false`: Nur der Server empfängt MATLAB und verteilt die Daten über den Datenkanal an die Clients. `true`: Jede Instanz (auch Brille oder FPS-Client) empfängt selbst per UDP, ohne Server und ohne Datenkanal. |

Wann `sim/udp_on_clients = true`? Für **eine einzelne Brille ohne Server**: MATLAB sendet direkt an die IP der Brille (`udpOpen(address="<IP der Brille>")`), und die Brille zeigt die Daten allein an. Bei mehreren Brillen bleibt es `false`: MATLAB sendet an den Server, der Datenkanal verteilt weiter. Mit `true` werden Frames auf den Clients nicht mehr vom Server geholt, und mehrere Absender auf demselben Port sind nicht vorgesehen.

Beispiel in `project.godot`:

```ini
[sim]

udp_port=4242
udp_on_clients=false
```

Auch beim F6-Test der `simulation_scene.tscn` allein empfängt die Instanz direkt per UDP, unabhängig von diesen Settings.

**Start:** Server-PC: F5, „Als Server starten“. Die Serveransicht lässt sich mit der Maus navigieren: links ziehen dreht, rechts ziehen verschiebt, Mausrad zoomt. Brillen: APK mit der Server-IP in den Settings. Desktop-Test: zweite Instanz mit „Als Spieler starten (Lokal / 127.0.0.1)“. Im Overlay (F3) zeigen „Rolle“ und „Relay“ den Stand.

**Nicht mehr aktuell:** `main.tscn` mit `orbit_camera.gd` und `xr_rig.gd` (Flug, LBE-Tag) ist nicht mehr die Startszene. Sie bleibt als eigenständiger Betrachter ohne Situs erhalten (auch der `selftest` nutzt sie). Der folgende Abschnitt „VR mit SteamVR“ beschreibt diesen alten Betrachter.

## VR mit SteamVR (alter Betrachter ohne Situs)

Das Projekt startet automatisch in VR, wenn SteamVR läuft und ein Headset erkannt wird (OpenXR). Ohne Headset bleibt die Desktop-Ansicht mit Orbit-Kamera. Die Konsole meldet `XR: OpenXR aktiv.` bzw. `XR: kein OpenXR-Headset, Desktop-Ansicht.`

**Voraussetzungen:** SteamVR starten und als OpenXR-Runtime setzen (SteamVR → Einstellungen → OpenXR → "SteamVR als OpenXR-Runtime festlegen"). Dann Godot 4.7 starten (F5 oder Play-Button).

**Steuerung (Flug, keine Schritte):**

| Eingabe | Wirkung |
|---|---|
| Linker Stick bzw. Trackpad | Fliegen in Zeigerichtung des linken Controllers (vor/zurück, seitlich) |
| Rechter Stick, x | Stufenlos drehen, um die Kopfposition |
| Rechter Stick, y | Senkrecht steigen / sinken |

Die Controller werden als kleine Quader dargestellt. Der Startpunkt liegt auf dem Boden, 1,5 m vor der Längskante der 4 × 8 m-Fläche, Blickrichtung in den Raum. Der Raum ist in Metern fest (siehe oben), er wird nicht mehr zum Headset hin skaliert. Geschwindigkeit und Drehrate stehen an der Node `XRRig` (`fly_speed`, `turn_speed_deg`, `deadzone`). Das Overlay (`F3`) ist nur im Desktopfenster sichtbar, nicht im Headset.

Aufbau: `godot/xr_rig.gd` liegt auf `XRRig` (XROrigin3D mit Kamera und zwei Controllern). Die Projekteinstellungen `xr/openxr/enabled` und `xr/shaders/enabled` sind gesetzt. Die Eingaben kommen aus der Standard-Action-Map von Godot (`primary` = Stick oder Trackpad).

## APK für die Brille (HTC Vive Focus 3 und Vision)

Einrichtung des Rechners, Export-Presets und was das Setup-Skript installiert: **[docs/INSTALL.md](docs/INSTALL.md)**. Kurz: `tools/setup_android.ps1` ausführen, Server-IP in den Project Settings setzen, Preset `Vive_LBE` exportieren und per `adb` installieren.

Die Brille bekommt ihre Daten im Normalfall vom Server über den Datenkanal (siehe „Situs Core“). Nur für eine einzelne Brille ohne Server kann MATLAB direkt an sie senden (`sim/udp_on_clients`, siehe oben). Die Brille bekommt per DHCP evtl. wechselnde Adressen: im Router eine feste IP reservieren.

## Tests

- **Godot ohne Netzwerk:** prüft Empfänger (Chunks, Warteschlange, Session, ungültige Header, Bit-Packen) und zeichnet jeden Magic zweimal (Neuaufbau und Update).
  ```
  Godot --headless --path godot --script res://selftest.gd
  ```
- **Zusammenspiel:** Godot starten, in MATLAB `udpTest` ausführen und im Overlay "Magic" und "Ebenen" beobachten.

## Auflösung und Datenrate

Begrenzend ist meist der MATLAB-Sender: Ein `write()` kostet etwa 10 ms je Datagramm von bis zu 65 kB. Große Datagramme werden im WLAN in ~1500-Byte-Fragmente zerlegt, geht eines verloren, ist das ganze Datagramm weg. Bei vielen "Verworfen" im Overlay `datagramSize` senken, das Gitter verkleinern, die Sendefrequenz senken oder 5-GHz-WLAN bzw. Kabel nutzen. Richtwerte (uint8, 1 Byte/Voxel): 32³ = 32 KB/Frame, 64³ = 256 KB/Frame, 128³ = 2 MB/Frame.

## Netzwerk-Tipps

- **IP des Godot-Rechners:** `ipconfig` (Windows), `ifconfig` (macOS), `ip a` (Linux). Beide Rechner im selben Subnetz. "AP/Client-Isolation" im Router ausschalten. Test: `ping <Godot-IP>`.
- **Firewall (Server-PC):** eingehend UDP 7777 (Brillen verbinden sich per ENet) und, wenn MATLAB auf einem anderen Rechner läuft, UDP 4242 freigeben, in einer Admin-PowerShell:
  ```powershell
  New-NetFirewallRule -DisplayName "Situs ENet 7777" -Direction Inbound -Protocol UDP -LocalPort 7777 -Action Allow
  New-NetFirewallRule -DisplayName "Godot UDP 4242" -Direction Inbound -Protocol UDP -LocalPort 4242 -Action Allow
  ```
- **Nur ein Programm pro Port:** `udpListen` (MATLAB) und der Godot-Betrachter können nicht gleichzeitig auf Port 4242 hören.
- **Empfangspuffer:** In Godot 4 MB (`recv_buffer_size`).

## Projektstand und Ausblick

Das Godot-Projekt läuft mit Godot 4.7 und dem GL-Compatibility-Renderer (am PC und auf der Brille) und nutzt Situs Core als Host. Die Shader sind auf der Vive Focus Vision im Standalone-Betrieb getestet. Der Betrieb mit Server und Brillen läuft im Netzwerk: MATLAB sendet an den Server-PC, der Server verteilt die Frames per Datenkanal, und eine Brille sieht die Daten und die zweite Brille. Offen sind Messungen mit 4 und 8 Brillen, die Rotationsrichtung und die Leistung des Raymarchings (siehe TODO-Liste in [docs/plan.md](docs/plan.md)). Texturen werden als `R8` (uint8) verwendet. Die Architektur für Server und Brillen steht in [docs/plan.md](docs/plan.md).
