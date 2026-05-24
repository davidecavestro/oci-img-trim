#!/bin/bash
set -euo pipefail

IMAGE=""
PLATFORM="local"

usage() {
    echo "Usage: docker run -it ... <image> [options]"
    echo ""
    echo "Arguments:"
    echo "  <image>                  Container image reference (e.g. registry/repo:tag)"
    echo ""
    echo "Options:"
    echo "  --platform <platform>    Platform to inspect/modify (default: local)"
    echo "  -h, --help               Show this help message"
    echo ""
    echo "Examples:"
    echo "  docker run -it --rm -v \$HOME/.docker/config.json:/root/.docker/config.json:ro \\"
    echo "    ghcr.io/davidecavestro/oci-img-trim:latest myregistry.io/myrepo:tag"
    echo ""
    echo "  docker run -it --rm -v \$HOME/.docker/config.json:/root/.docker/config.json:ro \\"
    echo "    ghcr.io/davidecavestro/oci-img-trim:latest myregistry.io/myrepo:tag --platform linux/amd64"
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        --platform)
            PLATFORM="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        -*)
            echo "Unknown option: $1"
            usage
            ;;
        *)
            if [ -z "$IMAGE" ]; then
                IMAGE="$1"
            else
                echo "Unexpected argument: $1"
                usage
            fi
            shift
            ;;
    esac
done

if [ -z "$IMAGE" ]; then
    echo "Error: image argument is required."
    echo ""
    usage
fi

# --- Helpers ---

human_size() {
    local bytes=$1
    if [ "$bytes" -ge 1073741824 ]; then
        printf "%.1fG" "$(echo "scale=1; $bytes/1073741824" | bc)"
    elif [ "$bytes" -ge 1048576 ]; then
        printf "%.1fM" "$(echo "scale=1; $bytes/1048576" | bc)"
    elif [ "$bytes" -ge 1024 ]; then
        printf "%.1fK" "$(echo "scale=1; $bytes/1024" | bc)"
    else
        printf "%sB" "$bytes"
    fi
}

# Decompress a layer blob into a directory, detecting compression from the mediaType.
extract_blob_to_dir() {
    local blob="$1" mediatype="$2" dest="$3"
    case "$mediatype" in
        *gzip*)  tar -xzf "$blob" -C "$dest" 2>/dev/null || true ;;
        *zstd*)  tar -I zstd -xf "$blob" -C "$dest" 2>/dev/null || true ;;
        *)       tar -xf  "$blob" -C "$dest" 2>/dev/null || true ;;
    esac
}

# Apply a single already-extracted OCI layer onto merge_dir, respecting whiteout semantics.
apply_layer() {
    local layer_tmp="$1" merge_dir="$2"
    local rel_dir base

    # Opaque whiteouts (.wh..wh..opq): clear the corresponding directory in merge_dir
    # before the layer's own content lands there, so lower-layer files disappear.
    while IFS= read -r -d '' opq; do
        rel_dir=$(dirname "${opq#${layer_tmp}/}")
        if [ "$rel_dir" = "." ]; then
            find "${merge_dir}" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
        else
            rm -rf "${merge_dir:?}/${rel_dir}"
            mkdir -p "${merge_dir}/${rel_dir}"
        fi
    done < <(find "$layer_tmp" -name '.wh..wh..opq' -print0)

    # Regular whiteouts (.wh.<name>): delete the named target from merge_dir.
    while IFS= read -r -d '' wh; do
        rel_dir=$(dirname "${wh#${layer_tmp}/}")
        base=$(basename "$wh")
        rm -rf "${merge_dir:?}/${rel_dir}/${base#.wh.}"
    done < <(find "$layer_tmp" -name '.wh.*' ! -name '.wh..wh..opq' -print0)

    # Remove processed whiteout files from layer_tmp, then copy remaining content.
    find "$layer_tmp" -name '.wh.*' -delete
    tar -cf - -C "$layer_tmp" . | tar -xf - -C "$merge_dir"
}

# Decompress a layer blob to an uncompressed tar file (required by --layer-add tar=).
decompress_blob_to_tar() {
    local blob="$1" mediatype="$2" output="$3"
    case "$mediatype" in
        *gzip*)  zcat "$blob" > "$output" ;;
        *zstd*)  zstd -d -q -o "$output" "$blob" ;;
        *)       cp   "$blob"    "$output" ;;
    esac
}

# --- Fetch image metadata ---

echo "Fetching manifest for $IMAGE (platform: $PLATFORM)..."

TOP_MANIFEST=$(regctl manifest get --format raw-body "$IMAGE" 2>/dev/null)

IS_MULTIPLATFORM=false
if echo "$TOP_MANIFEST" | jq -e '.manifests' >/dev/null 2>&1 && ! echo "$TOP_MANIFEST" | jq -e '.layers' >/dev/null 2>&1; then
    IS_MULTIPLATFORM=true
    echo "  Info: this is a multi-platform manifest list; showing platform '$PLATFORM'."
    echo "  Changes will be applied to the selected platform only."
    MANIFEST=$(regctl manifest get --platform "$PLATFORM" --format raw-body "$IMAGE" 2>/dev/null)
else
    MANIFEST="$TOP_MANIFEST"
fi

mapfile -t LAYER_DIGESTS < <(echo "$MANIFEST" | jq -r '.layers[].digest')
mapfile -t LAYER_SIZES   < <(echo "$MANIFEST" | jq -r '.layers[].size')

LAYER_COUNT=${#LAYER_DIGESTS[@]}

if [ "$LAYER_COUNT" -eq 0 ]; then
    echo "No layers found in image."
    exit 1
fi

mapfile -t HISTORY_CMDS < <(
    regctl image config --platform "$PLATFORM" "$IMAGE" 2>/dev/null \
    | jq -r '.history[] | select(.empty_layer != true) | .created_by // "(no history)"'
)

echo ""
echo "Image   : $IMAGE"
echo "Platform: $PLATFORM"
echo "Layers  : $LAYER_COUNT"
echo ""

# --- Build layer display strings ---

declare -a LAYER_DISPLAY
for i in "${!LAYER_DIGESTS[@]}"; do
    digest="${LAYER_DIGESTS[$i]}"
    short_digest="${digest:7:12}"
    size=$(human_size "${LAYER_SIZES[$i]}")
    cmd="${HISTORY_CMDS[$i]:-}"
    if [ ${#cmd} -gt 70 ]; then
        cmd="${cmd:0:67}..."
    fi
    LAYER_DISPLAY[$i]=$(printf "[%2d] sha256:%-12s  %7s  %s" "$((i+1))" "$short_digest" "$size" "$cmd")
done

# --- Interactive session ---
#
# fzf path: full back-navigation via nested loops.
#   ESC at any picker breaks to the enclosing loop, replaying the parent picker.
#   Empty new-tag input (continue) replays the destination picker.
#   "N" at confirm exits the script.
#
# Fallback path: linear, no back-navigation.

OPT_REMOVE="Remove selected layers"
OPT_MERGE="Merge/collapse contiguous layers"
OPT_OVERWRITE="Overwrite original  ($IMAGE)"
OPT_NEW_TAG="Push to a new tag"
OPT_LOAD="Load into local Docker daemon"

DOCKER_AVAILABLE=false
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    DOCKER_AVAILABLE=true
fi

ACTION=""
DEST_IMAGE=""
DEST_MODE="push"
SELECTED_SORTED_ASC=()
SELECTED_SORTED_DESC=()
MERGE_START_IDX=-1
MERGE_END_IDX=-1

_confirm_and_proceed() {
    # Print summary, ask for confirmation. Exits on "N"; returns 0 on "y".
    echo ""
    echo "Summary:"
    echo "  Source      : $IMAGE"
    if [ "$DEST_MODE" = "load" ]; then
        echo "  Destination : local Docker daemon ($DEST_IMAGE)"
    else
        echo "  Destination : $DEST_IMAGE"
    fi
    if [ "$ACTION" = "remove" ]; then
        echo "  Action      : Remove ${#SELECTED_SORTED_ASC[@]} layer(s) at indices: ${SELECTED_SORTED_ASC[*]}"
    else
        echo "  Action      : Merge layers $((MERGE_START_IDX+1))-$((MERGE_END_IDX+1)) into one"
    fi
    echo ""
    read -r -p "Proceed? [y/N]: " _confirm
    if [[ "${_confirm,,}" != "y" ]]; then echo "Aborted."; exit 0; fi
}

_pick_destination_fzf() {
    # Sets DEST_IMAGE and DEST_MODE. Returns 1 if the user pressed ESC (caller should break).
    while true; do
        local _dest_choice _fzf_input
        if [ "$DOCKER_AVAILABLE" = true ]; then
            _fzf_input=$(printf '%s\n' "$OPT_OVERWRITE" "$OPT_NEW_TAG" "$OPT_LOAD")
        else
            _fzf_input=$(printf '%s\n' "$OPT_OVERWRITE" "$OPT_NEW_TAG")
        fi
        _dest_choice=$(printf '%s' "$_fzf_input" | fzf \
            --no-multi \
            --header="ENTER=confirm  ESC=back" \
            --prompt="Destination > " \
            --height=30% \
            --reverse \
        2>/dev/tty) || true

        if [ -z "$_dest_choice" ]; then
            return 1   # ESC → caller breaks to the layer-selection loop
        fi

        if [ "$_dest_choice" = "$OPT_OVERWRITE" ]; then
            DEST_IMAGE="$IMAGE"
            DEST_MODE="push"
            return 0
        elif [ "$_dest_choice" = "$OPT_LOAD" ]; then
            local _local_tag
            read -r -p "Local image name:tag [ENTER for '$IMAGE']: " _local_tag
            DEST_IMAGE="${_local_tag:-$IMAGE}"
            DEST_MODE="load"
            return 0
        else
            read -r -p "Destination image reference (empty=back): " DEST_IMAGE
            if [ -n "$DEST_IMAGE" ]; then
                DEST_MODE="push"
                return 0
            fi
            # empty input → loop and re-show destination fzf
        fi
    done
}

if command -v fzf >/dev/null 2>&1; then

    # Build the fzf layer list input once; it doesn't change.
    FZF_LAYERS=""
    for i in "${!LAYER_DISPLAY[@]}"; do
        FZF_LAYERS+="${LAYER_DISPLAY[$i]}"$'\n'
    done

    _READY=false

    while [ "$_READY" = false ]; do   # ── action loop (ESC exits)

        echo "Choose an action:"
        echo ""
        ACTION_CHOICE=$(printf '%s\n' "$OPT_REMOVE" "$OPT_MERGE" | fzf \
            --no-multi \
            --header="ENTER=confirm  ESC=exit" \
            --prompt="Action > " \
            --height=25% \
            --reverse \
        2>/dev/tty) || true

        if [ -z "$ACTION_CHOICE" ]; then
            echo "Exiting."
            exit 0
        fi
        [ "$ACTION_CHOICE" = "$OPT_REMOVE" ] && ACTION="remove" || ACTION="merge"

        # ── remove path ──────────────────────────────────────────────────────
        if [ "$ACTION" = "remove" ]; then

            while [ "$_READY" = false ]; do   # ── layer-select loop (ESC → action)

                echo ""
                echo "Select layers to remove:"
                echo ""
                SELECTED_LINES=$(printf '%s' "$FZF_LAYERS" | fzf \
                    --multi \
                    --header="SPACE/TAB=toggle  CTRL-A=select all  CTRL-D=deselect all  ENTER=confirm  ESC=back" \
                    --prompt="Remove > " \
                    --height=80% \
                    --reverse \
                    --bind="space:toggle,ctrl-a:select-all,ctrl-d:deselect-all" \
                2>/dev/tty) || true

                if [ -z "$SELECTED_LINES" ]; then
                    break   # ESC → back to action loop
                fi

                SELECTED_INDICES=()
                while IFS= read -r line; do
                    for i in "${!LAYER_DISPLAY[@]}"; do
                        if [ "${LAYER_DISPLAY[$i]}" = "$line" ]; then
                            SELECTED_INDICES+=("$i")
                            break
                        fi
                    done
                done <<< "$SELECTED_LINES"

                mapfile -t SELECTED_SORTED_ASC  < <(printf '%s\n' "${SELECTED_INDICES[@]}" | sort -n)
                mapfile -t SELECTED_SORTED_DESC < <(printf '%s\n' "${SELECTED_INDICES[@]}" | sort -rn)

                echo ""
                echo "Layers selected for removal:"
                for idx in "${SELECTED_SORTED_ASC[@]}"; do
                    echo "  - ${LAYER_DISPLAY[$idx]}"
                done

                echo ""
                echo "Where should the modified image be pushed?"
                echo ""
                if _pick_destination_fzf; then
                    _confirm_and_proceed
                    _READY=true
                fi
                # _pick_destination_fzf returned 1 (ESC) → loop replays layer-select

            done   # ── end layer-select loop

        # ── merge path ───────────────────────────────────────────────────────
        else

            if [ "$LAYER_COUNT" -lt 2 ]; then
                echo "  Need at least 2 layers to merge."
                continue   # replay action loop
            fi

            while [ "$_READY" = false ]; do   # ── start-picker loop (ESC → action)

                echo ""
                echo "Select the FIRST layer of the merge range:"
                echo ""
                START_LINE=$(printf '%s' "$FZF_LAYERS" | fzf \
                    --no-multi \
                    --header="ENTER=confirm  ESC=back" \
                    --prompt="Merge from > " \
                    --height=80% \
                    --reverse \
                2>/dev/tty) || true

                if [ -z "$START_LINE" ]; then
                    break   # ESC → back to action loop
                fi

                MERGE_START_IDX=-1
                for i in "${!LAYER_DISPLAY[@]}"; do
                    if [ "${LAYER_DISPLAY[$i]}" = "$START_LINE" ]; then
                        MERGE_START_IDX=$i
                        break
                    fi
                done

                if [ "$MERGE_START_IDX" -ge $((LAYER_COUNT - 1)) ]; then
                    echo "  Start layer is the last layer; please pick an earlier one."
                    continue   # replay start-picker
                fi

                FZF_END_LAYERS=""
                for i in "${!LAYER_DISPLAY[@]}"; do
                    [ "$i" -gt "$MERGE_START_IDX" ] && FZF_END_LAYERS+="${LAYER_DISPLAY[$i]}"$'\n'
                done

                while [ "$_READY" = false ]; do   # ── end-picker loop (ESC → start-picker)

                    echo ""
                    echo "Select the LAST layer of the merge range:"
                    echo ""
                    END_LINE=$(printf '%s' "$FZF_END_LAYERS" | fzf \
                        --no-multi \
                        --header="ENTER=confirm  ESC=back" \
                        --prompt="Merge to   > " \
                        --height=80% \
                        --reverse \
                    2>/dev/tty) || true

                    if [ -z "$END_LINE" ]; then
                        break   # ESC → back to start-picker loop
                    fi

                    MERGE_END_IDX=-1
                    for i in "${!LAYER_DISPLAY[@]}"; do
                        if [ "${LAYER_DISPLAY[$i]}" = "$END_LINE" ]; then
                            MERGE_END_IDX=$i
                            break
                        fi
                    done

                    echo ""
                    echo "Layers to merge into one:"
                    for i in $(seq "$MERGE_START_IDX" "$MERGE_END_IDX"); do
                        echo "  - ${LAYER_DISPLAY[$i]}"
                    done

                    echo ""
                    echo "Where should the modified image be pushed?"
                    echo ""
                    if _pick_destination_fzf; then
                        _confirm_and_proceed
                        _READY=true
                    fi
                    # _pick_destination_fzf returned 1 (ESC) → loop replays end-picker

                done   # ── end end-picker loop

            done   # ── end start-picker loop

        fi   # end action branch

    done   # ── end action loop

else   # ── fallback: linear, no back-navigation ──────────────────────────────

    echo "Choose an action:"
    echo "  1) $OPT_REMOVE"
    echo "  2) $OPT_MERGE"
    echo ""
    read -r -p "Choice [1/2]: " action_input
    case "$action_input" in
        1) ACTION="remove" ;;
        2) ACTION="merge"  ;;
        *) echo "Invalid choice. Exiting."; exit 1 ;;
    esac

    if [ "$ACTION" = "remove" ]; then

        declare -A SELECTED_MAP

        print_layer_list() {
            echo ""
            for i in "${!LAYER_DISPLAY[@]}"; do
                if [ "${SELECTED_MAP[$i]:-}" = "1" ]; then marker="[x]"; else marker="[ ]"; fi
                echo "  $marker ${LAYER_DISPLAY[$i]}"
            done
            echo ""
        }

        echo ""
        echo "Layers (enter numbers to toggle selection, blank to confirm):"
        print_layer_list

        while true; do
            read -r -p "Toggle layer(s) [e.g. 1 3 or 1,3]: " input
            [ -z "$input" ] && break
            IFS=', ' read -ra NUMS <<< "$input"
            for num in "${NUMS[@]}"; do
                [[ -z "$num" ]] && continue
                if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -ge 1 ] && [ "$num" -le "$LAYER_COUNT" ]; then
                    idx=$((num-1))
                    if [ "${SELECTED_MAP[$idx]:-}" = "1" ]; then unset "SELECTED_MAP[$idx]"
                    else SELECTED_MAP[$idx]="1"; fi
                else
                    echo "  Invalid: $num (must be 1-$LAYER_COUNT)"
                fi
            done
            print_layer_list
        done

        SELECTED_INDICES=()
        for idx in "${!SELECTED_MAP[@]}"; do SELECTED_INDICES+=("$idx"); done

        if [ ${#SELECTED_INDICES[@]} -eq 0 ]; then
            echo "No layers selected. Exiting."
            exit 0
        fi

        mapfile -t SELECTED_SORTED_ASC  < <(printf '%s\n' "${SELECTED_INDICES[@]}" | sort -n)
        mapfile -t SELECTED_SORTED_DESC < <(printf '%s\n' "${SELECTED_INDICES[@]}" | sort -rn)

        echo ""
        echo "Layers selected for removal:"
        for idx in "${SELECTED_SORTED_ASC[@]}"; do echo "  - ${LAYER_DISPLAY[$idx]}"; done
        echo ""

    else   # merge fallback

        if [ "$LAYER_COUNT" -lt 2 ]; then
            echo "Need at least 2 layers to merge. Exiting."
            exit 1
        fi

        echo ""
        echo "Available layers:"
        for i in "${!LAYER_DISPLAY[@]}"; do echo "  ${LAYER_DISPLAY[$i]}"; done
        echo ""

        while true; do
            read -r -p "First layer of merge range [1-$((LAYER_COUNT - 1))]: " start_num
            if [[ "$start_num" =~ ^[0-9]+$ ]] && [ "$start_num" -ge 1 ] && [ "$start_num" -le $((LAYER_COUNT - 1)) ]; then
                MERGE_START_IDX=$((start_num - 1)); break
            fi
            echo "  Invalid: must be 1-$((LAYER_COUNT - 1))"
        done

        while true; do
            read -r -p "Last layer of merge range [$((MERGE_START_IDX + 2))-$LAYER_COUNT]: " end_num
            if [[ "$end_num" =~ ^[0-9]+$ ]] && [ "$end_num" -ge $((MERGE_START_IDX + 2)) ] && [ "$end_num" -le "$LAYER_COUNT" ]; then
                MERGE_END_IDX=$((end_num - 1)); break
            fi
            echo "  Invalid: must be $((MERGE_START_IDX + 2))-$LAYER_COUNT"
        done

        echo ""
        echo "Layers to merge into one:"
        for i in $(seq "$MERGE_START_IDX" "$MERGE_END_IDX"); do echo "  - ${LAYER_DISPLAY[$i]}"; done
        echo ""

    fi

    echo "Where should the modified image be pushed?"
    echo "  1) $OPT_OVERWRITE"
    echo "  2) $OPT_NEW_TAG"
    [ "$DOCKER_AVAILABLE" = true ] && echo "  3) $OPT_LOAD"
    echo ""
    if [ "$DOCKER_AVAILABLE" = true ]; then
        read -r -p "Choice [1/2/3]: " choice
    else
        read -r -p "Choice [1/2]: " choice
    fi
    case "$choice" in
        1) DEST_IMAGE="$IMAGE"; DEST_MODE="push" ;;
        2)
            read -r -p "Destination image reference: " DEST_IMAGE
            if [ -z "$DEST_IMAGE" ]; then echo "No destination provided. Exiting."; exit 1; fi
            DEST_MODE="push"
            ;;
        3)
            if [ "$DOCKER_AVAILABLE" = true ]; then
                read -r -p "Local image name:tag [ENTER for '$IMAGE']: " _local_tag
                DEST_IMAGE="${_local_tag:-$IMAGE}"
                DEST_MODE="load"
            else
                echo "Invalid choice. Exiting."; exit 1
            fi
            ;;
        *) echo "Invalid choice. Exiting."; exit 1 ;;
    esac

    _confirm_and_proceed

fi   # ── end fzf / fallback

# --- Execute ---

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

WORK_OCI="${WORK_DIR}/oci"
mkdir -p "$WORK_OCI"
WORK_REF="ocidir://${WORK_OCI}:result"
CURRENT_SRC="$IMAGE"

echo ""

# regctl image mod has no --platform flag. For multi-platform images we must first
# copy the target platform into the work OCI layout so every subsequent image mod
# operates on a single-platform reference with no platform ambiguity.
if [ "$IS_MULTIPLATFORM" = true ]; then
    echo "  Resolving $PLATFORM platform image..."
    regctl image copy --platform "$PLATFORM" "$IMAGE" "$WORK_REF"
    CURRENT_SRC="$WORK_REF"
fi

if [ "$ACTION" = "remove" ]; then

    # Remove layers in descending index order so earlier indices stay stable across iterations.
    STEP=1
    for idx in "${SELECTED_SORTED_DESC[@]}"; do
        echo "  [${STEP}/${#SELECTED_SORTED_DESC[@]}] Removing layer $((idx+1)) (sha256:${LAYER_DIGESTS[$idx]:7:12})..."
        regctl image mod --layer-rm-index "$idx" "$CURRENT_SRC" --create "$WORK_REF"
        CURRENT_SRC="$WORK_REF"
        STEP=$((STEP+1))
    done

else

    # Merge strategy:
    #  1. Copy image to a local OCI layout to access raw layer blobs without re-downloading.
    #  2. Build a merged filesystem by applying each range layer in order with whiteout semantics.
    #  3. Remove all layers from MERGE_START_IDX onwards (descending keeps indices stable).
    #  4. Add the merged layer tar.
    #  5. Re-add post-range layer tars in original order.

    OCI_SRC="${WORK_DIR}/oci_src"
    mkdir -p "$OCI_SRC"

    echo "  Fetching layer blobs..."
    regctl image copy "$CURRENT_SRC" "ocidir://${OCI_SRC}:src"

    MANIFEST_HASH=$(jq -r '.manifests[0].digest' "${OCI_SRC}/index.json" | sed 's/sha256://')
    mapfile -t OCI_MEDIATYPES < <(jq -r '.layers[].mediaType' "${OCI_SRC}/blobs/sha256/${MANIFEST_HASH}")

    MERGE_RANGE_COUNT=$(( MERGE_END_IDX - MERGE_START_IDX + 1 ))
    echo "  Merging $MERGE_RANGE_COUNT layer(s) into one..."

    MERGE_DIR="${WORK_DIR}/merged_fs"
    mkdir -p "$MERGE_DIR"

    STEP=1
    for i in $(seq "$MERGE_START_IDX" "$MERGE_END_IDX"); do
        echo "  [${STEP}/${MERGE_RANGE_COUNT}] Applying layer $((i+1))..."
        blob="${OCI_SRC}/blobs/sha256/${LAYER_DIGESTS[$i]#sha256:}"
        layer_tmp="${WORK_DIR}/layer_${i}"
        mkdir -p "$layer_tmp"
        extract_blob_to_dir "$blob" "${OCI_MEDIATYPES[$i]}" "$layer_tmp"
        apply_layer "$layer_tmp" "$MERGE_DIR"
        rm -rf "$layer_tmp"
        STEP=$((STEP+1))
    done

    MERGED_TAR="${WORK_DIR}/merged.tar"
    echo "  Packing merged layer..."
    tar -cf "$MERGED_TAR" -C "$MERGE_DIR" .

    # Save post-range layers as uncompressed tars before we remove them from the image.
    POST_TARS=()
    for i in $(seq $((MERGE_END_IDX + 1)) $((LAYER_COUNT - 1))); do
        blob="${OCI_SRC}/blobs/sha256/${LAYER_DIGESTS[$i]#sha256:}"
        post_tar="${WORK_DIR}/post_${i}.tar"
        decompress_blob_to_tar "$blob" "${OCI_MEDIATYPES[$i]}" "$post_tar"
        POST_TARS+=("$post_tar")
    done

    # Remove all layers from MERGE_START_IDX onwards (descending keeps indices stable).
    TOTAL_TO_RM=$(( LAYER_COUNT - MERGE_START_IDX ))
    STEP=1
    for i in $(seq $((LAYER_COUNT - 1)) -1 "$MERGE_START_IDX"); do
        echo "  [${STEP}/${TOTAL_TO_RM}] Removing original layer $((i+1))..."
        regctl image mod --layer-rm-index "$i" "$CURRENT_SRC" --create "$WORK_REF"
        CURRENT_SRC="$WORK_REF"
        STEP=$((STEP+1))
    done

    # Add the merged layer.
    echo "  Adding merged layer..."
    regctl image mod --layer-add "tar=${MERGED_TAR}" "$CURRENT_SRC" --create "$WORK_REF"
    CURRENT_SRC="$WORK_REF"

    # Re-add post-range layers in original order.
    if [ ${#POST_TARS[@]} -gt 0 ]; then
        STEP=1
        for post_tar in "${POST_TARS[@]}"; do
            echo "  [${STEP}/${#POST_TARS[@]}] Re-adding post-range layer..."
            regctl image mod --layer-add "tar=${post_tar}" "$CURRENT_SRC" --create "$WORK_REF"
            CURRENT_SRC="$WORK_REF"
            STEP=$((STEP+1))
        done
    fi

fi

if [ "$DEST_MODE" = "load" ]; then
    LOAD_TAR="${WORK_DIR}/export.tar"
    echo "  Exporting image to tar..."
    regctl image export "$CURRENT_SRC" "$LOAD_TAR"
    echo "  Loading into local Docker daemon..."
    # docker load errors go directly to stderr so they are visible even if the command fails.
    LOAD_OUT=$(docker load -i "$LOAD_TAR")
    echo "$LOAD_OUT"
    # docker load prints "Loaded image: name:tag" or "Loaded image ID: sha256:..."
    LOADED_REF=$(echo "$LOAD_OUT" | sed -n 's/^Loaded image[^:]*: \(.*\)$/\1/p')
    if [ -n "$LOADED_REF" ] && [ "$LOADED_REF" != "$DEST_IMAGE" ]; then
        docker tag "$LOADED_REF" "$DEST_IMAGE"
    fi
else
    echo "  Pushing result to $DEST_IMAGE..."
    regctl image copy "$CURRENT_SRC" "$DEST_IMAGE"
fi

echo ""
if [ "$DEST_MODE" = "load" ]; then
    echo "Done. Modified image loaded into local Docker daemon as: $DEST_IMAGE"
else
    echo "Done. Modified image available at: $DEST_IMAGE"
fi
