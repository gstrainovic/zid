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
