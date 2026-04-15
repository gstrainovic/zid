

● Ja, deutlich weniger — weil schon fertig im Repo.



&#x20; Aufwand-Reihenfolge (klein → groß):



&#x20; ┌──────────────────────┬────────────────────────────────┬───────────────────────────────────────────────────────────────────────────────────────┐

&#x20; │        Option        │             Status             │                                      Restaufwand                                      │

&#x20; ├──────────────────────┼────────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────────┤

&#x20; │ cairo.zig (existing) │ Schon im Repo, läuft für Icons │ \~30 Min: .svg in file\_types + SVG-Zweig in image\_renderer + viewBox-Parse             │

&#x20; ├──────────────────────┼────────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────────┤

&#x20; │ nanosvg              │ Neu integrieren                │ \~halber Tag: C-Source einbinden, @cImport, build.zig anpassen, RGBA-Output verdrahten │

&#x20; ├──────────────────────┼────────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────────┤

&#x20; │ resvg                │ Neu integrieren                │ \~2–3 Tage: Rust-Toolchain in Build, cargo für static-lib, C-FFI, Binary-Zuwachs       │

&#x20; └──────────────────────┴────────────────────────────────┴───────────────────────────────────────────────────────────────────────────────────────┘



&#x20; Warum cairo.zig so billig:

&#x20; - Code steht schon (src/svg/)

&#x20; - Parser kann SVG-Elements (nicht nur path\_data)

&#x20; - Clay-Integration via SvgRenderInfo existiert bereits

&#x20; - Wird aktiv für Lucide-Icons genutzt → getestet

&#x20; - Einziges "Neue": createTextureFromPath muss SVG-Zweig bekommen + Alpha-Mask → RGBA-Tint



&#x20; Trade-off bleibt:

&#x20; - cairo.zig: monochrom (Alpha-Mask)

&#x20; - nanosvg: farbig, Gradients, kein Text

&#x20; - resvg: volle Qualität



&#x20; Für "Dev-Preview, Full-View im Browser" → cairo.zig klarer Winner. Minimaler Aufwand, existierende Infrastruktur, Use-Case passt.

