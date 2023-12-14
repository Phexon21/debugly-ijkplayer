#! /usr/bin/env bash
#
# Copyright (C) 2021 Matt Reach<qianlongxu@gmail.com>

# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# if you want skip pull base form net, you can export SKIP_PULL_BASE=1

set -e

source $1

TOOLS=$(dirname "$0")
source ${TOOLS}/env_assert.sh

echo "===check env begin==="
echo "argv:[$*]"
env_assert "GIT_UPSTREAM"
env_assert "GIT_LOCAL_REPO"
env_assert "GIT_COMMIT"
env_assert "REPO_DIR"
echo "===check env end==="

PLAT=$2
ARCH=$3

if [[ "$ARCH" == 'all' || "x$ARCH" == 'x' ]]; then
    iOS_ARCHS="x86_64 arm64"
    macOS_ARCHS="x86_64 arm64"
elif [[ "$ARCH" == 'x86_64' || "$ARCH" == 'arm64' ]]; then
    iOS_ARCHS="$ARCH"
    macOS_ARCHS="$ARCH"
else
    echo "wrong arch:[$ARCH], can't init repo."
    exit -1
fi

function pull_common() {
    echo "== pull $REPO_DIR base =="
    if [[ -d "$GIT_LOCAL_REPO" ]]; then
        cd "$GIT_LOCAL_REPO"
        [[ -d .git/rebase-apply ]] && git am --skip
        git reset --hard

        local origin=$(git remote get-url origin)
        if [[ "$origin" != "$GIT_UPSTREAM" ]]; then
            git remote remove origin
            git remote add origin "$GIT_UPSTREAM"
            echo "force update origin to: $GIT_UPSTREAM"
        fi
        if [[ "$SKIP_PULL_BASE" ]]; then
            echo "skip pull $REPO_DIR because you set SKIP_PULL_BASE env."
        else
            git fetch --all --tags
        fi
    else
        if [[ "$SKIP_PULL_BASE" ]]; then
            echo "== local repo $REPO_DIR not exist,must clone by net firstly. =="
            echo "try:unset SKIP_PULL_BASE"
            exit -1
        else
            git clone $GIT_UPSTREAM $GIT_LOCAL_REPO
            cd "$GIT_LOCAL_REPO"
        fi
    fi

    # fix fatal: 'stable' is not a commit and a branch 'localBranch' cannot be created from it
    git checkout ${GIT_COMMIT} -B localBranch
    cd - >/dev/null
}

function apply_patches() {
    if [[ "$SKIP_FFMPEG_PATHCHES" && $REPO_DIR == 'ffmpeg' ]]; then
        echo "skip apply $REPO_DIR patches,because you set SKIP_FFMPEG_PATHCHES env."
        return
    fi

    local plat="$1"
    local patch_dir="${THIS_DIR}/../patches/$REPO_DIR"

    if [[ -d "${patch_dir}_${plat}" ]]; then
        patch_dir="${patch_dir}_${plat}"
    fi
    if [[ -d "$patch_dir" ]]; then
        echo
        echo "== Applying patches: $(basename $patch_dir) → $(basename $PWD) =="
        git am --keep $patch_dir/*.patch
        if [[ $? -ne 0 ]]; then
            echo 'Apply patches failed!'
            git am --skip
            exit 1
        fi
        echo
    fi
}

function make_arch_repo() {
    local dest_repo="build/src/$1/$REPO_DIR-$2"
    echo "== copy $REPO_DIR → $dest_repo =="
    $TOOLS/copy-local-repo.sh $GIT_LOCAL_REPO $dest_repo
    cd $dest_repo
    if [[ "$GIT_WITH_SUBMODULE" ]]; then
        git submodule update --init --depth=1
    fi
    echo "last commit:"$(git log -1 --pretty=format:"[%h] %s:%ce %cd")
    if [[ -n "$IJK_VERSION" ]]; then
        git tag "ff${GIT_COMMIT##*/}-ijk$IJK_VERSION"
    fi
    apply_patches $1
    echo "tag:$(git describe --tags)"
    cd - >/dev/null
}

function usage() {
    echo "usage:"
    echo "$0 ios|macos|all [arm64|x86_64]"
}

function main() {
    case "$1" in
    iOS | ios)
        pull_common
        found=0
        for arch in $iOS_ARCHS; do
            if [[ "$2" == "$arch" || "x$2" == "x" || "$2" == "all" ]]; then
                found=1
                make_arch_repo 'ios' $arch
            fi
        done

        if [[ found -eq 0 ]]; then
            echo "unknown arch:$2 for $1"
        fi
        ;;

    macOS | macos)

        pull_common
        found=0
        for arch in $macOS_ARCHS; do
            if [[ "$2" == "$arch" || "x$2" == "x" || "$2" == "all" ]]; then
                found=1
                make_arch_repo 'macos' $arch
            fi
        done

        if [[ found -eq 0 ]]; then
            echo "unknown arch:$2 for $1"
        fi
        ;;

    all)
        pull_common
        for arch in $iOS_ARCHS; do
            make_arch_repo 'ios' $arch
        done

        for arch in $macOS_ARCHS; do
            make_arch_repo 'macos' $arch
        done
        ;;

    *)
        usage
        exit 1
        ;;
    esac
}

main $PLAT $ARCH
