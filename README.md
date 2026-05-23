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

| Tag | Means |
|---|---|
| `latest` | most recent upstream stable PrusaSlicer release |
| `version_X.Y.Z` | mirrors the upstream PrusaSlicer git tag exactly (e.g. `version_2.9.5`) |

Per-version tags are immutable — once published, the digest behind
`version_2.9.5` never changes. `latest` is a moving pointer.

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
