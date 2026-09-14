# SSD-Tune

PowerShell-Skript für Windows, das die Ursachen für das Muster
*„SSD schreibt erst schnell, nach ein paar GB bricht sie ein, System hängt"*
findet und die sicheren Gegenmaßnahmen anwendet.

## Verwendung

PowerShell **als Administrator** öffnen:

```powershell
cd <Ordner mit dem Skript>
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force

# 1) Nur Analyse - verändert nichts
.\SSD-Tune.ps1

# 2) Analyse + sichere Fixes
.\SSD-Tune.ps1 -Apply
```

Weitere Schalter:

| Schalter | Wirkung |
| --- | --- |
| `-BenchGB <n>` | Größe des Schreibtests in GB (Default 10, `0` = überspringen) |
| `-Drive <X>` | Anderes Laufwerk prüfen (Default: Systemlaufwerk) |
| `-DisableSysMain` | Dienst SysMain/Superfetch abschalten (nicht in `-Apply` enthalten) |
| `-DisableSearchIndex` | Windows-Suchindizierung abschalten (nicht in `-Apply` enthalten) |

## Was geprüft wird

1. Laufwerk, Anbindung, Firmware — und ob Windows die SSD überhaupt als SSD führt
2. Freier Speicherplatz (größter Hebel für den SLC-Cache)
3. TRIM-Status und automatischer Optimierungszeitplan
4. Zustand: Temperatur-Throttling, Verschleiß, unkorrigierbare Fehler
5. Firmware-Stand samt passendem Herstellertool
6. Disk-Timeout und SATA Link Power Management
7. SysMain, Windows Search und Auslagerungsdatei als Mitverursacher
8. Over-Provisioning
9. **Schreibkurven-Test** — misst, nach wie vielen GB der SLC-Cache kippt und
   auf welche Dauerrate das Laufwerk danach fällt
10. Hinweise auf das, was nur manuell geht (Schreibcache, BIOS-Modus, Secure Erase)

Am Ende steht eine nach Priorität sortierte Zusammenfassung mit konkreten Befehlen.

## Was `-Apply` verändert

Ausschließlich verlustfreie Einstellungen:

- TRIM aktivieren, falls deaktiviert
- einmaliges ReTrim
- geplante Laufwerksoptimierung aktivieren
- Disk-Timeout auf „nie"
- SATA Link Power Management auf „Aktiv" (nur bei SATA; kostet auf Notebooks
  etwas Akkulaufzeit)

**Nicht** automatisch ausgeführt, weil folgenreich: Partition verkleinern
(Over-Provisioning), Secure Erase, Firmware-Update, Dienste abschalten.
Für diese Punkte gibt das Skript den fertigen Befehl aus.

## Der Schreibtest

Schreibt standardmäßig 10 GB in 256-MB-Schritten mit `FileOptions.WriteThrough`,
damit der RAM-Schreibpuffer die echten Gerätewerte nicht verdeckt, und gibt pro
Schritt die Rate aus. Die Testdatei wird danach gelöscht (auch bei Abbruch mit
Strg+C über einen `finally`-Block). Der Test läuft nur, wenn mindestens
Testgröße + 10 % Reserve frei sind. 10 GB sind für die Lebensdauer unerheblich —
die TBW-Budgets liegen bei hunderten Terabyte.

## Hintergrund

Beim Symptom „Cache voll, System hängt" sind zwei verschiedene Caches beteiligt:

- **SLC-Cache auf der SSD** — TLC/QLC-Zellen werden anfangs als schneller
  Pseudo-SLC beschrieben. Ist der voll, fällt die Rate auf native
  Geschwindigkeit, bei alten oder DRAM-losen Laufwerken auf 40–100 MB/s.
  Der Cache ist dynamisch: eine fast volle SSD hat kaum noch welchen.
- **Schreibpuffer im RAM** — Windows nimmt Daten erst schnell an und schreibt
  verzögert weg. Ist der Puffer voll, blockiert alles, bis die SSD hinterherkommt.
  Das ist der eigentliche Grund für das Einfrieren.

Deshalb wirken freier Platz, TRIM und Over-Provisioning stärker als jede
Registry-Einstellung: Sie vergrößern den SLC-Cache und senken die Write
Amplification.
