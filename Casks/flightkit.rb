cask "flightkit" do
  version "1.0.3"
  sha256 "820a2ac7eb71245027b902f04ecbef1d13a26acd0e9d079ba6e4cd16d0c85e9a"

  url "https://github.com/ersel95/FlightKit/releases/download/v#{version}/FlightKit-#{version}.dmg"
  name "FlightKit"
  desc "Menu-driven TestFlight & App Store publisher for iOS apps"
  homepage "https://github.com/ersel95/FlightKit"

  app "FlightKit.app"

  zap trash: [
    "~/Library/Application Support/FlightKit",
  ]
end
