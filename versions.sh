#!/usr/bin/env bash
set -Eeuo pipefail

cd "$(dirname "$(readlink -f "$BASH_SOURCE")")"

versions=( "$@" )
if [ ${#versions[@]} -eq 0 ]; then
	versions=( */ )
	json='{}'
else
	json="$(< versions.json)"
fi
versions=( "${versions[@]%/}" )

bashbrew --version > /dev/null
tempDir="$(mktemp -d)"
trap 'rm -rf "$tempDir"' EXIT
_bashbrew_list() {
	local image="$1"
	local repo="${image%:*}"
	local f="$tempDir/$repo"
	if [ ! -s "$f" ]; then
		wget -O "$f" "https://github.com/docker-library/official-images/raw/master/library/$repo"
	fi
	bashbrew --library "$tempDir" list --uniq "$image"
}

allVariants='[]'
for javaVersion in 17 11 8; do
	# Eclipse Temurin, followed by OpenJDK, and then all other variants alphabetically
	for vendorVariant in \
		temurin-focal \
		openjdk{,-slim}-{bullseye,buster} \
		corretto \
	; do
		for javaVariant in {jdk,jre}"$javaVersion"; do
			export variant="$javaVariant/$vendorVariant"
			if image="$(jq -nr '
				include "from";
				from
			' 2>/dev/null)" && _bashbrew_list "$image" &> /dev/null; then
				allVariants="$(jq <<<"$allVariants" -c '. + [env.variant]')"
			fi
		done
	done
done
export allVariants

for version in "${versions[@]}"; do
	majorVersion="${version%%.*}"

	possibleVersions="$(
		curl -fsSL --compressed "https://downloads.apache.org/tomcat/tomcat-$majorVersion/" \
			| grep '<a href="v'"$version." \
			| sed -r 's!.*<a href="v([^"/]+)/?".*!\1!' \
			| sort -rV
	)"
	fullVersion=
	sha512=
	for possibleVersion in $possibleVersions; do
		if possibleSha512="$(
			curl -fsSL "https://downloads.apache.org/tomcat/tomcat-$majorVersion/v$possibleVersion/bin/apache-tomcat-$possibleVersion.tar.gz.sha512" \
				| cut -d' ' -f1
		)" && [ -n "$possibleSha512" ]; then
			fullVersion="$possibleVersion"
			sha512="$possibleSha512"
			break
		fi
	done
	if [ -z "$fullVersion" ]; then
		echo >&2 "error: failed to find latest release for $version"
		exit 1
	fi

	echo "$version: $fullVersion ($sha512)"

	export version fullVersion sha512
	json="$(jq <<<"$json" -c '
		.[env.version] = {
			version: env.fullVersion,
			sha512: env.sha512,
			variants: (
				env.allVariants | fromjson
				| (env.version | tonumber) as $major
				| map(select(
					split("/")[0]
					| ltrimstr("jdk") | ltrimstr("jre")
					| tonumber
					# http://tomcat.apache.org/whichversion.html  ("Supported Java Versions")
					| if $major >= 10.1 then
						. >= 11
					elif $major >= 9.0 then
						. >= 8
					else
						. >= 7
					end
				))
			),
		}
	')"
done

jq <<<"$json" -S . > versions.json
