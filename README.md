# Musicat

Musicat is an open-source, cross-platform music player with built-in Soulseek
search and download, local library management, playlists, and (in later
phases) federated music/playlist sharing between friends.

Targets: Android (primary), Windows, and Linux, from a single Flutter
codebase.

## Status

Early development. See [`docs/architecture.md`](docs/architecture.md) for the
architecture overview and phased roadmap.

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
