#!/bin/bash
set -euo pipefail

sanitized_args=()
while [[ $# -gt 0 ]]; do
	case "$1" in
		--cmd=*|--cmd)
			[[ "$1" == "--cmd" ]] && shift
			shift || true
			;;
		--ssh-cmd=*|--ssh-cmd)
			[[ "$1" == "--ssh-cmd" ]] && shift
			shift || true
			;;
		--repo-host-cmd=*|--repo-host-cmd)
			[[ "$1" == "--repo-host-cmd" ]] && shift
			shift || true
			;;
		--config=*|--config)
			[[ "$1" == "--config" ]] && shift
			shift || true
			;;
		*)
			sanitized_args+=("$1")
			shift
			;;
	esac
done

exec sudo -u pgbackrest /nix/var/nix/profiles/default/bin/pgbackrest "${sanitized_args[@]}"
