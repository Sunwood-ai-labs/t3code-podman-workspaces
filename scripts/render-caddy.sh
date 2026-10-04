#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
export REPO_ROOT

if [[ -f "${SCRIPT_DIR}/lib.sh" ]]; then
	# shellcheck source=scripts/lib.sh
	source "${SCRIPT_DIR}/lib.sh"
	if ! declare -F load_config >/dev/null || ! declare -F list_users >/dev/null; then
		printf 'scripts/lib.sh must define load_config and list_users\n' >&2
		exit 1
	fi
	load_config
	BUILD_DIR="${BUILD_DIR:-${REPO_ROOT}/build}"
else
	# Minimal standalone fallback for parallel development before scripts/lib.sh
	# exists. Parse simple KEY=value lines without evaluating config.env as shell.
	load_config() {
		local line key value config_file="${REPO_ROOT}/config.env"
		if [[ ! -r "${config_file}" ]]; then
			printf 'Missing readable config file: %s\n' "${config_file}" >&2
			return 1
		fi
		while IFS= read -r line || [[ -n "${line}" ]]; do
			line="${line%$'\r'}"
			[[ "${line}" =~ ^[[:space:]]*(#|$) ]] && continue
			if [[ ! "${line}" =~ ^([A-Z_][A-Z0-9_]*)=(.*)$ ]]; then
				printf 'Unsupported config.env line: %s\n' "${line}" >&2
				return 1
			fi
			key="${BASH_REMATCH[1]}"
			value="${BASH_REMATCH[2]}"
			if [[ "${value}" == \"*\" && "${value}" == *\" ]]; then
				value="${value:1:${#value}-2}"
			elif [[ "${value}" == \'*\' && "${value}" == *\' ]]; then
				value="${value:1:${#value}-2}"
			fi
			printf -v "${key}" '%s' "${value}"
			export "${key?}"
		done < "${config_file}"
	}
	list_users() {
		local line
		if [[ ! -r "${REPO_ROOT}/users.conf" ]]; then
			printf 'Missing readable user list: %s\n' "${REPO_ROOT}/users.conf" >&2
			return 1
		fi
		while IFS= read -r line || [[ -n "${line}" ]]; do
			line="${line%$'\r'}"
			[[ "${line}" =~ ^[[:space:]]*(#|$) ]] && continue
			printf '%s\n' "${line}"
		done < "${REPO_ROOT}/users.conf"
	}
	public_url() {
		local user="$1" port_suffix=""
		[[ "${CADDY_HTTPS_PORT}" == 443 ]] || port_suffix=":${CADDY_HTTPS_PORT}"
		printf 'https://%s.%s%s\n' "${user}" "${T3_DOMAIN}" "${port_suffix}"
	}
	load_config
	BUILD_DIR="${REPO_ROOT}/build"
fi

required=(T3_DOMAIN T3_PORT CADDY_IMAGE CADDY_HTTP_PORT CADDY_HTTPS_PORT)
for name in "${required[@]}"; do
	if [[ -z "${!name:-}" ]]; then
		printf 'Required config value is missing: %s\n' "${name}" >&2
		exit 1
	fi
done

domain_label='[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?'
if [[ ! "${T3_DOMAIN}" =~ ^${domain_label}(\.${domain_label})*$ ]]; then
	printf 'T3_DOMAIN must be a DNS name containing only valid hostname labels: %s\n' "${T3_DOMAIN}" >&2
	exit 1
fi
if [[ ! "${T3_PORT}" =~ ^[0-9]+$ ]] || (( 10#${T3_PORT} < 1 || 10#${T3_PORT} > 65535 )); then
	printf 'T3_PORT must be an integer from 1 to 65535: %s\n' "${T3_PORT}" >&2
	exit 1
fi
for port_name in CADDY_HTTP_PORT CADDY_HTTPS_PORT; do
	port_value="${!port_name}"
	if [[ ! "${port_value}" =~ ^[0-9]+$ ]] || (( 10#${port_value} < 1 || 10#${port_value} > 65535 )); then
		printf '%s must be an integer from 1 to 65535: %s\n' "${port_name}" "${port_value}" >&2
		exit 1
	fi
done
if [[ "${CADDY_HTTP_PORT}" == "${CADDY_HTTPS_PORT}" ]]; then
	printf 'CADDY_HTTP_PORT and CADDY_HTTPS_PORT must be different\n' >&2
	exit 1
fi
if [[ "${CADDY_HTTPS_PORT}" == 443 ]]; then
	CADDY_HTTPS_PORT_SUFFIX=""
else
	CADDY_HTTPS_PORT_SUFFIX=":${CADDY_HTTPS_PORT}"
fi
if [[ ! "${CADDY_IMAGE}" =~ ^[A-Za-z0-9._:/@-]+$ ]]; then
	printf 'CADDY_IMAGE contains characters that cannot be rendered safely: %s\n' "${CADDY_IMAGE}" >&2
	exit 1
fi

users_output="$(list_users)"
USERS=()
if [[ -n "${users_output}" ]]; then
	mapfile -t USERS <<< "${users_output}"
fi
if (( ${#USERS[@]} == 0 )); then
	printf 'users.conf must contain at least one user\n' >&2
	exit 1
fi
declare -A seen_users=()
for user in "${USERS[@]}"; do
	if [[ ! "${user}" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || (( ${#user} > 63 )); then
		printf 'Invalid user name in users.conf: %s\n' "${user}" >&2
		exit 1
	fi
	if [[ -n "${seen_users[${user}]:-}" ]]; then
		printf 'Duplicate user in users.conf: %s\n' "${user}" >&2
		exit 1
	fi
	seen_users["${user}"]=1
done

TEMPLATE_DIR="${REPO_ROOT}/caddy"
CADDY_OUT_DIR="${BUILD_DIR}/caddy"
QUADLET_OUT_DIR="${BUILD_DIR}/quadlet"
mkdir -p -- "${CADDY_OUT_DIR}" "${QUADLET_OUT_DIR}"

caddy_tmp="$(mktemp "${CADDY_OUT_DIR}/.Caddyfile.XXXXXX")"
quadlet_tmp="$(mktemp "${QUADLET_OUT_DIR}/.t3code-caddy.container.XXXXXX")"
expanded_tmp="$(mktemp "${CADDY_OUT_DIR}/.expanded.XXXXXX")"
cleanup() {
	rm -f -- "${caddy_tmp}" "${quadlet_tmp}" "${expanded_tmp}"
}
trap cleanup EXIT

expand_template() {
	local template="$1"
	sed \
		-e "s|@@T3_DOMAIN@@|${T3_DOMAIN}|g" \
		-e "s|@@T3_PORT@@|${T3_PORT}|g" \
		-e "s|@@CADDY_IMAGE@@|${CADDY_IMAGE}|g" \
		-e "s|@@CADDY_HTTP_PORT@@|${CADDY_HTTP_PORT}|g" \
		-e "s|@@CADDY_HTTPS_PORT@@|${CADDY_HTTPS_PORT}|g" \
		"${template}"
}

expand_template "${TEMPLATE_DIR}/Caddyfile.tmpl" > "${expanded_tmp}"
while IFS= read -r line || [[ -n "${line}" ]]; do
	if [[ "${line}" == '@@SITE_BLOCKS@@' ]]; then
		first_site=1
		for user in "${USERS[@]}"; do
			upstream="t3code-${user}:${T3_PORT}"
			if (( first_site == 0 )); then
				printf '\n' >> "${caddy_tmp}"
			fi
			first_site=0
		sed \
				-e "s|@@USER@@|${user}|g" \
				-e "s|@@T3_DOMAIN@@|${T3_DOMAIN}|g" \
				-e "s|@@T3_PORT@@|${T3_PORT}|g" \
				-e "s|@@CADDY_HTTPS_PORT_SUFFIX@@|${CADDY_HTTPS_PORT_SUFFIX}|g" \
				-e "s|@@UPSTREAM@@|${upstream}|g" \
				"${TEMPLATE_DIR}/site.tmpl" >> "${caddy_tmp}"
		done
	else
		printf '%s\n' "${line}" >> "${caddy_tmp}"
	fi
done < "${expanded_tmp}"

expand_template "${TEMPLATE_DIR}/t3code-caddy.container.tmpl" > "${expanded_tmp}"
while IFS= read -r line || [[ -n "${line}" ]]; do
	if [[ "${line}" == '@@NETWORKS@@' ]]; then
		for user in "${USERS[@]}"; do
			printf 'Network=t3code-%s.network\n' "${user}" >> "${quadlet_tmp}"
		done
	else
		printf '%s\n' "${line}" >> "${quadlet_tmp}"
	fi
done < "${expanded_tmp}"

mv -f -- "${caddy_tmp}" "${CADDY_OUT_DIR}/Caddyfile"
mv -f -- "${quadlet_tmp}" "${QUADLET_OUT_DIR}/t3code-caddy.container"
printf 'Rendered %s and %s\n' \
	"${CADDY_OUT_DIR}/Caddyfile" \
	"${QUADLET_OUT_DIR}/t3code-caddy.container"
