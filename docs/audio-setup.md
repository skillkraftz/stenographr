# Audio setup: fixed names for the two Scarlett 2i2s

`system/wireplumber/51-scarletts.conf` is a WirePlumber 1.x rule file (not part of the Python package). The two
identical Scarlett 2i2s on the dock report the same serial, so WirePlumber told them apart only by a `.2` suffix
that depended on detection order, and after a replug the mic card could end up with no input. The file matches on
the USB product ID instead (the two cards are different models):

| Product ID | Card | Becomes |
|---|---|---|
| 1235:8016 | mic 2i2 (dock port 3.1.1) | device `scarlett-mic`, Pro Audio, input node `scarlett-mic` ("Scarlett mic"), default input via `priority.session` |
| 1235:8202 | main 2i2 (dock port 3.3.1) | device `scarlett-main`, profile HiFi, stays the default output |

Install (user config only, no sudo):

```sh
mkdir -p ~/.config/wireplumber/wireplumber.conf.d
ln -s <path to this checkout>/system/wireplumber/51-scarletts.conf ~/.config/wireplumber/wireplumber.conf.d/
systemctl --user restart wireplumber
```

WirePlumber keys its saved settings (`~/.local/state/wireplumber/`) by device name, so after the rename any
old entries for `alsa_card.usb-Focusrite_Scarlett_2i2_USB-00[.2]` are stale; rename or remove them (and, if
you pick a default by hand, run `wpctl set-default` once). Check with `wpctl status`.

Undo: `rm ~/.config/wireplumber/wireplumber.conf.d/51-scarletts.conf`, then restart wireplumber. The match is the model, not the port, so the cards can move between dock ports;
it stops working if both cards are the same model (`lsusb | grep 1235` shows the IDs).
