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
