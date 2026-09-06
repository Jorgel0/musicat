# Musicat

Musicat is an open-source, cross-platform music player with built-in Soulseek
search and download, local library management, playlists, and **federated
sharing between friends** — your music goes straight from your device to
theirs, with no company in the middle.

Targets: Android (primary), Windows, and Linux, from a single Flutter
codebase.

## Status

Early development, but the social side works end to end: you can create an
account, add a friend by username, and download a track from their device
across different networks.

Read [`docs/architecture.md`](docs/architecture.md) first — it explains the
three moving parts, the trust model, and the two rules that constrain most
design decisions here.

## Running your own server

You do not have to. The app **starts a Musicat Server inside itself**, so a
normal install needs no setup.

Self-hosting is for people who want it: `docker-compose up` runs slskd plus
a standalone Musicat Server — see
[`docs/self-hosting.md`](docs/self-hosting.md). Running your own **relay**
(the piece that lets two nodes behind NAT reach each other, and that hosts
accounts) is also supported; note that accounts are per-relay, so people on
different relays cannot add each other by username.

## Project layout

```
app/     Flutter application (client)
server/  Musicat Server (Fase 3+), the self-hosted backend that wraps slskd
         and later powers federated friend-sharing
docs/    Architecture notes and Architecture Decision Records (ADRs)
```

## License

The app (`app/`) is licensed under the [MIT License](LICENSE).
The server (`server/`) is licensed under [AGPL-3.0](server/LICENSE) to keep
the federated backend open if it is ever offered as a hosted service.

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md).
