cask "flightkit" do
  version "1.0.1"
  sha256 "ce46cfd0dd2f14c04184d9a4bbaab6dabe180781914f0796b834927551c12b21"

  url "https://github.com/ersel95/FlightKit/releases/download/v#{version}/FlightKit-#{version}.dmg"
  name "FlightKit"
  desc "Menu-driven TestFlight & App Store publisher for iOS apps"
  homepage "https://github.com/ersel95/FlightKit"

  app "FlightKit.app"

  zap trash: [
    "~/Library/Application Support/FlightKit",
  ]
end
