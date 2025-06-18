#!/bin/bash
set -eo pipefail

: "${DOWNLOAD_DIR:=/mnt/server/.downloads}"
: "${VERSION:=LATEST}"
: "${PREVIEW:=false}"
: "${EULA:=TRUE}"

function isTrue() {
  [[ "${1,,}" =~ ^(true|on|1)$ ]] && return 0
  return 1
}

function replace_version_in_url() {
  local original_url="$1"
  local new_version="$2"

  local modified_url
  modified_url=$(echo "$original_url" | sed -E "s/(bedrock-server-)[^/]+(\.zip)/\1${new_version}\2/")

  echo "$modified_url"
}

function lookupVersion() {
  platform=${1:?Missing required platform indicator}
  customVersion=${2:-}

  DOWNLOAD_URL=$(
    curl -fsSL "${getUrlPage}" |
      jq --arg platform "$platform" -rR '
        try(fromjson) catch({}) |
        .result.links // halt_error(1) |
          map(
            select(.downloadType == $platform)
          ) |
          if length > 0 then
            first |
            .downloadUrl
          else
            (
              "Error: could not find platform (\($platform))\n" |
              stderr |
              "" |
              halt_error(2)
            )
          end
        '
  )

  if [[ -n "${customVersion}" && -n "${DOWNLOAD_URL}" ]]; then
    DOWNLOAD_URL=$(replace_version_in_url "${DOWNLOAD_URL}" "${customVersion}")
    return
  fi

  # shellcheck disable=SC2012
  if [[ ${DOWNLOAD_URL} =~ http.*/.*-(.*)\.zip ]]; then
    VERSION=${BASH_REMATCH[1]}
  elif [[ $(ls -rv bedrock_server-* 2> /dev/null|head -1) =~ bedrock_server-(.*) ]]; then
    VERSION=${BASH_REMATCH[1]}
    echo "WARN Minecraft download page failed, so using existing download of $VERSION"
  else
    echo "Failed to lookup download URL: ${DOWNLOAD_URL}"
    exit 2
  fi
}

if [[ ${DEBUG^^} == TRUE ]]; then
  set -x
  curlArgs=(-v)
  echo "DEBUG: running as $(id -a) with $(ls -ld /data)"
  echo "       current directory is $(pwd)"
fi

export HOME="${PWD}"

getUrlPage=https://net-secondary.web.minecraft-services.net/api/v1.0/download/links

if [[ ${EULA^^} != TRUE ]]; then
  echo
  echo "EULA must be set to TRUE to indicate agreement with the Minecraft End User License"
  echo "See https://minecraft.net/terms"
  echo
  echo "Current value is '${EULA}'"
  echo
  exit 1
fi

if [[ -n "${DIRECT_DOWNLOAD_URL}" ]]; then
  echo "Using direct download URL from DIRECT_DOWNLOAD_URL environment variable."
  DOWNLOAD_URL="${DIRECT_DOWNLOAD_URL}"
  if [[ -z "${VERSION}" ]]; then
    if [[ "${DOWNLOAD_URL}" =~ bedrock-server-([0-9\.]+)\.zip ]]; then
      VERSION=${BASH_REMATCH[1]}
      echo "Extracted VERSION=${VERSION} from DIRECT_DOWNLOAD_URL."
    else
      echo "WARNING: Could not extract VERSION from DIRECT_DOWNLOAD_URL. Please ensure VERSION environment variable is set."
    fi
  else
    echo "VERSION=${VERSION} is explicitly set, using it with DIRECT_DOWNLOAD_URL."
  fi
else  case ${VERSION^^} in
    PREVIEW)
      echo "Looking up latest preview version..."
      lookupVersion serverBedrockPreviewLinux
      ;;
    LATEST)
      echo "Looking up latest version..."
      lookupVersion serverBedrockLinux
      ;;
    *)
      if isTrue "$PREVIEW"; then
        echo "Using given preview version ${VERSION}"
        lookupVersion serverBedrockPreviewLinux "${VERSION}"
      else
        echo "Using given version ${VERSION}"
        lookupVersion serverBedrockLinux "${VERSION}"
      fi
      ;;
  esac
fi

if [[ ! -f "bedrock_server-${VERSION}" ]]; then

  [[ $DOWNLOAD_DIR != /tmp ]] && mkdir -p "$DOWNLOAD_DIR"
  TMP_ZIP="$DOWNLOAD_DIR/$(basename "${DOWNLOAD_URL}")"

  echo "Downloading Bedrock server version ${VERSION} ..."
  if ! curl "${curlArgs[@]}" -o "${TMP_ZIP}" -A "ghcr.io/djstompzone/bds-pterodactyl" -fsSL "${DOWNLOAD_URL}"; then
    echo "ERROR failed to download from ${DOWNLOAD_URL}"
    echo "      Double check that the given VERSION is valid"
    exit 2
  fi

  rm -rf -- bedrock_server bedrock_server-* *.so release-notes.txt bedrock_server_how_to.html valid_known_packs.json premium_cache 2> /dev/null

  bkupDir=backup-pre-${VERSION}
  rm -rf "${bkupDir}"
  for d in behavior_packs definitions minecraftpe resource_packs structures treatments world_templates; do
    if [[ -d $d && -n "$(ls $d)" ]]; then
      mkdir -p "${bkupDir}/$d"
      echo "Backing up $d into $bkupDir"
      if [[ "$d" == "resource_packs" ]]; then
        cp -a $d/* "${bkupDir}/$d/"

        for rp_dir in chemistry vanilla editor; do
          if [[ -d "${d:?}/${rp_dir:?}" ]]; then
            rm -rf "${d:?}/${rp_dir:?}"
          fi
        done
      elif [[ "$d" == "behavior_packs" ]]; then
        find behavior_packs \( -name 'vanilla*' -o -name 'chemistry*' -o -name 'experimental*' \) -exec rm -rf {} +
      else
        mv $d "${bkupDir}/"
      fi
    fi
  done

  if (( ${PACKAGE_BACKUP_KEEP:=2} >= 0 )); then
    shopt -s nullglob
    # shellcheck disable=SC2012
    for d in $( ls -td1 backup-pre-* | tail +$(( PACKAGE_BACKUP_KEEP + 1 )) ); do
      echo "Pruning backup directory: $d"
      rm -rf "$d"
    done
  fi

  unzip -q -n "${TMP_ZIP}"
  [[ $DOWNLOAD_DIR != /tmp ]] && rm -rf "$DOWNLOAD_DIR"

  chmod +x bedrock_server
  mv bedrock_server "bedrock_server-${VERSION}"
fi

if [[ -n "$OPS" || -n "$MEMBERS" || -n "$VISITORS" ]]; then
  echo "Updating permissions"
  jq -n --arg ops "$OPS" --arg members "$MEMBERS" --arg visitors "$VISITORS" '[
  [$ops      | split(",") | map({permission: "operator", xuid:.})],
  [$members  | split(",") | map({permission: "member", xuid:.})],
  [$visitors | split(",") | map({permission: "visitor", xuid:.})]
  ]| flatten' > permissions.json
fi

if [[ -n "$ALLOW_LIST_USERS" || -n "$WHITE_LIST_USERS" ]]; then
  allowListUsers=${ALLOW_LIST_USERS:-$WHITE_LIST_USERS}

  if [[ "$allowListUsers" ]]; then
    echo "Setting allow list"
    if [[ "$allowListUsers" != *":"* ]]; then
      jq -c -n --arg users "$allowListUsers" '$users | split(",") | map({"ignoresPlayerLimit":false,"name": .})' > "allowlist.json"
    else
      jq -c -n --arg users "$allowListUsers" '$users | split(",") | map(split(":") | {"ignoresPlayerLimit":false,"name": .[0], "xuid": .[1]})' > "allowlist.json"
    fi
    ALLOW_LIST=true
  else
    ALLOW_LIST=false
    rm -f allowlist.json
  fi
fi

if [[ -n "$VARIABLES" ]]; then
  echo "Setting variables"
  mkdir -p config/default

  if echo "$VARIABLES" | jq empty >/dev/null 2>&1; then
    echo "$VARIABLES" | jq '.' > "config/default/variables.json"
  else
    echo "VARIABLES is not valid JSON, attempting to parse as custom format"

    jq -n --arg vars "$VARIABLES" '
      $vars
      | split(",")
      | map(
          split("=") as $kv |
          { ($kv[0]): ($kv[1] | fromjson? // $kv[1]) }
        )
      | add
    ' > "config/default/variables.json"
  fi
fi



_SERVER_PROPERTIES=$(sed '/^white-list=.*/d' server.properties)
echo "${_SERVER_PROPERTIES}" > server.properties
export ALLOW_LIST

set-property --file server.properties --bulk /etc/bds-property-definitions.json

export LD_LIBRARY_PATH=.

mcServerRunnerArgs=()
if isTrue "${ENABLE_SSH}"; then
  mcServerRunnerArgs+=(--remote-console)
  if ! [[ -v RCON_PASSWORD ]]; then
    RCON_PASSWORD=$(openssl rand -hex 12)
    export RCON_PASSWORD
  fi

  echo "password=${RCON_PASSWORD}" > "$HOME/.remote-console.env"
  echo "password: \"${RCON_PASSWORD}\"" > "$HOME/.remote-console.yaml"
fi

echo "Starting Bedrock server..."
if [[ -f /usr/local/bin/box64 ]] ; then
    exec mc-server-runner "${mcServerRunnerArgs[@]}" box64 ./"bedrock_server-${VERSION}"
else
    exec mc-server-runner "${mcServerRunnerArgs[@]}" ./"bedrock_server-${VERSION}"
fi
