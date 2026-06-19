cask "flightkit" do
  version "1.0.13"
  sha256 "8426012fde4e295914b9601b13ff60a006e9410dfeef7f80b2ec64b5fd0ce7fa"

  url "https://github.com/ersel95/FlightKit/releases/download/v#{version}/FlightKit-#{version}.dmg"
  name "FlightKit"
  desc "Menu-driven TestFlight & App Store publisher for iOS apps"
  homepage "https://github.com/ersel95/FlightKit"

  app "FlightKit.app"

  zap trash: [
    "~/Library/Application Support/FlightKit",
  ]
end
