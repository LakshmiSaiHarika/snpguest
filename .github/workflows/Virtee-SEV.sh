#!/bin/bash
usage() {
  >&2 echo "Usage: $0  [COMMAND]"
  >&2 echo "  where COMMAND must be one of the following:"
  >&2 echo "    install-snp-on-the-host            Build required SNP components and set up host with latest SNP kernel"
  >&2 echo "    reboot-host                        Reboot the server"
  >&2 echo "    verify-snp-on-host                 Verify if SNP is enabled in Server BIOS before Virtee CI test"
  >&2 echo "    test-sev-on-host                   Perform Virtee SEV test on the host"
  >&2 echo "    test-sev-on-guest                  Perform Virtee SEV test on the guest"
  return 1
}

install_snp_on_the_host () {
  # Install upstream/stable (6.11.rc5)
  wget https://raw.githubusercontent.com/LakshmiSaiHarika/sev-utils/Latest-SNP-Kernel-Upstream/tools/snp.sh
  chmod +x snp.sh

  ./snp.sh setup-host
}

# 3. Test if SNP is enabled
verify_snp_host() {

  local AMDSEV_URL="https://github.com/LakshmiSaiHarika/AMDSEV.git"
  local AMDSEV_DEFAULT_BRANCH="build-and-install-kernel-upstream"


  if ! sudo dmesg | grep -i "SEV-SNP enabled" 2>&1 >/dev/null; then
    echo -e "SEV-SNP not enabled on the host. Please follow these steps to enable:\n\
    $(echo "${AMDSEV_URL}" | sed 's|\.git$||g')/tree/${AMDSEV_DEFAULT_BRANCH}#prepare-host"
    return 1
  fi
}

install_rust() {
  source "${HOME}/.cargo/env" 2>/dev/null || true

  if which rustc 2>/dev/null 1>&2; then
    echo -e "Rust previously installed"
    return 0
  fi

  sudo apt install cargo

  # Install rust
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs -sSf | sh -s -- -y
  source "${HOME}/.cargo/env" 2>/dev/null
}

# Test SEV host library
test_SEV_on_host () {

  # Clone sev
  sudo git clone https://github.com/virtee/sev.git
  cd sev

  # Install rust
  $(install_rust)

  # Run sev cargo test
  sudo cargo test 
}

ssh_guest_command() {
  [ -n "${1}" ] || { >&2 echo -e "No guest command specified"; return 1; }

  # Remove fail on error
  set +eE; set +o pipefail

  {
    IFS=$'\n' read -r -d '' CAPTURED_STDERR;
    IFS=$'\n' read -r -d '' CAPTURED_STDOUT;
    (IFS=$'\n' read -r -d '' _ERRNO_; return ${_ERRNO_});
  } < <((printf '\0%s\0%d\0' "$(ssh -p 10022 \
    -i ${HOME}/snp/launch/snp-guest-key \
    -o "StrictHostKeyChecking no" \
    -o "PasswordAuthentication=no" \
    -o ConnectTimeout=1 \
    -t amd@localhost \
    "${1}")" "${?}" 1>&2) 2>&1)

  local return_code=$?

  # Reset fail on error
  set -eE; set -o pipefail

  [[ $return_code -eq 0 ]] \
    || { >&2 echo "${CAPTURED_STDOUT}"; >&2 echo "${CAPTURED_STDERR}"; return ${return_code}; }
  echo "${CAPTURED_STDOUT}"
}

verify_snp_guest() {
  # Exit if SSH private key does not exist
  local GUEST_SSH_KEY_PATH="${HOME}/snp/launch/snp-guest-key"
  if [ ! -f "${GUEST_SSH_KEY_PATH}" ]; then
    >&2 echo -e "SSH key not present [${GUEST_SSH_KEY_PATH}], cannot verify guest SNP enabled"
    return 1
  fi

  # Look for SNP enabled in guest dmesg output
  local snp_dmesg_grep_text="Memory Encryption Features active:.*SEV-SNP"
  local snp_enabled=$(ssh_guest_command "sudo dmesg | grep \"${snp_dmesg_grep_text}\"")

  [[ -n "${snp_enabled}" ]] \
    && { echo "DMESG REPORT: ${snp_enabled}"; echo -e "SNP is Enabled"; } \
    || { >&2 echo -e "SNP is NOT Enabled"; return 1; }
}

# Launch and test the guest library
test_SEV_on_guest () {

  # Launch SNP guest using snp script
  ./snp.sh launch-guest
  verify_snp_guest  

  # Install sev dependencies as a root user
  ssh_guest_command "sudo su - <<EOF
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs -sSf | sh -s -- -y
source "${HOME}/.cargo/env" 2>/dev/null
sudo dnf install -y git gcc
EOF"

  # Clone and test sev library as root user to fix OS permission denied issues
  ssh_guest_command "sudo su - <<EOF
git clone https://github.com/virtee/sev.git
cd ~/sev && cargo test
EOF"
}

# test_SEV_on_guest

main() {
  # A command must be specified
  if [ -z "${1}" ]; then
    usage
    return 1
  fi
  
  # Parse command args and options
  while [ -n "${1}" ]; do
    case "${1}" in

      install-snp-on-the-host)
        COMMAND="install-snp-on-the-host"
        shift
        ;;

      reboot-host)
        COMMAND="reboot-host"
        shift
        ;;

      verify-snp-on-host)
        COMMAND="verify-snp-on-host"
        shift
        ;;

      test-sev-on-host)
        COMMAND="test-sev-on-host"
        shift
        ;;

      test-sev-on-guest)
        COMMAND="test-sev-on-guest"
        shift
        ;;

      -*|--*)
        >&2 echo -e "Unsupported Option: [${1}]\n"
        usage
        return 1
        ;;

      *)
        >&2 echo -e "Unsupported Command: [${1}]\n"
        usage
        return 1
        ;;
    esac
  done


  # Execute command
  case "${COMMAND}" in
    help)
      usage
      return 1
      ;;

    install-snp-on-the-host)
      install_snp_on_the_host
      echo -e "\nThe host must be rebooted for changes to take effect"
      ;;

    reboot-host)
      sudo reboot
      ;;

    verify-snp-on-host)
      verify_snp_host
      ;;

    test-sev-on-host)
      test_SEV_on_host
      ;;

    test-sev-on-guest)
      test_SEV_on_guest
      ;;

    *)
      >&2 echo -e "Unsupported Command: [${1}]\n"
      usage
      return 1
      ;;
  esac
}


main "${@}"

# CLI to use each step in GH Action Script
  # install_snp_on_the_host
  # verify_snp_host
  # test_SEV_on_host

# GH Actions Flow to execute
  # install_snp_on_the_host
  # Reboot
  # verify_snp_host
  # test_SEV_on_host
