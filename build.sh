#!/bin/bash
# Builds the UO Outlands AppImage
#
# Requirements on the host machine
#   wget or curl, tar (required)
#   ImageMagick (convert) required if icon download fails
#
# Usage
#   chmod +x build.sh && ./build.sh [OUTPUT_PATH]
#
#   OUTPUT_PATH  Optional path for the resulting AppImage
#                Can be a directory (AppImage placed inside it) or a full file path
#                Defaults to the project root

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APPDIR="$SCRIPT_DIR/AppDir"
SETTINGS_PATH="$SCRIPT_DIR/settings.conf"
LOCAL_SETTINGS_PATH="$SCRIPT_DIR/local_settings.conf"
PROJECT_CONSTANTS_PATH="$SCRIPT_DIR/constants/project.conf"

# shellcheck source=settings.conf
source "$SETTINGS_PATH"
# shellcheck disable=SC1090
[[ -f "$LOCAL_SETTINGS_PATH" ]] && source "$LOCAL_SETTINGS_PATH"
# shellcheck disable=SC1090
source "$PROJECT_CONSTANTS_PATH"

: "${appimage_file_name:=UO-Outlands}"
: "${app_id:=uooutlands}"
: "${release_arch:=x86_64}"
: "${release_version:=0.0.0}"
# Allow the caller to override the version without touching settings.conf
[[ -n "${RELEASE_VERSION:-}" ]] && release_version="$RELEASE_VERSION"

readonly EXIT_SUCCESS=0
readonly EXIT_ERROR=1

# = Output path resolution ===================================================
# Everything (AppImage, appimagetool, runtime, staging) is strictly confined to OUT_DIR
if [[ $# -ge 1 && -n "$1" ]]; then
	if [[ -d "$1" ]]; then
		# Caller passed an existing directory
		OUT_DIR="$(realpath "$1")"
		OUTPUT="$OUT_DIR/${appimage_file_name}-x86_64.AppImage"
	else
		# Caller passed a full file path (parent dir must exist)
		output_dir="$(dirname "$1")"
		[[ -d "$output_dir" ]] \
			|| { echo "ERROR: Output directory does not exist: $output_dir"; exit $EXIT_ERROR; }
		OUT_DIR="$(realpath "$output_dir")"
		OUTPUT="$OUT_DIR/$(basename "$1")"
	fi
else
	OUT_DIR="$SCRIPT_DIR"
	OUTPUT="$OUT_DIR/${appimage_file_name}-x86_64.AppImage"
fi

APPIMAGETOOL="$OUT_DIR/appimagetool-x86_64.AppImage"
APPIMAGETOOL_URL="https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage"

RUNTIME="$OUT_DIR/runtime-x86_64"
RUNTIME_URL="https://github.com/AppImage/type2-runtime/releases/download/continuous/runtime-x86_64"

# Static curl binary bundled into the AppImage so it has a download tool at runtime
CURL_BUNDLE="$OUT_DIR/bundled-curl"
CURL_BUNDLE_URL="https://github.com/moparisthebest/static-curl/releases/latest/download/curl-amd64"

# The staging dir lives inside OUT_DIR and is cleaned up on exit
STAGING_DIR="$OUT_DIR/.staging"
trap 'rm -rf "$STAGING_DIR"' EXIT

ICON_DEST="$STAGING_DIR/${app_id}.png"
ICON_DEST_HICOLOR="$STAGING_DIR/usr/share/icons/hicolor/256x256/apps/${app_id}.png"

# Candidate URLs for the UO Outlands icon (tried in order)
ICON_URLS=(
	"https://uooutlands.com/apple-touch-icon.png"
	"https://uooutlands.com/favicon-32x32.png"
	"https://uooutlands.com/favicon.png"
)

# = Helpers ==================================================================

print_step() { echo ""; echo "==> $*"; }
print_info() { echo "    $*"; }

copy_if_present() {
	local source_path="$1"
	local target_path="$2"
	[[ -e "$source_path" ]] || return 0
	mkdir -p "$(dirname "$target_path")"
	cp -a "$source_path" "$target_path"
}

# Read a single key from an unquoted lang file
read_lang_key() {
	local lang_file="$1" key="$2" line
	while IFS= read -r line; do
		[[ "$line" == "$key="* ]] || continue
		printf '%s' "${line#*=}"
		return
	done < "$lang_file"
}

# Download url to dest using wget or curl, whichever is available
fetch_url() {
	local url="$1" dest="$2"
	if command -v wget &>/dev/null; then
		wget -q --show-progress -O "$dest" "$url"
	else
		curl -fL --progress-bar -o "$dest" "$url"
	fi
}

# Return 0 if the SHA-256 of path matches expected, 1 otherwise
verify_sha256() {
	local path="$1" expected="$2" actual
	actual="$(sha256sum "$path" 2>/dev/null | cut -d' ' -f1)"
	[[ "$actual" == "$expected" ]]
}

copy_library_with_links() {
	local library_path="$1"
	local library_dir="$2"
	local resolved_library_path

	[[ -e "$library_path" ]] || return 0
	resolved_library_path="$(readlink -f "$library_path")"

	cp -a "$resolved_library_path" "$library_dir/"
	if [[ "$resolved_library_path" != "$library_path" ]]; then
		cp -a "$library_path" "$library_dir/"
	fi
}

bundle_zenity() {
	local zenity_path library_dir module_root wrapper_path
	local -a library_roots=()

	command -v zenity >/dev/null 2>&1 || {
		print_info "zenity not found on build host, skipping GUI bundling."
		return 0
	}

	zenity_path="$(command -v zenity)"
	library_dir="$STAGING_DIR/usr/lib/uooutlands-zenity"
	wrapper_path="$STAGING_DIR/usr/bin/zenity"

	mkdir -p \
		"$library_dir" \
		"$STAGING_DIR/usr/libexec/uooutlands" \
		"$(dirname "$wrapper_path")"
	cp -a "$zenity_path" "$STAGING_DIR/usr/libexec/uooutlands/zenity.real"

	while IFS= read -r library_path; do
		[[ -n "$library_path" ]] || continue
		case "$library_path" in
			/lib*/ld-linux-*|/lib*/libc.so.*|/lib*/libm.so.*|/lib*/libpthread.so.*|/lib*/libdl.so.*|/lib*/librt.so.*)
				continue
				;;
		esac
		copy_library_with_links "$library_path" "$library_dir"
	done < <(
		ldd "$zenity_path" \
			| awk '/=> \/|^\s*\// {
				for (field_index = 1; field_index <= NF; field_index++) {
					if ($field_index ~ /^\//) {
						print $field_index
					}
				}
			}'
	)

	for module_root in /usr/lib64 /usr/lib /usr/lib/x86_64-linux-gnu; do
		[[ -d "$module_root" ]] && library_roots+=("$module_root")
	done

	for module_root in "${library_roots[@]}"; do
		copy_if_present "$module_root/gio/modules" "$STAGING_DIR/usr/lib/gio/modules"
		copy_if_present "$module_root/gdk-pixbuf-2.0" "$STAGING_DIR/usr/lib/gdk-pixbuf-2.0"
		copy_if_present "$module_root/girepository-1.0" "$STAGING_DIR/usr/lib/girepository-1.0"
		copy_if_present "$module_root/gtk-4.0" "$STAGING_DIR/usr/lib/gtk-4.0"
		copy_if_present "$module_root/gstreamer-1.0" "$STAGING_DIR/usr/lib/gstreamer-1.0"
	done

	copy_if_present /usr/share/glib-2.0/schemas "$STAGING_DIR/usr/share/glib-2.0/schemas"
	if [[ -d "$STAGING_DIR/usr/share/glib-2.0/schemas" ]]; then
		# GTK4 requires the compiled gschemas.compiled file to find its settings.
		if command -v glib-compile-schemas &>/dev/null; then
			glib-compile-schemas "$STAGING_DIR/usr/share/glib-2.0/schemas"
		else
			echo "  WARNING: glib-compile-schemas not found; zenity may print schema warnings."
		fi
	fi
	copy_if_present /usr/share/icons/Adwaita "$STAGING_DIR/usr/share/icons/Adwaita"
	copy_if_present /usr/share/themes/Adwaita "$STAGING_DIR/usr/share/themes/Adwaita"

	cat > "$wrapper_path" <<'EOF'
#!/bin/bash
set -euo pipefail

APPDIR="${APPDIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
ZENITY_LIB_DIR="$APPDIR/usr/lib/uooutlands-zenity"

export LD_LIBRARY_PATH="$ZENITY_LIB_DIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export GSETTINGS_SCHEMA_DIR="$APPDIR/usr/share/glib-2.0/schemas"
export GI_TYPELIB_PATH="$APPDIR/usr/lib/girepository-1.0${GI_TYPELIB_PATH:+:$GI_TYPELIB_PATH}"
export GIO_MODULE_DIR="$APPDIR/usr/lib/gio/modules"
export GDK_PIXBUF_MODULEDIR="$APPDIR/usr/lib/gdk-pixbuf-2.0/2.10.0/loaders"
export GST_PLUGIN_SYSTEM_PATH="$APPDIR/usr/lib/gstreamer-1.0"
export XDG_DATA_DIRS="$APPDIR/usr/share${XDG_DATA_DIRS:+:$XDG_DATA_DIRS}"

exec "$APPDIR/usr/libexec/uooutlands/zenity.real" "$@"
EOF
	chmod +x "$wrapper_path"
	print_info "Bundled zenity and GTK runtime files."
}

# Hashes the prefix bytes and embeds a PGP detached signature into the AppImage
sign_image() {
	local appimage="$1"
	local key="$2"
	local sig_file section_info sig_offset sig_size sig_len

	print_info "Signing AppImage…"

	section_info=$(readelf -S "$appimage" \
		| awk '/\.sha256_sig/{f=1;o=$5;next} f{print o" "$1;f=0}')
	sig_offset=$(( 16#$(cut -d' ' -f1 <<< "$section_info") ))
	sig_size=$(( 16#$(cut -d' ' -f2 <<< "$section_info") ))

	local digest
	digest=$(dd if="$appimage" bs=1 count="$sig_offset" 2>/dev/null \
		| sha256sum | cut -d' ' -f1)

	sig_file=$(mktemp)
	local gpg_pass_args=()
	if [[ -v GPG_PASSPHRASE ]]; then
		exec 3<<<"${GPG_PASSPHRASE:-}"
		gpg_pass_args=(--pinentry-mode loopback --passphrase-fd 3)
	fi
	printf '%s' "$digest" | xxd -r -p \
		| gpg --batch --yes "${gpg_pass_args[@]}" \
			--detach-sign --armor -u "$key" --output "$sig_file"
	exec 3<&- 2>/dev/null || true

	sig_len=$(wc -c < "$sig_file")
	if [[ "$sig_len" -gt "$sig_size" ]]; then
		rm -f "$sig_file"
		echo "ERROR: signature ($sig_len bytes) exceeds section size ($sig_size bytes)."
		exit $EXIT_ERROR
	fi

	dd if="$sig_file" of="$appimage" bs=1 seek="$sig_offset" \
		conv=notrunc 2>/dev/null

	rm -f "$sig_file"
	print_info "AppImage signed."
}

# = Preflight ================================================================

print_step "Checking dependencies"

if ! command -v tar &>/dev/null; then
	echo "ERROR: 'tar' is required but not installed."
	exit $EXIT_ERROR
fi
if ! command -v wget &>/dev/null && ! command -v curl &>/dev/null; then
	echo "ERROR: 'wget' or 'curl' is required but neither is installed."
	exit $EXIT_ERROR
fi

# = Staging dir ==============================================================

print_step "Preparing staging directory"
cp -a "$APPDIR" "$STAGING_DIR"
chmod +x "$STAGING_DIR/AppRun"
mkdir -p "$STAGING_DIR/usr/share/$app_id"
cp "$PROJECT_CONSTANTS_PATH" "$STAGING_DIR/usr/share/$app_id/project.conf"
mkdir -p "$STAGING_DIR/usr/share/$app_id/lang"
cp "$SCRIPT_DIR"/lang/*.conf "$STAGING_DIR/usr/share/$app_id/lang/"

# Build the desktop file from the lang files and include a Comment per language
{
	base_comment="$(read_lang_key "$SCRIPT_DIR/lang/en.conf" app_comment)"
	printf '[Desktop Entry]\nType=Application\nName=Ultima Online: Outlands\n'
	printf 'GenericName=Ultima Online: Outlands\n'
	printf 'Comment=%s\n' "$base_comment"
	printf 'Exec=AppRun\nIcon=uooutlands\n'
	printf 'Categories=Game;RolePlaying;\n'
	printf 'Keywords=uo;outlands;ultima;online;mmorpg;roleplay;\n'
	printf 'Terminal=false\nStartupNotify=true\n'
	for _lang_file in "$SCRIPT_DIR"/lang/*.conf; do
		_lang_code="$(basename "${_lang_file%.conf}")"
		[[ "$_lang_code" == "en" ]] && continue
		_lang_comment="$(read_lang_key "$_lang_file" app_comment)"
		[[ -n "$_lang_comment" ]] \
			&& printf 'Comment[%s]=%s\n' "$_lang_code" "$_lang_comment"
	done
} > "$STAGING_DIR/uooutlands.desktop"
mkdir -p "$STAGING_DIR/usr/share/applications"
cp "$STAGING_DIR/uooutlands.desktop" \
	"$STAGING_DIR/usr/share/applications/uooutlands.desktop"

# Generate AppStream metainfo so software centres and AppImage tooling can index this
mkdir -p "$STAGING_DIR/usr/share/metainfo"
{
	local_summary="$(read_lang_key "$SCRIPT_DIR/lang/en.conf" app_comment)"
	local_summary="${local_summary%.}"
	local_date="$(date +%Y-%m-%d)"
	printf '<?xml version="1.0" encoding="UTF-8"?>\n'
	printf '<component type="desktop-application">\n'
	printf '  <id>com.uooutlands.UOOutlands</id>\n'
	printf '  <name>UO Outlands</name>\n'
	printf '  <summary>%s</summary>\n' "$local_summary"
	printf '  <description><p>%s</p></description>\n' "$local_summary"
	printf '  <launchable type="desktop-id">uooutlands.desktop</launchable>\n'
	printf '  <metadata_license>MIT</metadata_license>\n'
	printf '  <project_license>LicenseRef-proprietary</project_license>\n'
	printf '  <url type="homepage">https://uooutlands.com</url>\n'
	printf '  <releases>\n'
	printf '    <release version="%s" date="%s"/>\n' "$release_version" "$local_date"
	printf '  </releases>\n'
	printf '</component>\n'
} > "$STAGING_DIR/usr/share/metainfo/com.uooutlands.UOOutlands.appdata.xml"

# Inject the bundled curl binary so the AppImage can download without system dependencies
if [[ -f "$CURL_BUNDLE" ]]; then
	mkdir -p "$STAGING_DIR/usr/bin"
	cp "$CURL_BUNDLE" "$STAGING_DIR/usr/bin/curl"
	chmod +x "$STAGING_DIR/usr/bin/curl"
	print_info "Bundled curl injected into staging."

	# Bundle CA certificates alongside curl so HTTPS works without system certs.
	ca_cert_source=""
	for _ca in /etc/ssl/certs/ca-certificates.crt \
				/etc/pki/tls/certs/ca-bundle.crt \
				/etc/ssl/ca-bundle.pem \
				/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem; do
		[[ -f "$_ca" ]] && { ca_cert_source="$_ca"; break; }
	done
	if [[ -n "$ca_cert_source" ]]; then
		mkdir -p "$STAGING_DIR/etc/ssl/certs"
		cp "$ca_cert_source" "$STAGING_DIR/etc/ssl/certs/ca-certificates.crt"
		print_info "Bundled CA certificates from: $ca_cert_source"
	else
		echo "  WARNING: No CA certificate bundle found on this machine."
		echo "           HTTPS downloads inside the AppImage may fail."
	fi
fi

print_info "Staging dir: $STAGING_DIR"

# = appimagetool =============================================================

print_step "Checking appimagetool"

if [[ -f "$APPIMAGETOOL" ]] && ! verify_sha256 "$APPIMAGETOOL" "$appimagetool_sha256"; then
	print_info "Cached appimagetool hash mismatch, re-downloading…"
	rm -f "$APPIMAGETOOL"
fi
if [[ ! -f "$APPIMAGETOOL" ]]; then
	print_info "Downloading appimagetool…"
	fetch_url "$APPIMAGETOOL_URL" "$APPIMAGETOOL"
	file "$APPIMAGETOOL" | grep -qiE 'ELF|AppImage' \
		|| { rm -f "$APPIMAGETOOL"; echo "ERROR: appimagetool download is not a valid binary."; exit $EXIT_ERROR; }
	verify_sha256 "$APPIMAGETOOL" "$appimagetool_sha256" \
		|| { rm -f "$APPIMAGETOOL"; echo "ERROR: appimagetool hash mismatch. Update appimagetool_sha256 in constants/project.conf to upgrade."; exit $EXIT_ERROR; }
	chmod +x "$APPIMAGETOOL"
	print_info "appimagetool downloaded."
else
	print_info "appimagetool already present, skipping download."
fi

if [[ -f "$RUNTIME" ]] && ! verify_sha256 "$RUNTIME" "$runtime_sha256"; then
	print_info "Cached runtime hash mismatch, re-downloading…"
	rm -f "$RUNTIME"
fi
if [[ ! -f "$RUNTIME" ]]; then
	print_info "Downloading AppImage runtime…"
	fetch_url "$RUNTIME_URL" "$RUNTIME"
	file "$RUNTIME" | grep -qi 'ELF' \
		|| { rm -f "$RUNTIME"; echo "ERROR: runtime download is not a valid ELF binary."; exit $EXIT_ERROR; }
	verify_sha256 "$RUNTIME" "$runtime_sha256" \
		|| { rm -f "$RUNTIME"; echo "ERROR: runtime hash mismatch. Update runtime_sha256 in constants/project.conf to upgrade."; exit $EXIT_ERROR; }
	print_info "Runtime downloaded."
else
	print_info "Runtime already present, skipping download."
fi

print_step "Bundling curl"

if [[ -f "$CURL_BUNDLE" ]] && ! verify_sha256 "$CURL_BUNDLE" "$curl_bundle_sha256"; then
	print_info "Cached bundled-curl hash mismatch, re-downloading…"
	rm -f "$CURL_BUNDLE"
fi
if [[ ! -f "$CURL_BUNDLE" ]]; then
	print_info "Downloading static curl to bundle into the AppImage…"
	if fetch_url "$CURL_BUNDLE_URL" "$CURL_BUNDLE.tmp" 2>/dev/null \
			&& [[ -s "$CURL_BUNDLE.tmp" ]]; then
		verify_sha256 "$CURL_BUNDLE.tmp" "$curl_bundle_sha256" \
			|| { rm -f "$CURL_BUNDLE.tmp"; echo "ERROR: bundled-curl hash mismatch. Update curl_bundle_sha256 in constants/project.conf to upgrade."; exit $EXIT_ERROR; }
		mv "$CURL_BUNDLE.tmp" "$CURL_BUNDLE"
		chmod +x "$CURL_BUNDLE"
		print_info "Bundled: $("$CURL_BUNDLE" --version | head -1)"
	else
		rm -f "$CURL_BUNDLE.tmp"
		echo ""
		echo "  WARNING: Could not download static curl for bundling."
		echo "           The AppImage will require curl or wget on the user's system."
	fi
else
	print_info "Already cached: $("$CURL_BUNDLE" --version | head -1 | cut -d' ' -f1-3)"
fi

# = Icon =====================================================================

print_step "Preparing icon"

if [[ ! -f "$ICON_DEST" ]]; then
	icon_is_valid=false

	print_info "Trying to download icon from official sources…"
	for url in "${ICON_URLS[@]}"; do
		if fetch_url "$url" "$ICON_DEST" 2>/dev/null; then
			# Verify the downloaded file is actually an image.
			if file "$ICON_DEST" 2>/dev/null | grep -qiE 'PNG|JPEG|image data'; then
				print_info "Downloaded icon from: $url"
				icon_is_valid=true
				break
			fi
			# Not a valid image. Discard it and try the next URL.
			rm -f "$ICON_DEST"
		fi
	done

	if ! $icon_is_valid; then
		print_info "Could not download an icon from any known URL."
		if command -v convert &>/dev/null; then
			print_info "Generating placeholder icon with ImageMagick…"
			convert -size 256x256 \
				gradient:"#1a0905-#4a200e" \
				-fill "#c8a84b" -stroke "#1a0905" -strokewidth 2 \
				-font "DejaVu-Sans-Bold" -pointsize 32 \
				-gravity center -annotate 0 "UO\nOutlands" \
				"$ICON_DEST"
			print_info "Placeholder icon created at: AppDir/uooutlands.png"
		else
			echo "ERROR: Icon download failed and ImageMagick is not installed."
			echo "       Place a 256x256 PNG at AppDir/uooutlands.png and re-run."
			exit $EXIT_ERROR
		fi
	fi
else
	print_info "Icon already present, skipping."
fi

# Copy icon into the standard XDG hicolor tree so desktop environments pick it up
mkdir -p "$(dirname "$ICON_DEST_HICOLOR")"
cp -f "$ICON_DEST" "$ICON_DEST_HICOLOR"
print_info "Icon copied to usr/share/icons/hicolor/256x256/apps/."

print_step "Bundling zenity"
bundle_zenity

# = Build AppImage ===========================================================

print_step "Building AppImage"
print_info "Source: $STAGING_DIR"
print_info "Output: $OUTPUT"

appimagetool_args=(--runtime-file "$RUNTIME")
# Embed update information when the caller provides it (used by release builds)
[[ -n "${UPDATE_INFO:-}" ]] && appimagetool_args+=(-u "$UPDATE_INFO")
ARCH="$release_arch" VERSION="$release_version" "$APPIMAGETOOL" "${appimagetool_args[@]}" "$STAGING_DIR" "$OUTPUT"
chmod 0755 "$OUTPUT"
# Sign after build so only .sha256_sig is patched, not .sig_key
[[ -n "${SIGN_KEY:-}" ]] && sign_image "$OUTPUT" "$SIGN_KEY"

# = Done =====================================================================

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║                  Build complete!                         ║"
echo "╠══════════════════════════════════════════════════════════╣"
printf  "║  %-56s ║\n" "Dir:    $OUT_DIR"
printf  "║  %-56s ║\n" "Output: $(basename "$OUTPUT")"
echo "╚══════════════════════════════════════════════════════════╝"

exit $EXIT_SUCCESS
