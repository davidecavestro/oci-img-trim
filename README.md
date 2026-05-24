# oci-img-trim

![Test](https://github.com/davidecavestro/oci-img-trim/workflows/Test/badge.svg)
![Build](https://github.com/davidecavestro/oci-img-trim/workflows/Build%20and%20Publish/badge.svg)
![License](https://img.shields.io/badge/license-MIT-blue.svg)

`oci-img-trim` is an interactive CLI tool that lets you selectively remove or merge layers from an OCI container image. It lists the image's layers with their digest, size, and build history, lets you choose an action, then asks where to send the result — overwrite the original tag, push to a new tag, or load directly into the local Docker daemon.

Under the hood it uses [regctl](https://github.com/regclient/regclient) (`regctl image mod`).

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

To enable the **load into local Docker daemon** option, also mount the Docker socket:

```bash
docker run -it --rm \
  -v $HOME/.docker/config.json:/root/.docker/config.json:ro \
  -v /var/run/docker.sock:/var/run/docker.sock \
  oci-img-trim myregistry.io/myrepo:tag
```

`docker-run-trim.sh` detects `/var/run/docker.sock` automatically and mounts it when present.

Add `--platform linux/amd64` (or any OCI platform string) to target a specific platform of a multi-platform image.

## Interactive flow

1. The tool fetches the image manifest and config, then displays all layers with their index, digest, size, and the build command from history.
2. **Choose an action**: Remove selected layers or Merge/collapse a contiguous range.
3. **Layer selection** depends on the action chosen (see below).
4. Choose a **destination**: overwrite the original tag, push to a new tag, or load into the local Docker daemon (shown only when Docker is available).
5. Confirm and the tool executes the operation.

**If `fzf` is available** (it is inside the container), all menus are browseable lists. Otherwise a numbered fallback is used.

### Remove layers

Select any combination of layers to delete. SPACE or TAB to toggle, CTRL-A/D to select/deselect all, ENTER to confirm.

> Removing an intermediate layer does not replay the layers above it — the result may have an inconsistent filesystem if the removed layer's files were referenced by later layers.

### Merge layers

Pick a **start** layer and then an **end** layer (end must be after start). The tool extracts each layer in the range in order, applying OCI whiteout semantics, and combines them into a single new layer. Layers outside the range are left untouched.

Useful for collapsing a set of incremental changes into a single layer without altering the net filesystem result.

## How it works

**Remove**: layers are deleted in descending index order so earlier indices stay stable across iterations.

**Merge**: the image is copied to a local OCI layout to access raw blobs. Range layers are extracted and composed with correct whiteout handling into a single tar. The original range (and any layers above it) is removed, then the merged layer and post-range layers are re-added in order. All intermediate results stay in a local OCI layout (`/tmp`); only the final image is pushed to the registry.

**Load into local Docker daemon**: instead of pushing to a registry, the result is exported as a Docker-compatible tar and piped into `docker load`, then tagged with the chosen name. Requires the Docker socket to be mounted into the container (done automatically by `docker-run-trim.sh` when `/var/run/docker.sock` exists on the host).

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
