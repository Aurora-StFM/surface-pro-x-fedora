# Build and update cheat sheet

Copy-paste blocks for rebuilding the kit and updating the Surface. The build
machine is any x86 or ARM PC with Fedora (native or WSL2); the examples use a
Fedora x86 PC with the kit in `~/surface-pro-x-fedora`.

## 1. One-time setup of a build PC

```bash
sudo dnf install -y git gh rsync
gh auth login            # GitHub.com → HTTPS → login with a web browser
gh auth setup-git
git config --global user.name "Aurora-StFM"
git config --global user.email "84717132+Aurora-StFM@users.noreply.github.com"

cd ~
gh repo clone Aurora-StFM/surface-pro-x-fedora surface-pro-x-fedora
cd surface-pro-x-fedora
./build.sh deps
```

**Signing key:** every RPM is signed with a local key in `out/signing/` (created
on the first build). Either copy `out/signing/` from your previous build PC
before building, or import the new key on the Surface once (section 5).

## 2. Bring in a new kit version (from a `.tar.gz`)

Only needed when the changes come as a kit archive instead of through git.
`--exclude .git --exclude out` keeps your git history and built files.

```bash
rm -rf /tmp/kit && mkdir /tmp/kit
tar -xzf ~/Downloads/surface-pro-x-fedora-kit.tar.gz -C /tmp/kit
rsync -a --delete --exclude .git --exclude out \
    /tmp/kit/surface-pro-x-fedora/ ~/surface-pro-x-fedora/
cd ~/surface-pro-x-fedora && git status --short
```

If the changes come as a patch file instead:

```bash
cd ~/surface-pro-x-fedora
git pull
git am ~/Downloads/0001-*.patch
```

## 3. Build

```bash
cd ~/surface-pro-x-fedora
./build.sh kernel        # kernel-spx (the slow one)
./build.sh support       # surface-pro-x-support
./build.sh firmware      # only when the firmware changed
ls -l out/rpms/
```

The version numbers come from `config.env` (`KERNEL_PKG_RELEASE`) and
`support/surface-pro-x-support.spec` (`Version:`).

## 4. Commit and push

```bash
cd ~/surface-pro-x-fedora
git add -A
git status --short
git commit -m "Short description of the change"
git push
```

`out/` is in `.gitignore`, so built RPMs and the signing key are never committed.

## 5. Install on the Surface

Copy the new RPMs from `out/rpms/` to the Surface (USB stick, or e.g.
`scp out/rpms/*.rpm spx@<surface-ip>:~/Downloads/`), then on the Surface:

```bash
cd ~/Downloads
sudo dnf install ./kernel-spx-*.rpm ./surface-pro-x-support-*.rpm
sudo reboot
```

After the reboot:

```bash
uname -r                 # should show the new kernel-spx release
rpm -q surface-pro-x-support
```

Only when the build PC made a new signing key (once):

```bash
sudo rpm --import RPM-GPG-KEY-surface-pro-x-local   # from out/signing/
```

## 6. After every boot (until audio starts by itself)

```bash
~/start-audio.sh         # or tools/start-audio.sh from the kit
```

## If the new kernel doesn't boot

Pick the previous kernel in the GRUB menu (older kernel-spx entries stay
installed). Once booted, remove the broken one:

```bash
rpm -q kernel-spx
sudo dnf remove kernel-spx-<broken version>
```
