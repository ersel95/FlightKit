cask "flightkit" do
  version "1.0.5"
  sha256 "45e661c643b2b38056c3c20ae8ab5545d362b91af6a7aa9ca40f72b96cd6e7a0"

  url "https://github.com/ersel95/FlightKit/releases/download/v#{version}/FlightKit-#{version}.dmg"
  name "FlightKit"
  desc "Menu-driven TestFlight & App Store publisher for iOS apps"
  homepage "https://github.com/ersel95/FlightKit"

  app "FlightKit.app"

  zap trash: [
    "~/Library/Application Support/FlightKit",
  ]
end
