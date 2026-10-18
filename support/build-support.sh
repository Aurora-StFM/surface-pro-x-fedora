#!/usr/bin/env bash
# Package the Fedora integration files as surface-pro-x-support (noarch).
set -euo pipefail
. "$(dirname "$0")/../lib/common.sh"

require_cmds rpmbuild rpmsign gpg

TOP="$WORK_DIR/rpmbuild-support"
rm -rf "$TOP"
mkdir -p "$TOP/SOURCES" "$RPM_DIR"
cp -r "$KIT_DIR"/support/files/. "$TOP/SOURCES/"
# rpmbuild looks up SourceN files by basename, so the UCM files go flat too.
cp "$KIT_DIR"/support/files/ucm/* "$TOP/SOURCES/"

msg "Packaging surface-pro-x-support RPM"
rpmbuild -bb --define "_topdir $TOP" "$KIT_DIR/support/surface-pro-x-support.spec"
rm -f "$RPM_DIR"/surface-pro-x-support-*.rpm
find "$TOP/RPMS" -name '*.rpm' -exec cp -t "$RPM_DIR" {} +
sign_rpms "$RPM_DIR"/surface-pro-x-support-*.rpm
msg "Done: $(ls "$RPM_DIR"/surface-pro-x-support-*.rpm)"
