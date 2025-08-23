#!/bin/bash

set -exo pipefail

# Remove initialization sentinel and data, in case we are reinitializing.
rm -fr /mnt/data/*

# Remove addons dir, in case we are reinitializing after a previously
# failed installation.
rm -fr $ADDONS_DIR
# Download the repository at git reference into $ADDONS_DIR.
# We use curl instead of git clone because the git clone method used more than 1GB RAM,
# which exceeded the default pod memory limit.
mkdir -p $ADDONS_DIR
cd $ADDONS_DIR

set +x
echo "Cloning main repository https://github.com/${RUNBOAT_GIT_REPO}/tarball/${RUNBOAT_GIT_REF}"
curl -H "Authorization: Bearer $GITHUB_TOKEN" -sSL https://github.com/${RUNBOAT_GIT_REPO}/tarball/${RUNBOAT_GIT_REF} | tar zxf - --strip-components=1
set -x

if [ -f "external_repos.txt" ]; then # Download all external repositories listed in external_repos.txt
    echo "Processing external addon repositories"
    while IFS= read -r line; do
        if [[ -z "$line" || "$line" =~ ^# ]]; then
            continue
        fi

        EXTERNAL_REPO_URL=$(echo "$line" | awk '{print $1}')
        EXTERNAL_REPO_BRANCH=$(echo "$line" | awk '{print $2}')
        EXTERNAL_REPO_MODULES=$(echo "$line" | awk '{print $3}')
        EXTERNAL_REPO_PATH=$(echo "$EXTERNAL_REPO_URL" | sed -e 's|https://github.com/||g' -e 's|.git$||g')
        EXTERNAL_REPO_NAME=$(basename "$EXTERNAL_REPO_PATH")
        EXTERNAL_REPO_TEMP_DIR=$(mktemp -d -t odoo_external_repo_XXXXXX)

        if [ -z "$EXTERNAL_REPO_URL" ] || [ -z "$EXTERNAL_REPO_BRANCH" ]; then
            echo "Warning: Invalid line format in external_dependencies.txt: '$line' (Expected '[url] [branch] [modules]')" >&2
            continue
        fi

        echo "Using temporary directory for external repo processing: ${EXTERNAL_REPO_TEMP_DIR}"

        set +x
        echo "Cloning external repository https://github.com/${EXTERNAL_REPO_PATH}/tarball/${EXTERNAL_REPO_BRANCH} into ${EXTERNAL_REPO_TEMP_DIR}"
        curl -H "Authorization: Bearer $GITHUB_TOKEN" -sSL https://github.com/${EXTERNAL_REPO_PATH}/tarball/${EXTERNAL_REPO_BRANCH} | tar zxf - --strip-components=1 -C "${EXTERNAL_REPO_TEMP_DIR}"
        set -x

        if [ $? -ne 0 ]; then 
            echo "Error: Failed to download or extract tarball from https://github.com/${EXTERNAL_REPO_PATH}/tarball/${EXTERNAL_REPO_BRANCH}" >&2
            rm -rf "${EXTERNAL_REPO_TEMP_DIR}" # Clean up temp dir on error
            exit 1
        fi

        if [ -n "$EXTERNAL_REPO_MODULES" ]; then # Only filter if specific modules are listed
            echo "Filtering modules for repository: ${EXTERNAL_REPO_NAME}. Keeping only: ${EXTERNAL_REPO_MODULES}"
            (    cd "${EXTERNAL_REPO_TEMP_DIR}" || { echo "Error: Could not change directory to ${EXTERNAL_REPO_TEMP_DIR} for filtering." >&2; exit 1; }
                MODULES_TO_KEEP_SPACED=$(echo "$EXTERNAL_REPO_MODULES" | tr ',' ' ')

                declare -A keep_map
                for km in $MODULES_TO_KEEP_SPACED; do
                    keep_map["$km"]=1
                done

                set +x
                for dir in *; do
                    if [ -d "$dir" ] && [[ ! "$dir" =~ ^\. ]]; then
                        if [[ -z "${keep_map["$dir"]}" ]]; then
                            echo "  Removing unwanted module directory: ${EXTERNAL_REPO_TEMP_DIR}/${dir}"
                            rm -rf "$dir"
                        fi
                    fi
                done
                set -x
            ) || { echo "Error: Filtering modules in temporary directory failed." >&2; rm -fr "${EXTERNAL_REPO_TEMP_DIR}"; exit 1; }
        else
            echo "No specific modules listed for ${EXTERNAL_REPO_NAME}. Keeping all modules from this repository."
        fi


    done < "external_repos.txt"
else
    echo "No external_repos.txt found. Skipping downloading external repositories."
fi

set +x
for item in "${EXTERNAL_REPO_TEMP_DIR}"/*; do
    if [ -d "$item" ]; then # Check if it's a directory
    # Checks for __manifest__.py (Odoo 10+) or __openerp__.py (Odoo < 10) to confirm it's an Odoo module
        if [ -f "${item}/__manifest__.py" ] || [ -f "${item}/__openerp__.py" ]; then
            cp -r "$item" "${ADDONS_DIR}/" || { echo "Error: Failed to copy module $item to ADDONS_DIR." >&2; rm -fr "${TEMP_REPO_DIR}"; exit 1; }
        fi
    fi
done

# Clean up the temporary directory
echo "Cleaning up temporary directory: ${EXTERNAL_REPO_TEMP_DIR}"
rm -fr "${EXTERNAL_REPO_TEMP_DIR}"
set -x

# Install.
INSTALL_METHOD=${INSTALL_METHOD:-oca_install_addons}
if [[ "${INSTALL_METHOD}" == "oca_install_addons" ]] ; then
    oca_install_addons
elif [[ "${INSTALL_METHOD}" == "editable_pip_install" ]] ; then
    pip install -e .
else
    echo "Unsupported INSTALL_METHOD: '${INSTALL_METHOD}'"
    exit 1
fi

# Keep a copy of the venv that we can re-use for shorter startup time.
cp -ar /opt/odoo-venv/ /mnt/data/odoo-venv

touch /mnt/data/initialized
