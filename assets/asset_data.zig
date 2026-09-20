//! Eingebettete Anwendungsdaten. zid liest sie aus dem Binary, damit ein
//! installiertes zid ohne Datenverzeichnis und aus jedem Arbeitsverzeichnis läuft.

/// Logo der Kopfzeile (PNG).
pub const logo_png = @embedFile("ziglang_logo.png");
