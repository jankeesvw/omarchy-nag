# Nag

Disposable alarms for the Omarchy bar. Type `15:15 pick up the kids` into one field and it is set. The bar counts down to it, turns red in the last five minutes, and then keeps going until you answer it.

It exists because an alarm for quarter past three today is not an appointment. Putting it in a calendar gives it a life it does not deserve: it syncs to your phone, it shows up in next week's agenda view, and you have to go back and delete it. Nag is the other thing, the one a kitchen timer does, with the difference that you can say what it is for.

Named after and inspired by [Pester](https://sabi.net/nriley/software/) by Nicholas Riley, which has done this on the Mac since 2002.

## What you can type

The field takes the time and the message together, and works out where one ends and the other begins.

| You type | You get |
| --- | --- |
| `5m tea` | five minutes from now |
| `90s` | ninety seconds, no message |
| `1h30 call Paul` | an hour and a half from now |
| `15:15 pick up the kids` | quarter past three today, or tomorrow if it has gone |
| `9pm laundry` | tonight |
| `tomorrow 9:00 dentist` | tomorrow morning |
| `wed 18:15 hockey` | the next Wednesday |
| `next monday 8:00 standup` | as it says |
| `2d water the plants` | two days from now |
| `25 dec 9:00 call mum` | a date further out |

A bare number is minutes, so `5` is five minutes, which is what `omarchy reminder` takes too. Durations also accept the spelled-out units (`min`, `hour`, `days`) and `u` for uur.

The line under the field shows what was understood before you commit to it, in the same words the bar will use afterwards. That is the point of it: `wed 18:15 hockey` reading back as "Hockey Wednesday at 18:15" tells you the Wednesday went into the time and not into the message.

## Keys

Everything works without the mouse, and the field keeps the focus the whole time so you can keep typing.

| Key | What it does |
| --- | --- |
| `Enter` | set the alarm |
| `Down` and `Up` | walk into the list of alarms and back out |
| `Enter` on a ringing alarm | snooze it five minutes |
| `Delete` on an alarm | remove it, or dismiss it if it is ringing |
| `Escape` | leave the list, then close the panel |

Typing anything takes the cursor back out of the list, so you never have to think about which mode you are in.

## When it goes off

A critical notification, the freedesktop alarm sound, and the bar widget pulsing red. The alarm keeps ringing in the panel until you dismiss or snooze it, because an alarm that clears itself after a few seconds is one you can miss, and missing it is the whole thing this is meant to prevent. Clicking the notification opens the panel.

## Setting one from anywhere

`nag ask` opens the Omarchy menu's text prompt, so you can set an alarm without the bar widget being open or even visible. Add it to your menu by putting this in `~/.config/omarchy/extensions/omarchy-menu.jsonc`, with the path to where you installed the plugin:

```jsonc
"nag": {
  "icon": "󰔟",
  "label": "Nag",
  "description": "Set a disposable alarm",
  "action": "$HOME/.config/omarchy/plugins/jankeesvw.nag/bin/nag ask"
}
```

Or bind it to a key in `~/.config/hypr/bindings.conf`:

```
bindd = SUPER, N, Set an alarm, exec, $HOME/.config/omarchy/plugins/jankeesvw.nag/bin/nag ask
```

The panel itself opens with `omarchy-shell shell toggle jankeesvw.nag`.

## Install

```sh
omarchy plugin add https://github.com/jankeesvw/omarchy-nag.git --enable
omarchy bar move jankeesvw.nag --section right
```

Update an installed copy with `omarchy plugin update jankeesvw.nag`.

Nothing to configure, no account, no API key. It needs `jq`, `dd`, `date` and `systemd-run`, which Omarchy already has, and it plays the alarm through `pw-play` with a sound from the `sound-theme-freedesktop` package.

## How it works, and why that matters

Alarms are systemd user timers, set with `--on-calendar` against wall-clock time. That is what makes them survive a shell restart, a Quickshell crash and a suspend. It is also the one behavioural difference from the built-in `omarchy reminder`, which uses `--on-active`: those count monotonic seconds, which stop while the machine sleeps, so a reminder set for 15:15 fires late by however long the lid was shut.

Every alarm is written to disk as well, and the plugin re-arms any timer that has gone missing while its time is still ahead. That covers a reboot, which transient systemd units do not survive on their own.

There is no network access of any kind. Nothing is sent anywhere, and nothing is fetched.

## Files it writes

Everything lives under `~/.local/state/nag`, created 0700, with each file 0600:

- `alarms/<id>.json` for each pending alarm, holding its time and its message
- `ringing/<id>.json` for an alarm that has gone off and is waiting to be answered

Your alarm messages are in those files, so treat them as you would any note to yourself.

It also creates one transient systemd user unit per alarm, named `nag-<id>.timer`, and it does not touch your Hyprland configuration, `shell.json`, or any other plugin's files.

## Removing it

```sh
omarchy plugin remove jankeesvw.nag
```

Two things survive that, and both need one command each.

Alarms that have not gone off yet are systemd timers, and they keep running after the plugin directory is gone. Stop them before or after removal, which works either way because it does not need the plugin:

```sh
systemctl --user stop 'nag-*.timer'
```

Your stored alarms and messages stay on disk. Delete them if you want them gone:

```sh
rm -rf ~/.local/state/nag
```

If you added the menu row or the keybinding above, remove those lines by hand as well. The plugin never wrote them.

## Licence

MIT. See [LICENSE](LICENSE).
