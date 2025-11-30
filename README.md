# Mullvad Helper

A compact, privacy‑focused wrapper around the Mullvad VPN CLI.  
The script enforces strong security settings, provides convenient EU connections, and verifies your connection externally every time.

## What It Does
- Ensures **auto-connect** is enabled on every run.
- Ensures **lockdown mode** is active (no traffic leaks if disconnected).
- first‑run **privacy hardening**:
  - Block LAN traffic  
  - Enable in‑tunnel IPv6  
  - Enable Mullvad DNS filtering
  - Enforce WireGuard protocol  
  - Enable DAITA + quantum resistance when available  
- Easy, fast **EU connection**:
  - `eu-connect` → random European country  
  - or force a specific one, e.g. `eu-connect de`
- After connecting, the script automatically:
  - Shows Mullvad status (`mullvad status -v`)
  - Shows outside IP information (`curl ifconfig.io/all`)
  - Verifies Mullvad tunnel status (`https://am.i.mullvad.net/connected`)

## Usage
```
./mullvad-helper.sh eu-connect         # random recommended EU country
./mullvad-helper.sh eu-connect se      # choose specific EU country
./mullvad-helper.sh connect            # connect using current settings
./mullvad-helper.sh status             # see status + external verification
```

## Requirements
- Mullvad VPN installed and CLI available in PATH
- curl installed


