# MoE-Modell ganz im RAM gegen Nachladen von der Platte (i7-8850H)

Frage: Wie schnell läuft ein MoE-Modell, das nicht in den RAM passt und per mmap von der NVMe
nachgeladen wird (Ansatz für GLM-5.2 mit 217 GB als 1-Bit-GGUF oder 372 GB int4 mit colibri)?
Und was bringen die 46 GB RAM, wenn das Modell ganz hineinpasst?

```
Engine  llama.cpp b11062 (Commit 3cf03257f), zid-Engine ~/.local/share/zid/engines/b11062, -ngl 0 -t 6
Modell  unsloth/Qwen3-30B-A3B-Instruct-2507-GGUF, Q4_K_M
sha256  6c997b8af17debdfb01d890214400ccbab00db6acc0ba8da5de1cc906c4774d0
size    18556686752
Platte  Toshiba KXG50ZNV512G (XG5), PCIe 3.0 x4
```

## Platte (fio, nur lesend direkt auf /dev/nvme0n1)

| Test | Ergebnis |
|---|---|
| sequentiell 1M, QD32 | 1.99 GB/s (Datenblatt: 3 GB/s) |
| zufällig 64K, QD32 | 1.41 GB/s |
| zufällig 4K, QD1 | 8.3k IOPS (34 MB/s) |

Eine Testdatei auf btrfs liefert trotz `--direct=1` Werte aus dem Seitencache (8.9 GB/s); nur
die Messung am Gerät gilt.

## Modell

| Lauf | tg (tok/s) |
|---|---|
| ganz im RAM (46 GB) | **11.67 ± 1.95** (pp64 13.85) |
| `systemd-run -p MemoryMax=6G -p MemorySwapMax=0`, Cache vorher geleert | **0.39** |

Mit 6 GB von 17.3 GB im Speicher fällt der Durchsatz auf ein Dreissigstel. Das Nachladen per
Seitenfehler erreicht dabei grob 0.5 GB/s, ein Drittel dessen, was die Platte bei 64K-Blöcken
schafft.

## Folgerung für GLM-5.2

Hochrechnung, nicht gemessen: rund 40 Mrd. aktive Parameter bei durchschnittlich ~2.3 Bit
(217 GB / 744 Mrd.) sind ~12 GB pro Token, davon passt nur ein kleiner Teil in den RAM. Bei
~0.5 GB/s Nachladen ergibt das 0.05–0.1 tok/s, für ein Arbeitsmodell unbrauchbar.

Der RAM ist der Vorteil: MoE-Modelle bis gut 40 GB laufen ganz im Speicher. Qwen3-30B-A3B
erreicht auf der CPU 11.7 tok/s, Werkzeugwahl (`bench/agent_eval.py`) nicht gemessen.

## Gegenprobe mit colibri

```
colibri v2.0.0, Commit bf2442915d6e3dd4cdfd2eb9c2a3d2aa44a25850, Engine qwen36, CPU-Build -march=native
Modell  Justvugg/Qwen3-Coder-30B-A3B-colibri-int4 (19.4 GB)
Messung coli serve --model <dir> --cap N, OpenAI-Streaming, 128 Token, temperature 0,
        Seitencache vor Lauf 1 geleert, Läufe 2 und 3 warm
```

| Einstellung | Lauf 1 (kalt) | Lauf 2/3 (warm) | erstes Token warm | RSS |
|---|---|---|---|---|
| `--cap 128` (alle Experten) | 7.49 tok/s | **12.72 / 12.74** | 1.3 s | 14.4 GB |
| `--cap 32` | 2.63 | 2.67 / 2.76 | 9.3 s | 6.2 GB |
| `--cap 32`, `MemoryMax=9G` | 2.59 | 2.64 / 2.70 | 9.6 s | 6.2 GB |

Ganz im RAM ist colibri so schnell wie llama.cpp (Modelle verwandt, nicht identisch). Beim
Nachladen von der Platte liefert es 2.7 tok/s gegen 0.39 von llama.cpp per mmap; die Grenzen
sind nicht gleich (9 GB gegen 6 GB), der Abstand ist trotzdem gross. Das README nennt für
`--cap 32` 5.1 tok/s auf einem Ryzen 7 PRO 8700GE mit NVMe-RAID. Mit oder ohne Speichergrenze
bleibt `--cap 32` gleich schnell, der Seitencache hilft colibri also nicht.

### Mit der Quadro P1000 (Vulkan)

colibri mit `make qwen36 VK=1` und `COLI_VULKAN=1`; llama.cpp b11062 mit `-dev Vulkan1 -ngl 99`,
die Experten von `-ncmoe` Schichten auf der CPU, `llama-bench -p 64 -n 64 -r 2`.

| Einstellung | Decode (warm) |
|---|---|
| llama.cpp, nur CPU | 11.67 tok/s |
| llama.cpp, `-ncmoe 48` (alle Experten auf der CPU) | 14.61 |
| llama.cpp, `-ncmoe 44` | 14.70 |
| llama.cpp, `-ncmoe 40` | **15.21** |
| colibri `--cap 128`, nur CPU | 12.74 |
| colibri `--cap 128`, Vulkan (Dense-Kette an, Standard) | 12.78 (GPU ausgefallen) |
| colibri `--cap 128`, Vulkan, `COLI_VK_CHAIN=0` | 9.99 (41 % der Experten auf der GPU) |

Mit der Dense-Kette verliert colibri die Karte beim ersten Prompt: `[VK] chain: fence wait
failed (-4): the device is lost`, im Kernel `NVRM: Xid 13, Graphics Exception:
SKEDCHECK18_L1_CONFIG_TOO_SMALL` (ein Shader verlangt mehr gemeinsamen Speicher, als Pascal
hergibt). colibri rechnet danach auf der CPU weiter. Ohne Kette läuft die GPU, ist aber langsamer
als die CPU allein. Auf dieser Maschine ist llama.cpp mit P1000 der schnellste Weg.

**`--cap` gehört hinter den Unterbefehl** (`coli serve --cap 128`). Als `coli --cap 128 serve`
wird es ohne Meldung ignoriert, die Engine startet mit `cache=8/layer` (Kopfzeile im Log) und
liefert 1.3 tok/s bei 3 GB RSS.

**`coli tune` scheitert bei Qwen3-Coder** mit «engine reported no decode speed»: Die
tune-Vorlage der Qwen3.6-Familie endet auf `<think>\n`, Qwen3-Coder denkt nicht und gibt sofort
das Ende aus. Ohne `<think>` in `tune_prompt_template` (`c/family_registry.py`) läuft es; einzig
geprüfter Kandidat war `omp-3`, die Grundeinstellung blieb (kein Gewinn über 3 %).
