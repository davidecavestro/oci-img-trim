# oci-img-trim

![Test](https://github.com/davidecavestro/oci-img-trim/workflows/Test/badge.svg)
![Build](https://github.com/davidecavestro/oci-img-trim/workflows/Build%20and%20Publish/badge.svg)
![License](https://img.shields.io/badge/license-MIT-blue.svg)

`oci-img-trim` is an interactive CLI tool that lets you selectively remove layers from an OCI container image. It lists the image's layers with their digest, size, and build history, lets you pick which ones to remove, then asks whether to overwrite the original tag or push to a new one.

Under the hood it uses [regctl](https://github.com/regclient/regclient) (`regctl image mod --layer-rm-index`).

> **Warning**: removing an intermediate layer does not replay the layers above it — any files that were added by the removed layer and then modified or deleted by later layers may leave the filesystem in an inconsistent state. Use this tool on layers you fully understand.

## Usage

```bash
./docker-run-trim.sh <image> [--platform <platform>]
```

Or build and run directly:

```bash
docker build -t oci-img-trim .
docker run -it --rm \
  -v $HOME/.docker/config.json:/root/.docker/config.json:ro \
  oci-img-trim myregistry.io/myrepo:tag
```

Add `--platform linux/amd64` (or any OCI platform string) to target a specific platform of a multi-platform image.

## Interactive flow

1. The tool fetches the image manifest and config, then displays all layers with their index, digest, size, and the build command from history.
2. **If `fzf` is available** (it is inside the container): use TAB to toggle individual layers, CTRL-A to select all, CTRL-D to deselect all, ENTER to confirm.
3. **Fallback**: type space- or comma-separated layer numbers to toggle them; press ENTER with no input to confirm.
4. Choose whether to **overwrite** the original tag or **push to a new tag**.
5. Confirm and the tool removes the selected layers in the correct order and pushes the result.

## How it works

Layers are removed in **descending index order** so that earlier indices stay stable across iterations. Intermediate results are kept in a local OCI layout (`/tmp`) to avoid unnecessary registry round-trips; only the final image is pushed to the registry.

## Authentication

Mount your Docker credential store into the container:

```bash
-v $HOME/.docker/config.json:/root/.docker/config.json:ro
```

For credential helpers (e.g. `docker-credential-ecr-login`) you may need to mount the helper binary and `$HOME/.docker/` directory as well.

## Examples

Remove one or more layers from a private image, pushing to a new tag:

```bash
./docker-run-trim.sh myregistry.io/myapp:v1.2.3
# interactive selection...
# > Push to a different tag: myregistry.io/myapp:v1.2.3-slim
```

Target a specific platform of a multi-arch image:

```bash
./docker-run-trim.sh myregistry.io/myapp:latest --platform linux/arm64
```
