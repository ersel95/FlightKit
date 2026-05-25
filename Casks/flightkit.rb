cask "flightkit" do
  version "1.0.4"
  sha256 "fa85131a19160d5ec7af8a9fb8a931c0692f7384a61903558c18d451737734a7"

  url "https://github.com/ersel95/FlightKit/releases/download/v#{version}/FlightKit-#{version}.dmg"
  name "FlightKit"
  desc "Menu-driven TestFlight & App Store publisher for iOS apps"
  homepage "https://github.com/ersel95/FlightKit"

  app "FlightKit.app"

  zap trash: [
    "~/Library/Application Support/FlightKit",
  ]
end
