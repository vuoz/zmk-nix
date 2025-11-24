{ lib
, writeShellApplication
, coreutils
, findutils
, git
, gnugrep
, gnused
, nix
, yq
}:

writeShellApplication {
  name = "zmk-firmware-update";

  runtimeInputs = [
    coreutils
    findutils
    git
    gnugrep
    gnused
    nix
    yq
  ];

  text = ''
    export NIX_CONFIG='extra-experimental-features = nix-command flakes'

    # get repo toplevel
    toplevel="$(git rev-parse --show-toplevel || (printf 'Could not find root of repository\nAre we running from within the git repo?\n' >&2; exit 1))"

    # get package attr and path
    attr="''${UPDATE_NIX_ATTR_PATH:-firmware}"
    westRoot="$toplevel/''${UPDATE_WEST_ROOT:-$(nix eval --raw "$toplevel"#"$attr" --apply 'drv: drv.westRoot or "config"')}"
    pkgpath="$(nix eval --raw "$toplevel"#"$attr".meta.position | cut -d: -f1)"
    outpath="$(nix eval --raw --impure --expr "builtins.fetchGit { url = \"$toplevel\"; shallow = true; }")"
    [ -n "$outpath" ] && pkgpath="''${pkgpath/$outpath/$toplevel}"

    # get manifest revision heads and update
    # shellcheck disable=SC2016
    yq -cj '
      .manifest.remotes as $remotes
      | .manifest.projects
      | map(.remote as $remote | {name, url: (($remotes[] | select(.name == $remote))."url-base" + "/" + (if ."repo-path" then ."repo-path" else .name end)), revision}) []
      | tostring + "\u0000"
    ' "$westRoot"/west.yml | xargs -0 -L1 "$BASH" -c '
      set -euo pipefail

      westRoot="$0"
      project="$1"

      url="$(echo "$project" | yq -r .url)"
      currevision="$(echo "$project" | yq -r .revision)"

      if ! printf '%s' "$currevision" | grep -Eq '^[0-9a-f]{40}$'; then
        exit 0
      fi

      line="$(grep -F "$currevision" "$westRoot"/west.yml | head -n1 || true)"
      head="$(printf '%s' "$line" | sed -n 's/.*#[[:space:]]*//p' | tr -d '[:space:]')"

      [ -z "$head" ] && exit 0

      newrevision="$(git ls-remote "$url" "$head" | sed -e "s/\t.*$//")"
      [ -n "$newrevision" ] && sed -i -e "s|$currevision|$newrevision|" "$westRoot"/west.yml
    ' "$westRoot"

    # get new deps hash
    curhash="$(nix eval --raw "$toplevel"#"$attr".westDeps.outputHash)"
    drv="$(nix eval --raw "$toplevel"#"$attr".westDeps --apply 'drv: (drv.overrideAttrs { outputHash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="; }).drvPath')"
    newhash="$(nix build --no-link "$drv^*" 2>&1 >/dev/null | grep -F 'got:' | tail -n1 | cut -d: -f2- | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' || true)"

    # set new deps hash
    sed -i -e "s|\"$curhash\"|\"$newhash\"|" "$pkgpath"
  '';

  meta = with lib; {
    description = "ZMK config dependency updater";
    license = licenses.mit;
    platforms = platforms.all;
    maintainers = with maintainers; [ /*lilyinstarlight*/ ];
  };
}
