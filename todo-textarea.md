# TextArea Feature Spec

## Features
- Multiline Text
- Cursor blinkend
- Einfügen (Insert)
- Kopieren (Copy)
- Ausschneiden (Cut)
- Scrollen mit Mausrad
- Scrollen mit Scrollbar
- Mausklick zur Cursor-Positionierung
- Context Menu (wie terminal und editor)

## Verwendung
- TextArea Tab im Tab-Bar Dropdown (+ Button → "New TextArea")
- Später: Ersatz für ai_chat Input-Zeile

## Architektur
- Neue Komponente: `src/ui/components/textarea.zig`
- Text pro Tab in `TabBarState` (wie terminal_instances)
- Oder globaler `TextAreaState` in `UI`
