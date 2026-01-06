#!/usr/bin/env bash
set -euo pipefail

################################################################################
# Posit Package Manager base install (Ubuntu 24.04)
# - R (multi-version)
# - Python via uv (multi-version)
# - Posit Package Manager (PPM)
################################################################################

# ----------------------------
# Versions (EDIT THESE)
# ----------------------------

# Install ALL versions listed here
R_VERSIONS=(
  "4.5.2"
  "4.4.3"
)

PYTHON_VERSIONS=(
  "3.12.4"
  "3.11.9"
)

QUARTO_VERSIONS=(
  "1.8.25"
  "1.7.12"
)

# PPM server version
PPM_VERSION="2025.12.0-14"

# Pro Drivers version
PRO_DRIVERS_VERSION_DEB="2025.07.0" 
PRO_DRIVERS_INSTALLER_ID="7C152C12" 
 

# ----------------------------
# Constants (Ubuntu 24.04)
# ----------------------------
CREATE_R_SYMLINKS=true         
CREATE_QUARTO_SYMLINK=true     
CREATE_PYTHON_PROFILED=true   
UBUNTU_R_BASE_URL="https://cdn.posit.co/r/ubuntu-2404/pkgs"
PPM_BASE_URL="https://dl.posit.co/public/pro/deb/ubuntu/pool/noble/main/r/rs"

UV_INSTALL_DIR="/usr/local/bin"
PYTHON_INSTALL_ROOT="/opt/python"
QUARTO_INSTALL_ROOT="/opt/quarto"

WORKDIR="/tmp/posit-installer"
mkdir -p "$WORKDIR"

log() { echo "[$(date -Is)] $*"; }

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "ERROR: Please run as root (or via sudo)."
    exit 1
  fi
}

detect_arch() {
  local dpkg_arch
  dpkg_arch="$(dpkg --print-architecture)"
  case "$dpkg_arch" in
    amd64) echo "amd64" ;;
    arm64) echo "arm64" ;;
    *)
      echo "ERROR: Unsupported architecture: $dpkg_arch"
      exit 1
      ;;
  esac
}

quarto_asset_arch() {
  local a="$1"
  case "$a" in
    amd64) echo "linux-amd64" ;;
    arm64) echo "linux-arm64" ;;
    *) echo "ERROR: Unsupported arch for quarto: $a"; exit 1 ;;
  esac
}

# Use `apt install ./file.deb` (supports local paths), and fall back to dpkg if needed.
install_local_deb() {
  local deb_path="$1"

  if [[ ! -f "$deb_path" ]]; then
    echo "ERROR: local deb not found: $deb_path"
    exit 1
  fi

  log "Installing local deb: $deb_path"
  apt-get update -y

  # Preferred path on Ubuntu/Debian
  if apt install -y "$deb_path"; then
    return 0
  fi

  # Fallback: dpkg then fix dependencies
  log "apt install failed; falling back to dpkg -i + apt-get -f install"
  dpkg -i "$deb_path" || true
  apt-get -f install -y
}

apt_install_base_deps() {
  log "Installing base dependencies..."
  apt-get update -y
  apt-get install -y --no-install-recommends \
    ca-certificates curl gnupg tar xz-utils \
    unixodbc unixodbc-dev \
    odbcinst
}

install_r_versions() {
  local arch="$1"
  log "Installing R versions: ${R_VERSIONS[*]}"

  for ver in "${R_VERSIONS[@]}"; do
    local deb="r-${ver}_1_${arch}.deb"
    local url="${UBUNTU_R_BASE_URL}/${deb}"

    log "Downloading R ${ver} from: ${url}"
    (cd "$WORKDIR" && curl -fLO "$url")

    log "Installing R ${ver}..."
    install_local_deb "${WORKDIR}/${deb}"

    log "Verifying R ${ver}..."
    "/opt/R/${ver}/bin/R" --version >/dev/null
  done

  if [[ "$CREATE_R_SYMLINKS" == "true" ]]; then
    if [[ ! -e /usr/local/bin/R && ! -e /usr/local/bin/Rscript ]]; then
      local first="${R_VERSIONS[0]}"
      log "Creating /usr/local/bin/R and Rscript symlinks -> /opt/R/${first}/bin/*"
      ln -s "/opt/R/${first}/bin/R" /usr/local/bin/R
      ln -s "/opt/R/${first}/bin/Rscript" /usr/local/bin/Rscript
    else
      log "Skipping R symlink creation (already exists)."
    fi
  fi
}

install_uv() {
  log "Installing uv to ${UV_INSTALL_DIR}..."
  if command -v "${UV_INSTALL_DIR}/uv" >/dev/null 2>&1; then
    log "uv already present at ${UV_INSTALL_DIR}/uv; skipping."
    return 0
  fi

  curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR="${UV_INSTALL_DIR}" sh
  "${UV_INSTALL_DIR}/uv" --version >/dev/null
}

install_python_versions() {
  log "Installing Python versions via uv: ${PYTHON_VERSIONS[*]}"
  mkdir -p "$PYTHON_INSTALL_ROOT"

  for ver in "${PYTHON_VERSIONS[@]}"; do
    log "Installing Python ${ver} into ${PYTHON_INSTALL_ROOT}..."
    "${UV_INSTALL_DIR}/uv" python install "${ver}" --install-dir="${PYTHON_INSTALL_ROOT}"

    local target
    target="$(ls -d "${PYTHON_INSTALL_ROOT}/cpython-${ver}-"* 2>/dev/null | head -n 1 || true)"
    if [[ -z "$target" ]]; then
      echo "ERROR: Could not find installed cpython directory for ${ver} in ${PYTHON_INSTALL_ROOT}"
      exit 1
    fi

    log "Symlinking ${PYTHON_INSTALL_ROOT}/${ver} -> ${target}"
    ln -sfn "${target}" "${PYTHON_INSTALL_ROOT}/${ver}"

    log "Verifying Python ${ver}..."
    "${PYTHON_INSTALL_ROOT}/${ver}/bin/python" --version >/dev/null
  done

  if [[ "$CREATE_PYTHON_PROFILED" == "true" ]]; then
    local first="${PYTHON_VERSIONS[0]}"
    log "Writing /etc/profile.d/python.sh to add Python ${first} to PATH..."
    cat > /etc/profile.d/python.sh <<EOF
#!/usr/bin/env bash
export PATH=${PYTHON_INSTALL_ROOT}/${first}/bin:\$PATH
EOF
    chmod 0644 /etc/profile.d/python.sh
  fi
}


install_ppm() {
  local arch="$1"
  log "Installing Posit Package Manager (PPM) ${PPM_VERSION}..."

  local deb="rstudio-pm_${PPM_VERSION}_${arch}.deb"
  local url="${PPM_BASE_URL}/rstudio-pm_${PPM_VERSION}/${deb}"

  log "Downloading PPM from: ${url}"
  (cd "$WORKDIR" && curl -fLO "$url")

  log "Installing PPM..."
  install_local_deb "${WORKDIR}/${deb}"

  log "Enabling and starting rstudio-pm service..."
  systemctl daemon-reload
  systemctl enable --now rstudio-pm || true

  log "PPM status:"
  systemctl --no-pager --full status rstudio-pm || true
}

smoke_tests() {
  log "Running quick smoke tests..."

  log "R versions:"
  for v in "${R_VERSIONS[@]}"; do
    "/opt/R/${v}/bin/R" --version | head -n 2
  done

  log "Python versions:"
  for v in "${PYTHON_VERSIONS[@]}"; do
    "${PYTHON_INSTALL_ROOT}/${v}/bin/python" --version
  done


  log "Package Manager service + listener (default port 4242):"
  systemctl is-active rstudio-pm || true
  ss -lntp | grep 4242 || true

  log "Connect HTTP check (local):"
  curl -sS -o /dev/null -w "HTTP %{http_code}\n" http://127.0.0.1:4242/ || true

  log "Smoke tests complete."
}

main() {
  require_root
  local arch
  arch="$(detect_arch)"
  log "Detected architecture: ${arch}"

  apt_install_base_deps
  install_r_versions "$arch"
  install_uv
  install_python_versions
  install_ppm "$arch"
  
  smoke_tests

  log "DONE."
  log "R: /opt/R/<version>"
  log "Python: /opt/python/<version>"
  log "Package Manager: http://<host>:4242"
}

main "$@"
