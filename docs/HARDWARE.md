# Tested hardware

The monitors, connections and Macs Candela has been used on, one row per
monitor and connection. Rows come from
[hardware reports](https://github.com/Rydersel/Candela/issues/new?template=hardware_report.yml)
and from the maintainers' own displays; the columns match what the report form
asks for, so a report becomes a row without translation.

Every row is self-reported: the person who filed it observed the behaviour on
their own panel. Maintainers do not re-verify rows they cannot reproduce. If
your monitor is here and behaves differently for you, that difference is
exactly what a report is for.

The capability columns say what actually changed the display, not what the
spec sheet promises. `yes` means the control worked, `no` means it did
nothing, `n/a` means the monitor declares that it has no such control, and
`not tried` means nobody has checked yet. **DDC reads** is the "Reading values
back" line on the display's Diagnostics page: a monitor that answers reads
lets Candela confirm what it set, and one that does not is driven blind, with
Candela remembering the last value it wrote.

| Monitor | Panel | Connection | Mac | macOS | Candela | Brightness | Volume | Contrast | HDR toggle | DDC reads |
|---|---|---|---|---|---|---|---|---|---|---|
| MSI MAG 341CQP QD-OLED (reports as "MAG 341C OLED") | 34 inch QD-OLED, 3440 x 1440, 175 Hz | DisplayPort | MacBook Pro 14 inch (M1 Pro, 2021) | 26.6 | 1.0.0 | yes | yes | yes | yes | no |
| MSI MAG 341CQP QD-OLED (reports as "MAG 341C OLED") | 34 inch QD-OLED, 3440 x 1440, 175 Hz | USB-C / Thunderbolt, direct | MacBook Pro 14 inch (M1 Pro, 2021) | 26.6 | 1.0.0 | yes | yes | yes | yes | no |
| Dell U2725QE (reports as "DELL U2725QE") | 27 inch IPS Black, 3840 x 2160, 120 Hz | Thunderbolt 5, direct | MacBook Pro 14 inch (M1 Pro, 2021) | 26.6 | 1.0.0 | yes | n/a | yes | not tried | yes |
| LG UltraFine 5K | 5120 x 2880, 60 Hz | Thunderbolt 3, direct | MacBook Pro 14 inch (M1 Pro, 2021) | 26.7 | 1.0.4 | yes | yes (USB audio) | not tried | n/a | yes |
| Kuycon P27U | 27 inch, 4K | USB-C / Thunderbolt, direct | Mac mini (M4) | 26.6.2 | 1.0.3 | yes | yes | yes | not tried | yes |
| Kuycon P32U | 32 inch, 4K | USB-C / Thunderbolt, direct | Mac mini (M4) | 26.6.2 | 1.0.3 | yes | yes | yes | not tried | yes |
