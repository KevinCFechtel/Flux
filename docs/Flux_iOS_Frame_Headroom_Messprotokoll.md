# Flux iOS Timeline — Messprotokoll Frame-Kopfraum

Zweck: die gemessene Drop-Rate aus `docs/Flux_iOS_Scroll_FrameDrop_Analyse_892eeda.md`
(**5,6 % bei Bewegung, 1 Drop je 281 pt**) in zwei Anteile zerlegen:

1. **Main-Thread-Anteil** — von der App direkt kontrollierbar.
2. **Render-Server-/GPU-Anteil** — enthält den konstanten Aufwand des
   iOS-26-Scroll-Edge-Effekts über der Timeline.

Der Scroll-Edge-Effekt bleibt eine Produktentscheidung und wird nicht geändert.
Er wird hier nur beziffert, damit feststeht, wie viel Kopfraum die übrigen
Maßnahmen liefern müssen.

## Warum zwei Messpunkte nötig sind

`docs/tools/scroll-frame-analysis.swift` misst, **dass** Display-Frames fehlen
— zuverlässig, weil ein pixelidentischer Frame in einer 60-fps-Aufnahme eines
60-Hz-Geräts genau ein verworfener Frame ist. Es kann einen Drop aber nicht
**zuordnen**: ein Frame geht verloren, wenn entweder der Main Thread den Vsync
verpasst oder der Render-Server nicht rechtzeitig komponiert.

`IOSUIKitTimelineFrameHeadroomRecorder`
(`apple/ios/FluxNews/IOSTimelineFrameHeadroomDiagnostic.swift`) schließt diese
Lücke ohne Instruments. Ein `CADisplayLink` feuert einmal je Vsync; sein
`timestamp` gehört zu genau diesem Vsync. Ein Abstand von mehr als einer
Periode zwischen zwei Callbacks bedeutet daher, dass der Main Thread noch
beschäftigt war und der Callback komplett ausgefallen ist. Die Belegung wird
vom Callback bis zur `beforeWaiting`-Aktivität der Run Loop gemessen, mit einem
Observer nach dem Commit-Observer von Core Animation — sie enthält also Layout,
Display und den CATransaction-Commit.

**Auswertungsregel:**

| Video zeigt Drop | Recorder zeigt `skippedVSyncs` | Ursache |
|---|---|---|
| ja | ja | Main Thread — app-seitig behebbar |
| ja | nein | Render-Server/GPU — enthält den Glasanteil |

## Durchführung

Beide Arme in **einer** Sitzung auf demselben Gerät, damit Build, Thermik,
Datenbestand und Wischablauf identisch sind.

1. `bash apple/ios/Build/archive.sh` und über TestFlight oder Xcode auf das
   iPhone 15 installieren. Release ist Pflicht: der Archivpfad setzt
   `SWIFT_COMPILATION_MODE=wholemodule`, und `-O` ist im Build-Log bestätigt.
2. Bildreiches Feed-Scope im **Visuell**-Modus öffnen, einmal vorscrollen und
   zurück, damit Bild- und Layoutcaches warm sind.
3. Settings → Developer Diagnostics → *Timeline Frame Headroom*:
   **Scroll edge effect = System (shipping)**, dann *Reset Frame Headroom*.
4. Bildschirmaufnahme starten. Denselben Wischablauf wie in der
   Referenzmessung ausführen (~45 s, langsame und schnelle Wischer,
   unmittelbare Richtungswechsel).
5. Aufnahme beenden, zurück in Developer Diagnostics, *Refresh Frame Headroom*,
   Werte notieren oder per Screenshot sichern.
6. Schritte 3–5 mit **Scroll edge effect = Disabled** wiederholen.
7. Beide Aufnahmen auswerten:

```bash
swiftc -O docs/tools/scroll-frame-analysis.swift -o /tmp/sfa
/tmp/sfa <aufnahme.MP4>
```

Jeden Arm zusätzlich einmal mit **Mark as read on Scrollover an** und einmal
**aus** aufnehmen. Mit eingeschaltetem Scrollover kommen zwei verschiedene
Kosten gleichzeitig hinzu, die getrennt gehören:

* der Geometrie-Sampler pro Scroll-Callback — **Main-Thread**-Arbeit
  (`ArticleListView.swift:1259` steigt sonst sofort aus);
* die Undo-Pille, die mit `.regularMaterial` über der scrollenden Liste
  schwebt und ihren Hintergrund in jedem Frame neu abtastet — **Render-Server**-
  Arbeit, und nach dem Ergebnis oben die plausiblere Ursache.

Der Schalter *Scrollover Undo pill* trennt beide: Arm **Opaque** entfernt die
Abtastung, lässt den Sampler aber unverändert laufen.

## Ergebnis Arm *System* (iPhone 15, Release-Archiv)

```
budget 16.6 ms/frame
frames 8240      skippedVSyncs 0      unyielded 23
busy avg 2.93 ms   max 26.46 ms
mainThreadOverBudget 0.61 %   skippedVSyncRate 0.00 %
busyMs ≤2.0=2873 ≤4.0=4236 ≤6.0=541 ≤8.0=187 ≤10.0=86 ≤12.0=82 ≤14.0=85 ≤16.7=100 ≤20.0=37 ≤25.0=12 ≤33.0=1
```

**Der Main Thread ist entlastet.** 92,8 % der Scroll-Frames verbrauchen ≤ 6 ms
von 16,6 ms; der Mittelwert von 2,93 ms sind 17,6 % des Budgets. Über 8240
Frames wurde kein einziger Vsync-Callback übersprungen.

Einschränkungen, die zum Ergebnis gehören:

* Die 23 `unyielded`-Proben sind bauartbedingt überhöht: ihr Intervall reicht
  bis zum nächsten Vsync und ist damit per Konstruktion ≥ 16,6 ms. Die echte
  Zahl der budgetüberschreitenden Frames liegt eher bei 27 (0,33 %) als bei 50.
* `skippedVSyncs = 0` neben budgetüberschreitenden Frames ist eine leichte
  Spannung. `CADisplayLink.timestamp` ist der Zeitpunkt des zuletzt
  **dargestellten** Frames, weshalb die Skip-Arithmetik unterzählen kann.
  `skippedVSyncs` ist deshalb als **untere Schranke** zu lesen.

Beide Vorbehalte ändern die Schlussfolgerung nicht: selbst mit der
pessimistischen Lesart (0,61 %) liegt der Main-Thread-Anteil eine
Größenordnung unter der gemessenen Drop-Rate von 5,6 %. **Mindestens rund
neun Zehntel des Defizits liegen beim Render-Server.**

Bemerkenswert ist die Form der Verteilung: eine schmale Masse bei 2–4 ms und
ein flacher Schwanz von **353 Frames (4,3 %) zwischen 8 und 16,7 ms**. Diese
Frames überschreiten das Budget nicht allein, verkürzen dem Render-Server aber
die verbleibende Zeit. Das ist der einzige Ansatzpunkt, an dem Main-Thread-
Arbeit noch etwas bewirkt — nicht der Mittelwert.

## Erfassungsbogen

| Arm | Undo-Pille | Scrollover | Drop-Rate (Video) | skippedVSyncRate | busy avg | mainThreadOverBudget |
|---|---|---|---|---|---|---|
| System | Material | aus | | 0,00 % | 2,93 ms | 0,61 % |
| System | Material | an | | | | |
| System | Opaque | an | | | | |
| Disabled | Material | aus | | | | |
| Disabled | Material | an | | | | |

Bezugswert `892eeda`: 5,6 % verworfene Bewegungsframes, Budget 16,7 ms.
Zielwert unverändert: **< 1 % bei Bewegung.**

Die Video-Drop-Rate fehlt für den obigen Lauf. Ohne sie wird der Recorder gegen
einen Wert aus einem anderen Build verglichen; die Zeile bleibt offen, bis eine
Aufnahme desselben Laufs ausgewertet ist.

## Interpretation

* **`busy avg` deutlich unter 16,7 ms und `skippedVSyncRate` ≈ 0, Video zeigt
  trotzdem ~5 %** → das Defizit liegt beim Render-Server. Weil das Glas bleibt,
  müssen die app-seitigen GPU-Terme sinken: opake Kartenkomposition (P1) statt
  weiterer Main-Thread-Optimierung.
* **`skippedVSyncRate` in der Größenordnung der Video-Drop-Rate** → Main-Thread-
  Arbeit dominiert. Dann zuerst P3 (doppelte Pro-Zellen-Arbeit) und P2
  (manuelles Zell-Layout statt Auto Layout).
* **Differenz System ↔ Disabled** → der Anteil des Scroll-Edge-Effekts. Das ist
  das feste Budget, das die übrigen Maßnahmen ausgleichen müssen.

`ReplayKit` kostet während der Aufnahme selbst CPU und GPU. Das betrifft das
Niveau beider Arme gleichermaßen, nicht ihre Differenz.

## Aufräumen

Alles in `IOSTimelineFrameHeadroomDiagnostic.swift` sowie seine Aufrufe in
`ArticleListView.swift` und `DeveloperDiagnosticsView.swift` sind als
`TEMPORARY PERFORMANCE DIAGNOSTIC — MUST NOT SHIP` markiert und vor Release
zu entfernen — zusammen mit
`IOSUIKitTimelineArticleImageRasterScalePerformanceDiagnostic`, dessen
2x-Experiment abgeschlossen ist.
