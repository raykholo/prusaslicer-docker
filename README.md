# prusaslicer-docker

Headless [PrusaSlicer](https://github.com/prusa3d/PrusaSlicer), source-built
from upstream tags, packaged as a slim Docker image.

```bash
docker pull ghcr.io/raykholo/prusaslicer:latest
docker run --rm -v "$PWD:/work" ghcr.io/raykholo/prusaslicer:latest \
  prusa-slicer --slice --load /work/printer.ini --load /work/print.ini \
               --load /work/filament.ini -o /work/out.gcode /work/input.stl
```

## Why this exists

Prusa stopped publishing Linux AppImages on GitHub Releases after
**PrusaSlicer 2.8.1** (Sep 2024). The 2.9.x line ships Linux only via
Flathub — which is the wrong tool inside a container (sandbox / D-Bus
complications, large overhead, x86 emulation issues). There is no
upstream Docker image for headless Linux use.

This repository fills that gap: a multi-stage Dockerfile that clones
PrusaSlicer at a pinned upstream tag, follows
[upstream's Linux build doc](https://github.com/prusa3d/PrusaSlicer/blob/master/doc/How%20to%20build%20-%20Linux%20et%20al.md)
to compile both the bundled deps (Boost, CGAL, OpenVDB, OCCT, TBB, …)
and the slicer itself, and emits a slim runtime image with just the
`prusa-slicer` binary, its `resources/` tree, and the runtime libs it
needs.

## Tags

Two variants, four tags:

| Tag | Variant | Means |
|---|---|---|
| `latest` | **headless** | most recent upstream stable, CLI-only build (`SLIC3R_GUI=no`); slim runtime |
| `version_X.Y.Z` | **headless** | mirrors the upstream PrusaSlicer git tag exactly (immutable) |
| `gui-latest` | **GUI** | same upstream tag as `latest`, but built with `SLIC3R_GUI=1` and packaged with Xvfb + x11vnc + noVNC + fluxbox WM + supervisord; reach PrusaSlicer in a browser at port 8080 |
| `gui-version_X.Y.Z` | **GUI** | per-version pin of the GUI variant (immutable) |

`latest` / `gui-latest` are moving pointers (auto-updated by the daily
scheduled GHA when a new upstream release lands). Per-version tags never
change once published.

## Usage

### CLI invocation

The binary is on PATH inside the image:

```bash
docker run --rm -v "$PWD:/work" ghcr.io/raykholo/prusaslicer:latest \
  prusa-slicer --slice \
               --load /work/printer.ini \
               --load /work/print.ini \
               --load /work/filament.ini \
               --output /work/out.gcode \
               /work/input.stl
```

Same `--slice` / `--load` / `--output` CLI as desktop PrusaSlicer — the
build flag set is `SLIC3R_GUI=no` so only the headless code path is
present.

### As a base image

```dockerfile
FROM ghcr.io/raykholo/prusaslicer:version_2.9.5

# add your own wrapper, scheduler, API service, etc.
```

The binary lives at `/opt/prusaslicer/bin/prusa-slicer` with a symlink
at `/usr/local/bin/prusa-slicer`. Resources are at
`/opt/prusaslicer/resources/` — **don't move them**; PrusaSlicer
resolves resources via `<binary>/../resources` from
`boost::dll::program_location()` (Linux, non-FHS build), with no env-var
override.

### Running the GUI in a browser (the `:gui-*` tags)

```bash
docker run --rm \
  -p 8080:8080 \
  -v "$PWD/profiles:/root/.config/PrusaSlicer" \
  --shm-size=1gb \
  ghcr.io/raykholo/prusaslicer:gui-latest
```

Then open `http://localhost:8080/vnc.html` — full PrusaSlicer in a
browser tab via noVNC. The container internally runs Xvfb (software X
server, no GPU needed), x11vnc on port 5900, websockify+noVNC on 8080,
fluxbox window manager, all orchestrated by supervisord with
auto-restart.

PrusaSlicer's data dir is at `/root/.config/PrusaSlicer/` — bind-mount
your preset repo there. The `--shm-size=1gb` flag matters: the default
64 MB shm is too small for wx/Gtk in some configurations and causes
silent crashes.

### Inspecting build provenance

Every image records the exact upstream commit it was built from:

```bash
docker run --rm ghcr.io/raykholo/prusaslicer:latest cat /opt/prusaslicer/SOURCE
```

```
This image bundles PrusaSlicer.

License:       GNU Affero General Public License v3 (see ./LICENSE).
Upstream:      https://github.com/prusa3d/PrusaSlicer
Built from:    tag version_2.9.5, commit 9a583bd438b195856f3bcf7ea99b69ba4003a961
Source code:   https://github.com/prusa3d/PrusaSlicer/tree/9a583bd438b195856f3bcf7ea99b69ba4003a961
...
```

## How it's built

| Stage | What | Roughly |
|---|---|---|
| Builder | `ubuntu:24.04` + apt deps from upstream's build doc | ~50 MB image overhead |
| Stage A — bundled deps | `cmake .. -DDEP_WX_GTK3=ON && make` in `deps/build/` (Boost, OCCT, OpenVDB, CGAL, MPFR, …) | ~30-60 min cold on 4-core |
| Stage B — slicer | `cmake .. -DSLIC3R_STATIC=1 -DSLIC3R_GTK=3 -DSLIC3R_GUI=no -DSLIC3R_PCH=OFF && make PrusaSlicer` | ~10-20 min |
| Runtime | `python:3.12-slim` + minimal libs + binary + resources + LICENSE/SOURCE | final image ~650 MB |

CI uses BuildKit's GitHub Actions cache backend, so subsequent builds
with the same `PRUSASLICER_REF` finish in a couple minutes (the deps
layer is cached).

## Rebuild policy

The `.github/workflows/build.yml` workflow runs on three triggers:

1. **Scheduled** — daily at 04:00 UTC: query GitHub for the current
   upstream `releases/latest`; if newer than what's cached, build and
   publish.
2. **Manual** — `workflow_dispatch` with an optional `tag` input. Use
   this to build a specific older tag, a release-candidate, or to force
   a rebuild.
3. **On push** to `main` affecting `Dockerfile` or the workflow itself —
   rebuilds against the currently-pinned `PRUSASLICER_REF` default.

## TODO / future improvements

- **Apply BuildKit cache mounts to the headless `Dockerfile`.** The
  `:gui` variant's Dockerfile already has them
  (`RUN --mount=type=cache,id=prusa-deps,target=/src/deps/build`, same
  for the slicer build dir). They make rebuilds after apt/Dockerfile
  tweaks complete in ~10-15 min instead of ~90 — the cache survives
  RUN-command-text changes, so cmake/make re-execute but find the
  pre-built `.o` files and only relink. The headless Dockerfile would
  benefit identically. Not done yet because adding them now would burn
  a needless ~90-min cold rebuild just to install the cache
  infrastructure on a Dockerfile that already works. Apply next time
  there's a real reason to edit the headless `Dockerfile`. Same
  `mkdir -p /out && cp /src/build/src/prusa-slicer /out/prusa-slicer`
  + runtime-stage `COPY --from=builder /out/prusa-slicer ...`
  pattern.
- **Multi-arch builds (`linux/arm64`).** Would let the image run
  natively on Apple Silicon, Raspberry Pi 5, etc. Cost: GitHub-hosted
  arm64 runners are still preview / paid for private repos; QEMU
  emulation works but is dog slow for a source build of this size.
  Revisit if there's demand.

## License

This repository — the `Dockerfile`, the GitHub Actions workflow,
the `README.md`, and supporting files — is **MIT** (see [`LICENSE`](LICENSE)).

The **Docker images this repository produces** bundle PrusaSlicer,
which is **GNU AGPLv3** (see
[`prusa3d/PrusaSlicer/LICENSE`](https://github.com/prusa3d/PrusaSlicer/blob/master/LICENSE)).
Distribution of those images is therefore subject to AGPLv3 §§ 5–6 (preserve
the license notice; convey the corresponding source).

For every image we produce, the corresponding source is `prusa3d/PrusaSlicer`
at the exact commit recorded inside the image at `/opt/prusaslicer/SOURCE`.
The verbatim AGPLv3 license text is shipped at `/opt/prusaslicer/LICENSE`.

We are **not affiliated with Prusa Research**. This is an independent
packaging effort.
