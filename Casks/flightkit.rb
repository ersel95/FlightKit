cask "flightkit" do
  version "1.0.10"
  sha256 "a8f44a1644bcb45b1fcb26603b9c852cb0d977e664c3a2a3d03ca8b6e198be50"

  url "https://github.com/ersel95/FlightKit/releases/download/v#{version}/FlightKit-#{version}.dmg"
  name "FlightKit"
  desc "Menu-driven TestFlight & App Store publisher for iOS apps"
  homepage "https://github.com/ersel95/FlightKit"

  app "FlightKit.app"

  zap trash: [
    "~/Library/Application Support/FlightKit",
  ]
end
