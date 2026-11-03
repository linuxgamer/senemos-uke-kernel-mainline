#!/usr/bin/env bash
# Source metadata preparation only; COPR owns source RPMs and native checks.
set -Eeuo pipefail
release_fields() {
    local metadata=$1
    jq -er '
      . as $metadata |
      [.releases[] | select(.version | test("^7[.]3([.][0-9]+)?$"))] |
      sort_by(.version | split(".") | map(tonumber)) | last.version as $v |
      if ($v|test("^[0-9]+[.][0-9]+([.][0-9]+)?$")) then
        [$metadata.releases[] | select(.version==$v)] as $r |
        if ($r|length)==1 and ($r[0].moniker|IN("mainline","stable","longterm")) and
           $r[0].source==("https://cdn.kernel.org/pub/linux/kernel/v"+($v|split(".")[0])+".x/linux-"+$v+".tar.xz") and
           $r[0].pgp==("https://cdn.kernel.org/pub/linux/kernel/v"+($v|split(".")[0])+".x/linux-"+$v+".tar.sign") and
           ($r[0].released.timestamp|type)=="number" and
           ($r[0].released.timestamp|.>0 and .==floor and .<=now) then
          [$v, $r[0].source, $r[0].pgp, ($r[0].released.timestamp|tostring)]|@tsv
        else error("Unadmitted upstream release metadata") end
      else error("No admitted Linux 7.3 release") end' "$metadata"
}
matching_build() {
    jq -cer --arg package "$2" --arg evr "$3" '
      [.items[] | select(.source_package.name==$package and .source_package.version==$evr) |
       select(.source_package.url|startswith("https://download.copr.fedorainfracloud.org/results/mcc45tr/uke-linux-test/srpm-builds/")) |
       select(.chroots|index("fedora-rawhide-aarch64")) |
       select(.id|type=="number" and .>0 and .==floor)] |
      sort_by(.id) | last // {state:"absent"}' "$1"
}
replace_version() {
    local file=$1 old=$2 next=$3 old_release=$4 next_release=$5 content literal replacement
    [[ -f $file ]] || return 0
    content=$(cat "$file")
    for literal in "$old-$old_release" "${old//./\\.}-$old_release" "${old//./[.]}-$old_release"; do
        replacement="$next-$next_release"
        [[ $literal != *'\.'* ]] || replacement="${next//./\\.}-$next_release"
        [[ $literal != *'[.]'* ]] || replacement="${next//./[.]}-$next_release"
        content=${content//"$literal"/"$replacement"}
    done
    for literal in "$old" "${old//./\\.}" "${old//./[.]}"; do
        replacement=$next
        [[ $literal != *'\.'* ]] || replacement=${next//./\\.}
        [[ $literal != *'[.]'* ]] || replacement=${next//./[.]}
        content=${content//"$literal"/"$replacement"}
    done
    printf '%s\n' "$content" > "$file"
}
prepare_metadata() {
    local role=$1 evr=$2 spec json old version release old_release abi
    [[ $evr =~ ^[0-9]+\.[0-9]+\.[0-9]+-[1-9][0-9]*$ ]] || return 2
    spec=packaging/senemos-uke-linux-kernel-mainline-singleboot.spec json=packaging/singleboot.json
    [[ $role != kvm-singleboot ]] || {
        spec=packaging/senemos-uke-linux-kernel-mainline-kvm-singleboot.spec; json=packaging/kvm-singleboot.json;
    }
    old=$(rpmspec -q --srpm --qf '%{VERSION}' "$spec")
    old_release=$(rpmspec --define 'dist %{nil}' -q --srpm --qf '%{RELEASE}' "$spec")
    [[ $old-$old_release != "$evr" ]] || { printf 'unchanged\t%s\n' "$evr"; return; }
    [[ $(printf '%s\n' "$old-$old_release" "$evr" | sort -V | tail -1) == "$evr" ]] || {
        echo 'Refusing an automatic metadata downgrade' >&2; return 1;
    }
    version=${evr%-*} release=${evr##*-} abi=$evr
    [[ $role != kvm-singleboot ]] || abi=$evr-kvm
    sed -i "s/^Version: .*/Version: $version/; s/^Release: [0-9][0-9]*/Release: $release/; s/%{version}-$old_release\//%{version}-$release\//g" "$spec"
    if [[ $role == kvm-singleboot ]]; then
        sed -i "s/^%global senemos_build_release $old_release$/%global senemos_build_release $release/" "$spec"
    fi
    jq --arg abi "$abi" '.kernel_release=$abi | .boot_image=("/usr/lib/senemos/kernel-updates/"+$abi+"/userdata.img")' "$json" > "$json.tmp"
    mv "$json.tmp" "$json"
    replace_version tests/singleboot-package-contract.sh "$old" "$version" "$old_release" "$release"
    # Keep future SCM metadata checks independent of COPR's stacked dist macros.
    for contract in tests/singleboot-package-contract.sh tests/kvm-singleboot-package-contract.sh; do
        [[ ! -f $contract ]] || sed -i "s/rpmspec --undefine dist/rpmspec --define 'dist %{nil}'/" "$contract"
    done
    if [[ $role == singleboot ]]; then
        sed -i '/^Release [0-9].*requires the exact/,$d' packaging/SINGLEBOOT.md
        printf '\nThe exact current tuple is recorded in the installed JSON descriptor.\nThe common kernel and physical acceptance retain their separate evidence.\n' >> packaging/SINGLEBOOT.md
    fi
    git add "$spec" "$json"
    for contract in tests/singleboot-package-contract.sh tests/kvm-singleboot-package-contract.sh packaging/SINGLEBOOT.md; do
        [[ ! -f $contract ]] || git add "$contract"
    done
    git -c core.hooksPath=/dev/null -c commit.gpgsign=false -c user.name='Senemos Automation' -c user.email='41898282+github-actions[bot]@users.noreply.github.com' commit -m "Select matched $role kernel $evr"
    printf 'prepared\t%s\n' "$evr"
}
prepare_common() {
    local metadata=$1 fields raw url signature epoch next current release base cache archive sig keyring status primary signer tree profile spec value
    fields=$(release_fields "$metadata")
    IFS=$'\t' read -r raw url signature epoch <<< "$fields"
    next=$raw
    [[ $next == *.*.* ]] || next=$next.0
    spec=packaging/senemos-uke-linux-kernel-mainline.spec
    current=$(rpmspec -q --srpm --qf '%{VERSION}' "$spec")
    release=$(rpmspec --define 'dist %{nil}' -q --srpm --qf '%{RELEASE}' "$spec")
    [[ $current =~ ^7[.]3[.][0-9]+$ ]] || {
        echo 'Automatic updates require an already reviewed Linux 7.3 source queue' >&2; return 1;
    }
    if [[ $(printf '%s\n' "$current" "$next" | sort -V | tail -1) == "$current" ]]; then
        printf 'unchanged\t%s-%s\n' "$current" "$release"; return;
    fi
    base=$(git rev-parse HEAD)
    cache=$PWD/referances/releases; mkdir -p "$cache"
    archive=$cache/linux-$next.tar.xz sig=$cache/linux-$next.tar.sign
    curl -fL --connect-timeout 20 --max-time 900 "$url" -o "$archive.part"
    curl -fL --connect-timeout 20 --max-time 90 "$signature" -o "$sig.part"
    keyring=$(mktemp -d); chmod 700 "$keyring"
    CANDIDATE_GPG_HOME=$keyring
    trap 'gpgconf --homedir "$CANDIDATE_GPG_HOME" --kill all; rm -rf -- "$CANDIDATE_GPG_HOME"' EXIT
    gpg --homedir "$keyring" --batch --import configs/keys/linux-stable.asc
    # Pinned primary fingerprints published by kernel.org/signature.html.
    timeout 90 gpg --homedir "$keyring" --batch --auto-key-locate clear,wkd --locate-keys torvalds@kernel.org gregkh@kernel.org
    xz -cd "$archive.part" | gpg --homedir "$keyring" --batch --status-fd=1 --verify "$sig.part" - > "$keyring/status"
    status=$(awk '$1=="[GNUPG:]" && $2=="VALIDSIG" {print $3, $NF}' "$keyring/status")
    read -r signer primary <<< "$status"
    case $primary in ABAF11C65A2970B130ABE3C479BE3E4300411886|647F28654894E3BD457199BE38DBBDC86092693E) ;; *) echo 'Unadmitted release signer' >&2; return 1;; esac
    tree=linux-$raw
    value=$(xz -cd "$archive.part" | tar -xOf - "$tree/Makefile" | awk '$1=="VERSION"{v=$3}$1=="PATCHLEVEL"{p=$3}$1=="SUBLEVEL"{s=$3}END{print v"."p"."s}')
    [[ $value == "$next" ]] || { echo 'Signed source version mismatch' >&2; return 1; }
    mv "$archive.part" "$archive"; mv "$sig.part" "$sig"
    [[ ! -e patches/$next && ! -e manifests/linux-$next.json ]]
    cp -a "patches/$current" "patches/$next"
    profile=manifests/linux-$next.json
    jq --arg old "$current" --arg next "$next" --arg url "$url" --arg signature "$signature" \
       --arg hash "$(sha256sum "$archive" | cut -d ' ' -f1)" --arg signer "$signer" --arg primary "$primary" \
       --arg base "$base" --arg tree "$tree" --argjson epoch "$epoch" '
       .version=$next | .source_url=$url | .signature_url=$signature | .source_sha256=$hash |
       .signer=$signer | .source_date_epoch=$epoch | .hardware_tested=false |
       .candidate={base_commit:$base,source_tree:$tree,primary_signer:$primary,physical_tested:false} |
       (.patches[].path)|=sub("/"+$old+"/";"/"+$next+"/")' "manifests/linux-$current.json" > "$profile"
    gpg --homedir "$keyring" --batch --armor --export "$primary" > configs/keys/linux-stable.asc
    replace_version Makefile "$current" "$next" "$release" 1
    replace_version tests/mainline-package-contract.sh "$current" "$next" "$release" 1
    sed -i "s/^Version: .*/Version: $next/; s@^%setup -q -n linux-.*@%setup -q -n $tree@" "$spec"
    # Clean COPR clones must fetch the admitted original URL, including x.y releases.
    # shellcheck disable=SC2016 # Preserve Make and jq expressions in the recipe.
    sed -i 's@"https://cdn.kernel.org/pub/linux/kernel/v7.x/$$name"@"$$(jq -er --arg n "$$name" '\''if ($n|endswith(".tar.sign")) then .signature_url else .source_url end'\'' manifests/linux-$(version).json)"@' Makefile
    if [[ -f manifests/llcc-source-candidate-20261020.json ]]; then
        value=$next-1
        [[ $(rpmspec -q --srpm --qf '%{NAME}' "$spec") != *-kvm ]] || value=$value-kvm
        jq --arg abi "$value" '.kernel_release=$abi' manifests/llcc-source-candidate-20261020.json > "$cache/llcc.json"
        mv "$cache/llcc.json" manifests/llcc-source-candidate-20261020.json
    fi
    git add Makefile "$spec" "$profile" "patches/$next" configs/keys/linux-stable.asc tests/mainline-package-contract.sh manifests/llcc-source-candidate-20261020.json
    git -c core.hooksPath=/dev/null -c commit.gpgsign=false -c user.name='Senemos Automation' -c user.email='41898282+github-actions[bot]@users.noreply.github.com' commit -m "Prepare signed Linux $raw source candidate"
    printf 'prepared\t%s-1\n' "$next"
}
main() {
    [[ $# == 3 ]] || { echo 'Usage: prepare-upstream-candidate.sh SOURCE ROLE METADATA_OR_EVR' >&2; return 2; }
    cd "$1"
    [[ -z $(git status --porcelain) ]] || { echo 'Use a clean isolated checkout' >&2; return 1; }
    case $2 in
        common|kvm) prepare_common "$3";;
        singleboot|kvm-singleboot) prepare_metadata "$2" "$3";;
        *) return 2;;
    esac
}
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
