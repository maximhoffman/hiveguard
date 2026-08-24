# typed: false
# frozen_string_literal: true

# Canonical Homebrew formula for hiveguard.
# The CI workflow (.github/workflows/bump-tap.yml) fills the url and sha256 from
# the pushed tag and publishes the result to the tap repo (maximhoffman/
# homebrew-hiveguard) as Formula/hiveguard.rb. Do not edit url/sha256 by hand.
class Hiveguard < Formula
  desc "Supply-chain safety for local dev on macOS — OSV scans + install-time gating"
  homepage "https://github.com/maximhoffman/hiveguard"
  url "__URL__"
  sha256 "__SHA256__"
  license "MIT"

  depends_on "jq"
  depends_on "osv-scanner"
  depends_on "python@3.14"

  def install
    # Ship the whole toolkit into libexec, preserving the bin/ layout the
    # dispatcher expects (it resolves siblings by path and its repo root as
    # the parent of its own directory).
    libexec.install "bin", "launchd", "README.md", "LICENSE"

    # Install-method marker + version, read by `hiveguard version`, doctor, and
    # the brew-aware `hiveguard update`.
    (libexec/"VERSION").write "version=#{version}\nmethod=brew\n"

    # Entry point: a wrapper that runs the real dispatcher with the dependency's
    # python3 on PATH (the report generation uses python3). $0 inside the real
    # script is the stable libexec path, which the resolver handles directly.
    (bin/"hiveguard").write_env_script libexec/"bin/hiveguard",
      PATH: "#{Formula["python@3.14"].opt_bin}:$PATH"
    bin.install_symlink "hiveguard" => "hvg"
  end

  def caveats
    <<~EOS
      The daily scan is NOT scheduled automatically. Turn it on — you choose the
      time and name the folders to scan (there is no whole-home default):
        hiveguard schedule on --hour 10 ~/Projects

      Catch-up: if your Mac is asleep or off at the scheduled time, the scan runs
      at the next wake or startup instead.

      Before `brew uninstall hiveguard`, run `hiveguard schedule off` and
      `hiveguard mark clear` — the launchd agent is not managed by brew services,
      and the Finder tags/state hiveguard placed on flagged folders would
      otherwise survive too. `hiveguard doctor` flags this (and other install
      issues).

      Migrating from the git install? Run:
        hiveguard doctor --fix
      to remove the old ~/bin symlinks and any stale launchd agent. Your
      ~/.hiveguard data (acks, cache, reports) carries over untouched.

      Optional extras:
        brew install gh                 # richer `hiveguard brew` changelogs
        brew install terminal-notifier  # desktop alerts on findings

      Install-time gating (bumblebee) is a separate upstream tool. To enable the
      shell guard, add to ~/.zshrc:
        source "#{opt_libexec}/bin/bumblebee-guard.sh"

      Want a terminal reminder when you cd into a project hiveguard flagged?
      Add the line `hiveguard mark hook` prints to ~/.zshrc the same way.
    EOS
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/hiveguard version")
    system bin/"hiveguard", "help"
  end
end
