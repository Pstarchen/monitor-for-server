#!/usr/bin/env bash

offline_parse_agent_manifest() {
  local manifest="$1"
  awk '
    function invalid() {
      print "Agent manifest 必须使用 release-manifest 生成的 schemaVersion 1 格式。" > "/dev/stderr"
      failed = 1
      exit 1
    }
    {
      sub(/\r$/, "")
      if (state == 0) {
        if ($0 != "{") invalid()
        state = 1
      } else if (state == 1) {
        if ($0 != "  \"schemaVersion\": 1,") invalid()
        state = 2
      } else if (state == 2) {
        if ($0 !~ /^  "version": "[^"]+",$/) invalid()
        version = $0
        sub(/^  "version": "/, "", version)
        sub(/",$/, "", version)
        state = 3
      } else if (state == 3) {
        if ($0 !~ /^  "publishedAt": "[^"]+",$/) invalid()
        published = $0
        sub(/^  "publishedAt": "/, "", published)
        sub(/",$/, "", published)
        state = 4
      } else if (state == 4) {
        if ($0 !~ /^  "minimumCompatibleControllerVersion": "[^"]+",$/) invalid()
        minimum = $0
        sub(/^  "minimumCompatibleControllerVersion": "/, "", minimum)
        sub(/",$/, "", minimum)
        state = 5
      } else if (state == 5) {
        if ($0 != "  \"assets\": [") invalid()
        print "META\t" version "\t" published "\t" minimum
        state = 6
      } else if (state == 6) {
        if ($0 != "    {") invalid()
        state = 7
      } else if (state == 7) {
        if ($0 !~ /^      "os": "[^"]+",$/) invalid()
        os_name = $0
        sub(/^      "os": "/, "", os_name)
        sub(/",$/, "", os_name)
        state = 8
      } else if (state == 8) {
        if ($0 !~ /^      "arch": "[^"]+",$/) invalid()
        arch = $0
        sub(/^      "arch": "/, "", arch)
        sub(/",$/, "", arch)
        state = 9
      } else if (state == 9) {
        if ($0 !~ /^      "file": "[^"]+",$/) invalid()
        file = $0
        sub(/^      "file": "/, "", file)
        sub(/",$/, "", file)
        state = 10
      } else if (state == 10) {
        if ($0 !~ /^      "url": "[^"]*",$/) invalid()
        url = $0
        sub(/^      "url": "/, "", url)
        sub(/",$/, "", url)
        state = 11
      } else if (state == 11) {
        if ($0 !~ /^      "sha256": "[a-fA-F0-9]{64}",$/) invalid()
        sha256 = $0
        sub(/^      "sha256": "/, "", sha256)
        sub(/",$/, "", sha256)
        state = 12
      } else if (state == 12) {
        if ($0 !~ /^      "size": [1-9][0-9]*$/) invalid()
        size = $0
        sub(/^      "size": /, "", size)
        state = 13
      } else if (state == 13) {
        asset_count++
        if (asset_count < 4 && $0 != "    },") invalid()
        if (asset_count == 4 && $0 != "    }") invalid()
        if (asset_count > 4) invalid()
        print "ASSET\t" os_name "\t" arch "\t" file "\t" url "\t" sha256 "\t" size
        state = (asset_count == 4 ? 14 : 6)
      } else if (state == 14) {
        if ($0 != "  ]") invalid()
        state = 15
      } else if (state == 15) {
        if ($0 != "}") invalid()
        state = 16
      } else {
        invalid()
      }
    }
    END {
      if (!failed && (state != 16 || asset_count != 4)) invalid()
    }
  ' "${manifest}"
}

offline_verify_agent_release() {
  local manifest="$1" assets_dir="$2" checksums="$3" expected_version="$4"
  local parsed_file record field1 field2 field3 field4 field5 field6 manifest_version published minimum
  local os_name arch file url expected_hash expected_size
  local key expected_file actual_hash actual_size line checksum_file checksum_hash checksum_count=0
  local version_number="${expected_version#v}"
  declare -A seen_platform=() manifest_hashes=() checksum_hashes=()

  [[ -f "${manifest}" && ! -L "${manifest}" ]] || { echo "缺少可信 Agent manifest。" >&2; return 1; }
  [[ -f "${checksums}" && ! -L "${checksums}" ]] || { echo "缺少可信 Agent checksums.txt。" >&2; return 1; }
  parsed_file="$(mktemp)" || return 1
  if ! offline_parse_agent_manifest "${manifest}" > "${parsed_file}"; then
    rm -f -- "${parsed_file}"
    return 1
  fi

  while IFS=$'\t' read -r record field1 field2 field3 field4 field5 field6; do
    if [[ "${record}" == META ]]; then
      manifest_version="${field1}"
      published="${field2}"
      minimum="${field3}"
      [[ "${manifest_version}" == "${expected_version}" ]] || { echo "Agent manifest 版本与离线 bundle 不一致。" >&2; rm -f -- "${parsed_file}"; return 1; }
      [[ "${minimum}" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ && -n "${published}" ]] \
        || { echo "Agent manifest 的发布时间或最低兼容版本无效。" >&2; rm -f -- "${parsed_file}"; return 1; }
      continue
    fi
    [[ "${record}" == ASSET ]] || { echo "Agent manifest 记录无效。" >&2; rm -f -- "${parsed_file}"; return 1; }
    os_name="${field1}"
    arch="${field2}"
    file="${field3}"
    url="${field4}"
    expected_hash="${field5}"
    expected_size="${field6}"
    [[ "${os_name}" == linux || "${os_name}" == windows ]] \
      || { echo "Agent manifest 包含无效操作系统：${os_name}" >&2; rm -f -- "${parsed_file}"; return 1; }
    [[ "${arch}" == amd64 || "${arch}" == arm64 ]] \
      || { echo "Agent manifest 包含无效架构：${arch}" >&2; rm -f -- "${parsed_file}"; return 1; }
    key="${os_name}/${arch}"
    [[ -z "${seen_platform[${key}]:-}" ]] \
      || { echo "Agent manifest 包含重复平台：${key}" >&2; rm -f -- "${parsed_file}"; return 1; }
    seen_platform["${key}"]=true
    if [[ "${os_name}" == linux ]]; then
      expected_file="xingchen-agent_${version_number}_${os_name}_${arch}.tar.gz"
    else
      expected_file="xingchen-agent_${version_number}_${os_name}_${arch}.zip"
    fi
    [[ "${file}" == "${expected_file}" ]] \
      || { echo "Agent manifest 文件名与平台不一致：${file}" >&2; rm -f -- "${parsed_file}"; return 1; }
    if [[ -n "${url}" ]]; then
      [[ "${url}" == https://* && "${url}" != *[?#]* && "${url}" != *\\* && "${url##*/}" == "${file}" ]] \
        || { echo "Agent manifest URL 路径与文件名不一致：${file}" >&2; rm -f -- "${parsed_file}"; return 1; }
    fi
    [[ -f "${assets_dir}/${file}" && ! -L "${assets_dir}/${file}" ]] \
      || { echo "缺少 Agent 制品：${file}" >&2; rm -f -- "${parsed_file}"; return 1; }
    actual_size="$(wc -c < "${assets_dir}/${file}" | tr -d '[:space:]')"
    actual_hash="$(sha256sum "${assets_dir}/${file}" | awk '{print tolower($1)}')"
    expected_hash="${expected_hash,,}"
    [[ "${expected_size}" -le 536870912 && "${actual_size}" == "${expected_size}" ]] \
      || { echo "Agent manifest 大小与制品不一致：${file}" >&2; rm -f -- "${parsed_file}"; return 1; }
    [[ "${actual_hash}" == "${expected_hash}" ]] \
      || { echo "Agent manifest SHA256 与制品不一致：${file}" >&2; rm -f -- "${parsed_file}"; return 1; }
    manifest_hashes["${file}"]="${expected_hash}"
  done < "${parsed_file}"
  rm -f -- "${parsed_file}"

  for key in linux/amd64 linux/arm64 windows/amd64 windows/arm64; do
    [[ "${seen_platform[${key}]:-}" == true ]] || { echo "Agent manifest 缺少平台：${key}" >&2; return 1; }
  done

  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line%$'\r'}"
    [[ "${line}" =~ ^([a-fA-F0-9]{64})[[:space:]]([[:space:]]|\*)([A-Za-z0-9][A-Za-z0-9._-]{0,199})$ ]] \
      || { echo "Agent checksums.txt 格式无效。" >&2; return 1; }
    checksum_hash="${BASH_REMATCH[1],,}"
    checksum_file="${BASH_REMATCH[3]}"
    [[ -z "${checksum_hashes[${checksum_file}]:-}" ]] \
      || { echo "Agent checksums.txt 包含重复文件：${checksum_file}" >&2; return 1; }
    checksum_hashes["${checksum_file}"]="${checksum_hash}"
    ((checksum_count += 1))
  done < "${checksums}"
  [[ "${checksum_count}" -eq 4 ]] || { echo "Agent checksums.txt 必须且只能包含四个平台制品。" >&2; return 1; }
  for file in "${!manifest_hashes[@]}"; do
    [[ "${checksum_hashes[${file}]:-}" == "${manifest_hashes[${file}]}" ]] \
      || { echo "Agent checksums.txt 与 manifest 不一致：${file}" >&2; return 1; }
  done
}

offline_compact_json() {
  awk '
    BEGIN { in_string = 0; escaped = 0 }
    {
      for (position = 1; position <= length($0); position++) {
        character = substr($0, position, 1)
        if (in_string) {
          printf "%s", character
          if (escaped) escaped = 0
          else if (character == "\\") escaped = 1
          else if (character == "\"") in_string = 0
        } else if (character == "\"") {
          in_string = 1
          printf "%s", character
        } else if (character !~ /[[:space:]]/) {
          printf "%s", character
        }
      }
    }
    END {
      if (in_string || escaped) exit 1
      printf "\n"
    }
  ' "$1"
}

offline_parse_docker_manifest() {
  local compact="$1"
  awk '
    function emit_scalar(source, field, type, rest, token, pattern) {
      rest = source
      pattern = quote field quote ":" quote "[^" quote "]+" quote
      while (match(rest, pattern)) {
        token = substr(rest, RSTART, RLENGTH)
        sub("^" quote field quote ":" quote, "", token)
        sub(quote "$", "", token)
        print type "\t" token
        rest = substr(rest, RSTART + RLENGTH)
      }
    }
    function emit_array(source, field, type, rest, block, count, values, position, pattern) {
      rest = source
      pattern = quote field quote ":\\[[^]]*\\]"
      while (match(rest, pattern)) {
        block = substr(rest, RSTART, RLENGTH)
        sub("^" quote field quote ":\\[", "", block)
        sub("\\]$", "", block)
        if (block != "") {
          count = split(block, values, ",")
          for (position = 1; position <= count; position++) {
            if (values[position] !~ /^"[^"]+"$/) exit 2
            token = values[position]
            sub(/^"/, "", token)
            sub(/"$/, "", token)
            print type "\t" token
          }
        }
        rest = substr(rest, RSTART + RLENGTH)
      }
    }
    BEGIN { quote = sprintf("%c", 34) }
    {
      if ($0 !~ /^\[.*\]$/ || $0 ~ /\\/) exit 2
      emit_scalar($0, "Config", "CONFIG")
      emit_array($0, "RepoTags", "TAG")
      emit_array($0, "Layers", "LAYER")
    }
  ' "${compact}"
}

offline_verify_controller_image_archive() {
  local archive="$1" version="$2" list_file manifest_file compact_file parsed_file
  local record value expected config_count=0 tag_count=0 layer_count=0
  declare -A archive_entries=() archive_tags=()
  local expected_images=(
    "ghcr.io/pstarchen/monitor-for-server-setup:${version}"
    "ghcr.io/pstarchen/monitor-for-server-server:${version}"
    "ghcr.io/pstarchen/monitor-for-server-web:${version}"
    "ghcr.io/pstarchen/monitor-for-server-agent:${version}"
    "postgres:16-alpine"
    "redis:7.4-alpine"
  )

  command -v tar >/dev/null 2>&1 || { echo "离线镜像归档校验需要 tar。" >&2; return 1; }
  [[ -s "${archive}" && ! -L "${archive}" ]] || { echo "缺少可信离线镜像归档。" >&2; return 1; }
  list_file="$(mktemp)" || return 1
  manifest_file="$(mktemp)" || { rm -f -- "${list_file}"; return 1; }
  compact_file="$(mktemp)" || { rm -f -- "${list_file}" "${manifest_file}"; return 1; }
  parsed_file="$(mktemp)" || { rm -f -- "${list_file}" "${manifest_file}" "${compact_file}"; return 1; }
  if ! tar -tf "${archive}" > "${list_file}" 2>/dev/null \
      || [[ "$(grep -Fxc 'manifest.json' "${list_file}" || true)" -ne 1 ]] \
      || ! tar -xOf "${archive}" manifest.json > "${manifest_file}" 2>/dev/null \
      || [[ ! -s "${manifest_file}" || "$(wc -c < "${manifest_file}")" -gt 1048576 ]] \
      || ! offline_compact_json "${manifest_file}" > "${compact_file}" \
      || ! offline_parse_docker_manifest "${compact_file}" > "${parsed_file}"; then
    rm -f -- "${list_file}" "${manifest_file}" "${compact_file}" "${parsed_file}"
    echo "controller-images.tar 不是有效的 Docker save 镜像归档。" >&2
    return 1
  fi
  while IFS= read -r value || [[ -n "${value}" ]]; do
    value="${value%$'\r'}"
    [[ -n "${value}" && -z "${archive_entries[${value}]:-}" ]] \
      || { rm -f -- "${list_file}" "${manifest_file}" "${compact_file}" "${parsed_file}"; echo "controller-images.tar 包含空路径或重复条目。" >&2; return 1; }
    archive_entries["${value}"]=true
  done < "${list_file}"
  while IFS=$'\t' read -r record value; do
    [[ "${value}" =~ ^[A-Za-z0-9][A-Za-z0-9._+@:/-]*$ && "${value}" != /* && "${value}" != */../* && "${value}" != ../* ]] \
      || { rm -f -- "${list_file}" "${manifest_file}" "${compact_file}" "${parsed_file}"; echo "Docker 镜像归档 manifest 包含不安全路径或标签。" >&2; return 1; }
    case "${record}" in
      CONFIG)
        [[ "${archive_entries[${value}]:-}" == true ]] || { rm -f -- "${list_file}" "${manifest_file}" "${compact_file}" "${parsed_file}"; echo "Docker 镜像归档缺少 config：${value}" >&2; return 1; }
        ((config_count += 1))
        ;;
      LAYER)
        [[ "${archive_entries[${value}]:-}" == true ]] || { rm -f -- "${list_file}" "${manifest_file}" "${compact_file}" "${parsed_file}"; echo "Docker 镜像归档缺少 layer：${value}" >&2; return 1; }
        ((layer_count += 1))
        ;;
      TAG)
        archive_tags["${value}"]=$(( ${archive_tags[${value}]:-0} + 1 ))
        ((tag_count += 1))
        ;;
      *)
        rm -f -- "${list_file}" "${manifest_file}" "${compact_file}" "${parsed_file}"
        echo "Docker 镜像归档 manifest 记录无效。" >&2
        return 1
        ;;
    esac
  done < "${parsed_file}"
  rm -f -- "${list_file}" "${manifest_file}" "${compact_file}" "${parsed_file}"
  [[ "${config_count}" -eq 6 && "${tag_count}" -eq 6 && "${layer_count}" -ge 1 ]] \
    || { echo "controller-images.tar 必须且只能包含六个完整镜像记录。" >&2; return 1; }
  for expected in "${expected_images[@]}"; do
    [[ "${archive_tags[${expected}]:-0}" -eq 1 ]] \
      || { echo "controller-images.tar 缺少或重复预期镜像：${expected}" >&2; return 1; }
  done
}
