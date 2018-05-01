#!/usr/bin/env bash
###########################
## Default configuration ##
###########################
DUPLICITEASY_DEFAULT_CONFIG_FILE="~/dupliciteasy/dupliciteasy.conf"

###########################
######## Functions ########
###########################
unset_variables()
{
    unset DUPLICITY_SOURCE
    unset DUPLICITY_SOURCE_INCLUDE
    unset DUPLICITY_TARGET_SCHEME
    unset DUPLICITY_REMOTE_HOST
    unset DUPLICITY_REMOTE_USER
    unset DUPLICITY_REMOTE_PATH
    unset DUPLICITY_TARGET
    unset DUPLICITY_FLAGS_EXT
    unset DUPLICITY_LOG_FILE
}

load_config()
{
    unset_variables; # Clear variables
    . "${1}" # Source configuration file
}

###########################
#### Get configuration ####
###########################
# Get main configuration file from parameter or use the default
if [ -n "${1}" ]; then
    DUPLICITEASY_CONFIG_FILE="${1}"
else
    DUPLICITEASY_CONFIG_FILE="${DUPLICITEASY_DEFAULT_CONFIG_FILE}"
fi

if ! [ -f "${DUPLICITEASY_CONFIG_FILE}" ]; then
    echo "Main configuration file '${DUPLICITEASY_CONFIG_FILE}' missing"
    exit 1
fi

# Source main configuration file
. "${DUPLICITEASY_CONFIG_FILE}"

###########################
###### Sanity checks ######
###########################
SANITY_CHECK_ERRORS=()

# Check main configration file permissions
if [ -n "${SIGN_PASSPHRASE}" ] || [ -n "${PASSPHRASE}" ]; then
    CONF_FILE_PERMISSIONS=$(stat -c %a "${DUPLICITEASY_CONFIG_FILE}" | cut -c 2-)
    if [ "$CONF_FILE_PERMISSIONS" != "00" ]; then
        SANITY_CHECK_ERRORS+=("Permissions 'x${CONF_FILE_PERMISSIONS}' are too open for configuration file containing GPG passphrase(s)")
    fi
fi

# Check configuration directory and files
if ! [ -d "${DUPLICITEASY_CONFIG_DIR}" ]; then
    SANITY_CHECK_ERRORS+=("Configuration directory '${DUPLICITEASY_CONFIG_DIR}' does not exist")
else
    CONF_FILE_COUNT=$(ls -1q "${DUPLICITEASY_CONFIG_DIR}"/*.conf 2> /dev/null | wc -l)
    if [ "${CONF_FILE_COUNT}" -eq 0 ]; then
        SANITY_CHECK_ERRORS+=("No configration files found")
    fi
fi

# Check GPG signing key
if [ -z "${DUPLICITY_SIGN_KEY}" ]; then
    SANITY_CHECK_ERRORS+=("Signing key is not configured")
else
    if ! gpg --list-secret-keys "${DUPLICITY_SIGN_KEY}" > /dev/null 2>&1; then
        SANITY_CHECK_ERRORS+=("Private key '${DUPLICITY_SIGN_KEY}' for signing is missing")
    fi
fi

# Check GPG encryption keys
if [ ${#DUPLICITY_ENCRYPT_KEYS[@]} -eq 0 ]; then
    SANITY_CHECK_ERRORS+=("Encryption key is not configured")
else
    for enc_key in "${DUPLICITY_ENCRYPT_KEYS[@]}"; do
        if ! gpg --list-keys "${enc_key}" > /dev/null 2>&1; then
            SANITY_CHECK_ERRORS+=("Public key '${enc_key}' for encryption is missing")
        fi
    done
fi

# Check log Configuration
if [ -n "${DUPLICITY_LOG_DIR}" ]; then
    if ! [ -d "${DUPLICITY_LOG_DIR}" ]; then
        SANITY_CHECK_ERRORS+=("Log directory '${DUPLICITY_LOG_DIR}' does not exist")
    fi
fi

for conf_file in "${DUPLICITEASY_CONFIG_DIR}"/*; do
    # Source configuration file
    load_config "${conf_file}"

    # Check target configuration
    if [ -z "${DUPLICITY_TARGET_SCHEME}" ] || [ -z "${DUPLICITY_REMOTE_PATH}" ]; then
        SANITY_CHECK_ERRORS+=("${conf_file}: Target configuration incomplete")
    elif [ "${DUPLICITY_TARGET_SCHEME}" = "scp" ] || [ "${DUPLICITY_TARGET_SCHEME}" = "rsync" ]; then
        # Check ssh connection to host
        if ! ssh -q -o PasswordAuthentication=no "${DUPLICITY_REMOTE_USER}@${DUPLICITY_REMOTE_HOST}" exit; then
            SANITY_CHECK_ERRORS+=("${conf_file}: A problem occured when connecting to ${DUPLICITY_REMOTE_USER}@${DUPLICITY_REMOTE_HOST}")
        fi
    fi

    # Check included files and directories
    if ! [ -d "${DUPLICITY_SOURCE}" ]; then
        SANITY_CHECK_ERRORS+=("${conf_file}: Source path missing")
    else
        for inc in "${DUPLICITY_SOURCE_INCLUDE[@]}"; do
            if ! [ -e "${DUPLICITY_SOURCE}/${inc}" ]; then
                SANITY_CHECK_ERRORS+=("${conf_file}: Included file '${DUPLICITY_SOURCE}/${inc}' does not exist")
            fi
        done
    fi
done

# If errors exist, list them and exit
if [ ${#SANITY_CHECK_ERRORS[@]} -ne 0 ]; then
    for err in "${SANITY_CHECK_ERRORS[@]}"; do
        echo "${err}"
    done
    exit 1
fi

###########################
####### Main script #######
###########################
for conf_file in "${DUPLICITEASY_CONFIG_DIR}"/*; do
    echo "Backing up ${DUPLICITY_SOURCE}"

    # Source configuration file
    load_config "${conf_file}"

    # Generate target string
    DUPLICITY_TARGET="${DUPLICITY_TARGET_SCHEME}://"
    if [ -n "${DUPLICITY_REMOTE_USER+x}" ]; then
        DUPLICITY_TARGET="${DUPLICITY_TARGET}${DUPLICITY_REMOTE_USER}@"
    fi
    if [ -n "${DUPLICITY_REMOTE_HOST+x}" ]; then
        DUPLICITY_TARGET="${DUPLICITY_TARGET}${DUPLICITY_REMOTE_HOST}/"
    fi
    DUPLICITY_TARGET="${DUPLICITY_TARGET}${DUPLICITY_REMOTE_PATH}"

    # Copy duplicity flags variable to preserve original
    DUPLICITY_FLAGS_EXT="${DUPLICITY_FLAGS}"

    # Generate log file flag
    if [ -n "${DUPLICITY_LOG_DIR}" ]; then
        DUPLICITY_LOG_FILE=$(sed -r 's/[\/\.@:]+/-/g' <<< "${DUPLICITY_TARGET}")
        DUPLICITY_FLAGS_EXT+=("--log-file" "${DUPLICITY_LOG_DIR}/${DUPLICITY_LOG_FILE}.log")
    fi

    # Generate key flags
    DUPLICITY_FLAGS_EXT+=("--sign-key" "${DUPLICITY_SIGN_KEY}")
    for enc_key in "${DUPLICITY_ENCRYPT_KEYS[@]}"; do
        DUPLICITY_FLAGS_EXT+=("--encrypt-key" "${enc_key}")
    done

    # Generate source include list
    for inc in "${DUPLICITY_SOURCE_INCLUDE[@]}"; do
        DUPLICITY_FLAGS_EXT+=("--include" "${DUPLICITY_SOURCE}/${inc}")
    done
    if [ ${#DUPLICITY_SOURCE_INCLUDE[@]} -ne 0 ]; then
        DUPLICITY_FLAGS_EXT+=("--exclude" "${DUPLICITY_SOURCE}")
    fi

    # Run duplicity
    duplicity "${DUPLICITY_FLAGS_EXT[@]}" "${DUPLICITY_SOURCE}" "${DUPLICITY_TARGET}"
done
