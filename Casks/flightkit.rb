cask "flightkit" do
  version "1.0.17"
  sha256 "cf265f8932b2bc58b049297ba2b11958db83d9a52f1d4ac76f460c39013c80b5"

  url "https://github.com/ersel95/FlightKit/releases/download/v#{version}/FlightKit-#{version}.dmg"
  name "FlightKit"
  desc "Menu-driven TestFlight & App Store publisher for iOS apps"
  homepage "https://github.com/ersel95/FlightKit"

  app "FlightKit.app"

  zap trash: [
    "~/Library/Application Support/FlightKit",
  ]
end
