//! Eingebettete Anwendungsdaten. zid liest sie aus dem Binary, damit ein
//! installiertes zid ohne Datenverzeichnis und aus jedem Arbeitsverzeichnis läuft.

/// Logo der Kopfzeile (PNG). Aus packaging/io.github.gstrainovic.zid.svg gerendert,
/// damit Kopfzeile und App-Icon dasselbe Zeichen zeigen.
pub const logo_png = @embedFile("zid_logo.png");
