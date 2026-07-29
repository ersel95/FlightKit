cask "flightkit" do
  version "1.0.18"
  sha256 "2f4fc81f243ebfe0f1aeb24b36ffc0ffdf76f3a38df26b717ea370dbd2844c2b"

  url "https://github.com/ersel95/FlightKit/releases/download/v#{version}/FlightKit-#{version}.dmg"
  name "FlightKit"
  desc "Menu-driven TestFlight & App Store publisher for iOS apps"
  homepage "https://github.com/ersel95/FlightKit"

  app "FlightKit.app"

  zap trash: [
    "~/Library/Application Support/FlightKit",
  ]
end
