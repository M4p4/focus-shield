# Focus Shield

A macOS menubar app that throttles or blocks distracting websites by routing browser traffic through a local HTTPS proxy. Personal-use, no cloud, no sync.

You list sites you want to limit. The app gives you a daily quota for each (say, 30 minutes of YouTube) or blocks them outright. When the quota runs out, the site shows a custom block page instead. There's a "for 5 more minutes" escape button if you really need it.

![Menubar popover showing today's quotas and the protection toggle](docs/screenshots/ui.png)

---

## Requirements

- macOS 13 (Ventura) or later
- For building from source: Xcode Command Line Tools and Go 1.23+

## Install

No distribution yet. Build it from source:

```sh
git clone <repo>
cd focus-shield
make app
open build/FocusShield.app
```

The first launch opens an onboarding window that walks you through installing the local root certificate (one admin prompt). After that the shield icon lives in the menubar.

---

## Using it

### The menubar icon

The shield in the menubar tells you the state at a glance:

- Outline shield: off
- Green filled shield: on, no quota hit yet
- Yellow filled shield: on, at least one site is at its daily quota
- Red: the proxy crashed or system proxy failed

Click the shield to open the popover.

### Turning protection on and off

Flip the switch in the popover. When on, the app starts the local proxy and points your system proxy at it (all network services: Wi-Fi, Ethernet, etc.). When off, the proxy stops and the system proxy is restored. Internal traffic (localhost, RFC1918, `.local`) is always bypassed.

### Adding sites

Open Settings (⌘,) and go to the Sites tab. Each rule has:

- A domain (`youtube.com`, `reddit.com`, etc.)
- A mode: **Off** / **Timed** / **Blocked**
- For Timed: a daily limit in minutes

Subdomains and known CDN hosts roll up automatically. Adding `youtube.com` covers `m.youtube.com`, `googlevideo.com`, `ytimg.com`, `youtu.be`. Same for `x.com` / `twitter.com` and `reddit.com` / `redd.it`.

Save to apply. If the app is running, the change takes effect on the next request, no restart needed.

### How time is counted

Time counts only when both are true:

1. A browser is the frontmost macOS app
2. You've moved the mouse, typed, or scrolled in the last 30 seconds

A YouTube tab open in the background while you write code doesn't burn quota. Neither does walking away from the laptop with the browser still focused. The popover status line tells you which mode the tracker is in ("Active — tracking" or "Active — paused (no browser focus)").

The day resets at local midnight. Usage persists to `usage.json` so a restart mid-day keeps your numbers.

### The block page

When a site is blocked, the proxy serves a calm HTML page in its place. It tells you why (daily limit reached, or always blocked), how long until midnight, and how much time you used.

![Block page shown in the browser when a site is over quota](docs/screenshots/blocked_page.png)

There's a single button: **Unlock for 5 minutes**. It starts disabled with a 10-second countdown. Click after the countdown to grant yourself a temporary bypass. If you've set a password (see below), you also have to type it.

While a bypass is active, the popover shows a yellow "UNLOCKED" row with a live countdown so you don't forget the clock is ticking.

### Password protection

In Settings → Security, you can require a password for:

- Disabling the app from the menubar
- Editing rules in Settings
- Using the "unlock 5 minutes" button on the block page
- Quitting the app

It's stored as an Argon2id hash, never plaintext. If you forget it, the only way out is **Reset everything** from the About tab, which wipes the password along with everything else.

### Launch at login

Settings → General has a switch. First time you enable it, macOS may need approval from you in System Settings → General → Login Items (the app gives you a link).

### Reset everything

About tab → **Reset everything…**. Wipes config, usage, password, removes the trusted certificate from your keychain (admin prompt), disables autostart, clears system proxy. The app stays on disk so you can throw it in the Trash yourself.

---

## Troubleshooting

**Browsers can't load any sites after the app crashed.**
The next launch detects orphaned proxy settings and clears them automatically. If you can't even launch the app, run this in Terminal to clear the system proxy by hand:

```sh
for s in $(networksetup -listallnetworkservices | tail -n +2 | sed 's/^\*//'); do
  networksetup -setwebproxystate "$s" off
  networksetup -setsecurewebproxystate "$s" off
done
```

**A site (bank, Apple service) won't load through the proxy.**
Cert-pinned sites break under HTTPS interception. The app already passes through Apple, iCloud, Microsoft Authenticator, and a handful of major banks. To add more, edit the list in `proxy/passthrough.go` and rebuild. A UI for this is on the wishlist.

**Block page never shows up.**
Make sure the proxy is actually intercepting: System Settings → Network → Wi-Fi → Details → Proxies should show "Web Proxy 127.0.0.1:8888" enabled while the app is on. If not, toggle the app off and on again.

**Reading the logs.**
About tab → "Open logs folder". Or:

```
~/Library/Application Support/FocusShield/logs/proxy.log
```

---

## For devs

### Data files

All under `~/Library/Application Support/FocusShield/`:

- `ca.pem` / `ca.key`: local root CA (generated on first run)
- `config.json`: rules, enabled flag, passwordRequired flag
- `usage.json`: today's elapsed seconds per rule, plus bypass log
- `secrets.json`: Argon2id password hash (mode 0600)
- `proxy.sock`: Unix domain socket for IPC
- `logs/proxy.log`: proxy stdout/stderr

### Testing

`make test` runs the Go unit tests covering the rule matcher, the tracker (idle close, persistence, active-user gating), the bypass manager, password hashing/verify, passthrough matching, and the midnight scheduler.

There are no Swift tests yet. The UI is verified manually.
