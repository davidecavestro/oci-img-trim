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

# --- Fetch image metadata ---

echo "Fetching manifest for $IMAGE (platform: $PLATFORM)..."

TOP_MANIFEST=$(regctl manifest get --format raw-body "$IMAGE" 2>/dev/null)

if echo "$TOP_MANIFEST" | jq -e '.manifests' >/dev/null 2>&1 && ! echo "$TOP_MANIFEST" | jq -e '.layers' >/dev/null 2>&1; then
    echo "  Info: this is a multi-platform manifest list; showing platform '$PLATFORM'."
    echo "  The layer removal will be applied to the selected platform only."
    MANIFEST=$(regctl manifest get --platform "$PLATFORM" --format raw-body "$IMAGE" 2>/dev/null)
else
    MANIFEST="$TOP_MANIFEST"
fi

# Extract layers from manifest
mapfile -t LAYER_DIGESTS < <(echo "$MANIFEST" | jq -r '.layers[].digest')
mapfile -t LAYER_SIZES   < <(echo "$MANIFEST" | jq -r '.layers[].size')

LAYER_COUNT=${#LAYER_DIGESTS[@]}

if [ "$LAYER_COUNT" -eq 0 ]; then
    echo "No layers found in image."
    exit 1
fi

# Fetch config history (only non-empty layers, matching layer order)
mapfile -t HISTORY_CMDS < <(
    regctl image config --platform "$PLATFORM" "$IMAGE" 2>/dev/null \
    | jq -r '.history[] | select(.empty_layer != true) | .created_by // "(no history)"'
)

echo ""
echo "Image   : $IMAGE"
echo "Platform: $PLATFORM"
echo "Layers  : $LAYER_COUNT"
echo ""

# --- Build display strings ---

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

# --- Interactive multi-select ---

SELECTED_INDICES=()

if command -v fzf >/dev/null 2>&1; then
    # Build fzf input
    FZF_INPUT=""
    for i in "${!LAYER_DISPLAY[@]}"; do
        FZF_INPUT+="${LAYER_DISPLAY[$i]}"$'\n'
    done

    echo "Select layers to remove (SPACE/TAB to toggle, ENTER to confirm, ESC to cancel):"
    echo ""
    SELECTED_LINES=$(
        printf '%s' "$FZF_INPUT" | fzf \
            --multi \
            --header="SPACE/TAB=toggle  CTRL-A=select all  CTRL-D=deselect all  ENTER=confirm" \
            --prompt="Remove > " \
            --height=80% \
            --reverse \
            --bind="space:toggle,ctrl-a:select-all,ctrl-d:deselect-all" \
        2>/dev/tty
    ) || true

    if [ -z "$SELECTED_LINES" ]; then
        echo "No layers selected. Exiting."
        exit 0
    fi

    while IFS= read -r line; do
        for i in "${!LAYER_DISPLAY[@]}"; do
            if [ "${LAYER_DISPLAY[$i]}" = "$line" ]; then
                SELECTED_INDICES+=("$i")
                break
            fi
        done
    done <<< "$SELECTED_LINES"

else
    # Fallback: numbered toggle menu
    declare -A SELECTED_MAP

    print_layer_list() {
        echo ""
        for i in "${!LAYER_DISPLAY[@]}"; do
            if [ "${SELECTED_MAP[$i]:-}" = "1" ]; then
                marker="[x]"
            else
                marker="[ ]"
            fi
            echo "  $marker ${LAYER_DISPLAY[$i]}"
        done
        echo ""
    }

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
                if [ "${SELECTED_MAP[$idx]:-}" = "1" ]; then
                    unset "SELECTED_MAP[$idx]"
                else
                    SELECTED_MAP[$idx]="1"
                fi
            else
                echo "  Invalid: $num (must be 1-$LAYER_COUNT)"
            fi
        done

        print_layer_list
    done

    for idx in "${!SELECTED_MAP[@]}"; do
        SELECTED_INDICES+=("$idx")
    done
fi

if [ ${#SELECTED_INDICES[@]} -eq 0 ]; then
    echo "No layers selected. Exiting."
    exit 0
fi

# Sort indices ascending for display, descending for removal
mapfile -t SELECTED_SORTED_ASC  < <(printf '%s\n' "${SELECTED_INDICES[@]}" | sort -n)
mapfile -t SELECTED_SORTED_DESC < <(printf '%s\n' "${SELECTED_INDICES[@]}" | sort -rn)

echo ""
echo "Layers selected for removal:"
for idx in "${SELECTED_SORTED_ASC[@]}"; do
    echo "  - ${LAYER_DISPLAY[$idx]}"
done
echo ""

# --- Destination ---

OPT_OVERWRITE="Overwrite original  ($IMAGE)"
OPT_NEW_TAG="Push to a new tag"

if command -v fzf >/dev/null 2>&1; then
    echo "Where should the modified image be pushed?"
    echo ""
    DEST_CHOICE=$(printf '%s\n' "$OPT_OVERWRITE" "$OPT_NEW_TAG" | fzf \
        --no-multi \
        --header="ENTER=confirm  ESC=cancel" \
        --prompt="Destination > " \
        --height=30% \
        --reverse \
    2>/dev/tty) || true

    if [ -z "$DEST_CHOICE" ]; then
        echo "No destination selected. Exiting."
        exit 0
    fi

    if [ "$DEST_CHOICE" = "$OPT_OVERWRITE" ]; then
        DEST_IMAGE="$IMAGE"
    else
        read -r -p "Destination image reference: " DEST_IMAGE
        if [ -z "$DEST_IMAGE" ]; then
            echo "No destination provided. Exiting."
            exit 1
        fi
    fi
else
    echo "Where should the modified image be pushed?"
    echo "  1) $OPT_OVERWRITE"
    echo "  2) $OPT_NEW_TAG"
    echo ""
    read -r -p "Choice [1/2]: " choice

    case "$choice" in
        1)
            DEST_IMAGE="$IMAGE"
            ;;
        2)
            read -r -p "Destination image reference: " DEST_IMAGE
            if [ -z "$DEST_IMAGE" ]; then
                echo "No destination provided. Exiting."
                exit 1
            fi
            ;;
        *)
            echo "Invalid choice. Exiting."
            exit 1
            ;;
    esac
fi

echo ""
echo "Summary:"
echo "  Source      : $IMAGE"
echo "  Destination : $DEST_IMAGE"
echo "  Layers to remove (by index): ${SELECTED_SORTED_ASC[*]}"
echo ""
read -r -p "Proceed? [y/N]: " confirm
[[ "${confirm,,}" != "y" ]] && { echo "Aborted."; exit 0; }

# --- Execute removal ---
#
# Layers are removed in descending index order so that earlier indices remain
# stable across iterations. Intermediate results are stored in a local OCI
# layout to avoid round-trips to the registry.

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

WORK_REF="ocidir://${WORK_DIR}:work"
CURRENT_SRC="$IMAGE"
PLATFORM_FLAG=""
[ "$PLATFORM" != "local" ] && PLATFORM_FLAG="--platform $PLATFORM"

echo ""
STEP=1
for idx in "${SELECTED_SORTED_DESC[@]}"; do
    echo "  [${STEP}/${#SELECTED_SORTED_DESC[@]}] Removing layer index $idx (sha256:${LAYER_DIGESTS[$idx]:7:12})..."
    # shellcheck disable=SC2086
    regctl image mod --layer-rm-index "$idx" $PLATFORM_FLAG "$CURRENT_SRC" --create "$WORK_REF"
    CURRENT_SRC="$WORK_REF"
    STEP=$((STEP+1))
done

echo "  Pushing result to $DEST_IMAGE..."
regctl image copy "$CURRENT_SRC" "$DEST_IMAGE"

echo ""
echo "Done. Modified image available at: $DEST_IMAGE"
