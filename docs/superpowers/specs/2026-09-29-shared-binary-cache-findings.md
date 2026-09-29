# Shared binary cache across the three machines — findings

Status: **parked, not implemented.** Recorded so the measurements do not have
to be taken again.

## The question

Can suspense, dance and console share a local binary cache? Prompted by
noticing that a `dlsys rollout` makes dance build the `dlsys` binary itself,
since there is no shared cache.

## What is actually rebuilt (measured on suspense, 2026-09-29)

`nix path-info --all --json`, counting `ultimate == true`:

- **1177 paths, 13.27 GiB** genuinely built on this machine
- 33912 paths / 122 GiB total store

A first pass counted "paths with no cache.nixos.org signature" and got
29559 paths / 79 GiB. **That is wrong** — a missing signature does not mean
locally built. Use `ultimate`, not `signatures`.

Largest locally-built paths:

| Path | Size | Also on dance? |
|---|---|---|
| zoom (2 versions) | 1.7 GiB | yes |
| nvidia-x11 (×4) + cuda12.9-libcublas | 3.3 GiB | no — GPU-specific |
| ollama | 1.27 GiB | no |
| vintagestory (2 versions) | 1.6 GiB | no — gaming |
| spotify (2 versions) | 713 MiB | yes |
| floorp + zen-browser | 685 MiB | yes |
| discord | 557 MiB | yes |

## The actual finding

These are not compiles. They are **unfree binaries cache.nixos.org may not
redistribute**, so every machine fetches and repackages them from the vendor
independently. dance has the `desktop-apps` feature, so it holds its own
separately-downloaded copy of zoom, spotify, discord, floorp and
zen-browser.

So the win is roughly **3 GiB of redundant vendor downloads per machine per
version bump**, replaced by a LAN copy. dance has a *direct* tailscale route
(`10.0.70.79`), i.e. same LAN, so those transfers would be near-instant.

Worth keeping in proportion: **dance rebuilding `dlsys` — the thing that
prompted the question — is the smallest part of this.** That is 13 seconds.
The zoom/spotify/discord churn is the real case.

## Recommended approach if picked up

`services.harmonia` on suspense, serving the existing `/nix/store` over HTTP
to the tailnet. No separate storage, no database. Clients add it as a
substituter plus a `trusted-public-key`.

Rejected alternatives:

- **`ssh-ng://dlangevi@suspense` as a substituter** — needs no service, but
  the nix daemon runs as root, so *root* on each client needs an SSH key
  reaching suspense. Fiddlier than running harmonia.
- **Attic** — real retention and dedup, but overkill for three machines.
  Revisit only if the GC caveat below becomes a problem.

## Three things that will bite

1. **The signing key is credential material.** It must not land in this
   repo. `.gitignore` already guards `*.key` and `secrets/`, and
   `nixos/modules/media-audio.nix` sets the precedent of referencing secrets
   by out-of-band path.
2. **GC evicts the cache.** `nix.gc` in `nixos/common.nix` is `weekly` with
   `--delete-older-than 14d`, and harmonia serves the live store. This is a
   cache, not an archive. Retention independent of GC is the argument for
   Attic.
3. **suspense must be up.** Nix falls back to cache.nixos.org when a
   substituter is unreachable, but clients pay a connection timeout on every
   operation while suspense is off. Tune `connect-timeout`.

Console was offline (last seen 16h) when this was written. It needs no extra
work — include it and it benefits whenever it rejoins.
