# F-Droid: Status und verbindliche offene Abnahmen

> Stand: 18. Oktober 2026. **Vorbereitung ist mergefähig; Veröffentlichung
> ist gesperrt.** Diese Liste ist die einzige operative Restpunkt-Übersicht
> für die erste native F-Droid-Veröffentlichung. Der Merge von PR #66 erzeugt
> weder eine Veröffentlichung noch eine F-Droid-Einreichung.

## Bereits technisch nachgewiesen

- Native Rust-/UniFFI-Erzeugung inklusive `arm64-v8a`, `x86_64` und
  `armeabi-v7a`, mit `de.circle_dev.flux_news` und geprüftem APK-Inhalt.
- Zwei erfolgreiche F-Droid-`fdroidserver`-Rezept-Builds/Lint- und
  Scanner-Durchläufe: [#39140681750](https://github.com/KevinCFechtel/Flux/actions/runs/39140681750)
  und [#39145172707](https://github.com/KevinCFechtel/Flux/actions/runs/39145172707).
  **Nicht** derselbe Commit und daher **kein** Reproduzierbarkeitsbeweis.
- Finaler PR-#66-CI-Zyklus für
  [`c934e1afa`](https://github.com/KevinCFechtel/Flux/commit/c934e1afa8926edb2736a8ca450f392069eb6ef3):
  F-Droid-Rezept, Rust, Android, Apple und Release-Vertrag erfolgreich.
- Native Kandidatenmetadaten können mit exakter Quell-SHA und den
  Android-Versionsdateien vorbereitet werden. Historische Flutter-Builds
  und bisherige `AllowedAPKSigningKeys` werden dabei nicht überschrieben.
- **Keine** aktive Veröffentlichung/automatische F-Droid-Einreichung;
  der F-Droid-Workflow bleibt ein lokaler/CI-Feasibility-Test.

## Offen vor einer offiziellen F-Droid-Einreichung

| ID | Muss erledigt werden | Konkretes Abnahmekriterium |
| --- | --- | --- |
| FD-01 – Rustls-AAR | `rustls-platform-verifier-android` aus **akzeptiertem Quellcode** bauen; vorgefertigtes AAR aus dem Cargo-Paket ersetzen. Zusammen mit **aktuellen stabilen** rustls/JNI-Versionen aktualisieren. | Kein unzulässiges Embedded-AAR; aktueller Kotlin/Rust-Versionsabgleich; Android-TLS-Tests mit System- und Benutzer-CAs bestanden |
| FD-02 – Scanner | Danach `scanignore: android/settings.gradle.kts` entfernen bzw. nur mit offengelegter, aktuell akzeptierter Begründung weiterverwenden. | F-Droid-Scanner besteht ohne unzulässige Quellen-Ausnahme |
| FD-03 – Reproduzierbarkeit | Zwei unabhängige saubere Builds **derselben** Release-Commit-SHA mit demselben dokumentierten Toolchain-Vertrag. | Bitidentisches bzw. im anerkannten F-Droid-Repro-Verfahren eindeutig bestätigtes APK; SHA-256 und Logs dokumentiert |
| FD-04 – Signatur & Upgrade | Bestehende Flutter-F-Droid-Installationen beider überlieferten Signaturpfade identifizieren; native Upgrade-Pfade auf Geräten prüfen. | Update mit gleicher Package-ID, monotonem `versionCode`, passendem Signaturschlüssel und erhaltenen Nutzerdaten für jeden tatsächlich unterstützten Kanal nachgewiesen |
| FD-05 – Repository-Cutover | Nach nativer Übernahme von Flux nach **FluxNews** die alte Flutter-Workflows ersetzen und das endgültige F-Droid-`Repo` auf FluxNews umstellen. Import-Commit ist **kein Release-Commit**. | Historische Flutter-Tags/Builds bleiben erreichbar; neues Rezept baut die **spätere** explizit freigegebene FluxNews-Release-SHA |
| FD-06 – Release-Gate/Publish | Erst nach FD-01 bis FD-05 finale Android-Version, F-Droid-Quellbuild und Release-SHA freigeben. | Die Release-Orchestrierung läuft **nur in FluxNews**; separater autorisierter Publikationsschritt. Kein vorzeitiger Tag, Store-Upload oder automatischer GitLab-MR |

## Abgrenzung zur laufenden Dependency-Aktualisierung

**Jetzt** kann der vorbereitende PR #66 nach grünen Prüfungen nach
`main` übernommen werden. FD-01/02 gehören als **höchstprioritäre
Dependency-/Android-TLS-Aufgaben** in den unmittelbar folgenden
Aktualisierungsstrang, zusammen mit den anderen aktuellen Major-Upgrades.
FD-03/04 sind externe bzw. zeitaufwendige reale Abnahmeprüfungen,
die nicht durch `cargo audit`, `cargo test` oder einen grünen
F-Droid-Rezept-Build ersetzt werden. FD-05/06 folgen erst beim expliziten
FluxNews-Cutover bzw. einer späteren genehmigten Veröffentlichung.

Ressourcen:
[F-Droid-Plan](POST_REPLACEMENT_FOLLOWUP_PLAN.md),
[Release-Architektur](RELEASE_DISTRIBUTION.md),
[Dependency-Policy](DEPENDENCY_MAINTENANCE.md),
[Ruffle rustls-Quellbuild](https://github.com/ruffle-rs/ruffle-android/pull/866).

**Kein Punkt dieser Liste ist ein Grund, die erfolgreiche technische
Vorarbeit in einem dauerhaft offenen F-Droid-Branch zu halten.**
