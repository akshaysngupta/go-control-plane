#!/bin/bash -e

set -o pipefail

MIRROR_MSG="Mirrored from envoyproxy/envoy"
SRCS=(envoy contrib)
GO_TARGETS=(@envoy_api//...)
IMPORT_BASE="github.com/envoyproxy/go-control-plane"
COMMITTER_NAME="envoy-sync[bot]"
COMMITTER_EMAIL="envoy-sync[bot]@users.noreply.github.com"
ENVOY_SRC_DIR="${ENVOY_SRC_DIR:-}"


if [[ -z "$ENVOY_SRC_DIR" ]]; then
    echo "ENVOY_SRC_DIR not set, it should point to a cloned Envoy repo" >&2
    exit 1
elif [[ ! -d "$ENVOY_SRC_DIR" ]]; then
    echo "ENVOY_SRC_DIR ($ENVOY_SRC_DIR) not found, did you clone it?" >&2
    exit 1
fi


build_protos () {
    # TODO(phlax): use envoy do_ci target once https://github.com/envoyproxy/envoy/pull/27675 lands
    local go_protos go_proto go_file rule_dir proto input_dir output_dir
    echo "Building go protos ..."
    cd "${ENVOY_SRC_DIR}" || exit 1

    # shellcheck disable=SC1091
    . ci/setup_cache.sh

    read -r -a go_protos <<< "$(bazel query "kind('go_proto_library', ${GO_TARGETS[*]})" | tr '\n' ' ')"
    bazel build \
          --experimental_proto_descriptor_sets_include_source_info \
          "${go_protos[@]}"
    rm -rf build_go
    mkdir -p build_go
    for go_proto in "${go_protos[@]}"; do
        # strip @envoy_api//
        rule_dir="$(echo "${go_proto:12}" | cut -d: -f1)"
        proto="$(echo "${go_proto:12}" | cut -d: -f2)"
        input_dir="bazel-bin/external/envoy_api/${rule_dir}/${proto}_/${IMPORT_BASE}/${rule_dir}"
        output_dir="build_go/${rule_dir}"
        mkdir -p "$output_dir"
        while read -r go_file; do
            cp -a "$go_file" "$output_dir"
        done <<< "$(find "$input_dir" -name "*.go")"
    done
    cd - || exit 1
}

get_last_envoy_sha () {
    git log \
        --grep="$MIRROR_MSG" -n 1 \
        | grep "$MIRROR_MSG" \
        | tail -n 1 \
        | sed -e "s#.*$MIRROR_MSG @ ##"
}

sync_protos () {
    local src envoy_src
    echo "Syncing go protos ..."
    for src in "${SRCS[@]}"; do
        envoy_src="${ENVOY_SRC_DIR}/build_go/${src}"
        rm -rf "$src"
        echo "Copying ${envoy_src} -> ${src}"
        cp -a "$envoy_src" "$src"
        git add "$src"
    done
}

commit_changes () {
    local last_envoy_sha changes changed
    echo "Committing changes ..."
    changed="$(git diff HEAD --name-only | grep -v envoy/COMMIT || :)"
    if [[ -z "$changed" ]]; then
        echo "Nothing changed, not committing"
        return
    fi
    last_envoy_sha="$(get_last_envoy_sha)"
    changes="$(git -C "${ENVOY_SRC_DIR}" rev-list "${last_envoy_sha}"..HEAD)"
    echo "Changes detected: "
    echo "$changes"
    latest_commit="$(git -C "${ENVOY_SRC_DIR}" rev-list "${last_envoy_sha}"..HEAD | head -n1)"
    echo "$latest_commit" > envoy/COMMIT
    git config --global user.email "$COMMITTER_EMAIL"
    git config --global user.name "$COMMITTER_NAME"
    git add envoy contrib
    git commit --allow-empty -s -m "${MIRROR_MSG} @ ${latest_commit}"
    git push origin main
}


build_protos
sync_protos
commit_changes