# Third-party notices

The Go module file and checksum file pin the dependencies used by this prototype.

- **mautrix/gmessages / libgm** — Tulir Asokan and contributors; GNU Affero General Public License v3. The project imports this protocol library. [Source and licence](https://github.com/mautrix/gmessages).
- **go-sqlite3** — Yasuhiro Matsumoto and contributors; MIT. [Source](https://github.com/mattn/go-sqlite3). Builds use the macOS SQLite library through the `libsqlite3` build tag; FTS5 must be available.
- **zerolog** — Olivier Poitrey and contributors; MIT. [Source](https://github.com/rs/zerolog). Logging for the Google protocol client is disabled in this probe.
- **go.mau.fi/util**, the Go `x/*` modules, Google Protocol Buffers and transitive dependencies retain their own copyright and licence notices in the downloaded modules.
- **OpenMessage** — Max Ghenis and contributors. Its architecture and code were inspected as prior art; this prototype does not import or vendor OpenMessage. [Source](https://github.com/MaxGhenis/openmessage).

This is a development inventory, not a substitute for bundling every required third-party notice and corresponding source with a distributed release. The research checkouts and toolchain live in the ignored `.cache` directory and are not part of the project's source distribution.

