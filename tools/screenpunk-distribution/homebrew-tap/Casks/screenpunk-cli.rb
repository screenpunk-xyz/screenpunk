cask "screenpunk-cli" do
  version "1.0.2"
  sha256 "2a50c732bbff31ab330b1dd589f601b270db9216be8b641ed6e8b039f40c3749"

  url "https://github.com/screenpunk-xyz/homebrew-tap/releases/download/cli-v#{version}/Screenpunk-CLI-#{version}-arm64.dmg"
  name "Screenpunk CLI"
  desc "Offline-first Screenpunk CLI, MCP server, and user service"
  homepage "https://github.com/screenpunk-xyz/screenpunk"

  depends_on arch: :arm64
  depends_on macos: :sonoma

  # Vendor lifecycle commands need local broker/launchd IPC, which structured
  # flight-step sandboxes prohibit. Rearm only clears a removal fence; no
  # process is started and no kit or LaunchAgent is installed here.
  installer script: {
    executable: "#{staged_path}/Screenpunk CLI #{version}/bin/screenpunk",
    args:       ["package", "rearm"],
    sudo:       false,
  }
  binary "Screenpunk CLI #{version}/bin/screenpunk"
  binary "Screenpunk CLI #{version}/bin/screenpunk-mcp"

  # Uninstall scripts run before binary unlinking, including during upgrades.
  # Failure aborts removal while the package is still available for diagnosis.
  uninstall script: {
    executable: "#{staged_path}/Screenpunk CLI #{version}/bin/screenpunk",
    args:       ["package", "deactivate"],
    sudo:       false,
  }

  caveats <<~EOS
    Run `screenpunk setup` to choose or create your workspace. The first
    service request prepares the bundled offline kit and starts the user
    service. No additional installer or private software copy is needed.

    Use the same macOS account that installed this cask, without sudo.
    This Apple-silicon release supports Homebrew at /opt/homebrew.
    `brew upgrade --cask screenpunk-cli` and `brew uninstall --cask
    screenpunk-cli` stop the verified package service before removing files.
    User data, workspaces, installed kits, and Keychain entries are preserved.
  EOS
end
