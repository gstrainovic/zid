# Patches

## `bitnet-mad-const-y_col.patch`

Gegen `microsoft/BitNet` @ `01eb415` (`git apply` im BitNet-Arbeitsverzeichnis).

Der AVX2-Zweig von `ggml_vec_dot_i2_i8_s_Nx1` weist einen `const int8_t *` an ein
nicht-konstantes `int8_t *` zu:

```
src/ggml-bitnet-mad.cpp:811:18: error: cannot initialize a variable of type
'int8_t *' (aka 'signed char *') with an rvalue of type 'const int8_t *'
```

Upstream faellt das nicht auf, weil der offizielle Windows-Bauweg
(`setup_env.py` → `cmake -T ClangCL`) ohne `/arch:AVX2` uebersetzt. Damit bleibt
`__AVX2__` undefiniert und der ganze Block ist toter Code. Sobald man mit clang
oder gcc im GNU-Modus baut — also auf jedem Linux und bei jedem MinGW-Build unter
Windows — setzen die ggml-Flags `__AVX2__`, und die Uebersetzung bricht ab.

Die zweite, identisch gebaute Schleife ab Zeile 906 hat das `const` bereits. Der
Patch gleicht die erste nur an; er aendert keine Semantik.

Ob der Patch auf einer bestimmten Maschine ueberhaupt noetig ist, haengt allein
vom Compiler ab, nicht vom Betriebssystem. Wer den offiziellen MSVC-Weg geht,
trifft den Fehler nie.

## Wird die Datei ueberhaupt uebersetzt? Ja.

`results/linux-i7-8850H.md` stellt das in Frage: `src/CMakeLists.txt` setze
`GGML_SOURCES_BITNET` zweimal statt anzuhaengen, das zweite `set` ueberschreibe
das erste, `ggml-bitnet-mad.cpp` lande daher in keinem Build — und dieser Patch
korrigiere folglich eine nie uebersetzte Datei.

Der doppelte `set`-Aufruf ist real. Die Schlussfolgerung stimmt fuer den hier
gepinnten Stand trotzdem nicht: Diese Variable ist gar nicht der Mechanismus,
der die Datei einzieht. `3rdparty/llama.cpp/ggml/src/CMakeLists.txt` listet
beide Quelldateien mit festem Pfad direkt in den `ggml`-Zielen auf:

```cmake
../../../../src/ggml-bitnet-mad.cpp
../../../../src/ggml-bitnet-lut.cpp
```

Nachgeprueft an einem Build mit `-DBITNET_X86_TL2=OFF`
(`01eb415` + llama.cpp `1f86f058`, clang 22.1.7):

```
build/.../ggml.dir/__/__/__/__/src/ggml-bitnet-mad.cpp.obj   9941 Bytes
build/.../ggml.dir/__/__/__/__/src/ggml-bitnet-lut.cpp.obj    646 Bytes
```

Beide erscheinen ausserdem in `compile_commands.json`. Dass `lut.cpp` fast leer
bleibt, passt: sein Inhalt steht komplett hinter `#if defined(GGML_BITNET_X86_TL2)`
und ist mit `OFF` inert. `mad.cpp` traegt dagegen echten Code bei.

Der staerkste Beleg ist der Bauabbruch selbst — der Build ist genau an dieser
Datei gescheitert. Was nicht uebersetzt wird, kann die Uebersetzung nicht
abbrechen.

Die abweichende Beobachtung im Linux-Bericht stammt vermutlich vom Build der
**ungepinnten** Engine (`0b341e5` + llama.cpp `390c3077`), wo ggmls CMake
umgebaut ist. Fuer den gepinnten Referenzstand, auf dem alle Messungen in
`results/` beruhen, gilt sie nicht.
